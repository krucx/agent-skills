#!/usr/bin/env bash
# Map the orchestrator's four logical groups (In Progress, In Review, Done, Blocked) to this
# project's Paradev tags, so it files workspaces into the user's existing sidebar groups instead
# of creating duplicates. The mapping lives in ~/.agents/orchestrator/groups.json, keyed by
# project ID: {"<project-id>": {"In Progress": "in progress", "Blocked": "new group-6", ...}}.
#
# Usage:
#   groups.sh <project-id>               print the mapping as JSON; an unmapped group maps to its
#                                        own name. Exit 2 when the project has no saved mapping.
#   groups.sh <project-id> suggest       propose a mapping: tags whose sidebar name matches a group
#                                        (ignoring case), else the group's own name
#   groups.sh <project-id> save <json>   save a mapping (object of group -> tag) for the project
#
# suggest reads Paradev's private, undocumented host DB (~/.paradev/host/<org-id>/host.db, table
# tag_folder_settings) strictly read-only; it never writes there. Override the DB path with
# PARADEV_HOST_DB. If sqlite3 or the DB is missing or its schema differs, it warns in one line
# and falls back to the groups' own names.
set -euo pipefail

project=${1:?usage: groups.sh <project-id> [suggest | save <json>]}
mode=${2:-print}
file="$HOME/.agents/orchestrator/groups.json"
GROUPS_JSON='["In Progress","In Review","Done","Blocked"]'

# Fill every group the given object leaves out with the group's own name.
complete() {
  jq -c --argjson groups "$GROUPS_JSON" '. as $m | reduce $groups[] as $g ({}; .[$g] = ($m[$g] // $g))'
}

fallback() {
  echo "groups.sh: $1; suggesting the groups' own names" >&2
  echo '{}' | complete
}

suggest() {
  [[ $project =~ ^[A-Za-z0-9_-]+$ ]] || { fallback "unexpected project ID"; return; }
  command -v sqlite3 >/dev/null || { fallback "sqlite3 not found"; return; }
  local dbs=() db rows='[]' out
  if [[ -n ${PARADEV_HOST_DB:-} ]]; then dbs=("$PARADEV_HOST_DB")
  else for db in "$HOME"/.paradev/host/*/host.db; do [[ -f $db ]] && dbs+=("$db"); done
  fi
  ((${#dbs[@]})) || { fallback "Paradev host DB not found"; return; }
  for db in "${dbs[@]}"; do
    [[ -f $db ]] || { fallback "Paradev host DB not found: $db"; return; }
    # mode=ro: open read-only. Escape the characters a file: URI treats specially.
    db=${db//%/%25}; db=${db//\?/%3f}; db=${db//#/%23}
    out=$(sqlite3 -json "file:$db?mode=ro" "SELECT tag, display_name FROM tag_folder_settings
      WHERE scope = '$project' ORDER BY tab_order, updated_at DESC" 2>/dev/null) ||
      { fallback "can't read tag_folder_settings (Paradev's schema may have changed)"; return; }
    rows=$(jq -c --argjson more "${out:-[]}" '. + $more' <<<"$rows")
  done
  jq -c --argjson groups "$GROUPS_JSON" '. as $rows
    | reduce $groups[] as $g ({}; .[$g] = ([$rows[]
        | select((.display_name // .tag | ascii_downcase) == ($g | ascii_downcase)) | .tag][0] // $g))' \
    <<<"$rows"
}

case $mode in
  print)
    if [[ -f $file ]] && jq -e --arg p "$project" 'has($p)' "$file" >/dev/null; then
      jq -c --arg p "$project" '.[$p]' "$file" | complete
    else
      echo '{}' | complete
      exit 2
    fi ;;
  suggest) suggest ;;
  save)
    map=$(jq -ce --argjson groups "$GROUPS_JSON" '
      select(type == "object" and (keys - $groups == []) and all(.[]; type == "string" and . != ""))' \
      <<<"${3:?usage: groups.sh <project-id> save <json>}") ||
      { echo "groups.sh: expected an object of group -> tag, groups: $GROUPS_JSON" >&2; exit 1; }
    map=$(complete <<<"$map")
    mkdir -p "$(dirname "$file")"
    [[ -f $file ]] || echo '{}' >"$file"
    jq --arg p "$project" --argjson m "$map" '.[$p] = $m' "$file" >"$file.tmp.$$"
    mv "$file.tmp.$$" "$file"
    echo "$map" ;;
  *) echo "usage: groups.sh <project-id> [suggest | save <json>]" >&2; exit 1 ;;
esac
