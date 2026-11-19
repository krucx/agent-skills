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
unset ORCA_TERMINAL_HANDLE ORCA_WORKSPACE_ID ORCA_CLI_COMMAND  # tests pick their backend themselves
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
  root=$(mktemp -d "${TMPDIR:-/tmp}/issue-76-orchestrator-preserve-integration-carry.XXXXXX")
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

# --- plan creation: runId comes from one captured start time, not the model --------------------
sandbox
jq -n '{repo: "acme/app", runId: "1200", status: "active", items: []}' >"$root/next.json"
"$scripts/plan.sh" write "$root/next.json" >/dev/null
started_at=$(jq -r .startedAt "$plan")
expected_run_id=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$started_at" +%Y%m%d-%H%M 2>/dev/null ||
  date -u -d "$started_at" +%Y%m%d-%H%M)
expect_not "plan creation: records a UTC start timestamp" "$started_at" "null"
expect "plan creation: runId is derived from startedAt" "$(jq -r .runId "$plan")" "$expected_run_id"
expect_not "plan creation: caller runId ignored" "$(jq -r .runId "$plan")" "1200"
run_id=$(jq -r .runId "$plan")
started_at=$(jq -r .startedAt "$plan")
jq '.runId = "model-override"' "$plan" >"$root/next.json"
"$scripts/plan.sh" write "$root/next.json" >/dev/null
expect "plan update: runId preserved against override" "$(jq -r .runId "$plan")" "$run_id"
expect "plan update: startedAt preserved" "$(jq -r .startedAt "$plan")" "$started_at"

# --- existing plan identity survives resume and takeover ---------------------------------------
sandbox
plan_with '[]' '{"startedAt":"2026-11-12T20:15:03Z","runId":"20261112-2015","owner":"me"}'
"$scripts/plan.sh" claim >/dev/null
expect "resume: preserves runId" "$(jq -r .runId "$plan")" "20261112-2015"
expect "resume: preserves startedAt" "$(jq -r .startedAt "$plan")" "2026-11-12T20:15:03Z"

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

# --- worker block: criteria and unmet lines ----------------------------------------------------
sandbox
plan_with "[$(item '#16' in-progress w16 t16)]"
ws w16 b-#16 "In Progress"; snapshot w16 t16 idle
cat >"$FIX/screens/t16" <<'EOF'
⏺ ORCHESTRATOR_WORKER_DONE
  item: #16
  pr: https://github.com/acme/app/pull/16
  summary: Added CSV export
  checked: ran the export, 3/3 checks green
  criteria: 4/5
    unmet: "export is streamed" not verifiable, no large
    fixture to test with
    unmet: "docs updated" not met, ran out of time

────────────────────────────
❯
EOF
out=$(status)
expect "criteria: met" "$out" '"met":4'
expect "criteria: total" "$out" '"total":5'
expect "criteria: unmet lines, wrapped one rejoined" "$out" '"unmet":["\"export is streamed\" not verifiable, no large fixture to test with","\"docs updated\" not met, ran out of time"]'
expect "criteria: compact" "$(status --compact)" "criteria 4/5, 2 unmet"
printf '%s\n' "RUNWAVES_WORKER_DONE" "item: #16" "pr: https://github.com/acme/app/pull/16" "summary: done" "checked: all" "criteria: 3/3" "" >"$FIX/screens/t16"
expect "criteria: all met has no unmet" "$(status)" '"criteria":{"met":3,"total":3,"unmet":[]}'
expect "criteria: all met compact" "$(status --compact)" "criteria 3/3"
expect_not "criteria: all met compact has no unmet count" "$(status --compact)" "unmet"
printf '%s\n' "ORCHESTRATOR_WORKER_DONE" "item: #16" "pr: https://github.com/acme/app/pull/16" "summary: done" "checked: all" "" >"$FIX/screens/t16"
expect "criteria: absent is null" "$(status)" '"criteria":null'
printf '%s\n' "ORCHESTRATOR_WORKER_DONE" "item: #16" "pr: https://github.com/acme/app/pull/16" "summary: done" "checked: all" "criteria: <met>/<total>" "  unmet: <a criterion not met>" "" >"$FIX/screens/t16"
expect "criteria: the template placeholder is not a report" "$(status)" '"worker":null'

# --- worker block: the prompt's placeholder template is not a report --------------------------
sandbox
plan_with "[$(item '#13' in-progress w13 t13)]"
ws w13 b-#13 "In Progress"; snapshot w13 t13 working
printf '%s\n' "Finish your last message with exactly one of:" "ORCHESTRATOR_WORKER_BLOCKED" "item: #13" "reason: <what stops you>" "needs: <the decision or access required>" "" >"$FIX/screens/t13"
out=$(status)
expect "placeholder: template block is not a worker result" "$out" '"worker":null'
printf '%s\n' "ORCHESTRATOR_WORKER_BLOCKED" "item: #13" "reason: <what stops you>" "needs: <the decision or access required>" "" "Working..." "ORCHESTRATOR_WORKER_BLOCKED" "item: #13" "reason: no push access" "needs: write access to the repo" "" >"$FIX/screens/t13"
out=$(status)
expect "placeholder: a real block after the template is detected" "$out" '"reason":"no push access"'
printf '%s\n' "On a second hit, print ORCHESTRATOR_WORKER_BLOCKED and stop." "reason: the tests fail" "" >"$FIX/screens/t13"
expect "worker: marker mid-sentence is not a block" "$(status)" '"worker":null'

# --- worker block: a declared wait, then superseded by DONE ----------------------------------
sandbox
plan_with "[$(item '#14' in-progress w14 t14)]"
ws w14 b-#14 "In Progress"; snapshot w14 t14 idle
printf '%s\n' "⏺ ORCHESTRATOR_WORKER_WAITING" "  item: #14" "  waiting-on: three code-review subagents" \
  "  resumes-when: they report back" "" >"$FIX/screens/t14"
out=$(status)
expect "waiting: marker" "$out" '"marker":"waiting"'
expect "waiting: waiting-on" "$out" '"waitingOn":"three code-review subagents"'
expect "waiting: resumes-when" "$out" '"resumesWhen":"they report back"'
expect "waiting: compact names the wait" "$(status --compact)" "worker waiting, on: three code-review subagents"
printf '%s\n' "ORCHESTRATOR_WORKER_WAITING" "item: #14" "waiting-on: <what you are waiting for>" \
  "resumes-when: <what ends the wait>" "" >"$FIX/screens/t14"
expect "waiting: the prompt's placeholder is not a report" "$(status)" '"worker":null'
printf '%s\n' "ORCHESTRATOR_WORKER_WAITING" "item: #14" "waiting-on: CI" "resumes-when: checks finish" "" \
  "ORCHESTRATOR_WORKER_DONE" "item: #14" "pr: https://github.com/acme/app/pull/14" "summary: done" "" >"$FIX/screens/t14"
out=$(status)
expect "waiting: a later DONE replaces it" "$out" '"marker":"done"'
expect_not "waiting: no waiting-on left from the wait" "$out" "waitingOn"
printf '%s\n' "ORCHESTRATOR_WORKER_WAITING" "item: #14" "waiting-on: CI" "resumes-when: checks finish" "" \
  "ORCHESTRATOR_WORKER_BLOCKED" "item: #14" "reason: CI runner offline" "needs: a runner" "" >"$FIX/screens/t14"
expect "waiting: a later BLOCKED replaces it" "$(status)" '"marker":"blocked"'
snapshot w14 t14 working
printf '%s\n' "ORCHESTRATOR_WORKER_WAITING" "item: #14" "waiting-on: CI" "resumes-when: checks finish" "" \
  "  ■ You've hit your usage limit. Try again in 3 hours." "" >"$FIX/screens/t14"
expect "waiting: a fatal banner still blocks a waiting worker" "$(status)" '"state":"blocked"'

# --- worker block: a wait declared WAIT_MINUTES ago goes stale --------------------------------
sandbox
plan_with "[$(item '#15' in-progress w15 t15)]"
ws w15 b-#15 "In Progress"; snapshot w15 t15 idle
printf '%s\n' "ORCHESTRATOR_WORKER_WAITING" "item: #15" "waiting-on: CI" "resumes-when: checks finish" "" >"$FIX/screens/t15"
expect_not "stale wait: fresh wait is not stale" "$(status)" '"stale"'
screens="$HOME/.agents/orchestrator/screens/20261112-1200.json"
jq --argjson old $(($(date +%s) - 31 * 60)) '.t15.wait.since = $old' "$screens" >"$screens.tmp" && mv "$screens.tmp" "$screens"
printf '%s\n' "ORCHESTRATOR_WORKER_WAITING" "item: #15" "waiting-on: CI" "resumes-when: checks finish" "" "✻ Idle" >"$FIX/screens/t15"
out=$(status)
expect "stale wait: the same wait 31 minutes on is stale" "$out" '"stale":true'
expect "stale wait: compact says to check the screen" "$(status --compact)" "stale wait (31 minutes)"
printf '%s\n' "ORCHESTRATOR_WORKER_WAITING" "item: #15" "waiting-on: the review subagents" "resumes-when: they report" "" >"$FIX/screens/t15"
expect_not "stale wait: a new wait starts the clock again" "$(status)" '"stale"'

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

# --- write: pr must be a URL string (or null), never a bare number ---------------------------------
sandbox
plan_with "[$(item '#5' in-progress w5 t5)]"
for bad_pr in 388 '"388"' '"#388"'; do
  jq --argjson pr "$bad_pr" '.items[0].pr = $pr' "$plan" >"$root/next.json"
  out=$("$scripts/plan.sh" write "$root/next.json" 2>&1); code=$?
  expect_exit "write: item pr $bad_pr is rejected" $code 1
  expect "write: names the item and wants a URL" "$out" "#5: pr must be a PR URL"
done
jq '.integrations = [{id: "F1", pr: 12}]' "$plan" >"$root/next.json"
out=$("$scripts/plan.sh" write "$root/next.json" 2>&1); code=$?
expect_exit "write: integration pr number is rejected" $code 1
expect "write: names the integration" "$out" "F1: pr must be a PR URL"
jq '.items[0].pr = "https://github.com/acme/app/pull/388" | .integrations = [{id: "F1", pr: null}]' "$plan" >"$root/next.json"
"$scripts/plan.sh" write "$root/next.json" >/dev/null 2>&1
expect_exit "write: URL and null pass" $? 0
expect "write: URL is stored" "$(jq -r '.items[0].pr' "$plan")" "https://github.com/acme/app/pull/388"
jq '.items += [.items[0]]' "$plan" >"$root/next.json"
out=$("$scripts/plan.sh" write "$root/next.json" 2>&1); code=$?
expect_exit "write: a duplicate item id is rejected" $code 1
expect "write: names the id" "$out" "#5: item id used 2 times"

# --- events log and criteria ------------------------------------------------------------------------
sandbox
plan_with "[$(item '#5' in-progress w5 t5)]" '{"owner": "me", "heartbeat": "2026-11-12T20:00:00Z"}'
"$scripts/plan.sh" event '#5' dispatched "workspace w5" >/dev/null; expect_exit "event: appends" $? 0
"$scripts/plan.sh" event null waiting "quiet" >/dev/null
expect "event: entry fields" "$(jq -c '.events[0] | {item, action, detail}' "$plan")" '{"item":"#5","action":"dispatched","detail":"workspace w5"}'
expect "event: null item" "$(jq -c '.events[1].item' "$plan")" null
out=$("$scripts/plan.sh" event '#5' bogus x 2>&1); expect_exit "event: unknown action refused" $? 1
expect "event: names the action" "$out" "bogus"
expect "events: all, one line each" "$("$scripts/plan.sh" events | wc -l | tr -d ' ')" 2
expect "events: --since filters" "$("$scripts/plan.sh" events --since 2999-01-01T00:00:00Z | wc -l | tr -d ' ')" 0
expect "events: --since keeps later entries" "$("$scripts/plan.sh" events --since 2000-01-01T00:00:00Z | wc -l | tr -d ' ')" 2
SUPERSET_TERMINAL_ID=other "$scripts/plan.sh" event '#5' blocked x >/dev/null 2>&1
expect_exit "event: non-owner exits 3" $? 3
jq '.events += [{at: "2026-11-12T20:00:00Z", item: "#5", action: "nope", detail: "x"}]' "$plan" >"$root/next.json"
out=$("$scripts/plan.sh" write "$root/next.json" 2>&1); expect_exit "write: bad event rejected" $? 1
expect "write: names the event index" "$out" "events[2]"
jq '.events[0] |= del(.detail)' "$plan" >"$root/next.json"
out=$("$scripts/plan.sh" write "$root/next.json" 2>&1); expect "write: missing field names index" "$out" "events[0]"
for bad_c in '{"met":3,"total":2,"unmet":[]}' '{"met":1.5,"total":2,"unmet":[]}' '{"met":1,"total":2,"unmet":"x"}'; do
  jq --argjson c "$bad_c" '.items[0].criteria = $c' "$plan" >"$root/next.json"
  out=$("$scripts/plan.sh" write "$root/next.json" 2>&1); code=$?
  expect_exit "write: criteria $bad_c rejected" $code 1
  expect "write: names the item" "$out" "#5: criteria"
done
jq '.items[0].criteria = {met: 1, total: 2, unmet: ["b"]}' "$plan" >"$root/next.json"
"$scripts/plan.sh" write "$root/next.json" >/dev/null 2>&1; expect_exit "write: valid criteria passes" $? 0
jq '.items[0].criteria = null' "$plan" >"$root/next.json"
"$scripts/plan.sh" write "$root/next.json" >/dev/null 2>&1; expect_exit "write: null criteria passes" $? 0
"$scripts/plan.sh" close >/dev/null
expect "close: appends closed event" "$(jq -r '.events[-1].action' "$plan")" closed
sandbox
plan_with "[$(item '#5' in-progress w5 t5)]" '{"owner": "orch-1", "heartbeat": "2026-01-01T00:00:00Z"}'
"$scripts/plan.sh" claim --takeover --force >/dev/null
expect "takeover: appends taken-over with previous owner" "$(jq -c '.events[-1] | {action, detail}' "$plan")" 'taken-over","detail":"taken over from orch-1'
expect "takeover: preserves runId" "$(jq -r .runId "$plan")" "20261112-1200"

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

# --- close carries integration state into the next run's claim ---------------------------------
sandbox
plan_with '[{"id":"#20","state":"done","integration":"F1"},{"id":"#21","state":"blocked","reason":"needs review","integration":"F1"}]' \
  '{"integrations":[{"id":"F1","title":"CSV","branch":"feature/csv","base":"main","state":"open","pr":"https://github.com/acme/app/pull/50"},{"id":"F2","branch":"feature/old","base":"main","state":"merged"}]}'
out=$("$scripts/plan.sh" close)
expect "close integration: preserves unfinished item carry-over" "$out" '{"id":"#21","state":"blocked","reason":"needs review"}'
out=$("$scripts/plan.sh" claim)
carry=$(tail -n1 <<<"$out")
expect "claim integration: offers branch and base" "$(jq -c '.integrationCarryOver[0].integration | {id, branch, base}' <<<"$carry")" '{"id":"F1","branch":"feature/csv","base":"main"}'
expect "claim integration: carries participating item states" "$(jq -c '[.integrationCarryOver[0].items[] | {id, state}]' <<<"$carry")" '[{"id":"#20","state":"done"},{"id":"#21","state":"blocked"}]'
expect_not "claim integration: omits merged integration" "$out" 'feature/old'

# --- conflicting stacked PR: one filtered gh call marks it, with its base ---------------------
sandbox
plan_with "[$(item '#11' in-review w11 t11), $(item '#12' in-review w12 t12)]"
ws w11 b-#11 "In Review"; ws w12 b-#12 "In Review"; snapshot w11 t11 idle
echo x >"$FIX/screens/t11"
cat >"$FIX/prs.json" <<'EOF2'
[{"headRefName":"b-#11","number":21,"url":"u21","state":"OPEN","isDraft":false,"baseRefName":"b-#10","mergeable":"CONFLICTING"},
 {"headRefName":"b-#12","number":22,"url":"u22","state":"OPEN","isDraft":false,"baseRefName":"main","mergeable":"MERGEABLE"}]
EOF2
out=$(status)
expect "conflict: stacked PR is flagged" "$out" '"number":21,"url":"u21","state":"OPEN","isDraft":false,"conflicting":true,"base":"b-#10"'
expect_not "conflict: mergeable PR is not" "$out" '"number":22,"url":"u22","state":"OPEN","isDraft":false,"conflicting"'
expect "conflict: compact shows base" "$(status --compact)" "PR #21 OPEN CONFLICTING (base b-#10)"

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

# --- wait-change wakes on agents wait, polls for the rest ------------------------------------
# The poll is 30s, so anything seen within a few seconds came from `agents wait`.
wait_run() { # wait_run <timeout> -> out, elapsed
  local t0=$SECONDS
  POLL_SECONDS=${POLL:-30} "$scripts/wait-change.sh" proj "$plan" "$1" >"$root/out" 2>&1; code=$?
  out=$(cat "$root/out"); elapsed=$((SECONDS - t0))
}
wait_sandbox() {
  sandbox
  plan_with "[$(item '#10' in-progress w10 t10)]"
  ws w10 b-#10 "In Progress"; snapshot w10 t10 working; echo x >"$FIX/screens/t10"
}

wait_sandbox
(sleep 2; snapshot w10 t10 idle) &
wait_run 60
expect "wait agents: settle wakes before the poll" "$out" "changed: #10 agent working->idle"
expect_exit "wait agents: exit 0" $code 0
((elapsed < 10)) && ok "wait agents: woke in ${elapsed}s" || bad "wait agents: woke early" "<10s" "${elapsed}s"
sleep 0.3
expect_exit "wait agents: no orphaned waiters after a change" \
  "$(awk '{print $1}' "$FIX/agents-wait.log" | while read -r p; do kill -0 "$p" 2>/dev/null && echo alive; done | wc -l | tr -d ' ')" 0

wait_sandbox
(sleep 1; echo '[{"headRefName": "b-#10", "number": 5, "url": "u5", "state": "OPEN", "isDraft": false}]' >"$FIX/prs.json") &
POLL=2 wait_run 30
expect "wait agents: PR change without an agent change is polled" "$out" "changed: #10 pr none->OPEN"
sleep 0.3
expect_exit "wait agents: no orphaned waiters after a PR change" \
  "$(awk '{print $1}' "$FIX/agents-wait.log" | while read -r p; do kill -0 "$p" 2>/dev/null && echo alive; done | wc -l | tr -d ' ')" 0

wait_sandbox
POLL=2 wait_run 4
expect "wait agents: timeout still prints timeout" "$out" "timeout"
expect_exit "wait agents: timeout exit 0" $code 0
sleep 0.3
expect_exit "wait agents: no orphaned waiters after timeout" \
  "$(awk '{print $1}' "$FIX/agents-wait.log" | while read -r p; do kill -0 "$p" 2>/dev/null && echo alive; done | wc -l | tr -d ' ')" 0

# old CLI: no agents wait, the poll still sees the change
wait_sandbox; touch "$FIX/no-agents-wait"
(sleep 1; snapshot w10 t10 idle) &
POLL=2 wait_run 30
expect "wait fallback: poll sees the change" "$out" "changed: #10 agent working->idle"
[[ ! -f $FIX/agents-wait.log ]] && ok "wait fallback: no agents wait started" || bad "wait fallback" "no waiters" "$(cat "$FIX/agents-wait.log")"

# interrupt: waiters die with the waiter
wait_sandbox
POLL_SECONDS=30 "$scripts/wait-change.sh" proj "$plan" 60 >/dev/null 2>&1 &
waiter=$!
sleep 3; kill -INT $waiter 2>/dev/null; wait $waiter 2>/dev/null; sleep 0.5
expect_exit "wait agents: no orphaned waiters after interrupt" \
  "$(awk '{print $1}' "$FIX/agents-wait.log" | while read -r p; do kill -0 "$p" 2>/dev/null && echo alive; done | wc -l | tr -d ' ')" 0

# --- dispatch: branch collisions, recording, and rollback --------------------------------------
dispatch_sandbox() { # a bare "origin" the sandbox repo's github URL is redirected to
  sandbox
  git init -q --bare "$root/origin.git"
  git config url."file://$root/origin.git".insteadOf https://github.com/acme/app.git
  git config user.email t@t; git config user.name t
  plan=$("$scripts/plan.sh" path)  # the rewritten origin URL changes the plan's name
  git commit -q --allow-empty -m init
  plan_with "[$(jq -nc '{id: "#20", title: "Add CSV export, please!", state: "queued", branch: null, workspace: null, terminal: null, skill: "implement", agent: "claude"}'), $(item '#21' queued '' '')]" \
    '{"groups": {"In Progress": "wip"}}'
  snapshot w-new t-new working
}
dispatch() { "$scripts/dispatch.sh" proj "$plan" '#20' "$@"; }
plan_item() { jq -c '.items[] | select(.id == "#20") | {state, branch, workspace, terminal, reason, f: .dispatchFailures}' "$plan"; }

dispatch_sandbox
out=$(dispatch 2>&1); code=$?
expect_exit "dispatch: success exits 0" $code 0
expect "dispatch: one summary line" "$out" "dispatched #20 -> issue-20-add-csv-export-please (workspace w-new, terminal t-new)"
expect_exit "dispatch: output is one line" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 1
expect "dispatch: plan records workspace, terminal, branch" "$(plan_item)" \
  '{"state":"in-progress","branch":"issue-20-add-csv-export-please","workspace":"w-new","terminal":"t-new"'
args=$(cat "$FIX/create.args")
expect "dispatch: tag comes from the plan's groups" "$args" $'--tag\nwip'
expect "dispatch: prompt starts with the skill" "$args" "/implement #20"
expect "dispatch: prompt names the other items" "$args" "the others work on #21."
expect "dispatch: prompt stops on the same obstacle twice" "$args" "If you hit the same obstacle a second time"
expect "dispatch: an unfixable PR check is not an obstacle" "$args" "a PR check you cannot fix is not an obstacle"
expect "dispatch: prompt defines the wait block" "$args" "RUNWAVES_WORKER_WAITING"
expect "dispatch: wait block names what it waits on" "$args" "waiting-on: <what you are waiting for>"
expect "dispatch: waiting is not blocked" "$args" "Waiting is not blocked"
expect "dispatch: markers go on a line of their own" "$args" "the marker on a line of its own"
expect_not "dispatch: output never echoes the prompt" "$out" "RUNWAVES_WORKER_DONE"

# first prompt line per harness
for pair in 'opencode|Use the implement skill to do #20.' 'agy|/implement #20' 'antigravity|/implement #20' \
  'codex|$implement #20' 'hermes|/implement #20' 'gemini|Use the implement skill to do #20.'; do
  h=${pair%%|*} line=${pair#*|}
  dispatch_sandbox
  jq --arg a "$h" '.items[0].agent = $a' "$plan" >"$plan.tmp" && mv "$plan.tmp" "$plan"
  dispatch >/dev/null 2>&1
  expect "dispatch: $h first line" "$(sed -n 1,200p "$FIX/create.args")" $'--prompt\n'"$line"
done

# collision: remote branch, local branch, plan branch, and a PR each push the name to -2, -3, ...
dispatch_sandbox
git push -q origin HEAD:refs/heads/issue-20-add-csv-export-please
expect "collision: remote branch gets -2" "$(dispatch 2>&1)" "-> issue-20-add-csv-export-please-2 "
dispatch_sandbox
git branch issue-20-add-csv-export-please
git push -q origin HEAD:refs/heads/issue-20-add-csv-export-please-2
expect "collision: local and remote branches get -3" "$(dispatch 2>&1)" "-> issue-20-add-csv-export-please-3 "
dispatch_sandbox
plan_with "[$(jq -nc '{id: "#20", title: "Add CSV export", state: "queued", branch: null}'), $(item '#21' in-progress w21 t21 | jq -c '.branch = "issue-20-add-csv-export"')]"
expect "collision: a branch in the plan gets -2" "$(dispatch 2>&1)" "-> issue-20-add-csv-export-2 "
dispatch_sandbox
echo '[{"headRefName": "issue-20-add-csv-export-please", "number": 3}]' >"$FIX/prs.json"
expect "collision: a branch with a PR gets -2" "$(dispatch 2>&1)" "-> issue-20-add-csv-export-please-2 "

# rollback: the plan goes back to queued, and to blocked on the second failure
dispatch_sandbox
echo "host unreachable" >"$FIX/create-fail"
before=$(cat "$plan")
out=$(dispatch 2>&1); code=$?
expect_exit "rollback: failure exits 1" $code 1
expect "rollback: names the failing step" "$out" "dispatch #20 failed at workspace: host unreachable"
expect "rollback: first failure is queued again" "$(plan_item)" '{"state":"queued","branch":null,"workspace":null,"terminal":null,"reason":null,"f":1}'
dispatch >/dev/null 2>&1; code=$?
expect_exit "rollback: second failure exits 1" $code 1
expect "rollback: second failure is blocked with the error" "$(plan_item)" '"state":"blocked"'
expect "rollback: reason is the error" "$(plan_item)" 'workspace creation failed: host unreachable'
out=$(dispatch 2>&1); code=$?
expect "rollback: a blocked item is not dispatched again" "$out" "item is blocked, not queued"

# a refused plan write leaves the plan untouched and creates nothing
dispatch_sandbox
jq '.owner = "someone-else"' "$plan" >"$root/p" && mv "$root/p" "$plan"
snapshot w-new t-new working someone-else
before=$(cat "$plan")
out=$(dispatch 2>&1); code=$?
expect_exit "plan refusal: exits 1" $code 1
expect "plan refusal: names the step" "$out" "failed at plan"
expect_exit "plan refusal: plan untouched" "$([[ $(cat "$plan") == "$before" ]] && echo 0 || echo 1)" 0
expect_exit "plan refusal: no workspace created" "$([[ -f $FIX/create.args ]] && echo 1 || echo 0)" 0

# stacked prompt, and free-text branch names
dispatch_sandbox
out=$(dispatch --base issue-19-dep 2>&1)
expect "stacked: prompt says stacked" "$(cat "$FIX/create.args")" "Stacked: this branch starts from issue-19-dep"
dispatch_sandbox
plan_with "[$(jq -nc '{id: "T1", title: "Cache the thing", text: "Add a cache.", state: "queued", branch: null}')]"
expect "free text: task-<runId>-t1-<slug>" "$("$scripts/dispatch.sh" proj "$plan" T1 2>&1)" "-> task-20261112-1200-t1-cache-the-thing "
args=$(cat "$FIX/create.args")
expect "old single-text plan: prompt carries the text" "$args" $'/implement T1\n\nAdd a cache.\n'
expect "old single-text plan: still a plan label" "$args" "T1 is a label in this run's plan only"

# free text with the user's words and the orchestrator's notes kept apart
dispatch_sandbox
plan_with "[$(jq -nc '{id: "T2", title: "Cache the thing", ask: "cache the search results",
  notes: "Lives in search/. Out of scope: the image cache.", state: "queued", branch: null}')]"
out=$("$scripts/dispatch.sh" proj "$plan" T2 2>&1)
expect "two-part: free-text branch name" "$out" "-> task-20261112-1200-t2-cache-the-thing "
args=$(cat "$FIX/create.args")
expect "two-part: the user's words under their own label" "$args" \
  $'The user\'s words (verbatim; this is the task and the whole of its scope):\ncache the search results\n'
expect "two-part: the notes under their own label" "$args" \
  $'Coordinator\'s notes (context and what stays out of scope; they add no work):\nLives in search/. Out of scope: the image cache.\n'
expect "two-part: still a plan label" "$args" "T2 is a label in this run's plan only"
plan_with "[$(jq -nc '{id: "T3", title: "Fix login", ask: "fix the login redirect", notes: null, state: "queued", branch: null}')]"
"$scripts/dispatch.sh" proj "$plan" T3 >/dev/null 2>&1
args=$(cat "$FIX/create.args")
expect "two-part: words alone when there are no notes" "$args" $'fix the login redirect\n'
expect_not "two-part: no empty notes label" "$args" "Coordinator's notes"
dispatch_sandbox
dispatch >/dev/null 2>&1
expect_not "tracker item: no user's-words label" "$(cat "$FIX/create.args")" "The user's words"

# integration branch: created from its base when missing; items start on it, or on a parent when stacked
integ_plan() { # integ_plan: #20 targets integration f1 (feature/csv)
  plan_with "[$(jq -nc '{id: "#20", title: "Add CSV export", state: "queued", branch: null, integration: "f1"}')]" \
    '{"integrations": [{"id": "f1", "title": "CSV", "branch": "feature/csv", "base": "main", "pr": null, "state": "open"}]}'
}
dispatch_sandbox
git push -q origin HEAD:refs/heads/main
integ_plan
out=$(dispatch 2>&1)
expect "integration: item dispatches" "$out" "dispatched #20 -> issue-20-add-csv-export "
expect "integration: branch created on the remote from its base" \
  "$(git ls-remote --heads origin feature/csv | cut -f1)" "$(git rev-parse HEAD)"
args=$(cat "$FIX/create.args")
expect "integration: item starts from the integration branch" "$args" $'--base-branch\nfeature/csv'
expect "integration: PR targets it" "$args" 'gh pr create --base feature/csv'
expect_not "integration: not stacked" "$args" "Stacked:"
git commit -q --allow-empty -m moved && git push -q origin HEAD:refs/heads/main
dispatch_sandbox_again() { integ_plan; rm -f "$FIX/create.args"; }
dispatch_sandbox_again
before=$(git ls-remote --heads origin feature/csv | cut -f1)
dispatch >/dev/null 2>&1
expect "integration: an existing branch is left alone" "$(git ls-remote --heads origin feature/csv | cut -f1)" "$before"
dispatch_sandbox
git push -q origin HEAD:refs/heads/main
integ_plan
out=$(dispatch --base issue-19-dep 2>&1)
args=$(cat "$FIX/create.args")
expect "integration stacked: starts from the parent" "$args" $'--base-branch\nissue-19-dep'
expect "integration stacked: rebases onto the target" "$args" "git rebase --onto origin/feature/csv <that tip>"
expect "integration stacked: PR targets the integration" "$args" 'gh pr create --base feature/csv'
expect_not "integration stacked: no hard-coded main" "$args" "origin/main"
dispatch_sandbox
plan_with "[$(jq -nc '{id: "#20", title: "Add CSV export", state: "queued", integration: "gone"}')]"
expect "integration: unknown id fails" "$(dispatch 2>&1)" "not in the plan"
dispatch_sandbox
dispatch --base issue-19-dep >/dev/null 2>&1
args=$(cat "$FIX/create.args")
expect "no integration: stacked rebases onto main" "$args" "git rebase --onto origin/main <that tip>"
expect "no integration: PR targets main" "$args" 'gh pr create --base main'
expect "prompt: no PR checks means a local test run in checked:" "$args" "no PR checks; local: npm"

# --- integrate: when an integration is ready, held, and its dispatched item -------------------
integ_items() { # integ_items <state-of-#1> <state-of-#2> [dropped-of-#2]
  plan_with "[$(jq -nc --arg s "$1" '{id: "#1", title: "One", state: $s, integration: "F1", pr: "https://github.com/acme/app/pull/5", skill: "implement", agent: "claude"}'),
    $(jq -nc --arg s "$2" --argjson d "${3:-false}" '{id: "#2", title: "Two", state: $s, integration: "F1", pr: "https://github.com/acme/app/pull/6", dropped: $d}')]" \
    '{"integrations": [{"id": "F1", "title": "CSV", "branch": "feature/csv", "base": "main", "pr": null, "state": "open"}]}'
}
integ() { "$scripts/integrate.sh" "$1" "$plan" "${2:-}" 2>&1; }
dispatch_sandbox
integ_items done in-review
expect "integrate: an item in review keeps it open" "$(integ check)" "open F1: #2"
integ_items done done
expect "integrate: all done is ready" "$(integ check)" "ready F1"
integ_items done blocked
expect "integrate: a blocked item holds it" "$(integ check)" "held F1: #2 blocked"
integ_items done waiting
expect "integrate: a waiting item holds it" "$(integ check)" "held F1: #2 waiting"
integ_items done skipped
expect "integrate: a skipped item holds it" "$(integ check)" "held F1: #2 skipped"
integ_items done skipped true
expect "integrate: a dropped item releases it" "$(integ check)" "ready F1"
integ_items skipped skipped true
jq '.items[0].dropped = true' "$plan" >"$plan.t" && mv "$plan.t" "$plan"
expect "integrate: all dropped is empty" "$(integ check)" "empty F1"
integ_items done blocked
integ add F1 >/dev/null; code=$?
expect_exit "integrate: add refuses a held integration" "$code" 1
expect_not "integrate: and adds nothing" "$(jq -r '[.items[].id] | join(",")' "$plan")" "F1-integrate"
integ_items done skipped true
expect "integrate: add queues the item" "$(integ add F1)" "added F1-integrate"
expect "integrate: the item is queued and integrates F1" \
  "$(jq -c '.items[] | select(.id == "F1-integrate") | [.state, .integrates, .integration]' "$plan")" '["queued","F1",null]'
expect "integrate: once added, check says has" "$(integ check)" "has F1: F1-integrate is queued"
git push -q origin HEAD:refs/heads/main; git push -q origin HEAD:refs/heads/feature/csv
out=$("$scripts/dispatch.sh" proj "$plan" F1-integrate 2>&1)
expect "integrate dispatch: item dispatches" "$out" "dispatched F1-integrate -> f1-integrate-integrate-csv "
args=$(cat "$FIX/create.args")
expect "integrate dispatch: starts from the feature branch" "$args" $'--base-branch\nfeature/csv'
expect "integrate dispatch: merges main in" "$args" "git merge origin/main"
expect "integrate dispatch: opens feature to main" "$args" "gh pr create --base main --head feature/csv"
expect "integrate dispatch: lists the sub-PRs" "$args" "#1 One: https://github.com/acme/app/pull/5"
expect "integrate dispatch: names dropped items" "$args" "#2 Two: https://github.com/acme/app/pull/6 (dropped, not included)"
expect "integrate dispatch: leaves the merge to the user" "$args" "Do not merge the final PR"
expect_not "integrate dispatch: not stacked" "$args" "Stacked:"
expect "integrate dispatch: worker prompt still ends in a DONE block" "$args" "RUNWAVES_WORKER_DONE"

# --- merge gate --------------------------------------------------------------------------------
gate_sandbox() { # gate_sandbox <checked> [acceptance]
  sandbox
  plan_with "[$(jq -nc --arg c "$1" --arg a "${2-ok}" '{id: "#30", state: "in-review", integration: "F1", pr: "https://github.com/acme/app/pull/9", checked: $c, acceptance: $a}'),
    $(jq -nc '{id: "#31", state: "in-review", pr: "https://github.com/acme/app/pull/10", checked: "5/5 green", acceptance: "ok"}')]" \
    '{"integrations": [{"id": "F1", "branch": "feature/csv", "base": "main", "state": "open"}]}'
  pr_view OPEN feature/csv MERGEABLE '[{"name":"ci","conclusion":"SUCCESS"}]'
}
pr_view() { jq -n --arg s "$1" --arg b "$2" --arg m "$3" --argjson r "$4" \
  '{state: $s, baseRefName: $b, mergeable: $m, statusCheckRollup: $r}' >"$FIX/pr-view.json"; }
gate() { "$scripts/merge.sh" "${1:-check}" "$plan" "${2:-#30}" 2>&1; }

gate_sandbox "5/5 green"
expect "gate: green, mergeable, acceptance ok merges" "$(gate)" "merge"
expect_exit "gate: merge exits 0" "$(gate >/dev/null; echo $?)" 0
gate run >/dev/null
expect "gate run: merges with a merge commit" "$(cat "$FIX/merge.args")" "pr merge 9 --merge"
gate_sandbox "5/5 green"; pr_view OPEN main MERGEABLE '[{"name":"ci","conclusion":"SUCCESS"}]'
expect "gate: a PR into the default branch is never merged" "$(gate)" "no: PR #9 targets main"
gate run >/dev/null; expect "gate run: and gh pr merge is not called" "$(cat "$FIX/merge.args" 2>/dev/null)" ""
expect "gate: an item without integration is never merged" "$(gate check '#31')" "no: #31 targets the default branch"
gate_sandbox "5/5 green" "missing the docs"
expect "gate: an acceptance gap is not merged" "$(gate)" "no: acceptance is not ok"
gate_sandbox ""
expect "gate: no DONE block is not merged" "$(gate)" "no: no DONE block"
gate_sandbox "5/5 green"; pr_view OPEN feature/csv CONFLICTING '[{"name":"ci","conclusion":"SUCCESS"}]'
expect "gate: a conflict waits" "$(gate)" "wait: PR #9 conflicts"
expect_exit "gate: wait exits 2" "$(gate >/dev/null; echo $?)" 2
pr_view OPEN feature/csv UNKNOWN '[{"name":"ci","conclusion":"SUCCESS"}]'
expect "gate: unknown mergeability waits" "$(gate)" "wait: PR #9 mergeability unknown"
pr_view OPEN feature/csv MERGEABLE '[{"name":"ci","conclusion":"SUCCESS"},{"name":"lint","status":"IN_PROGRESS","conclusion":null}]'
expect "gate: pending checks wait" "$(gate)" "wait: checks still running"
pr_view OPEN feature/csv MERGEABLE '[{"name":"ci","conclusion":"SUCCESS"},{"name":"lint","conclusion":"FAILURE"}]'
expect "gate: red checks wait, naming them" "$(gate)" "wait: checks red: lint"
pr_view OPEN feature/csv MERGEABLE '[{"name":"ci","conclusion":"SKIPPED"},{"name":"lint","conclusion":"NEUTRAL"}]'
expect "gate: skipped and neutral checks are green" "$(gate)" "merge"
pr_view MERGED feature/csv MERGEABLE '[]'
expect "gate: a PR that is not open is not merged" "$(gate)" "no: PR #9 is not open"
gate_sandbox "no PR checks; local: npm test passed"; pr_view OPEN feature/csv MERGEABLE '[]'
expect "gate: no checks and a passing local run merges" "$(gate)" "merge"
gate_sandbox "no PR checks"; pr_view OPEN feature/csv MERGEABLE '[]'
expect "gate: no checks and no local run gets a follow-up" "$(gate)" "followup:"
expect_exit "gate: follow-up exits 3" "$(gate >/dev/null; echo $?)" 3
gate run >/dev/null; expect "gate run: no merge on a follow-up" "$(cat "$FIX/merge.args" 2>/dev/null)" ""
gate_sandbox "no PR checks; local: npm test failed, 2 red"; pr_view OPEN feature/csv MERGEABLE '[]'
expect "gate: no checks and a failing local run gets a follow-up" "$(gate)" "followup:"
gate_sandbox "no PR checks; local: npm test did not pass"; pr_view OPEN feature/csv MERGEABLE '[]'
expect "gate: a local run that did not pass gets a follow-up" "$(gate)" "followup:"
gate_sandbox "no PR checks; local: required tests passed"; pr_view OPEN feature/csv MERGEABLE '[]'
expect "gate: 'required' is not 'red'" "$(gate)" "merge"
gate_sandbox "5/5 green"
jq '.integrations[0].mergeNote = "human"' "$plan" >"$plan.t" && mv "$plan.t" "$plan"
expect "gate: a human-merge integration is not merged" "$(gate)" "no: F1's rulesets forbid"
gate_sandbox "5/5 green"; pr_view OPEN feature/csv MERGEABLE '[{"name":"ci","conclusion":"SUCCESS"}]'
jq '.items[0].state = "feedback"' "$plan" >"$plan.t" && mv "$plan.t" "$plan"
expect "gate: an item not in-review is not merged" "$(gate)" "no: #30 is not in-review"
gate_sandbox "no PR checks; npm test passed"; pr_view OPEN feature/csv MERGEABLE '[]'
expect "gate: a test run not marked local gets a follow-up" "$(gate)" "followup:"

# --- chains: offering dependency chains and importing an epic's sub-issues --------------------
chain_item() { # chain_item <id> <title> [dependsOn-json] [integration]
  jq -nc --arg id "$1" --arg t "$2" --argjson d "${3:-[]}" --arg i "${4:-}" \
    '{id: $id, title: $t, state: "queued", dependsOn: $d, integration: (if $i == "" then null else $i end)}'
}
sandbox
plan_with "[$(chain_item '#340' 'Cache Pester in CI'), $(chain_item '#341' 'Split backup' '["#340"]'),
  $(chain_item '#342' 'Add restore' '["#341"]'), $(chain_item '#350' 'Lone item'),
  $(chain_item '#360' 'Other root'), $(chain_item '#361' 'Other leaf' '["#360"]')]"
out=$("$scripts/chains.sh" offer "$plan")
expect "chains: a three-item chain is offered whole" "$out" '"items":["#340","#341","#342"]'
expect "chains: named after its root" "$out" 'group #340, #341, #342 into feature/340-cache-pester-in-ci?'
expect "chains: a second chain is offered separately" "$out" '"items":["#360","#361"]'
expect_not "chains: an independent item is not a chain" "$out" "#350"
expect "chains: accept makes an integration" "$("$scripts/chains.sh" accept "$plan" '#341')" "added F1 feature/340-cache-pester-in-ci: #340, #341, #342"
expect "chains: the chain's items join it" "$(jq -c '[.items[] | select(.integration == "F1") | .id]' "$plan")" '["#340","#341","#342"]'
expect "chains: the integration is based on the default branch" "$(jq -c '.integrations[0] | [.id, .base, .state]' "$plan")" '["F1","main","open"]'
expect "chains: an accepted chain is not offered again" "$("$scripts/chains.sh" offer "$plan")" '"items":["#360","#361"]'
expect_not "chains: nor its items" "$("$scripts/chains.sh" offer "$plan")" "#341"
expect "chains: a declined chain stays as it was" "$(jq -c '[.items[] | select(.id == "#360") | .integration]' "$plan")" '[null]'
"$scripts/chains.sh" accept "$plan" '#361' >/dev/null
expect "chains: the next integration gets the next id" "$(jq -r '.integrations[1].id' "$plan")" "F2"
expect "chains: accept refuses a lone item" "$("$scripts/chains.sh" accept "$plan" '#350' 2>&1)" "#350 is in no offered chain"

# a diamond is one chain
sandbox
plan_with "[$(chain_item '#1' 'Root'), $(chain_item '#2' 'Left' '["#1"]'), $(chain_item '#3' 'Right' '["#1"]'), $(chain_item '#4' 'Join' '["#2","#3"]')]"
expect "chains: a diamond is one chain" "$("$scripts/chains.sh" offer "$plan" | wc -l | tr -d ' ')" "1"
plan_with "[$(chain_item '#1' 'Solo' '["#99"]')]"
expect "chains: an outside dependency is no chain" "$("$scripts/chains.sh" offer "$plan")" ""

# critical path: every longest dependsOn chain, listed in plan order
crit() { "$scripts/chains.sh" critical "$plan" 2>&1; }
plan_with "[$(chain_item '#3' 'C' '["#2"]'), $(chain_item '#1' 'A'), $(chain_item '#2' 'B' '["#1"]'), $(chain_item '#9' 'Lone')]"
expect "critical: a linear chain, first to last" "$(crit)" '{"length":3,"items":["#3","#1","#2"],"paths":[["#1","#2","#3"]],"pathCount":1}'
plan_with "[$(chain_item '#1' 'Root'), $(chain_item '#2' 'Left' '["#1"]'), $(chain_item '#3' 'Right' '["#1"]'),
  $(chain_item '#4' 'Join' '["#3","#2"]')]"
expect "critical: a diamond has both branches" "$(crit)" '"paths":[["#1","#2","#4"],["#1","#3","#4"]],"pathCount":2'
plan_with "[$(chain_item '#1' 'Root'), $(chain_item '#2' 'Long' '["#1"]'), $(chain_item '#3' 'Short'),
  $(chain_item '#4' 'Join' '["#2","#3"]')]"
expect "critical: an item on no longest chain is not critical" "$(crit)" '"items":["#1","#2","#4"]'
plan_with "[$(chain_item '#1' 'A'), $(chain_item '#3' 'C'), $(chain_item '#2' 'B' '["#1"]'), $(chain_item '#4' 'D' '["#3"]')]"
expect "critical: two equal chains are both critical" "$(crit)" '{"length":2,"items":["#1","#3","#2","#4"],"paths":[["#1","#2"],["#3","#4"]],"pathCount":2}'
plan_with "[$(chain_item '#1' 'A'), $(chain_item '#2' 'B' '["#99"]'), $(chain_item '#3' 'C')]"
expect "critical: independent items have no path longer than 1" "$(crit)" '{"length":1,"items":[],"paths":[],"pathCount":0}'
plan_with "[$(chain_item '#1' 'A'), $(chain_item '#2' 'B' '["#1"]' | jq -c '.state = "skipped"'), $(chain_item '#3' 'C' '["#2"]')]"
expect "critical: a skipped item breaks the chain" "$(crit)" '"items":[]'
plan_with "[$(chain_item '#1' 'A' | jq -c '.state = "done"'), $(chain_item '#2' 'B' '["#1"]'), $(chain_item '#3' 'C' '["#2"]'),
  $(chain_item '#4' 'D'), $(chain_item '#5' 'E' '["#4"]')]"
expect "critical: a done item is off the path, its dependency met" "$(crit)" '{"length":2,"items":["#2","#3","#4","#5"]'
plan_with '[]'
expect "critical: an empty plan" "$(crit)" '{"length":0,"items":[],"paths":[],"pathCount":0}'
# a ladder of diamonds: 2^6 longest chains, five listed and all counted
ladder='[]' prev=''
for k in 1 2 3 4 5 6; do
  ladder=$(jq -c --arg k "$k" --arg p "$prev" '. + [{id: "r\($k)", state: "queued", dependsOn: (if $p == "" then [] else [$p] end)},
    {id: "l\($k)", state: "queued", dependsOn: ["r\($k)"]}, {id: "m\($k)", state: "queued", dependsOn: ["r\($k)"]},
    {id: "j\($k)", state: "queued", dependsOn: ["l\($k)", "m\($k)"]}]' <<<"$ladder")
  prev="j$k"
done
plan_with "$ladder"
expect "critical: many tied chains are counted, five listed" "$(crit | jq -c '[.length, .pathCount, (.paths | length)]')" '[18,64,5]'
plan_with "[$(chain_item '#1' 'A' '["#2"]'), $(chain_item '#2' 'B' '["#1"]')]"
expect "critical: a cycle is refused" "$(crit)" "dependency cycle in $plan"
expect_exit "critical: a cycle exits 1" "$("$scripts/chains.sh" critical "$plan" >/dev/null 2>&1; echo $?)" 1
expect_exit "waves: a cycle exits 1" "$("$scripts/chains.sh" waves "$plan" >/dev/null 2>&1; echo $?)" 1
expect "critical: a missing plan is not called a cycle" "$("$scripts/chains.sh" critical "$FIX/nope.json" 2>&1)" "Could not open file"
plan_with '[{"id": "#1", "state": "queued", "dependsOn": "#2"}]'
expect_not "critical: a malformed dependsOn is not called a cycle" "$(crit)" "dependency cycle"
expect_exit "critical: a malformed dependsOn exits 1" "$("$scripts/chains.sh" critical "$plan" >/dev/null 2>&1; echo $?)" 1

# waves: after every dependency, at most maxParallel each, critical items first
plan_with "[$(chain_item '#8' 'Lone'), $(chain_item '#1' 'A'), $(chain_item '#2' 'B' '["#1"]'), $(chain_item '#3' 'C' '["#2"]')]"
expect "waves: dependencies come first" "$("$scripts/chains.sh" waves "$plan")" '{"#1":1,"#8":1,"#2":2,"#3":3}'
jq '.maxParallel = 1' "$plan" >"$plan.t" && mv "$plan.t" "$plan"
expect "waves: under the limit the critical chain goes first" "$("$scripts/chains.sh" waves "$plan")" '{"#1":1,"#2":2,"#3":3,"#8":4}'
jq '.maxParallel = 0' "$plan" >"$plan.t" && mv "$plan.t" "$plan"
expect "waves: a limit under 1 counts as 1" "$("$scripts/chains.sh" waves "$plan")" '{"#1":1,"#2":2,"#3":3,"#8":4}'
plan_with "[$(chain_item '#1' 'A'), $(chain_item '#2' 'B' '["#1"]' | jq -c '.state = "waiting"'), $(chain_item '#3' 'C' '["#2"]'),
  $(chain_item '#4' 'D' '["#9"]')]"
expect "waves: a waiting item and its dependents get none" "$("$scripts/chains.sh" waves "$plan")" '{"#1":1,"#4":1}'

# table.sh --go: the go message's plan table
plan_with "[$(chain_item '#1' 'Root' | jq -c '. + {skill: "implement", agent: "claude", preset: "auto"}'),
  $(chain_item '#2' 'Left | pipe' '["#1"]' 'F1'), $(chain_item '#3' 'Right' '["#1"]'), $(chain_item '#4' 'Join' '["#2","#3"]'),
  $(chain_item '#5' 'Lone' | jq -c '.state = "skipped"'), $(chain_item '#6' 'Later' '["#7"]' | jq -c '.state = "waiting"'),
  $(chain_item '#8' 'Shipped' | jq -c '.state = "done"')]" \
  '{"integrations": [{"id": "F1", "title": "x", "branch": "feature/x", "base": "main", "pr": null, "state": "open"}]}'
out=$("$scripts/table.sh" --go "$plan")
expect "go table: header" "$out" "| Item | Title | Wave | Depends on | Critical | Target | Skill | Agent |"
expect "go table: a critical row" "$out" "| #1 | Root | 1 | — | yes | main | implement | claude auto |"
expect "go table: target is the integration branch, pipes escaped" "$out" '| #2 | Left \| pipe | 2 | #1 | yes | feature/x | — | — |'
expect_not "go table: a skipped item is left out" "$out" "| #5 |"
expect "go table: a waiting item says so" "$out" "| #6 | Later | waiting | #7 | — | main | — | — |"
expect "go table: a done item says so" "$out" "| #8 | Shipped | done | — | — | main | — | — |"
expect "go table: each critical path below" "$out" "Critical path (3): #1 → #2 → #4"
expect "go table: the tied path too" "$out" "Critical path (3): #1 → #3 → #4"
expect "go table: --force is accepted and changes nothing" "$("$scripts/table.sh" --force --go "$plan")" "$out"
plan_with "$ladder"
expect "go table: paths beyond five are counted" "$("$scripts/table.sh" --go "$plan")" "… and 59 more of length 18"
plan_with "[$(chain_item '#1' 'A' '["#2"]'), $(chain_item '#2' 'B' '["#1"]')]"
expect "go table: a cycle is refused" "$("$scripts/table.sh" --go "$plan" 2>&1)" "dependency cycle"

# a shared feature branch takes every item, chains included, and nothing is left to offer
sandbox
plan_with "[$(chain_item '#340' 'Cache Pester'), $(chain_item '#341' 'Split backup' '["#340"]'), $(chain_item '#350' 'Lone item')]"
expect "chains: share adds one feature branch" "$("$scripts/chains.sh" share "$plan" 'CSV export!')" "added F1 feature/csv-export"
expect "chains: share puts every item on it" "$(jq -c '[.items[].integration]' "$plan")" '["F1","F1","F1"]'
expect "chains: nothing to offer once shared" "$("$scripts/chains.sh" offer "$plan")" ""

# epic: sub-issues become the items of one integration named after the epic
sandbox
echo '{"number":400,"title":"CSV Export","url":"https://github.com/acme/app/issues/400"}' >"$FIX/epic.json"
echo '[{"number":401,"title":"Add button","state":"open","labels":[{"name":"enhancement"}]},
 {"number":402,"title":"Old","state":"closed","labels":[]},
 {"number":403,"title":"Vague","state":"open","labels":[{"name":"needs-info"}]},
 {"number":404,"title":"Planned","state":"open","labels":[]},
 {"number":405,"title":"Server","state":"open","labels":[]},
 {"number":406,"title":"A PR","state":"open","labels":[],"pull_request":{}}]' >"$FIX/sub-issues.json"
plan_with "[$(chain_item '#404' 'Planned')]"
out=$("$scripts/epic.sh" fetch 400 "$plan")
expect "epic: fetch lists the open sub-issues" "$(jq -c '[.items[].id]' <<<"$out")" '["#401","#405"]'
expect "epic: fetch drops a closed one" "$out" '{"id":"#402","reason":"closed"}'
expect "epic: fetch drops needs-info" "$out" '{"id":"#403","reason":"needs-info"}'
expect "epic: fetch drops an already planned one" "$out" '{"id":"#404","reason":"already planned"}'
expect "epic: fetch drops a pull request" "$out" '{"id":"#406","reason":"pull request"}'
out=$("$scripts/epic.sh" import "$plan" 400)
expect "epic: import names the integration after the epic" "$out" "imported 2 of #400 into feature/400-csv-export"
expect "epic: the integration carries the epic" "$(jq -c '.integrations[0] | [.branch, .epic.url, .state]' "$plan")" '["feature/400-csv-export","https://github.com/acme/app/issues/400","open"]'
expect "epic: the sub-issues are queued items on it" "$(jq -c '[.items[] | select(.integration == "F1") | [.id, .state]]' "$plan")" '[["#401","queued"],["#405","queued"]]'
expect "epic: the existing item is untouched" "$(jq -c '[.items[] | select(.id == "#404") | .integration]' "$plan")" '[null]'

# the final PR links the epic
dispatch_sandbox
integ_items done done
jq '.integrations[0].epic = {id: "#400", title: "CSV", url: "https://github.com/acme/app/issues/400"}' "$plan" >"$plan.t" && mv "$plan.t" "$plan"
"$scripts/integrate.sh" add "$plan" F1 >/dev/null
"$scripts/dispatch.sh" proj "$plan" F1-integrate >/dev/null 2>&1
expect "epic: the integrate worker links the epic" "$(cat "$FIX/create.args")" "and the epic https://github.com/acme/app/issues/400"

# --- rulesets of the integration branch -------------------------------------------------------
sandbox
echo '[]' >"$FIX/rules.json"
expect "rules: none means ok" "$("$scripts/merge.sh" rules feature/csv)" "ok"
echo '[{"type":"pull_request","parameters":{"allowed_merge_methods":["squash","rebase"]}}]' >"$FIX/rules.json"
out=$("$scripts/merge.sh" rules feature/csv)
expect "rules: squash/rebase only forbids merge commits" "$out" "no-merge-commit:"
expect_not "rules: and is not ok" "$out" $'
ok'
echo '[{"type":"required_linear_history"}]' >"$FIX/rules.json"
expect "rules: linear history forbids merge commits" "$("$scripts/merge.sh" rules feature/csv)" "no-merge-commit:"
echo '[{"type":"pull_request","parameters":{"allowed_merge_methods":["merge","squash"]}}]' >"$FIX/rules.json"
expect "rules: merge allowed is ok" "$("$scripts/merge.sh" rules feature/csv)" "ok"
echo '[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true}}]' >"$FIX/rules.json"
expect "rules: up-to-date requirement is reported" "$("$scripts/merge.sh" rules feature/csv)" "strict:"

# --- preflight: one call answers every question; each exit code only for its condition --------
pf_sandbox() {
  sandbox
  "$scripts/groups.sh" p1 save '{}' >/dev/null   # a saved group map: nothing to ask
}
pf() { out=$("$scripts/preflight.sh" "$@" 2>/dev/null); pf_rc=$?; }

pf_sandbox
pf; rc=$pf_rc
expect_exit "preflight: all well exits 0" "$rc" 0
expect "preflight: tools" "$out" '"paradevVersion":"2.0.8"'
expect "preflight: auth" "$(jq -c .auth <<<"$out")" '"gh":true'
expect "preflight: host" "$(jq -c .host <<<"$out")" '"reachable":true'
expect "preflight: repo and default branch" "$(jq -c .repo <<<"$out")" '"nameWithOwner":"acme/app","defaultBranch":"main"'
expect "preflight: project" "$(jq -c .project <<<"$out")" '"id":"p1"'
expect "preflight: plan claim is free" "$(jq -c .plan <<<"$out")" '"claim":"free"'
expect "preflight: groups" "$(jq -c .groups <<<"$out")" '"In Progress"'
expect "preflight: presets" "$(jq -c .presets.claude.auto[0].presetId <<<"$out")" 'claude-auto'

echo '{"nameWithOwner":"acme/app","defaultBranchRef":{"name":"trunk"},"squashMergeAllowed":true,"mergeCommitAllowed":false,"rebaseMergeAllowed":false}' >"$FIX/repo.json"
pf; expect "preflight: squash-only repo" "$(jq -c '.repo.mergeMethods' <<<"$out")" '["squash"]'

pf_sandbox; touch "$FIX/signed-out"; pf; rc=$pf_rc
expect_exit "preflight: signed out exits 1" "$rc" 1
expect "preflight: signed out names the error, JSON complete" "$(jq -c '[.error, .repo.nameWithOwner]' <<<"$out")" 'not signed in'
pf_sandbox; touch "$FIX/host-down"; pf
expect_exit "preflight: host down exits 1" "$pf_rc" 1
expect "preflight: host down reported" "$(jq -c .host <<<"$out")" '"reachable":false'
pf_sandbox; touch "$FIX/no-repo"; pf
expect_exit "preflight: not on GitHub exits 2" "$pf_rc" 2
pf_sandbox; echo '[{"id":"p9","name":"other"}]' >"$FIX/projects.json"; pf
expect_exit "preflight: no project exits 2" "$pf_rc" 2
expect "preflight: candidates listed" "$(jq -c .project.candidates <<<"$out")" '"p9"'

# plan ownership
pf_sandbox; snapshot w1 t1 working other
jq -n --arg beat "$(ago 1)" '{repo:"acme/app",runId:"r1",status:"active",owner:"other",heartbeat:$beat,items:[]}' >"$plan"
pf; expect_exit "preflight: live owner exits 3" "$pf_rc" 3
expect "preflight: live owner details" "$(jq -c .plan <<<"$out")" '"claim":"live-owner"'
expect "preflight: close also stops on a live owner" "$(pf --mode close >/dev/null; echo $pf_rc)" 3
pf_sandbox; snapshot w1 t1 working
jq -n --arg beat "$(ago 120)" '{repo:"acme/app",runId:"r1",status:"active",owner:"gone",heartbeat:$beat,items:[]}' >"$plan"
pf; expect_exit "preflight: stale owner on a run exits 4" "$pf_rc" 4
expect "preflight: stale reported" "$(jq -c .plan.claim <<<"$out")" 'stale'
pf --mode continue
expect_exit "preflight: continue takes over a stale owner, exit 0" "$pf_rc" 0
expect "preflight: takeover reported" "$(jq -c .plan <<<"$out")" '"takenOver":true'
expect "preflight: plan now owned" "$(jq -r .owner "$plan")" me
pf_sandbox; jq -n --arg beat "$(ago 1)" '{repo:"acme/app",runId:"r1",status:"active",owner:"other",heartbeat:$beat,items:[]}' >"$plan"
snapshot w1 t1 working other
pf --mode report
expect_exit "preflight: report ignores a live owner, exit 0" "$pf_rc" 0
expect "preflight: report uses plan check" "$(jq -c .plan.check <<<"$out")" 'other'
expect "preflight: report never claims" "$(jq -r .owner "$plan")" other

# groups
pf_sandbox; rm -rf "$HOME/.agents/orchestrator/groups.json"; pf
expect_exit "preflight: unsaved group map exits 5" "$pf_rc" 5
expect "preflight: unsaved flagged with a suggestion" "$(jq -c .groups.unsaved <<<"$out")" true
pf_sandbox; "$scripts/groups.sh" p1 save '{"In Progress":"wip"}' >/dev/null; pf
expect_exit "preflight: a lost tag exits 5" "$pf_rc" 5
expect "preflight: lost tag named" "$(jq -c .groups.lost <<<"$out")" '"In Progress":"wip"'

# presets: auto by label, auto by args, regular that auto-approves
pf_sandbox
echo '[{"presetId":"codex","label":"Codex","command":"codex","args":[]}]' >"$FIX/agents.json"
pf --harness codex; expect_exit "preflight: no auto instance exits 6" "$pf_rc" 6
expect "preflight: regular listed" "$(jq -c .presets.codex.regular[0].presetId <<<"$out")" codex
echo '[{"presetId":"claude","label":"Claude","command":"claude","args":[]},{"presetId":"claude-2","label":"Claude fast","command":"claude","args":["--permission-mode=auto"]}]' >"$FIX/agents.json"
pf; expect_exit "preflight: auto by args exits 0" "$pf_rc" 0
expect "preflight: classified auto by args" "$(jq -c .presets.claude.auto[0].by <<<"$out")" args
echo '[{"presetId":"claude","label":"Claude","command":"claude","args":["--permission-mode","auto"]}]' >"$FIX/agents.json"
pf
expect "preflight: regular preset that auto-approves is flagged" "$(jq -c .presets.claude.regular[0].autoApproves <<<"$out")" true
expect_exit "preflight: that regular preset is not an auto instance, exit 6" "$pf_rc" 6
echo '[{"presetId":"opencode","label":"OpenCode","command":"opencode","args":["run","--auto"]}]' >"$FIX/agents.json"
pf --harness opencode; expect_exit "preflight: OpenCode auto flag exits 0" "$pf_rc" 0
expect "preflight: OpenCode detected by args without auto label" "$(jq -c .presets.opencode.auto[0].by <<<"$out")" args
echo '[{"presetId":"opencode","label":"OpenCode","command":"opencode","args":["run","--auto-approve"]}]' >"$FIX/agents.json"
pf --harness opencode; expect_exit "preflight: OpenCode near-miss flag remains regular" "$pf_rc" 6
echo '[{"presetId":"agy","label":"Antigravity","command":"agy","args":["--mode","auto"]}]' >"$FIX/agents.json"
pf --harness antigravity; expect_exit "preflight: Antigravity auto mode exits 0" "$pf_rc" 0
expect "preflight: Antigravity detected by args without auto label" "$(jq -c .presets.antigravity.auto[0].by <<<"$out")" args
echo '[{"presetId":"agy","label":"Antigravity","command":"agy","args":["--mode","accept-edits"]}]' >"$FIX/agents.json"
pf --harness antigravity; expect_exit "preflight: Antigravity regular mode stays regular" "$pf_rc" 6
echo '[{"presetId":"agy","label":"Antigravity","command":"agy","args":["--dangerously-skip-permissions"]}]' >"$FIX/agents.json"
pf --harness antigravity; expect_exit "preflight: Antigravity skip permissions exits 0" "$pf_rc" 0
echo '[{"presetId":"claude","label":"Claude","command":"claude","args":[]},{"presetId":"claude-auto","label":"Claude (auto)","command":"claude","args":[]}]' >"$FIX/agents.json"
pf; expect "preflight: auto by label" "$(jq -c .presets.claude.auto[0].by <<<"$out")" label
expect_exit "preflight: report mode does not need an auto instance" "$(echo '[]' >"$FIX/agents.json"; pf --mode report >/dev/null; echo $pf_rc)" 0

# --- table.sh: the status table ---------------------------------------------------------------
sandbox
plan_with "[$(item '#1' in-review w1 t1 | jq -c '. + {title: "Cache CI", pr: "https://github.com/acme/app/pull/9", checked: "ran CI"}'),
  $(item '#2' queued '' '' | jq -c '. + {title: "Split job", dependsOn: ["#1"]}'),
  $(item '#3' skipped '' '' | jq -c '. + {title: "Vague"}')]"
ws w1 b-#1 "In Review"; snapshot w1 t1 idle
echo '[{"headRefName":"b-#1","number":9,"url":"https://github.com/acme/app/pull/9","state":"MERGED","isDraft":false}]' >"$FIX/prs.json"
printf 'idle\n' >"$FIX/screens/t1"
out=$("$scripts/table.sh" proj "$plan")
expect "table: header" "$out" "| Item | Title | Group | Agent | PR |"
expect "table: reconciled row uses the PR from status" "$out" "| #1 | Cache CI | In Review | done | #9 |"
expect "table: queued names its dependency" "$out" "| #2 | Split job | Queued (after #1) | — | — |"
expect "table: skipped" "$out" "| #3 | Vague | Skipped | — | — |"
expect "table: in-review item's checked is listed below" "$out" "#1 checked: ran CI"
expect "table: second run is unchanged" "$("$scripts/table.sh" proj "$plan")" "unchanged"
expect "table: --force prints it anyway" "$("$scripts/table.sh" --force proj "$plan")" "| #1 | Cache CI |"
rows=$("$scripts/status.sh" proj "$plan")
same=$("$scripts/table.sh" --force proj "$plan")
expect "table: rows from stdin equal status.sh's own" "$("$scripts/table.sh" --force --rows - proj "$plan" <<<"$rows")" "$same"
echo '[{"headRefName":"b-#1","number":9,"url":"https://github.com/acme/app/pull/9","state":"CLOSED","isDraft":false}]' >"$FIX/prs.json"
out=$("$scripts/table.sh" proj "$plan")
expect "table: a changed render prints again" "$out" "#1 PR #9 closed unmerged"

# --- finish.sh: final chat artifacts come from the current plan -------------------------------
sandbox
plan_with "[$(item '#1' done '' '' | jq -c '. + {title: "Cache CI"}')]" \
  '{"events": [
    {"at": "2026-11-12T20:15:03Z", "item": "#1", "action": "dispatched", "detail": "workspace w1"},
    {"at": "2026-11-12T20:20:03Z", "item": null, "action": "finished", "detail": "0 in review, 0 blocked"}]}'
snapshot none none idle
out=$("$scripts/finish.sh" proj "$plan")
expect "finish dry-run: table is freshly rendered from the plan" "$out" "| #1 | Cache CI | Done | — | — |"
expect "finish dry-run: events heading is in chat output" "$out" "Events"
expect "finish dry-run: complete log includes its first event" "$out" "workspace w1"
expect "finish dry-run: complete log includes finished last" "$(tail -n 1 <<<"$out")" "| 2026-11-12T20:20:03Z | — | finished | 0 in review, 0 blocked |"
sandbox
plan_with '[]' '{"events": []}'
snapshot none none idle
out=$("$scripts/finish.sh" proj "$plan")
expect "finish: empty items are explicit" "$out" "(no items)"
expect "finish: empty event log is explicit" "$out" "No events recorded."

# with integrations: grouped, held header, <F>-integrate last
sandbox
plan_with "[$(item '#1' done '' '' | jq -c '. + {title: "A", integration: "F1"}'),
  $(item '#2' blocked '' '' x | jq -c '. + {title: "B | pipes", integration: "F1", reason: "needs info"}'),
  $(item 'F1-integrate' queued '' '' | jq -c '. + {title: "Open F1 PR", integrates: "F1", dependsOn: ["#1", "#2"]}'),
  $(item '#4' queued '' '' | jq -c '. + {title: "Plain"}')]" \
  '{"integrations": [{"id": "F1", "title": "CSV", "branch": "feature/csv", "base": "main", "pr": null, "state": "open"}]}'
snapshot none none idle
out=$("$scripts/table.sh" proj "$plan")
expect "table: integration header with held items" "$out" "| **F1 feature/csv** (held: #2 blocked) | | | | |"
expect "table: items under the header" "$out" "| #1 | A | Done | — | — |"
expect "table: pipes in titles are escaped" "$out" 'B \| pipes'
expect "table: blocked reason below the table" "$out" "#2 blocked: needs info"
expect "table: default-branch item stays ungrouped, after the group" "$out" "| #4 | Plain | Queued |"
order=$(grep -n -e '^| #1 ' -e '^| F1-integrate' -e '^| #4 ' <<<"$out" | cut -d'|' -f2 | tr -d ' \n')
expect "table: <F>-integrate row is last in its group" "$order" "#1F1-integrate#4"

# --- cycle.sh ----------------------------------------------------------------------------------
snap() { # snap <workspace:terminal:state>...
  local a
  a=$(printf '%s\n' "$@" | jq -R 'split(":") | {id: .[0], terminals: [{id: .[1], agent: {id: "claude", state: .[2]}}]}' | jq -sc .)
  jq -n --argjson w "$a" '{workspaces: ($w + [{id: "orch", terminals: []}])}' >"$FIX/snapshot.json"
}
prs() { # prs <branch> <state> <number> [extra-json]: the one PR GitHub lists
  local x=${4:-}; [[ -n $x ]] || x='{}'
  jq -nc --arg b "$1" --arg s "$2" --argjson n "$3" --argjson x "$x" \
    '[{headRefName: $b, number: $n, url: "https://github.com/acme/app/pull/\($n)", state: $s, isDraft: false} + $x]' >"$FIX/prs.json"
}
# one <state> <tag> <agent-state> [item-json] [plan-json]: a plan with the one item #1 (workspace w1,
# terminal t1, tagged <tag>; no tag: Paradev no longer has it). maxParallel 0 keeps dispatch out.
one() {
  local x=${4:-} p=${5:-}
  [[ -n $x ]] || x='{}'; [[ -n $p ]] || p='{"maxParallel": 0}'
  dispatch_sandbox
  plan_with "[$(item '#1' "$1" w1 t1 | jq -c ". + $x")]" "$p"
  [[ -z $2 ]] || ws w1 'b-#1' "$2"
  snap w1:t1:"$3"
}
cyc() { out=$("$scripts/cycle.sh" "$@" proj "$plan" 2>"$FIX/cycle.err"); rc=$?; }
pf() { jq -r --arg id "${2:-#1}" ".items[] | select(.id == \$id) | $1" "$plan"; }
evs() { jq -r '[.events[] | .item + ":" + .action] | join(" ")' <<<"$out"; }
needs() { jq -r '[.needs[] | .kind + ":" + .item] | join(" ")' <<<"$out"; }
done_screen() { printf '%s\n' "ORCHESTRATOR_WORKER_DONE" "item: #1" "pr: https://github.com/acme/app/pull/9" "summary: s" "checked: $1" "" >"$FIX/screens/t1"; }

# Reconcile -----------------------------------------------------------------------------------
one in-review "" idle; snap none:none:idle; prs 'b-#1' MERGED 9; cyc
expect "reconcile: workspace gone, PR merged -> done" "$(pf .state)" done
expect "reconcile: workspace gone is an event" "$(evs)" "#1:pr-merged"
one in-progress "" idle; snap none:none:idle; prs 'b-#1' OPEN 9; cyc
expect "reconcile: workspace gone, open PR -> accepting, not in-review" "$(pf .state)" accepting
expect "reconcile: workspace gone, open PR needs acceptance" "$(needs)" "accept:#1"
one in-review "" idle; snap none:none:idle; echo '[]' >"$FIX/prs.json"; cyc
expect "reconcile: workspace gone, no PR -> blocked" "$(pf '.state + "/" + .reason')" "blocked/workspace missing"
expect "reconcile: workspace gone, no PR needs the user" "$(needs)" "blocked:#1"
expect_exit "reconcile: a need exits 10" "$rc" 10

one in-progress "In Progress" working; ws w1x 'b-new' none >/dev/null; jq 'map(if .id == "w1" then .branch = "b-new" else . end)' "$FIX/workspaces.json" >"$FIX/w.tmp" && mv "$FIX/w.tmp" "$FIX/workspaces.json"; cyc
expect "reconcile: renamed branch is stored" "$(pf .branch)" "b-new"
expect "reconcile: renamed branch is an event" "$(evs)" "#1:reconciled"
one in-progress "In Progress" working; snap w1:t9:working; cyc
expect "reconcile: replaced terminal is stored" "$(pf .terminal)" t9
one in-progress "" working '{"workspace": null, "branch": "b-#1"}'; ws w9 'b-#1' "In Progress"; snap w9:t9:working; cyc
expect "reconcile: workspace-less in-progress item gets its workspace" "$(pf .workspace)" w9
one in-progress "" working '{"workspace": null, "branch": "b-#1"}'; snap none:none:idle; cyc
expect "reconcile: no workspace found -> queued" "$(pf .state)" queued
one queued "" idle '{"workspace": null, "branch": "b-#1"}'; ws w5 'b-#1' "In Progress"; snap w5:t5:working; cyc
expect "reconcile: a tagged workspace matching a workspace-less item is adopted" "$(pf .workspace)" w5
one in-progress "In Progress" working; ws w7 other-branch "In Progress"; cyc
expect "reconcile: a tagged workspace outside the plan is ignored" "$(evs)" ""
expect_exit "reconcile: nothing to do exits 0" "$rc" 0
one in-progress "Blocked" working; cyc
expect "reconcile: user moved it to Blocked" "$(pf '.state + "/" + .reason')" "blocked/moved by user"
one in-review "Done" idle; cyc
expect "reconcile: user moved it to Done" "$(pf .state)" done
one in-review "In Progress" idle; cyc
expect "reconcile: other tag mismatch re-applies the group" "$(cat "$FIX/tags.log")" "w1 In Review"
expect "reconcile: re-tag is an event" "$(evs)" "#1:tag-moved"
one in-review "In Review" idle '{}' '{"maxParallel": 0, "groups": {"In Review": "rev"}}'; ws w2 b2 other >/dev/null; cyc
expect "reconcile: no tag call when the group already matches" "$(cat "$FIX/tags.log" 2>/dev/null)" ""

# Watch and move -----------------------------------------------------------------------------
one in-progress "In Progress" working; prs 'b-#1' OPEN 9; cyc
expect "move: PR URL recorded as a string" "$(pf .pr)" "https://github.com/acme/app/pull/9"
expect "move: PR opened is an event" "$(evs)" "#1:pr-opened"
expect "move: a working item stays in-progress" "$(pf .state)" in-progress
one in-progress "In Progress" idle; prs 'b-#1' OPEN 9; done_screen "CI 4/4 green; criteria 4/5; unmet: docs"; cyc
expect "move: a DONE block goes to accepting, never in-review" "$(pf '.state + "/" + .acceptance')" "accepting/pending"
expect "move: checked saved from the DONE block" "$(pf .checked)" "CI 4/4 green; criteria 4/5; unmet: docs"
expect "move: criteria saved from the DONE block" "$(pf '.criteria | tojson')" '{"met":4,"total":5,"unmet":["docs"]}'
expect "move: the DONE block is an accept need" "$(needs)" "accept:#1"
expect "move: accepting is an event" "$(evs)" "#1:pr-opened #1:accepting"
one in-progress "In Progress" idle; prs 'b-#1' OPEN 9; done_screen "5/5 green"; cyc; cyc
expect "move: accepting stays until accept.sh, needs reported each cycle" "$(pf .state):$(needs)" "accepting:accept:#1"
expect_not "move: accepting is reported once as an event" "$(jq -r '[.events[] | .action] | join(" ")' "$plan")" "accepting accepting"
one in-review "In Review" working; cyc
expect "move: in-review + working -> feedback" "$(pf .state)" feedback
one feedback "In Progress" working '{"reason": "follow-up sent"}'; cyc
expect "move: working clears the follow-up reason" "$(pf '.reason // "none"')" none
one feedback "In Progress" working '{"reason": "acceptance follow-up"}'; cyc
expect "move: working clears the acceptance follow-up reason" "$(pf '.reason // "none"')" none
one feedback "In Progress" idle; cyc
expect "move: feedback + idle, no reason -> in-review" "$(pf .state)" in-review
one feedback "In Progress" idle '{"reason": "follow-up sent"}'; cyc
expect "move: feedback + idle, reason set -> wait" "$(pf .state)" feedback
one feedback "In Progress" idle '{"acceptance": "docs missing"}'; cyc
expect "move: after an acceptance follow-up, re-compare" "$(pf .state):$(needs)" "accepting:accept:#1"

one in-progress "In Progress" working; printf 'busy\n' >"$FIX/screens/t1"; "$scripts/status.sh" proj "$plan" >/dev/null
screens="$HOME/.agents/orchestrator/screens/20261112-1200.json"
jq --argjson old $(($(date +%s) - 20 * 60)) '.t1.since = $old' "$screens" >"$screens.tmp" && mv "$screens.tmp" "$screens"; cyc
expect "move: stalled is an event and a need, state unchanged" "$(evs) $(needs) $(pf .state)" "#1:stalled stalled:#1 in-progress"
cyc
expect "move: stalled is reported as an event once" "$(jq -r '[.events[] | select(.action == "stalled")] | length' "$plan")" 1
one in-progress "In Progress" working; printf '%s\n' "■ You've hit your usage limit. Try again in 3 hours." >"$FIX/screens/t1"; cyc
expect "move: fatal banner -> blocked with the banner" "$(pf '.state + "/" + .reason')" "blocked/■ You've hit your usage limit. Try again in 3 hours."
expect "move: fatal banner is a blocked need" "$(needs)" "blocked:#1"
one in-progress "In Progress" blocked; cyc
expect "move: Paradev blocked (needs input) is a question, state unchanged" "$(needs) $(pf .state)" "question:#1 in-progress"
one in-progress "In Progress" idle; cyc
expect "move: idle, no PR, no wait -> one follow-up" "$(cat "$FIX/send.log")" "t1 Please finish: commit, push and open the PR (gh pr create --base main), then print your RUNWAVES_WORKER_DONE block."
expect "move: the follow-up is recorded" "$(pf .reason) $(evs)" "follow-up sent #1:follow-up-sent"
cyc
expect "move: a second idle cycle blocks instead of a second follow-up" "$(pf '.state + "/" + .reason') $(wc -l <"$FIX/send.log" | tr -d ' ')" "blocked/no PR after the follow-up 1"
one in-progress "In Progress" idle; printf '%s\n' "ORCHESTRATOR_WORKER_BLOCKED" "item: #1" "reason: needs the staging key" "needs: a key" "" >"$FIX/screens/t1"; cyc
expect "move: a BLOCKED block -> blocked with its reason" "$(pf '.state + "/" + .reason')" "blocked/needs the staging key"
expect "move: no follow-up for a BLOCKED block" "$(cat "$FIX/send.log" 2>/dev/null)" ""
one in-progress "In Progress" idle; printf '%s\n' "ORCHESTRATOR_WORKER_WAITING" "item: #1" "waiting-on: code review" "resumes-when: it ends" "" >"$FIX/screens/t1"; cyc
expect "move: a declared wait is skipped (no follow-up, no transition)" "$(cat "$FIX/send.log" 2>/dev/null)$(pf .state)$(needs)" "in-progress"
WAIT_MINUTES=0 cyc
expect "move: a stale wait is reported for a screen check" "$(needs)" "stale-wait:#1"
expect "move: a stale wait is not read here (no follow-up)" "$(cat "$FIX/send.log" 2>/dev/null)" ""
one in-review "In Review" idle; prs 'b-#1' MERGED 9; cyc
expect "move: PR MERGED -> done" "$(pf .state)" done
expect "move: merged is an event, and the item moves to Done" "$(evs) | $(cat "$FIX/tags.log")" "#1:pr-merged #1:tag-moved :finished | w1 Done"
one in-review "In Review" idle; prs 'b-#1' CLOSED 9; cyc
expect "move: PR CLOSED unmerged -> blocked" "$(pf '.state + "/" + .reason')" "blocked/PR closed unmerged"
expect "move: closed PR is a closed-pr need" "$(needs)" "closed-pr:#1"

# a stacked PR conflicting with its done parent: the rebase follow-up, once
stack_sandbox() {
  dispatch_sandbox
  plan_with "[$(item '#1' done '' '' | jq -c '. + {pr: "https://github.com/acme/app/pull/5"}'),
    $(item '#2' in-review w2 t2 | jq -c '. + {dependsOn: ["#1"], pr: "https://github.com/acme/app/pull/12"}')]" '{"maxParallel": 0}'
  ws w2 'b-#2' "In Review"; snap w2:t2:idle
  prs 'b-#2' OPEN 12 '{"baseRefName": "b-#1", "mergeable": "CONFLICTING"}'
}
stack_sandbox; cyc
expect "move: conflicting stacked PR gets the rebase follow-up" "$(cat "$FIX/send.log")" "t2 #1 has merged. Run: git fetch origin && git rebase --onto origin/main <#1's tip you noted> HEAD, then git push --force-with-lease, and drop the \"merge #1 first\" line from the PR description."
expect "move: rebase follow-up -> feedback, follow-up sent" "$(pf '.state + "/" + .reason' '#2') $(evs)" "feedback/follow-up sent #2:follow-up-sent"
jq '(.items[] | select(.id == "#2")) |= (.state = "in-review" | .reason = null)' "$plan" >"$FIX/p.tmp" && mv "$FIX/p.tmp" "$plan"; cyc
expect "move: the rebase follow-up is sent once; still conflicting is told" "$(wc -l <"$FIX/send.log" | tr -d ' ') $(needs)" "1 blocked:#2"

# Dependency failure and recovery
dispatch_sandbox
plan_with "[$(item '#1' blocked '' '' 'needs a key'), $(item '#2' queued '' '' | jq -c '. + {dependsOn: ["#1"]}')]" '{"maxParallel": 0}'
snap none:none:idle; cyc
expect "move: dependency failure -> dependents waiting" "$(pf '.state + "/" + .reason' '#2')" "waiting/waiting on #1: needs a key"
expect "move: dependency failure is a need" "$(needs)" "dependency-failed:#2"
jq '(.items[] | select(.id == "#1")) |= (.state = "in-progress" | .reason = null)' "$plan" >"$FIX/p.tmp" && mv "$FIX/p.tmp" "$plan"; cyc
expect "move: recovery -> waiting dependents queued again" "$(pf '.state + "/" + (.reason // "none")' '#2')" "queued/none"

# Follow-up owed after another item merges
dispatch_sandbox
plan_with "[$(item '#1' done '' ''), $(item '#2' in-review w2 t2 | jq -c '. + {followUp: {after: "#1", message: "redo the config"}}')]" '{"maxParallel": 0}'
ws w2 'b-#2' "In Review"; snap w2:t2:idle; cyc
expect "move: a follow-up owed after a merge is sent" "$(cat "$FIX/send.log") $(pf '.state + "/" + .reason' '#2') $(pf '.followUp | tojson' '#2')" "t2 redo the config feedback/follow-up sent null"

# Merge gate ----------------------------------------------------------------------------------
merge_sandbox() { # merge_sandbox <checked> [plan-json]
  local p=${2:-}
  [[ -n $p ]] || p='{"maxParallel": 0, "integrations": [{"id": "F1", "title": "F", "branch": "feature/csv", "base": "main", "state": "open"}]}'
  dispatch_sandbox
  plan_with "[$(item '#30' in-review w30 t30 | jq -c --arg c "$1" '. + {integration: "F1", pr: "https://github.com/acme/app/pull/9", checked: $c, acceptance: "ok"}')]" \
    "$p"
  ws w30 'b-#30' "In Review"; snap w30:t30:idle; prs 'b-#30' OPEN 9
  pr_view OPEN feature/csv MERGEABLE '[{"name":"ci","conclusion":"SUCCESS"}]'
}
merge_sandbox "5/5 green"; cyc
expect "merge gate: a green sub-PR into an integration branch is merged" "$(cat "$FIX/merge.args")" "pr merge 9 --merge"
expect "merge gate: the item is done, with a merged event" "$(pf .state '#30') $(evs)" "done F1:rules #30:merged"
expect "merge gate: rules are read once per integration and stored" "$(jq -r '.integrations[0].mergeNote' "$plan")" ok
merge_sandbox "5/5 green"; pr_view OPEN feature/csv MERGEABLE '[{"name":"ci","conclusion":"FAILURE"}]'; cyc
expect "merge gate: red checks wait, no merge" "$(cat "$FIX/merge.args" 2>/dev/null)$(pf .state '#30')" "in-review"
merge_sandbox "5/5 green"; pr_view OPEN feature/csv MERGEABLE '[]'; cyc
expect "merge gate: no PR checks and no local run: one follow-up" "$(pf '.state + "/" + .reason' '#30') $(cat "$FIX/send.log" | cut -c1-30)" "feedback/acceptance follow-up t30 Run the project's tests lo"
expect "merge gate: the gap is an acceptance-gap event" "$(evs)" "#30:acceptance-gap #30:follow-up-sent"
merge_sandbox "5/5 green"; echo '[{"type":"required_linear_history"}]' >"$FIX/rules.json"; cyc
expect "merge gate: rules forbidding merge commits leave the merge to humans" "$(jq -r '.integrations[0].mergeNote' "$plan") $(cat "$FIX/merge.args" 2>/dev/null)" "human "
merge_sandbox "5/5 green" '{"maxParallel": 0}'; pr_view OPEN main MERGEABLE '[{"name":"ci","conclusion":"SUCCESS"}]'
jq '(.items[0]).integration = null' "$plan" >"$FIX/p.tmp" && mv "$FIX/p.tmp" "$plan"; cyc
expect "merge gate: a PR into the default branch is never merged" "$(cat "$FIX/merge.args" 2>/dev/null)" ""

# Integrations --------------------------------------------------------------------------------
integ='{"maxParallel": 0, "integrations": [{"id": "F1", "title": "CSV", "branch": "feature/csv", "base": "main", "state": "open"}]}'
dispatch_sandbox
plan_with "[$(item '#1' done '' '' | jq -c '. + {integration: "F1", pr: "https://github.com/acme/app/pull/5"}')]" "$integ"; snap none:none:idle; cyc
expect "integrate: ready -> the <F>-integrate item is added" "$(pf .state F1-integrate)" queued
dispatch_sandbox
plan_with "[$(item '#1' blocked '' '' 'needs a key' | jq -c '. + {integration: "F1"}')]" "$integ"; snap none:none:idle; cyc
expect "integrate: held is an event and a need" "$(evs) $(needs)" "F1:held held:F1"
cyc
expect "integrate: held is reported once per cause" "$(jq -r '[.events[] | select(.action == "held")] | length' "$plan")" 1

# Dispatch ------------------------------------------------------------------------------------
state_tag() { if [[ $1 == in-review ]]; then echo "In Review"; elif [[ $1 == done ]]; then echo Done; else echo "In Progress"; fi; }
disp_sandbox() { # disp_sandbox <parent-state> <parent-agent> <plan-json> [parent-json]
  local x=${4:-}; [[ -n $x ]] || x='{}'
  dispatch_sandbox
  plan_with "[$(item '#1' "$1" w1 t1 | jq -c ". + {pr: \"https://github.com/acme/app/pull/5\"} + $x"),
    $(item '#2' queued '' '' | jq -c '. + {dependsOn: ["#1"]}')]" "$3"
  ws w1 'b-#1' "$(state_tag "$1")"
  snap w1:t1:"$2"; prs 'b-#1' OPEN 5
}
disp_sandbox in-review idle '{"mergeMethods": ["squash", "merge"]}'; cyc
expect "dispatch: a dependency with a PR is stacked on its branch" "$(pf .state '#2') $(grep -A1 -e '--base-branch' "$FIX/create.args" | tr '\n' ' ')" "in-progress --base-branch b-#1 "
expect "dispatch: the dispatch is an event" "$(evs)" "#2:dispatched"
disp_sandbox in-review idle '{"mergeMethods": ["squash"]}'; cyc
expect "dispatch: squash-only repos wait for the merge, no stacking" "$(pf .state '#2')" queued
disp_sandbox done idle '{"mergeMethods": ["squash"]}'; jq '.items[0].state = "done"' "$plan" >"$FIX/p.tmp" && mv "$FIX/p.tmp" "$plan"; cyc
expect "dispatch: squash-only, parent merged -> starts on its target" "$(pf .state '#2') $(grep -A1 -e '--base-branch' "$FIX/create.args" | tr '\n' ' ')" "in-progress --base-branch main "
disp_sandbox in-progress working '{}' '{"pr": null}'; prs 'zzz' OPEN 5; cyc
expect "dispatch: a dependency without a PR is not started" "$(pf .state '#2')" queued
disp_sandbox feedback working '{}'; cyc
expect "dispatch: never stack on a feedback item" "$(pf .state '#2')" queued
disp_sandbox in-progress working '{"maxParallel": 1}'; jq '.items[1].dependsOn = []' "$plan" >"$FIX/p.tmp" && mv "$FIX/p.tmp" "$plan"; cyc
expect "dispatch: the parallel limit holds a queued item back" "$(pf .state '#2')" queued
disp_sandbox feedback working '{"maxParallel": 1}'; jq '.items[1].dependsOn = []' "$plan" >"$FIX/p.tmp" && mv "$FIX/p.tmp" "$plan"; cyc
expect "dispatch: feedback is outside the limit" "$(pf .state '#2')" in-progress
disp_sandbox accepting idle '{"maxParallel": 1}'; jq '.items[1].dependsOn = []' "$plan" >"$FIX/p.tmp" && mv "$FIX/p.tmp" "$plan"; cyc
expect "dispatch: accepting is outside the limit" "$(pf .state '#2')" in-progress
expect "dispatch: a fresh dispatch is not re-tagged" "$(cat "$FIX/tags.log" 2>/dev/null)" ""

# Finished ------------------------------------------------------------------------------------
one done Done idle; cyc
expect "finished: all done -> finished, status finished, notification" "$(jq -r .finished <<<"$out") $(pf . | jq -r .state) $(jq -r .status "$plan") $(wc -l <"$FIX/notify.log" | tr -d ' ')" "true done finished 1"
expect_exit "finished: exit 0 with nothing to judge" "$rc" 0
one in-review "In Review" idle; cyc; cyc
expect "finished: in-review only -> finished but the run stays active" "$(jq -r .finished <<<"$out") $(jq -r .status "$plan")" "true active"
expect "finished: notified once" "$(wc -l <"$FIX/notify.log" | tr -d ' ')" 1
expect "finished: notification text" "$(cat "$FIX/notify.log")" "notifications show Runwaves finished --body 1 in review, 0 blocked --sound"
one in-progress "In Progress" working; cyc
expect "finished: a running item is not finished" "$(jq -r .finished <<<"$out")" false

# Exit codes and dry-run ----------------------------------------------------------------------
one in-progress "In Progress" working; jq '.owner = "someone-else"' "$plan" >"$FIX/p.tmp" && mv "$FIX/p.tmp" "$plan"
before=$(cksum <"$plan"); cyc
expect "exit 3: taken over prints taken-over" "$out" taken-over
expect_exit "exit 3: taken over" "$rc" 3
cyc --dry-run; expect_exit "exit 3: taken over also in --dry-run" "$rc" 3
expect "exit 3: nothing written" "$(cksum <"$plan")" "$before"
one in-progress "In Progress" working; touch "$FIX/host-down"; before=$(jq -S 'del(.heartbeat)' "$plan" | cksum); cyc
expect_exit "exit 1: a status failure stops the cycle" "$rc" 1
expect "exit 1: nothing half-applied (only the heartbeat)" "$(jq -S 'del(.heartbeat)' "$plan" | cksum)" "$before"
one in-review "In Progress" idle; prs 'b-#1' MERGED 9; before=$(cksum <"$plan"); cyc --dry-run
expect "dry-run: reports what it would do" "$(evs) $(jq -r .dryRun <<<"$out")" "#1:pr-merged #1:tag-moved :finished true"
expect "dry-run: the plan file is byte-identical" "$(cksum <"$plan")" "$before"
expect "dry-run: no tag call, no table, no message" "$(cat "$FIX/tags.log" 2>/dev/null)$(jq -r .table <<<"$out")" "null"
merge_sandbox "5/5 green"; before=$(cksum <"$plan"); cyc --dry-run
expect "dry-run: merge gate would merge but does not" "$(cat "$FIX/merge.args" 2>/dev/null)$(evs)" "#30:merged"
expect "dry-run: merge leaves the plan alone" "$(cksum <"$plan")" "$before"
disp_sandbox in-review idle '{"mergeMethods": ["merge"]}'; before=$(cksum <"$plan"); cyc --dry-run
expect "dry-run: would dispatch, creates nothing" "$(evs) $(cat "$FIX/create.args" 2>/dev/null)" "#2:dispatched"
expect "dry-run: dispatch leaves the plan alone" "$(cksum <"$plan")" "$before"
# --- summary.sh: the run-summary page ---------------------------------------------------------
sandbox
plan_with "[$(item '#1' done '' '' | jq -c '. + {title: "A", integration: "F1", pr: "https://github.com/acme/app/pull/9", checked: "ran <script>alert(1)</script>", criteria: {met: 1, total: 2, unmet: ["handles <b>x</b>"]}, acceptance: "gap & more", extras: "follow-up", branch: "b-1"}'),
  $(item '#2' blocked '' '' x | jq -c '. + {title: "B", integration: "F1", reason: "needs info"}'),
  $(item 'F1-integrate' queued '' '' | jq -c '. + {title: "Open F1 PR", integrates: "F1"}')]" \
  '{"integrations": [{"id": "F1", "title": "CSV", "branch": "feature/csv", "base": "main", "pr": "https://github.com/acme/app/pull/20", "state": "open"}],
    "carryOver": [{"id": "#2", "state": "blocked", "reason": "carry me"}],
    "events": [{"at": "2026-11-12T20:15:03Z", "item": "#1", "action": "dispatched", "detail": "workspace w1"}]}'
out=$("$scripts/summary.sh" "$plan")
html=$(cat "$FIX/pages.html")
expect "summary: prints url and visibility on one line" "$out" "https://pages.example/run (just_me)"
expect "summary: default visibility is just_me" "$(cat "$FIX/pages.args")" "just_me"
expect "summary: title carries the runId" "$(cat "$FIX/pages.args")" "Run 20261112-1200"
expect "summary: worker text is escaped" "$html" "ran &lt;script&gt;alert(1)&lt;/script&gt;"
expect_not "summary: no raw script tag" "$html" "<script>"
expect "summary: unmet criteria listed" "$html" "1/2<ul><li>handles &lt;b&gt;x&lt;/b&gt;</li></ul>"
expect "summary: acceptance gap, escaped" "$html" "gap &amp; more"
expect "summary: PR link" "$html" 'href="https://github.com/acme/app/pull/9"'
expect "summary: integration final PR" "$html" 'href="https://github.com/acme/app/pull/20"'
expect "summary: reason" "$html" "needs info"
expect "summary: carry-over" "$html" "carry me"
expect "summary: events" "$html" "workspace w1"
expect "summary: integrate row follows its items" "$(grep -o -e '<td>#1</td>' -e '<td>#2</td>' -e '<td>F1-integrate</td>' <<<"$html" | tr -d '\n')" "<td>#1</td><td>#2</td><td>F1-integrate</td>"
expect "summary: pageId stored in the plan" "$(jq -r .pageId "$plan")" "page-1"
"$scripts/summary.sh" "$plan" >/dev/null
expect "summary: second run passes --page" "$(cat "$FIX/pages.args")" "page-1"
expect "summary: first run had no --page" "$(head -1 "$FIX/pages.log")" "-"
expect "summary: pageId unchanged" "$(jq -r .pageId "$plan")" "page-1"
expect "summary: org only via the flag" "$("$scripts/summary.sh" "$plan" --visibility org)" "(org)"
expect "summary: bad visibility is refused" "$("$scripts/summary.sh" "$plan" --visibility everyone 2>&1)" "just_me or org"
"$scripts/summary.sh" "$plan" --open >/dev/null
expect "summary: --open opens the browser pane" "$(cat "$FIX/panes.args")" "https://pages.example/run"
touch "$FIX/no-panes-open"; rm -f "$FIX/panes.args"
"$scripts/summary.sh" "$plan" --open >/dev/null
expect_exit "summary: --open without panes open still succeeds" "$?" 0

# Atomicity: a plan write that fails before anything is recorded sends and tags nothing.
one in-progress "In Review" idle '{}' '{"maxParallel": 0}'
jq '.items += [{id: "#9", state: "queued", pr: "not-a-url"}]' "$plan" >"$FIX/p.tmp" && mv "$FIX/p.tmp" "$plan"
before=$(jq -S 'del(.heartbeat)' "$plan" | cksum); cyc
expect_exit "atomic: a failed plan write exits 1" "$rc" 1
expect "atomic: no follow-up sent, no tag moved, plan unchanged" "$(cat "$FIX/send.log" "$FIX/tags.log" 2>/dev/null)$(jq -S 'del(.heartbeat)' "$plan" | cksum)" "$before"

# --- send.sh and accept.sh ---------------------------------------------------------------------
acc_plan() { # acc_plan [item-json]: item #1 accepting (workspace w1, terminal t1), the plan owned by me
  local x=${1:-}; [[ -n $x ]] || x='{}'
  one accepting "In Progress" idle "$(jq -nc --argjson x "$x" '{pr: "https://github.com/acme/app/pull/9", acceptance: "pending", checked: "CI 4/4 green", criteria: {met: 4, total: 5, unmet: ["docs"]}} + $x')"
}
pr_files() { # pr_files <n>: n files in src/ and docs/ of 10 additions, 2 deletions each
  jq -nc --argjson n "$1" '{files: [range($n) | {path: (if . % 2 == 0 then "src/f\(.).sh" else "docs/f\(.).md" end), additions: 10, deletions: 2}]}' >"$FIX/pr-files.json"
}
issue_body() { jq -nc --arg b "$1" '{body: $b}' >"$FIX/issue-1.json"; }
setplan() { jq "$1" "$plan" >"$FIX/p.tmp" && mv "$FIX/p.tmp" "$plan"; }

acc_plan; "$scripts/send.sh" "$plan" '#1' "hello there" --reason "follow-up sent"; rc=$?
expect_exit "send: a send exits 0" "$rc" 0
expect "send: the text goes to the worker's terminal" "$(cat "$FIX/send.log")" "t1 hello there"
expect "send: --reason moves the item to feedback with it" "$(pf '.state + "/" + .reason')" "feedback/follow-up sent"
expect "send: the send is an event" "$(jq -r '.events | map(.action + ":" + .detail) | join(" ")' "$plan")" "follow-up-sent:hello there"
acc_plan; "$scripts/send.sh" "$plan" '#1' "just so"
expect "send: without --reason the state is untouched" "$(pf .state)" accepting
acc_plan; setplan '.items[0].terminal = null'; rm -f "$FIX/send.log"
err=$("$scripts/send.sh" "$plan" '#1' "x" 2>&1); rc=$?
expect_exit "send: a missing terminal exits 1" "$rc" 1
expect "send: a missing terminal is named" "$err" "#1 has no terminal"
expect "send: a missing terminal sends and records nothing" "$(cat "$FIX/send.log" 2>/dev/null)$(jq '.events // [] | length' "$plan")" "0"
err=$("$scripts/send.sh" "$plan" '#9' "x" 2>&1)
expect "send: an unknown item is named" "$err" "no item #9"
acc_plan; setplan '.owner = "someone-else"'; rm -f "$FIX/send.log"
"$scripts/send.sh" "$plan" '#1' "x" >/dev/null 2>&1
expect_exit "send: not the owner exits 3" "$?" 3
expect "send: not the owner sends nothing" "$(cat "$FIX/send.log" 2>/dev/null)" ""

# packet
acc_plan; issue_body $'## Acceptance criteria\n- [ ] packet shows the diff for a small PR\n- [x] big ones list files\n\nBlocked by #49'
pr_files 2; printf '%s\n' '+one line' '-another' >"$FIX/pr.diff"
pk=$("$scripts/accept.sh" packet "$plan")
expect "packet: names the item and PR" "$pk" "https://github.com/acme/app/pull/9"
expect "packet: carries the issue's checklist" "$pk" "- [ ] packet shows the diff for a small PR"
expect_not "packet: leaves the issue's prose out" "$pk" "Blocked by"
expect "packet: the worker's criteria and unmet lines" "$pk" "criteria 4/5, unmet: docs"
expect "packet: the worker's checked" "$pk" "checked: CI 4/4 green"
expect "packet: files with additions and deletions" "$pk" "src/f0.sh +10 -2"
expect "packet: a small PR includes the diff" "$pk" "+one line"
expect "packet: small packet is under budget" "$([[ ${#pk} -lt 1100 ]] && echo yes)" yes
pr_files 40; seq 1 400 | sed 's/^/+/' >"$FIX/pr.diff"
pk=$("$scripts/accept.sh" packet "$plan")
expect "packet: a large PR lists names only" "$pk" "diff: omitted (480 lines changed"
expect_not "packet: a large PR has no diff lines" "$pk" "+399"
expect "packet: over 15 files are grouped by top-level directory" "$pk" "src/ 20 files +200 -40"
expect_not "packet: grouped output does not list files" "$pk" "src/f0.sh"
expect "packet: large packet is under budget" "$([[ ${#pk} -lt 1100 ]] && echo yes)" yes
pr_files 40; pk=$("$scripts/accept.sh" packet "$plan" --group-over 100 --diff-under 5000)
expect "packet: --group-over lifts the grouping" "$pk" "src/f0.sh +10 -2"
pr_files 2; seq 1 400 | sed 's/^/+/' >"$FIX/pr.diff"
expect "packet: a diff over --diff-under is dropped" "$("$scripts/accept.sh" packet "$plan" --diff-under 5)" "diff: omitted"
pk=$("$scripts/accept.sh" packet "$plan" --diff-under 100)
expect "packet: a long diff is cut to fit the budget" "$([[ ${#pk} -lt 1100 ]] && echo yes)$(grep -c 'diff cut' <<<"$pk")" "yes1"
acc_plan '{"ask": "make the export friendly"}'; pk=$("$scripts/accept.sh" packet "$plan")
expect "packet: a free-text item shows its ask" "$pk" "criteria: make the export friendly"

# packet default: exactly the accepting items
acc_plan; setplan '.items += [{id: "#2", state: "in-review", pr: "https://github.com/acme/app/pull/10"}, {id: "#3", state: "accepting", pr: "https://github.com/acme/app/pull/11"}]'
pr_files 1; : >"$FIX/pr.diff"
expect "packet: no argument lists the accepting items" "$("$scripts/accept.sh" packet "$plan" | grep '^== ' | cut -c1-5 | tr '\n' ' ')" "== #1 == #3 "
expect "packet: named IDs pick just those" "$("$scripts/accept.sh" packet "$plan" '#3' | grep -c '^== ')" 1
acc_plan; setplan '.maxParallel = 0'; cyc
expect "packet: the default set equals cycle.sh's accept needs" "$(needs)" "accept:#1"

# verdict ok
acc_plan; rm -f "$FIX/tags.log"; "$scripts/accept.sh" verdict "$plan" '#1' ok >/dev/null; rc=$?
expect_exit "verdict ok exits 0" "$rc" 0
expect "verdict ok: acceptance ok, in-review" "$(pf '.acceptance + "/" + .state')" "ok/in-review"
expect "verdict ok: the tag moves" "$(cat "$FIX/tags.log")" "w1 In Review"
expect "verdict ok: an in-review event" "$(jq -r '[.events[].action] | join(" ")' "$plan")" "in-review"
"$scripts/accept.sh" verdict "$plan" '#1' ok >/dev/null 2>&1
expect_exit "verdict: an item not accepting is refused" "$?" 1

# verdict gap
acc_plan; rm -f "$FIX/send.log"; "$scripts/accept.sh" verdict "$plan" '#1' gap "4 of 24 screenshots are covered" >/dev/null; rc=$?
expect_exit "verdict gap exits 0" "$rc" 0
expect "verdict gap: acceptance is the gap, state feedback with the reason" "$(pf '.acceptance + "/" + .state + "/" + .reason')" "4 of 24 screenshots are covered/feedback/acceptance follow-up"
expect "verdict gap: the follow-up reaches the terminal" "$(cat "$FIX/send.log")" "t1 4 of 24 screenshots are covered"
expect "verdict gap: both events" "$(jq -r '[.events[].action] | join(" ")' "$plan")" "acceptance-gap follow-up-sent"
setplan '.items[0].state = "accepting"'
err=$("$scripts/accept.sh" verdict "$plan" '#1' gap "another" 2>&1); rc=$?
expect_exit "verdict gap: a second gap exits 1" "$rc" 1
expect "verdict gap: a second gap says why" "$err" "never a second round"
expect "verdict gap: a second gap sends nothing" "$(wc -l <"$FIX/send.log" | tr -d ' ')" 1
acc_plan; rm -f "$FIX/send.log"; "$scripts/accept.sh" verdict "$plan" '#1' gap "checks not reported" >/dev/null
expect "verdict gap: a checks gap asks to wait for the checks" "$(cat "$FIX/send.log")" "gh pr checks https://github.com/acme/app/pull/9 --watch --fail-fast"
acc_plan; setplan '.items[0].terminal = null'
err=$("$scripts/accept.sh" verdict "$plan" '#1' gap "gap" 2>&1); rc=$?
expect "verdict gap: a missing terminal is an error and the plan is unchanged" "$rc:$err:$(pf .state)" "1:send: #1 has no terminal in the plan:accepting"

# --- local integration branch: no sub-PRs, merged in this clone ---------------------------------
local_integ='{"integrations": [{"id": "F1", "title": "CSV", "branch": "feature/csv", "base": "main", "pr": null, "state": "open", "local": true}]}'
# dispatch: the branch is created here from its base, never on origin; the worker opens no PR
dispatch_sandbox
git push -q origin HEAD:refs/heads/main
plan_with "[$(jq -nc '{id: "#20", title: "Add CSV export", state: "queued", integration: "F1", skill: "implement", agent: "claude"}')]" "$local_integ"
out=$(dispatch 2>&1)
expect "local dispatch: dispatches" "$out" "dispatched #20 -> issue-20-add-csv-export "
expect "local dispatch: the integration branch is in this clone" "$(git show-ref --verify --quiet refs/heads/feature/csv && echo yes)" yes
expect "local dispatch: and not on origin" "$(git ls-remote --heads origin feature/csv)" ""
args=$(cat "$FIX/create.args")
expect "local dispatch: starts from the local branch" "$args" $'--base-branch\nfeature/csv'
expect "local dispatch: the worker opens no PR" "$args" "open no PR and push nothing"
expect "local dispatch: tests before each commit" "$args" "Before every commit run the test suites"
expect "local dispatch: DONE names the local run" "$args" "pr: none (local integration)"
expect_not "local dispatch: no PR check instructions" "$args" "gh pr checks"
expect "local dispatch: still ends in a DONE block" "$args" "RUNWAVES_WORKER_DONE"
# a GitHub-side item waits for every check, quietly
dispatch_sandbox; dispatch >/dev/null 2>&1; args=$(cat "$FIX/create.args")
expect "dispatch: DONE waits for every check" "$args" "RUNWAVES_WORKER_DONE while a check is pending or red"
expect "dispatch: checks are watched quietly" "$args" '--watch --fail-fast >/dev/null 2>&1; echo exit=$?'
expect "dispatch: only failed checks are listed" "$args" "--json name,state,bucket"
expect "dispatch: an open PR is still the goal" "$args" "Your goal is an open PR"
# the integrate worker of a local integration pushes the branch and lists the tasks
dispatch_sandbox
git push -q origin HEAD:refs/heads/main
plan_with "[$(jq -nc '{id: "#1", title: "One", state: "done", integration: "F1", branch: "b-1", pr: null, skill: "implement", agent: "claude"}')]" "$local_integ"
git branch -q feature/csv
"$scripts/integrate.sh" add "$plan" F1 >/dev/null
out=$("$scripts/dispatch.sh" proj "$plan" F1-integrate 2>&1)
expect "local integrate: dispatches" "$out" "dispatched F1-integrate -> f1-integrate-integrate-csv "
args=$(cat "$FIX/create.args")
expect "local integrate: names the merged branches" "$args" "already merged into it in this clone"
expect "local integrate: lists the task" "$args" "#1 One"
expect "local integrate: pushes the branch" "$args" "git push origin HEAD:feature/csv"
expect "local integrate: opens feature to main" "$args" "gh pr create --base main --head feature/csv"

# merge.sh: an accepted branch with a passing local run merges into the local branch, never via gh
local_sandbox() { # local_sandbox <checked>: feature/csv from main; b-30 adds f; #30 in review on F1 (local)
  dispatch_sandbox
  git branch -q feature/csv
  git checkout -q -b b-30 && echo one >f && git add f && git commit -q -m one
  plan_with "[$(jq -nc --arg c "$1" '{id: "#30", state: "in-review", integration: "F1", branch: "b-30", pr: null, checked: $c, acceptance: "ok", workspace: "w30", terminal: "t30"}')]" \
    "$(jq -c '. + {maxParallel: 0}' <<<"$local_integ")"
}
local_sandbox "local: npm test passed"
expect "local gate: a passing local run merges" "$(gate)" "merge"
expect "local gate run: merges the branch into the integration branch" "$(gate run)" "merged b-30 into feature/csv"
expect "local gate run: the integration branch has the commit" "$(git merge-base --is-ancestor b-30 feature/csv && echo yes)" yes
expect "local gate run: with a merge commit" "$(git rev-list --merges --count feature/csv)" 1
expect "local gate run: never gh pr merge" "$(cat "$FIX/merge.args" 2>/dev/null)" ""
expect "local gate run: the temporary worktree is gone" "$(git worktree list | wc -l | tr -d ' ')" 1
local_sandbox "tests pass"
expect "local gate: a run not marked local gets a follow-up" "$(gate)" "followup:"
expect_exit "local gate: follow-up exits 3" "$(gate >/dev/null; echo $?)" 3
local_sandbox "local: npm test failed"
expect "local gate: a failing local run gets a follow-up" "$(gate)" "followup:"
local_sandbox "local: npm test passed"; jq '.items[0].branch = "b-missing"' "$plan" >"$plan.t" && mv "$plan.t" "$plan"
expect "local gate: a branch not in this clone waits" "$(gate)" "wait: branch b-missing is not in this clone"
local_sandbox "local: npm test passed"
git checkout -q feature/csv && echo two >f && git add f && git commit -q -m two && git checkout -q b-30
expect "local gate run: a conflict waits" "$(gate run)" "wait: b-30 conflicts with feature/csv"
expect "local gate run: and leaves the integration branch alone" "$(git log -1 --format=%s feature/csv)" two
expect "local gate run: a conflict cleans the worktree up" "$(git worktree list | wc -l | tr -d ' ')" 1

# cycle.sh: a local integration reads no rules, notes "local", merges and records the branch
merge_sandbox "local: npm test passed" "$(jq -c '. + {maxParallel: 0}' <<<"$local_integ")"
jq '.items[0].pr = null' "$plan" >"$plan.t" && mv "$plan.t" "$plan"
git branch -q feature/csv; git checkout -q -b 'b-#30' && echo one >f && git add f && git commit -q -m one
echo '[]' >"$FIX/prs.json"; echo '[{"type":"required_linear_history"}]' >"$FIX/rules.json"
cyc
expect "cycle local: mergeNote is local, rules unread" "$(jq -r '.integrations[0].mergeNote' "$plan")" local
expect "cycle local: the branch merges and the item is done" "$(pf .state '#30') $(evs)" "done F1:rules #30:merged"
expect "cycle local: the merged event names the branch" "$(jq -r '.events[] | select(.action == "merged") | .detail' "$plan")" "merged branch b-#30 into feature/csv"
expect "cycle local: never gh pr merge" "$(cat "$FIX/merge.args" 2>/dev/null)" ""
# an idle local worker with no PR and no DONE is asked to commit, not to open a PR
one in-progress "In Progress" idle '{"integration": "F1"}' "$(jq -c '. + {maxParallel: 0}' <<<"$local_integ")"
echo '[]' >"$FIX/prs.json"; printf 'done I think\n' >"$FIX/screens/t1"; cyc
expect "cycle local: the finish follow-up asks for a commit, no PR" "$(cat "$FIX/send.log")" "commit on your branch (no PR: feature/csv is a local integration branch)"

# accept.sh packet: a local item's files and diff come from git
acc_plan '{"pr": null, "integration": "F1"}'
setplan ".integrations = $(jq -c .integrations <<<"$local_integ")"
git branch -q feature/csv; git checkout -q -b 'b-#1' && printf 'x\n' >g && git add g && git commit -q -m g
pk=$("$scripts/accept.sh" packet "$plan")
expect "local packet: files from git" "$pk" "files: 1, +1 -0 (local branch b-#1 vs feature/csv, no PR)"
expect "local packet: the file" "$pk" "g +1 -0"
expect "local packet: the diff" "$pk" "+x"

# chains and epics take --local
sandbox
plan_with "[$(chain_item '#340' 'Cache Pester'), $(chain_item '#341' 'Split backup' '["#340"]'), $(chain_item '#350' 'Lone')]"
"$scripts/chains.sh" accept "$plan" --local '#341' >/dev/null
expect "chains: accept --local marks the integration local" "$(jq -c '.integrations[0] | [.id, .local]' "$plan")" '["F1",true]'
"$scripts/chains.sh" share "$plan" csv >/dev/null
expect "chains: without --local there is no local field" "$(jq -c '.integrations[1] | has("local")' "$plan")" false
sandbox
plan_with "[$(chain_item '#350' 'Lone')]"
"$scripts/chains.sh" share "$plan" csv --local >/dev/null
expect "chains: share --local marks the integration local" "$(jq -c '.integrations[0].local' "$plan")" true
sandbox
echo '{"number":400,"title":"CSV Export","url":"https://github.com/acme/app/issues/400"}' >"$FIX/epic.json"
echo '[{"number":401,"title":"Add button","state":"open","labels":[]}]' >"$FIX/sub-issues.json"
plan_with "[]"
"$scripts/epic.sh" import "$plan" 400 --local >/dev/null
expect "epic: import --local marks the integration local" "$(jq -c '.integrations[0].local' "$plan")" true

# --- local chain branches: critical-path chains inside a GitHub integration -------------------
gh_integ='{"integrations": [{"id": "F1", "title": "CSV", "branch": "feature/csv", "base": "main", "pr": null, "state": "open"}]}'
sandbox
plan_with "[$(chain_item '#1' 'Parse rows' '[]' F1), $(chain_item '#2' 'Map columns' '["#1"]' F1), $(chain_item '#3' 'Write file' '["#2"]' F1),
  $(chain_item '#5' 'Docs' '[]' F1), $(chain_item '#6' 'Docs example' '["#5"]' F1), $(chain_item '#9' 'Lone' '[]' F1)]" "$gh_integ"
out=$("$scripts/chains.sh" offer "$plan")
expect "local chain: a critical chain on a GitHub integration is offered" "$out" '"items":["#1","#2","#3"]'
expect "local chain: on a local branch into the integration branch" "$out" '"branch":"chain/1-parse-rows","parent":"F1"'
expect "local chain: the question names the one PR" "$out" 'run #1, #2, #3 on the local branch chain/1-parse-rows, one PR into feature/csv?'
expect_not "local chain: a chain off the critical path is not offered" "$out" '#5'
expect_not "local chain: nor a lone item" "$out" '#9'
expect "local chain: accept adds a local integration under F1" "$("$scripts/chains.sh" accept "$plan" '#2')" "added F2 chain/1-parse-rows (local, into feature/csv): #1, #2, #3"
expect "local chain: based on the parent's branch" "$(jq -c '.integrations[1] | [.id, .branch, .base, .parent, .local, .state]' "$plan")" \
  '["F2","chain/1-parse-rows","feature/csv","F1",true,"open"]'
expect "local chain: its items move to it" "$(jq -c '[.items[] | [.id, .integration]]' "$plan")" \
  '[["#1","F2"],["#2","F2"],["#3","F2"],["#5","F1"],["#6","F1"],["#9","F1"]]'
expect "local chain: an accepted chain is not offered again" "$("$scripts/chains.sh" offer "$plan")" ""
expect "local chain: accept refuses an item on no offered chain" "$("$scripts/chains.sh" accept "$plan" '#6' 2>&1)" "#6 is in no offered chain"
# a local integration has no sub-PRs already: nothing to offer
jq '.integrations = [.integrations[0] | .local = true] | .items |= map(.integration = "F1")' "$plan" >"$plan.t" && mv "$plan.t" "$plan"
expect "local chain: none inside a local integration" "$("$scripts/chains.sh" offer "$plan")" ""
# a diamond splits at its fork and join: each side is its own chain, the join waits for both
sandbox
plan_with "[$(chain_item '#1' 'Root' '[]' F1), $(chain_item '#2' 'Left a' '["#1"]' F1), $(chain_item '#3' 'Left b' '["#2"]' F1),
  $(chain_item '#4' 'Right a' '["#1"]' F1), $(chain_item '#5' 'Right b' '["#4"]' F1), $(chain_item '#6' 'Join' '["#3","#5"]' F1)]" "$gh_integ"
out=$("$scripts/chains.sh" offer "$plan")
expect "local chain: a diamond offers its left side" "$out" '"items":["#2","#3"]'
expect "local chain: and its right side" "$out" '"items":["#4","#5"]'
expect "local chain: not the fork or the join" "$(wc -l <<<"$out" | tr -d ' ')" 2

# integrate.sh: a chain lands on its parent through one <F>-integrate sub-PR; the parent waits for it
chain_integ='{"integrations": [{"id": "F1", "title": "CSV", "branch": "feature/csv", "base": "main", "pr": null, "state": "open"},
  {"id": "F2", "title": "Parse rows", "branch": "chain/1-parse-rows", "base": "feature/csv", "parent": "F1", "pr": null, "state": "open", "local": true}]}'
chain_plan() { # chain_plan <state of #1> <state of #2> <state of #9>: #1 <- #2 on chain F2, #9 straight on F1
  plan_with "[$(jq -nc --arg s "$1" '{id: "#1", title: "Parse rows", state: $s, integration: "F2", branch: "b-1", skill: "implement", agent: "claude"}'),
    $(jq -nc --arg s "$2" '{id: "#2", title: "Map columns", state: $s, integration: "F2", dependsOn: ["#1"], branch: "b-2"}'),
    $(jq -nc --arg s "$3" '{id: "#9", title: "Lone", state: $s, integration: "F1", pr: "https://github.com/acme/app/pull/7"}')]" "$chain_integ"
}
sandbox
chain_plan done in-review done
out=$(integ check)
expect "chain integrate: an open chain keeps its parent open" "$out" "open F1: F2"
expect "chain integrate: the chain itself is open" "$out" "open F2: #2"
chain_plan done done done
expect "chain integrate: a finished chain is ready" "$(integ check)" "ready F2"
expect_not "chain integrate: its parent is not ready before the chain lands" "$(integ check)" "ready F1"
expect "chain integrate: add queues the chain's item" "$(integ add F2)" "added F2-integrate"
expect "chain integrate: the item is a sub-PR of the parent" \
  "$(jq -c '.items[] | select(.id == "F2-integrate") | [.state, .integrates, .integration]' "$plan")" '["queued","F2","F1"]'
expect "chain integrate: the parent waits for it" "$(integ check)" "open F1: F2-integrate"
jq '(.items[] | select(.id == "F2-integrate")).state = "done" | .integrations[1].state = "merged"' "$plan" >"$plan.t" && mv "$plan.t" "$plan"
expect "chain integrate: once it merges the parent is ready" "$(integ check)" "ready F1"
expect "chain integrate: the parent's final item is not a chain's" "$(integ add F1 && jq -c '.items[] | select(.id == "F1-integrate") | .integration' "$plan")" "null"
chain_plan done blocked done
out=$(integ check)
expect "chain integrate: a held chain is held" "$out" "held F2: #2 blocked"
expect "chain integrate: and holds its parent" "$out" "held F1: F2"
chain_plan skipped skipped done
jq '.items[0].dropped = true | .items[1].dropped = true' "$plan" >"$plan.t" && mv "$plan.t" "$plan"
out=$(integ check)
expect "chain integrate: an all-dropped chain is empty" "$out" "empty F2"
expect "chain integrate: and releases its parent" "$out" "ready F1"

# dispatch: a chain item starts on the local chain branch, cut from the parent's branch on origin
dispatch_sandbox
git push -q origin HEAD:refs/heads/main
chain_plan queued queued queued
out=$("$scripts/dispatch.sh" proj "$plan" '#1' 2>&1)
expect "chain dispatch: dispatches" "$out" "dispatched #1 -> "
expect "chain dispatch: the parent branch is created on origin" "$(git ls-remote --heads origin feature/csv | wc -l | tr -d ' ')" 1
expect "chain dispatch: the chain branch is in this clone" "$(git show-ref --verify --quiet refs/heads/chain/1-parse-rows && echo yes)" yes
expect "chain dispatch: and not on origin" "$(git ls-remote --heads origin chain/1-parse-rows)" ""
args=$(cat "$FIX/create.args")
expect "chain dispatch: starts from the chain branch" "$args" $'--base-branch\nchain/1-parse-rows'
expect "chain dispatch: the worker opens no PR" "$args" "open no PR and push nothing"
# the chain's integrate worker pushes it and opens one PR into the parent, which the gate merges
dispatch_sandbox
git push -q origin HEAD:refs/heads/main
chain_plan done done queued
git branch -q chain/1-parse-rows
"$scripts/integrate.sh" add "$plan" F2 >/dev/null
out=$("$scripts/dispatch.sh" proj "$plan" F2-integrate 2>&1)
expect "chain integrate dispatch: dispatches" "$out" "dispatched F2-integrate -> "
args=$(cat "$FIX/create.args")
expect "chain integrate dispatch: starts from the chain branch" "$args" $'--base-branch\nchain/1-parse-rows'
expect "chain integrate dispatch: pushes the chain branch" "$args" "git push origin HEAD:chain/1-parse-rows"
expect "chain integrate dispatch: opens chain to parent" "$args" "gh pr create --base feature/csv --head chain/1-parse-rows"
expect "chain integrate dispatch: lists the chain's tasks" "$args" "#2 Map columns"
expect "chain integrate dispatch: the coordinator merges it" "$args" "the coordinator merges it into feature/csv once its checks pass"
expect_not "chain integrate dispatch: not left to the user" "$args" "the user reviews and merges it"
expect "chain integrate dispatch: waits for its checks" "$args" "RUNWAVES_WORKER_DONE while a check is pending or red"
expect "chain integrate dispatch: the parent stays on origin" "$(git show-ref --verify --quiet refs/heads/feature/csv || echo none)" none

# merge.sh: a chain item merges into its chain branch in this clone; a conflict waits, a red run is not merged
local_sandbox "local: npm test passed"
jq --argjson i "$(jq -c .integrations <<<"$chain_integ")" '.integrations = $i | .items[0].integration = "F2"' "$plan" >"$plan.t" && mv "$plan.t" "$plan"
git branch -q chain/1-parse-rows feature/csv
expect "chain gate run: merges into the chain branch" "$(gate run)" "merged b-30 into chain/1-parse-rows"
expect "chain gate run: never gh pr merge" "$(cat "$FIX/merge.args" 2>/dev/null)" ""
expect "chain gate run: the parent branch is untouched" "$(git merge-base --is-ancestor b-30 feature/csv || echo untouched)" untouched
local_sandbox "local: npm test failed"
jq --argjson i "$(jq -c .integrations <<<"$chain_integ")" '.integrations = $i | .items[0].integration = "F2"' "$plan" >"$plan.t" && mv "$plan.t" "$plan"
git branch -q chain/1-parse-rows feature/csv
expect "chain gate: a red local run is not merged" "$(gate)" "followup:"
local_sandbox "local: npm test passed"
jq --argjson i "$(jq -c .integrations <<<"$chain_integ")" '.integrations = $i | .items[0].integration = "F2"' "$plan" >"$plan.t" && mv "$plan.t" "$plan"
git checkout -q -b chain/1-parse-rows feature/csv && echo two >f && git add f && git commit -q -m two && git checkout -q b-30
expect "chain gate run: a conflict waits" "$(gate run)" "wait: b-30 conflicts with chain/1-parse-rows"

# cycle.sh: each chain's PR into the parent stands alone; a join across chains waits for both to land
two_chains='{"maxParallel": 5, "integrations": [{"id": "F1", "title": "CSV", "branch": "feature/csv", "base": "main", "pr": null, "state": "open"},
  {"id": "F2", "title": "Left", "branch": "chain/2-left", "base": "feature/csv", "parent": "F1", "pr": null, "state": "open", "local": true},
  {"id": "F3", "title": "Right", "branch": "chain/4-right", "base": "feature/csv", "parent": "F1", "pr": null, "state": "open", "local": true}]}'
chain_cycle_sandbox() { # #2 <- #3 on F2 and #4 <- #5 on F3 done; F2-integrate (PR 11) and F3-integrate (PR 12) in review; #6 joins
  dispatch_sandbox
  git push -q origin HEAD:refs/heads/main HEAD:refs/heads/feature/csv
  plan_with "[$(jq -nc '{id: "#2", state: "done", integration: "F2"}'), $(jq -nc '{id: "#3", state: "done", integration: "F2", dependsOn: ["#2"]}'),
    $(jq -nc '{id: "#4", state: "done", integration: "F3"}'), $(jq -nc '{id: "#5", state: "done", integration: "F3", dependsOn: ["#4"]}'),
    $(item F2-integrate in-review w11 t11 | jq -c '. + {integrates: "F2", integration: "F1", pr: "https://github.com/acme/app/pull/11", checked: "3/3 green", acceptance: "ok"}'),
    $(item F3-integrate in-review w12 t12 | jq -c '. + {integrates: "F3", integration: "F1", pr: "https://github.com/acme/app/pull/12", checked: "3/3 green", acceptance: "ok"}'),
    $(jq -nc '{id: "#6", title: "Join", state: "queued", integration: "F1", dependsOn: ["#3", "#5"], skill: "implement", agent: "claude"}')]" "$two_chains"
  ws w11 b-F2-integrate "In Review"; ws w12 b-F3-integrate "In Review"; snap w11:t11:idle w12:t12:idle
  jq -n '[{headRefName: "b-F2-integrate", number: 11, url: "https://github.com/acme/app/pull/11", state: "OPEN", isDraft: false},
    {headRefName: "b-F3-integrate", number: 12, url: "https://github.com/acme/app/pull/12", state: "OPEN", isDraft: false}]' >"$FIX/prs.json"
  pr_view OPEN feature/csv MERGEABLE '[{"name":"ci","conclusion":"SUCCESS"}]'; mv "$FIX/pr-view.json" "$FIX/pr-view-11.json"
  pr_view OPEN feature/csv MERGEABLE '[{"name":"ci","conclusion":"FAILURE"}]'; mv "$FIX/pr-view.json" "$FIX/pr-view-12.json"
}
chain_cycle_sandbox; cyc
expect "chain cycle: the green chain PR merges into the parent" "$(pf .state F2-integrate) $(cat "$FIX/merge.args")" "done pr merge 11 --merge"
expect "chain cycle: and its chain is merged" "$(jq -r '.integrations[1].state' "$plan")" merged
expect "chain cycle: the red chain PR waits on its own chain" "$(pf .state F3-integrate) $(jq -r '.integrations[2].state' "$plan")" "in-review open"
expect "chain cycle: the join waits for every chain it needs" "$(pf .state '#6')" queued
pr_view OPEN feature/csv MERGEABLE '[{"name":"ci","conclusion":"SUCCESS"}]'; mv "$FIX/pr-view.json" "$FIX/pr-view-12.json"
cyc
expect "chain cycle: the fixed chain PR merges" "$(pf .state F3-integrate) $(jq -r '.integrations[2].state' "$plan")" "done merged"
expect "chain cycle: then the join dispatches" "$(pf .state '#6')" in-progress
# inside its own chain a done item is enough: the next link starts on the chain branch at once
chain_cycle_sandbox
jq '.items |= map(if .id == "#3" then .state = "queued" | .title = "Left b" | .skill = "implement" | .agent = "claude" else . end)
  | .items |= map(select(.id != "F2-integrate"))' "$plan" >"$plan.t" && mv "$plan.t" "$plan"
cyc
expect "chain cycle: the next link in a chain starts" "$(pf .state '#3')" in-progress

# a chain item never stacks on an unmerged sub-PR of its parent: it waits for the merge
chain_cycle_sandbox
jq '.items |= map(if .id == "#2" then .state = "queued" | .title = "Left a" | .skill = "implement" | .agent = "claude" | .dependsOn = ["#8"] else . end)
  | .items += [{id: "#8", state: "in-review", integration: "F1", branch: "b-8", pr: "https://github.com/acme/app/pull/8"}]
  | .items |= map(select(.id != "F2-integrate" and .id != "F3-integrate"))' "$plan" >"$plan.t" && mv "$plan.t" "$plan"
echo '[]' >"$FIX/prs.json"; cyc
expect "chain cycle: a chain item does not stack on a sub-PR" "$(pf .state '#2')" queued
# the chain's integrate row shows once, in the chain's group
chain_cycle_sandbox
out=$("$scripts/table.sh" proj "$plan" 2>&1)
expect "chain table: the chain's integrate row shows once" "$(grep -c '^| F2-integrate ' <<<"$out")" 1

# --- wait-change noise filter + watch.sh -------------------------------------------------------
noise_sandbox() { # #1 in-review idle, #2 in-progress working; events carry #2's dispatch <age> seconds ago
  dispatch_sandbox
  plan_with "[$(item '#1' in-review w1 t1), $(item '#2' in-progress w2 t2)]" '{"maxParallel": 0}'
  ws w1 'b-#1' "In Review"; ws w2 'b-#2' "In Progress"
  snap w1:t1:idle w2:t2:working
}
nw() { POLL_SECONDS=1 "$scripts/wait-change.sh" "$@" proj "$plan" 3 2>&1; }
flip() { (sleep 1; snap "$@") & }

noise_sandbox; flip w1:t1:working w2:t2:working
expect "noise: idle->working on an in-review item is ignored" "$(nw)" "timeout"
noise_sandbox; flip w1:t1:working w2:t2:working
expect "noise: --all-changes keeps it" "$(nw --all-changes)" "changed: #1 agent idle->working"
noise_sandbox; flip w1:t1:idle w2:t2:idle
expect "noise: working->idle on an in-progress item still counts" "$(nw)" "changed: #2 agent working->idle"
noise_sandbox; jq '(.items[] | select(.id == "#1")) |= (.state = "feedback" | .reason = "follow-up sent")' "$plan" >"$FIX/p.tmp" && mv "$FIX/p.tmp" "$plan"
flip w1:t1:working w2:t2:working
expect "noise: feedback with a reason is ignored" "$(nw)" "timeout"
noise_sandbox; jq '(.items[] | select(.id == "#1")) |= (.state = "feedback" | .reason = null)' "$plan" >"$FIX/p.tmp" && mv "$FIX/p.tmp" "$plan"
flip w1:t1:working w2:t2:working
expect "noise: feedback without a reason still counts" "$(nw)" "changed: #1 agent idle->working"
noise_sandbox; (sleep 1; prs 'b-#1' OPEN 9 '{"mergeable": "CONFLICTING"}') &
expect "noise: a conflict flag on a quiet item still counts" "$(nw)" "changed: #1 pr none->OPEN, conflict none->true"
noise_sandbox; (sleep 1; prs 'b-#1' MERGED 9) &
expect "noise: a PR state change on a quiet item still counts" "$(nw)" "changed: #1 pr none->MERGED"

# none->working within 90s of the dispatched event
noise_sandbox; snap w1:t1:idle none:none:idle
dispatched() { jq --arg at "$1" '.events = [{at: $at, item: "#2", action: "dispatched", detail: "x"}]' "$plan" >"$FIX/p.tmp" && mv "$FIX/p.tmp" "$plan"; }
jq -n '{workspaces: [{id: "w1", terminals: [{id: "t1", agent: {id: "claude", state: "idle"}}]}, {id: "w2", terminals: []}, {id: "orch", terminals: []}]}' >"$FIX/snapshot.json"
dispatched "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
flip w1:t1:idle w2:t2:working
expect "noise: none->working just after dispatch is ignored" "$(nw)" "timeout"
noise_sandbox
jq -n '{workspaces: [{id: "w1", terminals: [{id: "t1", agent: {id: "claude", state: "idle"}}]}, {id: "w2", terminals: []}, {id: "orch", terminals: []}]}' >"$FIX/snapshot.json"
dispatched "$(ago 5)"
flip w1:t1:idle w2:t2:working
expect "noise: none->working long after dispatch counts" "$(nw)" "changed: #2 agent none->working"
noise_sandbox
jq -n '{workspaces: [{id: "w1", terminals: [{id: "t1", agent: {id: "claude", state: "idle"}}]}, {id: "w2", terminals: []}, {id: "orch", terminals: []}]}' >"$FIX/snapshot.json"
dispatched "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
flip w1:t1:idle w2:t2:working
expect "noise: --all-changes keeps none->working after dispatch" "$(nw --all-changes)" "changed: #2 agent none->working"

# watch.sh
wt() { out=$(POLL_SECONDS=1 "$scripts/watch.sh" "$@" proj "$plan" "${WT:-15}" 2>"$FIX/watch.err"); rc=$?; }
# A finish observed by a cycle must end this watch iteration without entering another wait.
watch_fixture="$FIX/issue-74-orchestrator-verify-watch-sh"
mkdir -p "$watch_fixture"
cp "$scripts/watch.sh" "$watch_fixture/watch.sh"
cat >"$watch_fixture/cycle.sh" <<'EOF'
#!/usr/bin/env bash
count=0
[[ ! -f $FIX/issue-74-orchestrator-verify-watch-sh/cycles ]] || count=$(cat "$FIX/issue-74-orchestrator-verify-watch-sh/cycles")
count=$((count + 1))
echo "$count" >"$FIX/issue-74-orchestrator-verify-watch-sh/cycles"
if ((count == 1)); then
  echo '{"events":[],"needs":[],"finished":false,"table":null}'
else
  echo '{"events":[{"at":"2026-11-15T12:34:00Z","item":null,"action":"finished","detail":"0 in review, 0 blocked"}],"needs":[],"finished":true,"table":null}'
fi
EOF
cat >"$watch_fixture/wait-change.sh" <<'EOF'
#!/usr/bin/env bash
count=0
[[ ! -f $FIX/issue-74-orchestrator-verify-watch-sh/waits ]] || count=$(cat "$FIX/issue-74-orchestrator-verify-watch-sh/waits")
echo $((count + 1)) >"$FIX/issue-74-orchestrator-verify-watch-sh/waits"
echo changed
EOF
chmod +x "$watch_fixture/watch.sh" "$watch_fixture/cycle.sh" "$watch_fixture/wait-change.sh"
FIX="$FIX" out=$(FIX="$FIX" "$watch_fixture/watch.sh" proj "$plan" 10 2>"$FIX/issue-74-watch.err"); rc=$?
expect_exit "watch: finish during an iteration exits with documented status" "$rc" 0
expect "watch: finished cycle is not followed by another wait" "$(cat "$watch_fixture/waits")" 1
expect "watch: one finished event is emitted" "$(grep -c 'finished 0 in review, 0 blocked' <<<"$out")" 1
expect "watch: finished is the final output line" "$(tail -n 1 <<<"$out")" finished
noise_sandbox; prs 'b-#1' OPEN 9
(sleep 1; prs 'b-#1' MERGED 9) &
(sleep 5; printf '%s\n' "ORCHESTRATOR_WORKER_DONE" "item: #2" "pr: https://github.com/acme/app/pull/10" "summary: s" "checked: 1/1 green" "" >"$FIX/screens/t2"; snap w2:t2:idle) &
wt
expect_exit "watch: a merge is handled alone, a DONE block ends it with exit 10" "$rc" 10
expect "watch: the merge produced an event line" "$out" " #1 pr-merged "
expect "watch: the DONE block is an accept need" "$(grep '^\[' <<<"$out")" '"kind":"accept","item":"#2"'
expect "watch: the last line is needs 1" "$(tail -n 1 <<<"$out")" "needs 1"
expect "watch: the needs JSON follows the events and precedes the last line" "$(tail -n 2 <<<"$out" | head -n 1 | cut -c1-1)" "["
expect "watch: event lines start HH:MM" "$(grep pr-merged <<<"$out")" "$(date -u +%H):"
noise_sandbox; WT=3 wt
expect_exit "watch: quiet timeout exits 0" "$rc" 0
expect "watch: an empty events list is printed, not absent" "$out" "events: none"
expect "watch: timeout is the last line" "$(tail -n 1 <<<"$out")" "timeout"
expect "watch: every cycle refreshes the heartbeat" "$(jq -r '.heartbeat' "$plan" | cut -c1-13)" "$(date -u +%Y-%m-%dT%H)"
noise_sandbox; jq '.owner = "someone-else"' "$plan" >"$FIX/p.tmp" && mv "$FIX/p.tmp" "$plan"
(sleep 1; snap w1:t1:idle w2:t2:idle) &
wt
expect_exit "watch: takeover exits 3" "$rc" 3
expect "watch: takeover prints taken-over last" "$(tail -n 1 <<<"$out")" "taken-over"
noise_sandbox; jq '.items |= map(.state = "done")' "$plan" >"$FIX/p.tmp" && mv "$FIX/p.tmp" "$plan"
(sleep 1; snap none:none:idle) &
wt
expect "watch: a finished run prints finished" "$(tail -n 1 <<<"$out")" "finished"
expect_exit "watch: finished exits 0" "$rc" 0
noise_sandbox; touch "$FIX/host-down"; WT=3 wt
expect_exit "watch: an error exits 1" "$rc" 1
expect "watch: an error says why" "$(tail -n 1 <<<"$out")" "error: "

# usage.py: totals, tool kinds and --run pairing, from tiny synthetic transcripts
if command -v python3 >/dev/null; then
  sandbox
  tl() { # tl <time> <output> <cache-read> <tool-use-json|none|empty> [id]
    jq -nc --arg t "$1" --argjson o "$2" --argjson c "$3" --arg id "${5:-x}" --arg u "$4" '{type: "assistant", timestamp: $t,
      message: {id: $id, usage: {input_tokens: 5, output_tokens: $o, cache_read_input_tokens: $c, cache_creation_input_tokens: 100},
      content: (if $u == "empty" then [] elif $u == "none" then [{type: "text", text: "hi"}] else [{type: "tool_use", id: $id, name: "Bash", input: {command: $u}}] end)}}'
  }
  proj="$root/projects"
  orch="$proj/$(printf %s "$(cd "$root/repo" && pwd)" | sed 's#[/.]#-#g')"
  mkdir -p "$orch" "$proj/-x-worktree-app-issue-7-thing"
  { tl 2026-11-14T10:00:00Z 10 1000 'plan.sh heartbeat' a; tl 2026-11-14T10:01:00Z 20 3000 'cycle.sh p plan' b
    tl 2026-11-14T10:02:00Z 30 2000 'jq . x | plan.sh write -' c; tl 2026-11-14T10:03:00Z 40 2000 'ls' d
    tl 2026-11-14T10:04:00Z 50 2000 none e; tl 2026-11-14T10:04:00Z 0 0 empty f; } >"$orch/o.jsonl"
  tl 2026-11-14T10:00:30Z 200 10000 'ls' w1 >"$proj/-x-worktree-app-issue-7-thing/w.jsonl"
  tl 2026-11-14T10:05:30Z 300 20000 none w2 >>"$proj/-x-worktree-app-issue-7-thing/w.jsonl"
  jq -n '{repo: "acme/app", runId: "R1", items: [{id: "#7", branch: "issue-7-thing"}]}' >"$HOME/.agents/orchestrator/acme-app.json"
  out=$(python3 -I "$scripts/usage.py" "$orch/o.jsonl" 2>&1)
  expect "usage: counts turns and output" "$(tail -n 1 <<<"$out" | awk '{print $2, $3, $4}')" "6 150 600"
  expect "usage: reports visible chat-only turns" "$(awk 'NR == 3 {print $13}' <<<"$out")" "1"
  expect "usage: labels chat-only column" "$out" "chat-only"
  expect "usage: reads peak context and duration" "$out" "4m00s"
  out=$(python3 -I "$scripts/usage.py" --turns 2 "$orch/o.jsonl" 2>&1)
  expect "usage: --turns cuts the transcript" "$(tail -n 1 <<<"$out" | awk '{print $2, $3}')" "2 30"
  out=$(python3 -I "$scripts/usage.py" --run R1 --repo-dir "$root/repo" --projects-dir "$proj" --plans-dir "$HOME/.agents/orchestrator" 2>&1)
  expect "usage: --run pairs a worker" "$out" "worker issue-7-thing"
  expect "usage: --run prints the percentage" "$out" "orchestrator output: 150 of 500 worker output = 30.0%"
  expect "usage: --run counts hand-written plan writes" "$out" "hand-written plan writes (jq ... | plan.sh write): 1"
fi

# --- Orca backend: ownership, dispatch, status, send ------------------------------------------
orca_on() { unset SUPERSET_TERMINAL_ID; export ORCA_TERMINAL_HANDLE=${1:-term_me}; }
orca_off() { unset ORCA_TERMINAL_HANDLE; export SUPERSET_TERMINAL_ID=me; }

sandbox; orca_on
jq -n '{repo: "acme/app", status: "active", items: []}' >"$root/next.json"
"$scripts/plan.sh" write "$root/next.json" >/dev/null
expect "orca plan: the owner is the Orca terminal handle" "$(jq -r .owner "$plan")" "term_me"
expect "orca plan: check says mine" "$("$scripts/plan.sh" check)" "mine"
orca_on term_other
echo '[{"handle": "term_me", "orphaned": false, "connected": true, "agentIdentity": "claude"}]' >"$FIX/orca-terminals.json"
out=$("$scripts/plan.sh" claim 2>&1); code=$?
expect_exit "orca plan: a live Orca owner refuses a second run" $code 3
echo '[{"handle": "term_me", "orphaned": false, "connected": true}]' >"$FIX/orca-terminals.json"
out=$("$scripts/plan.sh" claim 2>&1); code=$?
expect_exit "orca plan: an owner terminal with no agent is stale" $code 4
echo '[]' >"$FIX/orca-terminals.json"
out=$("$scripts/plan.sh" claim --takeover 2>&1); code=$?
expect_exit "orca plan: a gone Orca owner is taken over" $code 0
expect "orca plan: the takeover names the old owner" "$out" "taken over from term_me"
orca_off

dispatch_sandbox; orca_on; jq '.owner = "term_me"' "$plan" >"$plan.tmp" && mv "$plan.tmp" "$plan"
mkdir -p "$FIX/orca-wt"; git -C "$FIX/orca-wt" init -q -b krucx/issue-20-add-csv-export-please
out=$("$scripts/dispatch.sh" - "$plan" '#20' 2>&1); code=$?
expect_exit "orca dispatch: success exits 0" $code 0
expect "orca dispatch: one summary line" "$out" "dispatched #20 -> krucx/issue-20-add-csv-export-please (orca dispatch ctx_new, terminal term_new)"
expect "orca dispatch: plan records dispatch, terminal and Orca's branch" "$(plan_item)" \
  '{"state":"in-progress","branch":"krucx/issue-20-add-csv-export-please","workspace":"ctx_new","terminal":"term_new"'
args=$(cat "$FIX/orca-start.args")
expect "orca dispatch: a new child worktree" "$args" $'--worktree\nnew-child'
expect "orca dispatch: named after the branch" "$args" $'--name\nissue-20-add-csv-export-please'
expect "orca dispatch: from the target" "$args" $'--base-branch\nmain'
spec=$(cat "$FIX/orca-spec")
expect "orca dispatch: spec starts with the skill" "$(head -n 1 "$FIX/orca-spec")" "/implement #20"
expect "orca dispatch: spec asks for a PR into the target" "$spec" "Finish with a PR into main"
expect "orca dispatch: spec stays within the item" "$spec" "Other agents are changing this repo in parallel (#21): stay within #20."
for proto in WORKER_DONE WORKER_BLOCKED WORKER_WAITING "gh pr checks" "Docker Compose" "criteria:"; do
  expect_not "orca dispatch: no worker protocol ($proto)" "$spec" "$proto"
done
expect_exit "orca dispatch: the spec is short" "$(($(wc -c <"$FIX/orca-spec") < 600))" 1
expect_not "orca dispatch: no Paradev workspace" "$(cat "$FIX/create.args" 2>/dev/null)" "--project"

dispatch_sandbox; orca_on; jq '.owner = "term_me"' "$plan" >"$plan.tmp" && mv "$plan.tmp" "$plan"
echo "agent not enabled" >"$FIX/orca-start-fail"
out=$("$scripts/dispatch.sh" - "$plan" '#20' 2>&1); code=$?
expect_exit "orca dispatch: a failed start exits 1" $code 1
expect "orca dispatch: a failed start rolls back to queued" "$(plan_item)" '"state":"queued","branch":null'
orca_off

sandbox; orca_on
plan_with "[$(item '#1' in-progress ctx_1 term_1), $(item '#2' in-progress ctx_2 term_2), $(item '#3' in-progress ctx_gone '')]" '{"owner": "term_me"}'
mkdir -p "$FIX/orca-workers"
echo '{"dispatchId": "ctx_1", "runId": "run_1", "state": "succeeded", "terminal": "term_1"}' >"$FIX/orca-workers/ctx_1"
echo '{"dispatchId": "ctx_2", "runId": "run_1", "state": "running", "terminal": "term_2", "waitingOnHuman": true}' >"$FIX/orca-workers/ctx_2"
jq -n '[{type: "worker_done", body: "Done.\nRUNWAVES_WORKER_DONE\nitem: #1\npr: https://github.com/acme/app/pull/5\nsummary: s\nchecked: 2/2 green\ncriteria: 3/3\n",
         payload: {dispatchId: "ctx_1"}}]' >"$FIX/orca-inbox.json"
echo '[{"headRefName": "b-#1", "number": 5, "url": "https://github.com/acme/app/pull/5", "state": "OPEN", "isDraft": false}]' >"$FIX/prs.json"
rows=$("$scripts/status.sh" - "$plan")
row() { jq -c --arg i "$1" "select(.item == \$i) | $2" <<<"$rows"; }
expect "orca status: a settled dispatch is idle" "$(row '#1' .agent.state)" '"idle"'
expect "orca status: the worker_done block is parsed" "$(row '#1' .worker)" '"marker":"done"'
expect "orca status: criteria from the block" "$(row '#1' .worker.criteria)" '{"met":3,"total":3,"unmet":[]}'
expect "orca status: the branch's PR" "$(row '#1' .pr.number)" "5"
expect "orca status: waiting on a human is blocked with no reason" "$(row '#2' .agent)" '"reason":null,"state":"blocked"'
expect "orca status: an unknown dispatch is missing" "$(row '#3' .missing)" "true"
jq -n '[{type: "worker_done", subject: "#1 done: PR #5", body: "Opened PR #5; 2/2 checks green, npm test passed.",
         payload: {dispatchId: "ctx_1"}}]' >"$FIX/orca-inbox.json"
rows=$("$scripts/status.sh" - "$plan")
expect "orca status: a plain report counts as done" "$(row '#1' .worker.marker)" '"done"'
expect "orca status: the report is checked" "$(row '#1' .worker.checked)" "2/2 checks green, npm test passed."
echo '{"dispatchId": "ctx_1", "runId": "run_1", "state": "failed", "terminal": "term_1"}' >"$FIX/orca-workers/ctx_1"
rows=$("$scripts/status.sh" - "$plan")
expect "orca status: a failed dispatch's report is a block" "$(row '#1' .worker)" '"marker":"blocked","reason":"Opened PR #5'
echo '{"dispatchId": "ctx_1", "runId": "run_1", "state": "succeeded", "terminal": "term_1"}' >"$FIX/orca-workers/ctx_1"

out=$("$scripts/cycle.sh" - "$plan" 2>&1); code=$?
expect_exit "orca cycle: needs the model" $code 10
expect "orca cycle: the DONE item goes to acceptance" "$out" '"kind":"accept","item":"#1"'
expect "orca cycle: a worker question surfaces" "$out" '"kind":"question","item":"#2"'
expect_exit "orca cycle: no tag moves on Orca" "$([[ -f $FIX/tags.log ]] && echo moved || echo none)" none

expect "orca graph: one Orca run for the plan" "$(jq -r .orcaRun "$plan")" "run_g"
expect "orca graph: every item gets a Task" "$(jq -c '[.items[].orcaTask]' "$plan")" '["task_1","task_2","task_3"]'
expect "orca graph: the run is recorded as an event" "$(jq -c '[.events[] | select(.action == "graph")] | length' "$plan")" "4"

sandbox; orca_on
plan_with "[$(item '#1' done ctx_1 term_1), $(item '#2' queued '' ''), $(item '#3' queued '' ''), $(item '#4' skipped '' '' 'out of scope')]" '{"owner": "term_me"}'
jq '(.items[] | select(.id == "#1")) |= (.pr = "https://github.com/acme/app/pull/5")
    | (.items[] | select(.id == "#2")).dependsOn = ["#1"] | (.items[] | select(.id == "#3")).dependsOn = ["#1", "#2"]
    | (.items[] | select(.id == "#2")).state = "waiting" | (.items[] | select(.id == "#3")).state = "waiting"' "$plan" >"$plan.tmp" && mv "$plan.tmp" "$plan"
mkdir -p "$FIX/orca-workers"; echo '{"dispatchId": "ctx_1", "runId": "run_1", "state": "succeeded", "terminal": "term_1"}' >"$FIX/orca-workers/ctx_1"
"$scripts/cycle.sh" - "$plan" >/dev/null 2>&1
log=$(cat "$FIX/orca-graph.log")
expect "orca graph: Tasks in dependency order, deps as Task IDs" "$log" 'task-create run_g task_3 #3  deps=["task_1","task_2"]'
expect "orca graph: a dependency's Task comes first" "$log" 'task-create run_g task_2 #2  deps=["task_1"]'
expect "orca graph: a done item's Task is completed with its PR" "$log" "task-update task_1 completed https://github.com/acme/app/pull/5"
expect "orca graph: a skipped item's Task fails" "$log" "task-update task_4 failed skipped: out of scope"
expect_not "orca graph: a waiting item's Task is left to Orca" "$log" "task-update task_2"
"$scripts/cycle.sh" - "$plan" >/dev/null 2>&1
expect "orca graph: a second cycle creates and updates nothing" "$(grep -c . "$FIX/orca-graph.log")" "7"
orca_off

sandbox; orca_on
plan_with "[$(item '#1' queued '' '')]" '{"owner": "term_me", "orcaRun": "run_g"}'
touch "$FIX/orca-task-fail"
out=$("$scripts/cycle.sh" - "$plan" 2>&1)
expect "orca graph: a failed task-create is reported" "$out" "Orca task-create for #1 failed"
expect "orca graph: and retried next cycle (no Task recorded)" "$(jq -c '.items[0].orcaTask' "$plan")" "null"
orca_off

dispatch_sandbox; orca_on; jq '.owner = "term_me" | .items[0].orcaTask = "task_9"' "$plan" >"$plan.tmp" && mv "$plan.tmp" "$plan"
mkdir -p "$FIX/orca-wt"; git -C "$FIX/orca-wt" init -q -b krucx/issue-20-add-csv-export-please
dispatch >/dev/null 2>&1
expect "orca dispatch: the worker is a child of the item's Task" "$(cat "$FIX/orca-start.args")" $'--parent\ntask_9'
orca_off
sandbox; orca_on
plan_with "[$(item '#1' in-progress ctx_1 term_1), $(item '#2' in-progress ctx_2 term_2), $(item '#3' in-progress ctx_gone '')]" '{"owner": "term_me"}'
mkdir -p "$FIX/orca-workers"
echo '{"dispatchId": "ctx_2", "runId": "run_1", "state": "running", "terminal": "term_2", "waitingOnHuman": true}' >"$FIX/orca-workers/ctx_2"

"$scripts/send.sh" "$plan" '#2' "use the staging key" >/dev/null; code=$?
expect_exit "orca send: exits 0" $code 0
expect "orca send: goes to the dispatch" "$(cat "$FIX/orca-send.log")" "dispatch:ctx_2 use the staging key"
orca_off

# --- Orca reports: string payloads, replacement dispatches, failed outcomes ---------------------
orca_report_sandbox() { # orca_report_sandbox <payload-json>: #1 in-progress on ctx_1 into feature/csv, one worker_done
  sandbox; orca_on
  plan_with "[$(item '#1' in-progress ctx_1 term_1)]" \
    '{"owner": "term_me", "integrations": [{"id": "F1", "branch": "feature/csv", "base": "main", "state": "open"}]}'
  setplan '.items[0].integration = "F1"'
  mkdir -p "$FIX/orca-workers"
  echo '{"dispatchId": "ctx_1", "taskId": "task_w1", "runId": "run_1", "state": "succeeded", "terminal": "term_1"}' >"$FIX/orca-workers/ctx_1"
  jq -n --argjson p "$1" '[{type: "worker_done", subject: "#1 PR #5 open into feature/csv",
    body: "Opened PR #5 into feature/csv. no PR checks; local: npm test passed.", payload: $p}]' >"$FIX/orca-inbox.json"
  echo '[{"headRefName": "b-#1", "number": 5, "url": "https://github.com/acme/app/pull/5", "state": "OPEN", "isDraft": false}]' >"$FIX/prs.json"
}
orca_rows() { rows=$("$scripts/status.sh" - "$plan"); }

for payload in '"taskId=task_w1 dispatchId=ctx_1 outcome=succeeded filesModified=src/a.ts,src/b.ts"' \
    '"{\"taskId\":\"task_w1\",\"dispatchId\":\"ctx_1\",\"outcome\":\"succeeded\",\"filesModified\":[\"src/a.ts\"]}"' \
    '{"taskId": "task_w1", "dispatchId": "ctx_1", "outcome": "succeeded"}'; do
  kind=$(jq -r 'if type == "object" then "object" elif startswith("{") then "JSON string" else "key=value" end' <<<"$payload")
  orca_report_sandbox "$payload"; orca_rows
  expect "orca report ($kind payload): matched to its dispatch" "$(row '#1' .worker.marker)" '"done"'
  expect "orca report ($kind payload): the body is checked" "$(row '#1' .worker.checked)" "local: npm test passed"
done

# A key=value report goes all the way: acceptance sees `checked`, and the gate merges the green sub-PR.
orca_report_sandbox '"taskId=task_w1 dispatchId=ctx_1 outcome=succeeded"'
"$scripts/cycle.sh" - "$plan" >/dev/null 2>&1
expect "orca report: the item is accepting with the worker's checked" "$(jq -c '.items[0] | [.state, .checked]' "$plan")" \
  '["accepting","Opened PR #5 into feature/csv. no PR checks; local: npm test passed."]'
issue_body $'## Acceptance criteria\n- [ ] one'; pr_files 1; : >"$FIX/pr.diff"
expect "orca report: the packet shows checked" "$("$scripts/accept.sh" packet "$plan")" "checked: Opened PR #5 into feature/csv"
"$scripts/accept.sh" verdict "$plan" '#1' ok >/dev/null 2>&1
pr_view OPEN feature/csv MERGEABLE '[{"name":"ci","conclusion":"SUCCESS"}]'
expect "orca report: merge.sh check passes the green sub-PR" "$("$scripts/merge.sh" check "$plan" '#1' 2>&1)" "merge"

# outcome=failed partway: blocked with the worker's own reason, not "idle with no PR".
orca_report_sandbox '"taskId=task_w1 dispatchId=ctx_1 outcome=failed"'
echo '[]' >"$FIX/prs.json"
jq '.[0].subject = "Stopped: usage limit" | .[0].body = "Hit the usage limit after the migration; tests not run."' \
  "$FIX/orca-inbox.json" >"$FIX/i.tmp" && mv "$FIX/i.tmp" "$FIX/orca-inbox.json"
orca_rows
expect "orca report: outcome=failed is a block" "$(row '#1' .worker)" '"marker":"blocked","reason":"Hit the usage limit'
out=$("$scripts/cycle.sh" - "$plan" 2>&1)
expect "orca report: the failed item is blocked with its reason" "$(jq -c '.items[0] | [.state, .reason]' "$plan")" \
  '["blocked","Hit the usage limit after the migration; tests not run."]'
expect_not "orca report: no finish follow-up" "$(cat "$FIX/orca-send.log" 2>/dev/null)" "Please finish"

# A replacement dispatch (the follow-up reached an exited worker) reports for the same item.
replacement() { # replacement <payload-json> [worker-show of ctx_r]: ctx_1 exited quietly, ctx_r reports
  orca_report_sandbox "$1"
  setplan '.items[0].orcaTask = "task_g1"'
  echo '[]' >"$FIX/orca-inbox.json"
  jq -n --argjson p "$1" '[{type: "worker_done", subject: "PR #5 opened", from_handle: "term_r",
    body: "Opened PR #5 into feature/csv. no PR checks; local: npm test passed.", payload: $p}]' >"$FIX/orca-inbox.json"
  [[ -z ${2:-} ]] || echo "$2" >"$FIX/orca-workers/ctx_r"
}
replacement '"taskId=task_w1 dispatchId=ctx_r outcome=succeeded"'
orca_rows
expect "orca replacement: linked by the dispatch's task" "$(row '#1' '[.id, .replaces, .agent.terminal, .worker.marker]')" '["ctx_r","ctx_1","term_r","done"]'
"$scripts/cycle.sh" - "$plan" >/dev/null 2>&1
expect "orca replacement: the plan records the new dispatch and terminal" "$(jq -c '.items[0] | [.workspace, .terminal, .state]' "$plan")" \
  '["ctx_r","term_r","accepting"]'
expect "orca replacement: a reconciled event" "$(jq -c '[.events[] | select(.action == "reconciled") | .detail]' "$plan")" \
  "replacement dispatch ctx_r (terminal term_r) adopted for ctx_1"
expect_not "orca replacement: one event, not a terminal swap too" "$(jq -c '[.events[] | .detail]' "$plan")" "worker replaced"
replacement '"taskId=task_g1 dispatchId=ctx_r outcome=succeeded"'
orca_rows; expect "orca replacement: linked by the item's Orca task" "$(row '#1' .id)" '"ctx_r"'
replacement '"taskId=task_x dispatchId=ctx_r outcome=succeeded"' \
  '{"dispatchId": "ctx_r", "taskId": "task_x", "runId": "run_1", "followUpOf": "ctx_1", "state": "succeeded", "terminal": "term_r2"}'
orca_rows; expect "orca replacement: linked by Orca's followUpOf" "$(row '#1' '[.id, .agent.terminal]')" '["ctx_r","term_r2"]'
replacement '"taskId=task_x dispatchId=ctx_r outcome=succeeded"'
jq '.[0].subject = "#1 done: PR #5"' "$FIX/orca-inbox.json" >"$FIX/i.tmp" && mv "$FIX/i.tmp" "$FIX/orca-inbox.json"
orca_rows; expect "orca replacement: linked by the item in its subject" "$(row '#1' .id)" '"ctx_r"'
replacement '"taskId=task_x dispatchId=ctx_r outcome=succeeded"'
jq '.[0].subject = "#12 done"' "$FIX/orca-inbox.json" >"$FIX/i.tmp" && mv "$FIX/i.tmp" "$FIX/orca-inbox.json"
orca_rows; expect "orca replacement: an unlinked report is not adopted" "$(row '#1' '[.id, .worker]')" '["ctx_1",null]'
orca_off

# zsh too, when installed
if command -v zsh >/dev/null; then
  dispatch_sandbox
  expect "zsh: dispatch runs" "$(zsh "$scripts/dispatch.sh" proj "$plan" '#20' 2>&1)" "dispatched #20"
fi

echo
echo "$pass passed, $fail failed (bash $BASH_VERSION, $(uname -s))"
((fail == 0))
