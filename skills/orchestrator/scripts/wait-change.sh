#!/usr/bin/env bash
# Block until something the orchestrator acts on changes (a worker's agent state, a group tag, a
# workspace vanishing, a PR appearing, merging, closing or turning conflicting), or the timeout.
# Only plan workspaces count, plus tagged ones whose branch matches a workspace-less plan item;
# with no plan, all. Polls every POLL_SECONDS (60); meanwhile, where the CLI has `agents wait`,
# one per working terminal wakes the script within seconds of a worker settling.
#
# Usage: wait-change.sh <project-id> [plan-file] [timeout-seconds]   (default 1200)
# Prints "changed: #340 agent working->idle, pr none->OPEN; ..." or "timeout". Failing checks
# (status.sh already retries) don't stop the wait; still failing at the timeout: error, exit 1.
set -euo pipefail

project=$1
plan=${2:-}
timeout=${3:-1200}
here=$(cd "$(dirname "$0")" && pwd)

adoptBranches=null
if [[ -n "$plan" && -f "$plan" ]]; then
  adoptBranches=$(jq -c '[.items[] | select(.workspace == null) | .branch | strings]' "$plan")
fi

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
      changed=$(jq -r --argjson start "$start" '
        [.[] | . as $now | ([$start[] | select(.id == $now.id)][0]) as $was
          | select($was != $now)
          | "\($now.item // $now.id) " + if $was == null then "appeared" else
              ([("group", "missing", "agent", "pr", "conflict") as $k | select($was[$k] != $now[$k])
                | "\($k) \($was[$k] // "none")->\($now[$k] // "none")"] | join(", ")) end]
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
