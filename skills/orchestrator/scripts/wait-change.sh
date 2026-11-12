#!/usr/bin/env bash
# Block until the agent in any orchestrated workspace changes state (a worker finished its
# turn, needs input, or started working again because the user typed into its chat), or
# until the timeout passes. When it exits, act on what changed and start it again.
#
# Usage: wait-change.sh [timeout-seconds]   (default 1200)
# Prints the workspaces whose agent state changed; prints "timeout" if nothing did.
set -euo pipefail

timeout=${1:-1200}
TAGS=("In Progress" "In Review" "Done" "Blocked")

ids=$(for tag in "${TAGS[@]}"; do
  superset workspaces list --local --tag "$tag" --json | jq -r '.[].id'
done | jq -R . | jq -sc .)

states() {
  superset snapshot --json | jq -c --argjson ids "$ids" '
    [.workspaces[] | select(.id as $id | $ids | index($id)) | {id, name,
      state: ([.terminals[] | select(.agent != null) | .agent.state][0] // "none")}]'
}

start=$(states)
deadline=$((SECONDS + timeout))

while ((SECONDS < deadline)); do
  sleep 30
  changed=$(states | jq -c --argjson start "$start" '
    [.[] | . as $now | ($start[] | select(.id == $now.id) | .state) as $was
      | select($was != $now.state) | . + {was: $was}]')
  if [[ "$changed" != "[]" ]]; then
    jq . <<<"$changed"
    exit 0
  fi
done
echo timeout
