#!/usr/bin/env bash
# Print the final plan-derived status table and complete event log in chat.
#
# Usage: finish.sh <project-id> <plan-file>   (inside the repo the PRs belong to)
set -euo pipefail

project=${1:?usage: finish.sh <project-id> <plan-file>}
plan=${2:?usage: finish.sh <project-id> <plan-file>}
[[ -f $plan ]] || { echo "finish.sh: no plan file $plan" >&2; exit 1; }

here=$(cd "$(dirname "$0")" && pwd)
rows=$("$here/status.sh" "$project" "$plan")
table=$(jq -c . <<<"${rows:-}" | "$here/table.sh" --force --rows - "$project" "$plan")

printf '%s\n\n' 'Final status' "$table" 'Events'
jq -r '
  def cell: tostring | gsub("\\|"; "\\\\|") | gsub("[\\r\\n]+"; " ");
  (.events // []) as $events
  | if ($events | length) == 0 then "No events recorded."
    else "| At (UTC) | Item | Action | Detail |\n| --- | --- | --- | --- |\n"
      + ([$events[] | "| \(.at | cell) | \(.item // "—" | cell) | \(.action | cell) | \(.detail | cell) |"] | join("\n"))
    end
' "$plan"
