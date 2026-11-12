#!/usr/bin/env bash
# Block until something the orchestrator acts on changes, or until the timeout passes:
# a worker's agent state, a workspace's group tag, a workspace disappearing, or a PR
# appearing, merging or closing. Checks once a minute. When it exits, act on what changed and
# start it again.
#
# Usage: wait-change.sh <project-id> [plan-file] [timeout-seconds]   (default 1200)
# Prints the workspaces that changed, with their old values; prints "timeout" if none did.
set -euo pipefail

project=$1
plan=${2:-}
timeout=${3:-1200}
here=$(cd "$(dirname "$0")" && pwd)

signature() {
  "$here/status.sh" "$project" "$plan" |
    jq -sc 'map({id, group, missing, agent: .agent.state, pr: (.pr.state // null)})'
}

start=$(signature)
deadline=$((SECONDS + timeout))

while ((SECONDS < deadline)); do
  sleep 60
  changed=$(signature | jq -c --argjson start "$start" '
    [.[] | . as $now | ([$start[] | select(.id == $now.id)][0]) as $was
      | select($was != $now) | {now: $now, was: $was}]')
  if [[ "$changed" != "[]" ]]; then
    jq . <<<"$changed"
    exit 0
  fi
done
echo timeout
