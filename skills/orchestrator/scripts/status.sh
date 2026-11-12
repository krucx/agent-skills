#!/usr/bin/env bash
# Print one JSON object per workspace the orchestrator should know about: every workspace in
# the plan, plus every workspace of this project carrying a group tag.
#
# Usage: status.sh <project-id> [plan-file]   (run from inside the repo the PRs belong to)
#
# Fields:
#   id, name, branch       the workspace as Paradev has it now (branch may differ from the plan)
#   group                  the group tag it carries, or null
#   inPlan                 true when the plan lists this workspace ID
#   missing                true when the plan lists it but Paradev no longer has it
#   agent {terminal,state} state is working | idle | blocked | none
#   pr                     newest PR for the branch {number,url,state,isDraft}, or null
set -euo pipefail

project=$1
plan=${2:-}
TAGS=("In Progress" "In Review" "Done" "Blocked")

snapshot=$(superset snapshot --json)
prs=$(gh pr list --state all --limit 300 --json headRefName,number,url,state,isDraft)

tagged=$(for tag in "${TAGS[@]}"; do
  superset workspaces list --local --project "$project" --tag "$tag" --json |
    jq -c --arg group "$tag" '.[] | {id, name, branch, group: $group}'
done | jq -sc '.')

planned='[]'
if [[ -n "$plan" && -f "$plan" ]]; then
  planned=$(jq -c '[.items[] | select(.workspace != null) | {id: .workspace, branch}]' "$plan")
fi

# Planned workspaces that carry no group tag: look them up one by one.
untagged=$(jq -c --argjson tagged "$tagged" \
  '[.[] | select(.id as $id | $tagged | map(.id) | index($id) | not)]' <<<"$planned")
extra=$(jq -c '.[]' <<<"$untagged" | while IFS= read -r p; do
  id=$(jq -r .id <<<"$p")
  if ws=$(superset workspaces get "$id" --local --json 2>/dev/null); then
    jq -c '{id, name, branch, group: null, missing: false}' <<<"$ws"
  else
    jq -c '{id, name: null, branch, group: null, missing: true}' <<<"$p"
  fi
done | jq -sc '.')

jq -c --argjson tagged "$tagged" --argjson extra "$extra" --argjson planned "$planned" \
  --argjson snapshot "$snapshot" --argjson prs "$prs" -n '
  ($planned | map(.id)) as $planIds
  | ($tagged | map(. + {missing: false})) + $extra
  | .[]
  | . as $ws
  | . + {
      inPlan: ($planIds | index($ws.id) != null),
      agent: ([$snapshot.workspaces[] | select(.id == $ws.id) | .terminals[]
               | select(.agent != null)][0]
              | if . == null then {terminal: null, state: "none"}
                else {terminal: .id, state: .agent.state} end),
      pr: ([$prs[] | select(.headRefName == $ws.branch)][0]
           | if . == null then null else {number, url, state, isDraft} end)
    }'
