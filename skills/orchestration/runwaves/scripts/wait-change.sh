#!/usr/bin/env bash
# Block until something the coordinator acts on changes (a worker's agent state, a group tag, a
# workspace vanishing, a PR appearing, merging, closing or turning conflicting), or the timeout.
# Only plan workspaces count, plus tagged ones whose branch matches a workspace-less plan item;
# with no plan, all. Polls every POLL_SECONDS (60); meanwhile, where the CLI has `agents wait`,
# one per working terminal wakes the script within seconds of a worker settling.
#
# Noise filter (off with --all-changes): a working<->idle flip is ignored on items the plan has in-review,
# done, or in feedback with a reason, unless their PR state or conflict flag changes too; and none->working
# is ignored within 90 seconds of the item's `dispatched` event.
#
# Usage: wait-change.sh [--all-changes] <project-id> [plan-file] [timeout-seconds]   (default 1200)
# Prints "changed: #340 agent working->idle, pr none->OPEN; ..." or "timeout". Failing checks
# (status.sh already retries) don't stop the wait; still failing at the timeout: error, exit 1.
set -euo pipefail

allChanges=''
[[ ${1:-} == --all-changes ]] && { allChanges=1; shift; }
project=$1
plan=${2:-}
timeout=${3:-1200}
here=$(cd "$(dirname "$0")" && pwd)

adoptBranches=null
if [[ -n "$plan" && -f "$plan" ]]; then
  adoptBranches=$(jq -c '[.items[] | select(.workspace == null) | .branch | strings]' "$plan")
fi

# Items whose agent flips are noise (in-review, done, feedback with a reason), and each item's latest
# `dispatched` event as epoch seconds; both from the plan on disk.
quietItems() {
  [[ -n "$plan" && -f "$plan" ]] || { echo '[]'; return; }
  jq -c '[.items[] | select(.state == "in-review" or .state == "done" or (.state == "feedback" and (.reason // "") != "")) | .id]' "$plan"
}
dispatchedAt() {
  [[ -n "$plan" && -f "$plan" ]] || { echo '{}'; return; }
  jq -c '[(.events // [])[] | select(.action == "dispatched" and .item != null)
      | {key: .item, value: (.at | fromdateiso8601)}] | from_entries' "$plan" 2>/dev/null || echo '{}'
}

signature() {
  "$here/status.sh" "$project" "$plan" >"$rowsfile" || return
  jq -sc --argjson adoptBranches "$adoptBranches" '
      map(select($adoptBranches == null or .inPlan or (.branch as $b | $adoptBranches | index($b) != null))
        | {id, item, group, missing, agent: .agent.state, pr: (.pr.state // null), conflict: (.pr.conflicting // null)})' "$rowsfile"
}

# One `agents wait` per working plan terminal, as direct background children (so they can be
# killed on exit); without the command in this CLI, only the poll runs.
cli=$(command -v superset || command -v paradev || command -v pdev || true)
canWait=''
[[ -n $cli ]] && "$cli" agents wait --help >/dev/null 2>&1 && canWait=1
wpids=() wterms=()

startWaiters() { # for each working terminal in the last status rows not already waited on
  [[ -n $canWait ]] || return 0
  local ws t i known left=$((deadline - SECONDS))
  ((left > 0)) || return 0
  while IFS=$'\t' read -r ws t; do
    [[ -n $t ]] || continue
    known=''
    for ((i = 0; i < ${#wterms[@]}; i++)); do [[ ${wterms[i]} == "$t" ]] && known=1; done
    [[ -n $known ]] && continue
    "$cli" agents wait --local --workspace "$ws" --terminal "$t" --until settled --timeout "$left" \
      </dev/null >/dev/null 2>&1 &
    wpids+=($!) wterms+=("$t")
  done < <(jq -r 'select(.inPlan and (.missing | not) and .agent.state == "working" and .agent.terminal != null)
    | [.id, .agent.terminal] | @tsv' "$rowsfile")
}

# Drop finished waiters; succeeds when one of them saw its agent settle.
reapWaiters() {
  local i rc woke=1 np=() nt=()
  for ((i = 0; i < ${#wpids[@]}; i++)); do
    if kill -0 "${wpids[i]}" 2>/dev/null; then
      np+=("${wpids[i]}") nt+=("${wterms[i]}")
    else
      rc=0; wait "${wpids[i]}" 2>/dev/null || rc=$?
      ((rc == 0)) && woke=0
    fi
  done
  wpids=(${np[@]+"${np[@]}"}) wterms=(${nt[@]+"${nt[@]}"})
  return $woke
}

stopWaiters() {
  ((${#wpids[@]})) || return 0
  kill "${wpids[@]}" 2>/dev/null || true
  wait "${wpids[@]}" 2>/dev/null || true
  wpids=() wterms=()
}

errfile=$(mktemp "${TMPDIR:-/tmp}/wait-change.XXXXXX")
rowsfile=$(mktemp "${TMPDIR:-/tmp}/wait-change.XXXXXX")
trap 'stopWaiters; rm -f "$errfile" "$rowsfile"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
start='' err=''
deadline=$((SECONDS + timeout))

while :; do
  if now=$(signature 2>"$errfile"); then
    err=''
    if [[ -z $start ]]; then
      start=$now
    else
      changed=$(jq -r --argjson start "$start" --argjson quiet "$(quietItems)" --argjson dispatched "$(dispatchedAt)" \
          --argjson all "${allChanges:-0}" --argjson t "$(date +%s)" '
        def noise($k; $was; $now; $item):
          $all == 0 and $k == "agent" and (
            (($was.agent == "working" and $now.agent == "idle") or ($was.agent == "idle" and $now.agent == "working"))
              and ($quiet | index($item)) != null
            or (($was.agent // "none") == "none" and $now.agent == "working" and ($dispatched[$item] // 0) > $t - 90));
        [.[] | . as $now | ([$start[] | select(.id == $now.id)][0]) as $was | ($now.item // $now.id) as $item
          | select($was != $now)
          | if $was == null then "\($item) appeared" else
              ([("group", "missing", "agent", "pr", "conflict") as $k | select($was[$k] != $now[$k])
                | select(noise($k; $was; $now; $item) | not)
                | "\($k) \($was[$k] // "none")->\($now[$k] // "none")"] | join(", ")) as $d
              | select($d != "") | "\($item) \($d)" end]
        | join("; ")' <<<"$now")
      if [[ -n "$changed" ]]; then
        echo "changed: $changed"
        exit 0
      fi
    fi
  else
    err=$(tail -n 1 "$errfile")
    err=${err:-status.sh failed}
  fi
  ((SECONDS < deadline)) || break
  startWaiters
  if ((${#wpids[@]})); then
    for ((tick = 0; tick < ${POLL_SECONDS:-60}; tick++)); do
      sleep 1
      reapWaiters && break
    done
  else
    sleep "${POLL_SECONDS:-60}"
  fi
done
if [[ -n $err ]]; then
  echo "checks still failing at timeout: $err" >&2
  exit 1
fi
echo timeout
