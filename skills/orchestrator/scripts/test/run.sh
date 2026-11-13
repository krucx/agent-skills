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
expect "dispatch: prompt defines the wait block" "$args" "ORCHESTRATOR_WORKER_WAITING"
expect "dispatch: wait block names what it waits on" "$args" "waiting-on: <what you are waiting for>"
expect "dispatch: waiting is not blocked" "$args" "Waiting is not blocked"
expect "dispatch: markers go on a line of their own" "$args" "the marker on a line of its own"
expect_not "dispatch: output never echoes the prompt" "$out" "ORCHESTRATOR_WORKER_DONE"

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
  $'Orchestrator\'s notes (context and what stays out of scope; they add no work):\nLives in search/. Out of scope: the image cache.\n'
expect "two-part: still a plan label" "$args" "T2 is a label in this run's plan only"
plan_with "[$(jq -nc '{id: "T3", title: "Fix login", ask: "fix the login redirect", notes: null, state: "queued", branch: null}')]"
"$scripts/dispatch.sh" proj "$plan" T3 >/dev/null 2>&1
args=$(cat "$FIX/create.args")
expect "two-part: words alone when there are no notes" "$args" $'fix the login redirect\n'
expect_not "two-part: no empty notes label" "$args" "Orchestrator's notes"
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
expect "integrate dispatch: worker prompt still ends in a DONE block" "$args" "ORCHESTRATOR_WORKER_DONE"

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

# zsh too, when installed
if command -v zsh >/dev/null; then
  dispatch_sandbox
  expect "zsh: dispatch runs" "$(zsh "$scripts/dispatch.sh" proj "$plan" '#20' 2>&1)" "dispatched #20"
fi

echo
echo "$pass passed, $fail failed (bash $BASH_VERSION, $(uname -s))"
((fail == 0))
