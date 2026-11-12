#!/usr/bin/env bash
# Tests for the orchestrator scripts, against the superset and gh shims in test/bin (no Paradev
# host or GitHub needed). Runs on macOS bash 3.2 (BSD date) and Linux bash 5 (GNU date):
#
#   bash scripts/test/run.sh
#   docker run --rm -v "$PWD":/w -w /w debian:bookworm-slim sh -c \
#     'apt-get update -qq && apt-get install -qq -y jq git >/dev/null && bash scripts/test/run.sh'
set -uo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd)
scripts=$(dirname "$test_dir")
export PATH="$test_dir/bin:$PATH" RETRY_DELAY=0 PARADEV_HOST_DB=/nonexistent/host.db
pass=0 fail=0

ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n     expected: %s\n     got:      %s\n' "$1" "$2" "$3"; }
# expect <name> <actual> <substring>
expect() { if [[ $2 == *"$3"* ]]; then ok "$1"; else bad "$1" "*$3*" "$2"; fi; }
expect_not() { if [[ $2 != *"$3"* ]]; then ok "$1"; else bad "$1" "no $3" "$2"; fi; }
expect_exit() { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1" "exit $3" "exit $2"; fi; }

# ISO timestamp <minutes> ago, BSD or GNU date.
ago() {
  date -u -v-"$1"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "-$1 min" +%Y-%m-%dT%H:%M:%SZ
}

# A fresh HOME, fixtures dir and git repo per test.
sandbox() {
  root=$(mktemp -d "${TMPDIR:-/tmp}/orch-test.XXXXXX")
  export HOME="$root/home" FIX="$root/fix" SUPERSET_TERMINAL_ID=me
  mkdir -p "$HOME" "$FIX/screens" "$root/repo"
  cd "$root/repo" && git init -q && git remote add origin https://github.com/acme/app.git
  plan="$HOME/.agents/orchestrator/acme-app.json"
  mkdir -p "$(dirname "$plan")"
  echo '[]' >"$FIX/workspaces.json"
}

# snapshot <workspace> <terminal> <agent-state> [owner-terminal]
snapshot() {
  jq -n --arg w "$1" --arg t "$2" --arg s "$3" --arg o "${4:-}" '{workspaces: [
    {id: $w, terminals: [{id: $t, agent: {id: "claude", state: $s}}]},
    {id: "orch", terminals: (if $o == "" then [] else [{id: $o, agent: {id: "codex", state: "working"}}] end)}]}' \
    >"$FIX/snapshot.json"
}

# plan_with <items-json> [extra-object]
plan_with() {
  jq -n --argjson items "$1" --argjson extra "${2:-null}" --arg beat "$(ago 1)" \
    '{repo: "acme/app", runId: "20261112-1200", status: "active", owner: "me", heartbeat: $beat,
      items: $items} + ($extra // {})' >"$plan"
}

item() { # item <id> <state> <workspace> <terminal> [reason]
  jq -nc --arg id "$1" --arg s "$2" --arg w "$3" --arg t "$4" --arg r "${5:-}" \
    '{id: $id, state: $s, workspace: (if $w == "" then null else $w end), branch: "b-\($id)",
      terminal: (if $t == "" then null else $t end), reason: (if $r == "" then null else $r end)}'
}

ws() { # ws <id> <branch> <tag>
  jq --arg id "$1" --arg b "$2" --arg tag "$3" '. + [{id: $id, name: $id, branch: $b, tags: $tag}]' \
    "$FIX/workspaces.json" >"$FIX/w.tmp" && mv "$FIX/w.tmp" "$FIX/workspaces.json"
}

status() { "$scripts/status.sh" "$@" proj "$plan"; }

# --- stalled agent: same screen for STALL_MINUTES while Paradev says working -----------------
sandbox
plan_with "[$(item '#1' in-progress w1 t1)]"
ws w1 b-#1 "In Progress"; snapshot w1 t1 working
printf 'Working on it\n' >"$FIX/screens/t1"
expect "stall: first look is working" "$(status --compact)" "#1 | In Progress | working"
screens="$HOME/.agents/orchestrator/screens/20261112-1200.json"
jq --argjson old $(($(date +%s) - 16 * 60)) '.t1.since = $old' "$screens" >"$screens.tmp" && mv "$screens.tmp" "$screens"
out=$(status)
expect "stall: unchanged 16 minutes is stalled" "$out" '"state":"stalled"'
expect "stall: reason says how long" "$out" "unchanged for 16 minutes"
printf 'Working on it\nnew output\n' >"$FIX/screens/t1"
expect "stall: a changed screen is working again" "$(status)" '"state":"working"'
snapshot w1 t1 idle
jq --argjson old $(($(date +%s) - 60 * 60)) '.t1.since = $old' "$screens" >"$screens.tmp" && mv "$screens.tmp" "$screens"
expect "stall: idle is never stalled" "$(status)" '"state":"idle"'

# --- fatal banner: usage limit while Paradev still says working ------------------------------
sandbox
plan_with "[$(item '#2' in-progress w2 t2)]"
ws w2 b-#2 "In Progress"; snapshot w2 t2 working
printf '%s\n' "• Running tests" "  ■ You've hit your usage limit. Upgrade to Pro or try again in 3 hours." "" "› " >"$FIX/screens/t2"
out=$(status)
expect "banner: usage limit is blocked" "$out" '"state":"blocked"'
expect "banner: reason is the line" "$out" "You've hit your usage limit"
printf '%s\n' "Implemented rate limiting middleware" "All tests pass" >"$FIX/screens/t2"
expect "banner: ordinary text is not a banner" "$(status)" '"state":"working"'
printf '%s\n' "ORCHESTRATOR_WORKER_DONE" "item: #2" "summary: return 429 when the rate limit exceeded" "" >"$FIX/screens/t2"
expect "banner: a worker block's summary is not a banner" "$(status)" '"state":"working"'

# --- worker block, wrapped checked: line ------------------------------------------------------
sandbox
plan_with "[$(item '#3' in-progress w3 t3)]"
ws w3 b-#3 "In Progress"; snapshot w3 t3 idle
cat >"$FIX/screens/t3" <<'EOF'
⏺ ORCHESTRATOR_WORKER_DONE
  item: #3
  pr: https://github.com/acme/app/pull/9
  summary: Added CSV export
  checked: ran the export on the sample data and compared
  it with the fixture

────────────────────────────
❯
EOF
out=$(status)
expect "worker: marker" "$out" '"marker":"done"'
expect "worker: wrapped checked rejoined" "$out" '"checked":"ran the export on the sample data and compared it with the fixture"'
expect "worker: compact shows checked" "$(status --compact)" "worker done, checked: ran the export"

# --- worker replaced: terminal differs from the plan's ---------------------------------------
sandbox
plan_with "[$(item '#4' in-progress w4 t-old)]"
ws w4 b-#4 "In Progress"; snapshot w4 t-new working
echo hi >"$FIX/screens/t-new"
expect "replaced: compact names the new terminal" "$(status --compact)" "terminal t-new (claude)"
expect "replaced: JSON follows the new terminal" "$(status)" '"terminal":"t-new","id":"claude"'
plan_with "[$(item '#4' in-progress w4 t-new)]"
expect_not "replaced: no note once the plan has it" "$(status --compact)" "terminal t-new"

# --- groups: the plan's map wins, and missing tags are reported ------------------------------
sandbox
plan_with "[$(item '#5' in-review w5 t5)]" '{"groups": {"In Review": "new group-6"}}'
ws w5 b-#5 "new group-6"; snapshot w5 t5 idle; echo x >"$FIX/screens/t5"
expect "groups: plan map gives the group" "$(status --compact)" "#5 | In Review"
expect "groups: plan subcommand prints it" "$("$scripts/groups.sh" proj plan "$plan")" '"In Review":"new group-6"'
"$scripts/groups.sh" proj >/dev/null; expect_exit "groups: no saved map exits 2" $? 2
out=$("$scripts/groups.sh" proj check '{"In Progress":"In Progress","In Review":"new group-6","Done":"done","Blocked":"old blocked"}')
code=$?
expect_exit "groups: a missing tag exits 5" $code 5
expect "groups: names the missing tag" "$out" '{"Blocked":"old blocked"}'
"$scripts/groups.sh" proj check '{"In Review":"new group-6","Blocked":"Blocked"}' >/dev/null
expect_exit "groups: carried or own-name tags pass" $? 0
if command -v sqlite3 >/dev/null; then
  sqlite3 "$root/host.db" "CREATE TABLE tag_folder_settings (scope, tag, display_name, tab_order, updated_at);
    INSERT INTO tag_folder_settings VALUES ('proj', 'new group-9', 'blocked', 1, 0);"
  PARADEV_HOST_DB="$root/host.db" "$scripts/groups.sh" proj check '{"Blocked":"new group-9"}' >/dev/null
  expect_exit "groups: a folder with no workspaces passes" $? 0
fi

# --- ownership: live vs stale, and forced takeover (macOS and GNU date parsing) ----------------
sandbox
plan_with "[$(item '#6' in-progress w6 t6)]" "{\"owner\": \"orch-1\", \"heartbeat\": \"$(ago 2)\"}"
snapshot w6 t6 working orch-1
expect "owner: fresh heartbeat and live terminal is other" "$("$scripts/plan.sh" check)" other
plan_with "[$(item '#6' in-progress w6 t6)]" "{\"owner\": \"orch-1\", \"heartbeat\": \"$(ago 50)\"}"
expect "owner: 50-minute-old heartbeat is stale" "$("$scripts/plan.sh" check)" stale
plan_with "[$(item '#6' in-progress w6 t6)]" "{\"owner\": \"orch-1\", \"heartbeat\": \"$(ago 2)\"}"
snapshot w6 t6 working
expect "owner: terminal gone is stale" "$("$scripts/plan.sh" check)" stale
snapshot w6 t6 working orch-1
"$scripts/plan.sh" claim --takeover >/dev/null; expect_exit "takeover: live owner refuses" $? 3
out=$("$scripts/plan.sh" claim --takeover --force); code=$?
expect_exit "takeover: --force succeeds" $code 0
expect "takeover: says forced" "$out" "taken over from orch-1 (forced)"
expect "takeover: records takenOverFrom and forcedAt" "$(jq -c '{owner, takenOverFrom, f: (.forcedAt != null)}' "$plan")" \
  '{"owner":"me","takenOverFrom":"orch-1","f":true}'

# --- close with carry-over, then the next claim surfaces it --------------------------------------
sandbox
plan_with "[$(item '#7' done w7 t7), $(item '#8' blocked w8 t8 'usage limit'), $(item '#9' waiting '' '' 'waiting on #8')]"
out=$("$scripts/plan.sh" close)
expect "close: carry-over lists unfinished items" "$out" '{"id":"#8","state":"blocked","reason":"usage limit"}'
expect_not "close: done items stay out" "$out" '#7'
expect "close: status finished" "$(jq -r .status "$plan")" finished
out=$("$scripts/plan.sh" claim)
expect "close: next claim is free" "$out" free
expect "close: next claim shows the carry-over" "$out" '"carryOver":[{"id":"#8"'
expect "close: plan moved to history" "$(ls "$HOME/.agents/orchestrator/history")" "acme-app-20261112-1200.json"

# --- wait-change prints one line --------------------------------------------------------------
sandbox
plan_with "[$(item '#10' in-progress w10 t10)]"
ws w10 b-#10 "In Progress"; snapshot w10 t10 working; echo x >"$FIX/screens/t10"
POLL_SECONDS=1 "$scripts/wait-change.sh" proj "$plan" 20 >"$root/out" 2>&1 &
waiter=$!
sleep 2; snapshot w10 t10 idle
wait $waiter
out=$(cat "$root/out")
expect "wait: one-line summary" "$out" "changed: #10 agent working->idle"
expect_exit "wait: single line" "$(wc -l <"$root/out" | tr -d ' ')" 1

echo
echo "$pass passed, $fail failed (bash $BASH_VERSION, $(uname -s))"
((fail == 0))
