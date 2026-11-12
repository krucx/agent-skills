#!/usr/bin/env bash
# Map the orchestrator's four logical groups (In Progress, In Review, Done, Blocked) to this
# project's Paradev tags, so it files workspaces into the user's existing sidebar groups instead
# of creating duplicates. The mapping lives in ~/.agents/orchestrator/groups.json, keyed by
# project ID: {"<project-id>": {"In Progress": "in progress", "Blocked": "new group-6", ...}}.
#
# Usage:
#   groups.sh <project-id>               print the mapping as JSON; an unmapped group maps to its
#                                        own name. Exit 2 when the project has no saved mapping.
#   groups.sh <project-id> plan <file>   the plan's "groups" map if it has one (the run carries its
#                                        map to whichever orchestrator picks it up), else as above
#   groups.sh <project-id> suggest       propose a mapping: tags whose sidebar name matches a group
#                                        (ignoring case), else the group's own name
#   groups.sh <project-id> save <json>   save a mapping (object of group -> tag) for the project
#   groups.sh <project-id> check <json>  are the map's tags still in Paradev? Prints the missing ones
#                                        as {"group": "tag"}; exit 5 if any. A tag counts as present
#                                        when Paradev has a folder for it, a workspace carries it, or
#                                        it is the group's own name (a first move creates that folder).
#
# suggest and check read Paradev's private, undocumented host DB (~/.paradev/host/<org-id>/host.db, table
# tag_folder_settings) strictly read-only; it never writes there. Override the DB path with
# PARADEV_HOST_DB. If sqlite3 or the DB is missing or its schema differs, it warns in one line
# and falls back to the groups' own names.
set -euo pipefail

project=${1:?usage: groups.sh <project-id> [suggest | save <json>]}
mode=${2:-print}
file="$HOME/.agents/orchestrator/groups.json"
GROUPS_JSON='["In Progress","In Review","Done","Blocked"]'

# Fill every group the given object leaves out with the group's own name.
with_defaults() {
  jq -c --argjson groups "$GROUPS_JSON" '. as $m | reduce $groups[] as $g ({}; .[$g] = ($m[$g] // $g))'
}

fallback() {
  echo "groups.sh: $1; suggesting the groups' own names" >&2
  echo '{}' | with_defaults
}

# The project's sidebar folders [{tag, display_name}] from the host DB; on failure, print why on
# stderr and return 1.
folders() {
  [[ $project =~ ^[A-Za-z0-9_-]+$ ]] || { echo "unexpected project ID" >&2; return 1; }
  command -v sqlite3 >/dev/null || { echo "sqlite3 not found" >&2; return 1; }
  local dbs=() db rows='[]' out
  if [[ -n ${PARADEV_HOST_DB:-} ]]; then dbs=("$PARADEV_HOST_DB")
  else for db in "$HOME"/.paradev/host/*/host.db; do [[ -f $db ]] && dbs+=("$db"); done
  fi
  ((${#dbs[@]})) || { echo "Paradev host DB not found" >&2; return 1; }
  for db in "${dbs[@]}"; do
    [[ -f $db ]] || { echo "Paradev host DB not found: $db" >&2; return 1; }
    # mode=ro: open read-only. Escape the characters a file: URI treats specially.
    db=${db//%/%25}; db=${db//\?/%3f}; db=${db//#/%23}
    out=$(sqlite3 -json "file:$db?mode=ro" "SELECT tag, display_name FROM tag_folder_settings
      WHERE scope = '$project' ORDER BY tab_order, updated_at DESC" 2>/dev/null) ||
      { echo "can't read tag_folder_settings (Paradev's schema changed, or sqlite3 lacks -json)" >&2; return 1; }
    rows=$(jq -c --argjson more "${out:-[]}" '. + $more' <<<"$rows")
  done
  echo "$rows"
}

suggest() {
  local rows
  rows=$(folders 2>&1) || { fallback "$rows"; return; }
  jq -c --argjson groups "$GROUPS_JSON" '. as $rows
    | reduce $groups[] as $g ({}; .[$g] = ([$rows[]
        | select((.display_name // .tag | ascii_downcase) == ($g | ascii_downcase)) | .tag][0] // $g))' \
    <<<"$rows"
}

# Tags of the map that Paradev no longer has; see the usage notes.
check() {
  local map=$1 tags rows cli missing
  tags=$(folders 2>/dev/null | jq -c '[.[].tag]') || tags='[]'
  cli=$(command -v superset || command -v paradev || command -v pdev) ||
    { echo "groups.sh: Paradev CLI not found: install superset, paradev or pdev" >&2; exit 1; }
  rows=$("$cli" workspaces list --local --project "$project" --json) || exit 1
  # tags is a comma-separated string in current CLIs; accept an array too.
  missing=$(jq -c --argjson known "$tags" --argjson ws "$rows" '
    ([$ws[] | .tags // [] | if type == "string" then split(",") else . end | .[]
      | gsub("^ +| +$"; "")] + $known | map(ascii_downcase)) as $have
    | with_entries(select((.value | ascii_downcase) as $t
        | ($have | index($t)) == null and $t != (.key | ascii_downcase)))' <<<"$map")
  echo "$missing"
  [[ $missing == '{}' ]] || exit 5
}

case $mode in
  print|plan)
    if [[ $mode == plan && -f ${3:-} ]] && jq -e '.groups | type == "object"' "$3" >/dev/null; then
      jq -c '.groups' "$3" | with_defaults
    elif [[ -f $file ]] && jq -e --arg p "$project" 'has($p)' "$file" >/dev/null; then
      jq -c --arg p "$project" '.[$p]' "$file" | with_defaults
    else
      echo '{}' | with_defaults
      exit 2
    fi ;;
  suggest) suggest ;;
  check) check "${3:?usage: groups.sh <project-id> check <json>}" ;;
  save)
    map=$(jq -ce --argjson groups "$GROUPS_JSON" '
      select(type == "object" and (keys - $groups == []) and all(.[]; type == "string" and . != ""))' \
      <<<"${3:?usage: groups.sh <project-id> save <json>}" | with_defaults |
      jq -ce 'select([.[] | ascii_downcase] | length == (unique | length))') ||
      { echo "groups.sh: expected an object of group -> distinct tag, groups: $GROUPS_JSON" >&2; exit 1; }
    mkdir -p "$(dirname "$file")"
    [[ -f $file ]] || echo '{}' >"$file"
    jq --arg p "$project" --argjson m "$map" '.[$p] = $m' "$file" >"$file.tmp.$$"
    mv "$file.tmp.$$" "$file"
    echo "$map" ;;
  *) echo "usage: groups.sh <project-id> [plan <file> | suggest | save <json> | check <json>]" >&2; exit 1 ;;
esac
