#!/usr/bin/env bash
# Print one JSON object per workspace the orchestrator should know about: every workspace in
# the plan, plus every workspace of this project carrying a group tag.
#
# Usage: status.sh <project-id> [plan-file]   (run from inside the repo the PRs belong to)
#
# Fields:
#   id, name, branch       the workspace as Paradev has it now (branch may differ from the plan)
#   group                  its logical group (In Progress, In Review, Done, Blocked; tags mapped
#                          by groups.sh), or null
#   inPlan                 true when the plan lists this workspace ID
#   missing                true when the plan lists it but Paradev no longer has it
#   agent {terminal,state} state is working | idle | blocked | none
#   pr                     newest PR for the branch {number,url,state,isDraft}, or null
set -euo pipefail

project=$1
plan=${2:-}
here=$(cd "$(dirname "$0")" && pwd)
# superset, paradev and pdev are the same Paradev CLI; use whichever is installed.
cli=$(command -v superset || command -v paradev || command -v pdev) ||
  { echo "Paradev CLI not found: install superset, paradev or pdev" >&2; exit 1; }

# Run a gh or Paradev call, retrying transient failures (e.g. "error connecting to
# api.github.com") with backoff; print its output only once it succeeds.
retry() {
  local i out
  for i in 1 2 3; do
    out=$("$@") && { printf '%s\n' "$out"; return; }
    ((i < 3)) && sleep $((i * ${RETRY_DELAY:-5}))
  done
  return 1
}

groups=$("$here/groups.sh" "$project") || (($? == 2))
snapshot=$(retry "$cli" snapshot --json)
prs=$(retry gh pr list --state all --limit 300 --json headRefName,number,url,state,isDraft)

tagged=$(jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<<"$groups" | while IFS=$'\t' read -r group tag; do
  retry "$cli" workspaces list --local --project "$project" --tag "$tag" --json |
    jq -c --arg group "$group" '.[] | {id, name, branch, group: $group}' || exit 1
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
  if ws=$(retry "$cli" workspaces get "$id" --local --json 2>/dev/null); then
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
