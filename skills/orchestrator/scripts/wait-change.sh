#!/usr/bin/env bash
# Block until something the orchestrator acts on changes, or until the timeout passes:
# a worker's agent state, a workspace's group tag, a workspace disappearing, or a PR
# appearing, merging or closing. Only plan workspaces count, plus tagged ones whose branch
# matches a plan item without a workspace (Reconcile adopts those); with no plan, all count.
# Checks once a minute. When it exits, act on what changed and start it again.
#
# Usage: wait-change.sh <project-id> [plan-file] [timeout-seconds]   (default 1200)
# Prints the workspaces that changed, with their old values; prints "timeout" if none did.
# A failing check (e.g. GitHub unreachable; status.sh already retries) doesn't stop the wait;
# only if checks still fail at the timeout does it print the error and exit 1.
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
  "$here/status.sh" "$project" "$plan" |
    jq -sc --argjson adoptBranches "$adoptBranches" '
      map(select($adoptBranches == null or .inPlan or (.branch as $b | $adoptBranches | index($b) != null))
        | {id, group, missing, agent: .agent.state, pr: (.pr.state // null)})'
}

errfile=$(mktemp "${TMPDIR:-/tmp}/wait-change.XXXXXX")
trap 'rm -f "$errfile"' EXIT
start='' err=''
deadline=$((SECONDS + timeout))

while :; do
  if now=$(signature 2>"$errfile"); then
    err=''
    if [[ -z $start ]]; then
      start=$now
    else
      changed=$(jq -c --argjson start "$start" '
        [.[] | . as $now | ([$start[] | select(.id == $now.id)][0]) as $was
          | select($was != $now) | {now: $now, was: $was}]' <<<"$now")
      if [[ "$changed" != "[]" ]]; then
        jq . <<<"$changed"
        exit 0
      fi
    fi
  else
    err=$(tail -n 1 "$errfile")
    err=${err:-status.sh failed}
  fi
  ((SECONDS < deadline)) || break
  sleep "${POLL_SECONDS:-60}"
done
if [[ -n $err ]]; then
  echo "checks still failing at timeout: $err" >&2
  exit 1
fi
echo timeout
