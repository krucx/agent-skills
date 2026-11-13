#!/usr/bin/env bash
# Import an epic's sub-issues as one integration named after the epic ("orchestrate feature #400").
#
# Usage: epic.sh fetch  <epic-number> [plan-file]   JSON: {epic, items: [...], dropped: [...]}
#        epic.sh import <plan-file> <epic-number>   add the integration and its queued items
#
# GitHub sub-issues only (Linear/Jira children: use `superset tasks get`, then add the integration
# by hand). Dropped like any tracker item: closed, pull requests, already in the plan, labelled
# needs-info or needs-triage; each is listed with its reason. The epic is stored on the integration
# (`epic`: {id, title, url}) so the final feature -> default PR links it. import writes via plan.sh;
# the items get the default skill, agent and preset, and no dependencies: set those afterwards.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
default_base=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)
default_base=${default_base:-main}

fetch() { # fetch <epic> [plan]
  local epic=$1 plan=${2:-} repo parent subs planned='[]'
  repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)
  parent=$(gh issue view "$epic" --json number,title,url) || { echo "cannot read #$epic" >&2; exit 1; }
  subs=$(gh api "repos/$repo/issues/$epic/sub_issues" --paginate) || { echo "cannot read sub-issues of #$epic" >&2; exit 1; }
  [[ -z $plan || ! -f $plan ]] || planned=$(jq -c '[.items[].id]' "$plan")
  jq -nc --argjson p "$parent" --argjson s "$subs" --argjson planned "$planned" '
    ($s | map({id: "#\(.number)", title, state, pr: (.pull_request != null),
        labels: [(.labels // [])[] | if type == "object" then .name else . end]})) as $all
    | def why: if .state == "closed" then "closed"
        elif .pr then "pull request"
        elif (.id as $i | $planned | index($i)) then "already planned"
        elif any(.labels[]; . == "needs-info" or . == "needs-triage") then "needs-info"
        else null end;
      {epic: {id: "#\($p.number)", title: $p.title, url: $p.url},
       items: [$all[] | select(why == null) | {id, title}],
       dropped: [$all[] | select(why != null) | {id, reason: why}]}'
}

case ${1:-} in
  fetch) fetch "$2" "${3:-}" ;;
  import)
    plan=$2 epic=$3
    data=$(fetch "$epic" "$plan")
    tmp=$(mktemp "${TMPDIR:-/tmp}/epic.XXXXXX")
    trap 'rm -f "$tmp"' EXIT
    slug=$(jq -r '.epic.title' <<<"$data" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-40 | sed -E 's/-+$//')
    jq --argjson d "$data" --arg n "$epic" --arg s "$slug" --arg base "$default_base" '
      ([.integrations[]?.id | ltrimstr("F") | tonumber?] | max // 0 | . + 1 | "F\(.)") as $f
      | .integrations = (.integrations // []) + [{id: $f, title: $d.epic.title, branch: "feature/\($n)-\($s)",
          base: $base, pr: null, state: "open", epic: $d.epic}]
      | .items += [$d.items[] | {id, title, integration: $f, dependsOn: [], skill: "implement", agent: "claude",
          preset: "auto", state: "queued", branch: null, workspace: null, terminal: null, pr: null,
          checked: null, acceptance: null, followUp: null, ask: null, notes: null, extras: null}]' "$plan" >"$tmp"
    "$here/plan.sh" write "$tmp"
    jq -r '"imported \(.items | length) of #'"$epic"' into feature/'"$epic-$slug"'\(if (.dropped | length) > 0 then "; dropped: " + ([.dropped[] | "\(.id) (\(.reason))"] | join(", ")) else "" end)"' <<<"$data" ;;
  *) echo "usage: epic.sh fetch <epic> [plan-file] | import <plan-file> <epic>" >&2; exit 64 ;;
esac
