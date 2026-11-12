#!/usr/bin/env bash
# Print one JSON object per orchestrated workspace: everything the orchestrator needs to
# decide group moves and render the status table.
#
# Usage: status.sh            (run from inside the repo the workers' PRs belong to)
#
# A workspace is "orchestrated" when it carries one of the group tags. Match the output to
# plan items by workspace id. Agent state comes from `superset snapshot`; PR state comes from
# GitHub, looked up by the workspace's branch.
set -euo pipefail

TAGS=("In Progress" "In Review" "Done" "Blocked")
snapshot=$(superset snapshot --json)

for tag in "${TAGS[@]}"; do
  superset workspaces list --local --tag "$tag" --json |
    jq -c --arg group "$tag" '.[] | {id, name, branch, group: $group}'
done | while IFS= read -r ws; do
  id=$(jq -r .id <<<"$ws")
  branch=$(jq -r .branch <<<"$ws")

  # First terminal that runs an agent: its state is working | idle | blocked.
  agent=$(jq -c --arg id "$id" '
    [.workspaces[] | select(.id == $id) | .terminals[] | select(.agent != null)][0]
    | if . == null then {terminal: null, state: "none"} else {terminal: .id, state: .agent.state} end
  ' <<<"$snapshot")

  pr=$(gh pr list --head "$branch" --state all --limit 1 --json number,url,state,isDraft |
    jq -c '.[0] // null')

  jq -c --argjson agent "$agent" --argjson pr "$pr" '. + {agent: $agent, pr: $pr}' <<<"$ws"
done
