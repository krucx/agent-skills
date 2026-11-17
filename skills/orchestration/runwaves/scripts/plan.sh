#!/usr/bin/env bash
# Own and update the repo's plan file safely: one coordinator per repo's plan at a time. The plan
# records its owner (the coordinator's Paradev terminal, or its Orca terminal handle) and a heartbeat; every write is
# owner-checked, locked and swapped in atomically, so a crash never leaves a half-written plan.
#
# Usage (inside the repo):
#   plan.sh path                  the plan file path for this repo
#   plan.sh check                 read-only: none | finished | mine | other | stale
#   plan.sh claim [--takeover [--force]]
#                                 may this session start or resume a run? (exit codes below)
#                                 --force takes over even from a live owner, only when the user
#                                 asks. "free" is followed by a closed run's carryOver, if any.
#   plan.sh write <json-file>     replace the plan with <json-file> (sets owner and heartbeat);
#                                 exit 1 if an item's or integration's pr is not a URL string or null,
#                                 an events entry is malformed, an item's criteria is invalid or
#                                 two items share an id
#   plan.sh event <item> <action> "<detail>"
#                                 append one entry to the events log under the lock (owner-checked,
#                                 exit 3 if not the owner); <item> is an ID, F1 or "null"
#   plan.sh events [--since <ISO>]
#                                 print the log, newest last, one JSON line each (read-only);
#                                 --since prints only entries after that time
#   plan.sh heartbeat             refresh the heartbeat only
#   plan.sh close                 finish the run now; items not done or skipped go to carryOver
#
# An owner is live while its heartbeat is under STALE_MINUTES (45) old and its terminal runs an
# agent. Exit: 0 ok; 3 a live coordinator owns the active run (details on stdout); 4 the active
# run is stale and needs --takeover; 1 anything else.
set -euo pipefail

STALE_MINUTES=${STALE_MINUTES:-45}
dir="$HOME/.agents/orchestrator"
# owner/repo from the origin remote (git@github.com:o/r.git or https://github.com/o/r), offline.
repo=$(git remote get-url origin | sed -E 's#(\.git)?/?$##; s#^.*[:/]([^/]+/[^/]+)$#\1#')
plan="$dir/${repo//\//-}.json"
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
# The coordinator's terminal: Paradev's ID, else the Orca terminal handle (term_…).
if [[ $(backend) == orca ]]; then me=$ORCA_TERMINAL_HANDLE; else me=${SUPERSET_TERMINAL_ID:-unknown}; fi
# superset, paradev and pdev are the same Paradev CLI; use whichever is installed.
cli=$(command -v superset || command -v paradev || command -v pdev || true)
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
run_id_from_now=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$now" +%Y%m%d-%H%M 2>/dev/null ||
  date -u -d "$now" +%Y%m%d-%H%M)
# The fixed list of event actions; keep in step with references/plan-schema.md.
actions='["dispatched","pr-opened","in-review","merged","pr-merged","tag-moved","follow-up-sent","acceptance-gap","blocked","waiting","skipped","taken-over","finished","closed","reconciled","stalled","accepting","held","queued","feedback","rules"]'

lock() {
  mkdir -p "$dir"
  for _ in $(seq 50); do
    mkdir "$plan.lock" 2>/dev/null && { trap 'rmdir "$plan.lock"' EXIT; return; }
    sleep 0.2
  done
  echo "plan is locked by another writer: $plan.lock (remove it if no coordinator is running)" >&2
  exit 1
}

# Atomic replace: write next to the target, then rename over it.
put() {
  local tmp="$plan.tmp.$$"
  cat >"$tmp"
  jq -e '.items | type == "array"' "$tmp" >/dev/null || { rm -f "$tmp"; echo "invalid plan" >&2; exit 1; }
  mv -f "$tmp" "$plan"
}

owner_alive() {
  local terminal=$1
  [[ "$terminal" != "unknown" ]] || return 1
  if [[ $terminal == term_* ]]; then  # an Orca owner: live while Orca lists its terminal running an agent
    local list
    list=$(orca_cli terminal list --json 2>/dev/null) || { echo "Orca CLI not reachable: cannot tell whether $terminal is live" >&2; exit 1; }
    jq -e --arg t "$terminal" '[.result.terminals[]? | select(.handle == $t and (.orphaned | not)
      and .connected != false and .agentIdentity != null)] | length > 0' <<<"$list" >/dev/null
    return
  fi
  [[ -n "$cli" ]] || { echo "Paradev CLI not found: install superset, paradev or pdev" >&2; exit 1; }
  "$cli" snapshot --json | jq -e --arg t "$terminal" \
    '[.workspaces[].terminals[] | select(.id == $t and .agent != null)] | length > 0' >/dev/null
}

stale() {
  local beat age
  beat=$(jq -r '.heartbeat // empty' "$plan")
  [[ -z "$beat" ]] && return 0
  age=$(( ($(date -u +%s) - $(date -u -j -f %Y-%m-%dT%H:%M:%SZ "$beat" +%s 2>/dev/null ||
           date -u -d "$beat" +%s)) / 60 ))
  ((age >= STALE_MINUTES)) || ! owner_alive "$(jq -r '.owner // "unknown"' "$plan")"
}

case ${1:-} in
  path)
    echo "$plan"
    ;;
  check)
    if [[ ! -f "$plan" ]]; then echo none
    elif [[ $(jq -r .status "$plan") == finished ]]; then echo finished
    elif [[ $(jq -r '.owner // "unknown"' "$plan") == "$me" ]]; then echo mine
    elif stale; then echo stale
    else echo other
    fi
    ;;
  claim)
    lock
    if [[ ! -f "$plan" ]] || [[ $(jq -r .status "$plan") == finished ]]; then
      echo "free"
      if [[ -f "$plan" ]]; then
        old="$dir/history/${repo//\//-}-$(jq -r .runId "$plan").json"
        mkdir -p "$dir/history"
        mv "$plan" "$old"
        jq -c --arg from "$old" '
          (.items // []) as $items
          | ([.integrations[]? | select((.state // "open") == "open") as $integration
              | {integration: $integration,
                 items: [$items[] | select(.integration == $integration.id)]}]) as $integrations
          | (.carryOver // []) as $carry
          | select(($carry | length) > 0 or ($integrations | length) > 0)
          | {carryOver: $carry, integrationCarryOver: $integrations, from: $from}' "$old"
      fi
      exit 0
    fi
    current=$(jq -r '.owner // "unknown"' "$plan")
    if [[ "$current" == "$me" ]]; then
      jq --arg now "$now" '.heartbeat = $now' "$plan" | put
      echo "resumed"
      exit 0
    fi
    forced=null
    if [[ ${2:-} == --takeover && ${3:-} == --force ]]; then
      forced="\"$now\""
    elif ! stale; then
      jq -c '{runId, owner, heartbeat}' "$plan"
      exit 3
    elif [[ ${2:-} != --takeover ]]; then
      jq -c '{runId, owner, heartbeat, stale: true}' "$plan"
      exit 4
    fi
    jq --arg me "$me" --arg now "$now" --arg was "$current" --argjson forced "$forced" \
      '.owner = $me | .heartbeat = $now | .takenOverFrom = $was
       | .events = ((.events // []) + [{at: $now, item: null, action: "taken-over",
                                        detail: "taken over from \($was)\(if $forced then " (forced)" else "" end)"}])
       | if $forced then .forcedAt = $forced else del(.forcedAt) end' "$plan" | put
    echo "taken over from $current${forced:+ (forced)}"
    ;;
  write|close)
    lock
    if [[ -f "$plan" && $(jq -r .status "$plan") == active && $(jq -r '.owner // "unknown"' "$plan") != "$me" ]]; then
      echo "not the owner of the active run; it belongs to $(jq -r .owner "$plan")" >&2
      exit 3
    fi
    if [[ $1 == close ]]; then
      [[ -f "$plan" ]] || { echo "no plan to close" >&2; exit 1; }
      jq --arg now "$now" '.status = "finished" | .closedAt = $now
        | .events = ((.events // []) + [{at: $now, item: null, action: "closed", detail: "run closed"}])
        | .carryOver = [.items[] | select(.state != "done" and .state != "skipped")
                        | {id, state, reason}]
        | .integrationCarryOver = ((.items // []) as $items | [.integrations[]? | select((.state // "open") == "open") as $integration
                                   | {integration: $integration,
                                      items: [$items[] | select(.integration == $integration.id)]}])' "$plan" | put
      jq -c '.carryOver' "$plan"
      exit 0
    fi
    # pr is the full PR URL or null: dispatch.sh and merge.sh read it as a string.
    badpr=$(jq -r '[(.items[]?, .integrations[]?) | select(.pr != null and ((.pr | type) != "string" or (.pr | test("^https?://") | not)))
                    | "\(.id): pr must be a PR URL string, not \(.pr | tojson)"] | .[]' "$2")
    [[ -z "$badpr" ]] || { echo "$badpr" >&2; exit 1; }
    # events entries carry at, item (an ID or null), action from the fixed list and detail;
    # criteria is null or {met <= total (integers), unmet: [...]}; item ids are unique.
    badev=$(jq -r --argjson actions "$actions" '
      (if (.events // []) | type != "array" then "events: must be an array" else empty end),
      ((.events // []) | if type == "array" then to_entries[] else empty end
       | select(.value | (type == "object" and (.at | type) == "string" and has("item")
                          and (.item == null or (.item | type) == "string")
                          and (.action as $a | $actions | index($a) != null)
                          and (.detail | type) == "string") | not)
       | "events[\(.key)]: needs at, item, action (one of the fixed kinds) and detail, got \(.value | tojson)"),
      ((.items[]? | select(.criteria != null)
        | select(.criteria | (type == "object" and (.met | type) == "number" and (.total | type) == "number"
                              and .met == (.met | floor) and .total == (.total | floor) and .met >= 0
                              and .met <= .total and (.unmet | type) == "array") | not))
       | "\(.id): criteria needs integer met <= total and an unmet array, got \(.criteria | tojson)"),
      ([.items[]?.id] | group_by(.)[] | select(length > 1) | "\(.[0]): item id used \(length) times")' "$2")
    [[ -z "$badev" ]] || { echo "$badev" >&2; exit 1; }
    # The first write owns the run identity. Ignore model-authored values; subsequent writes
    # preserve the original identity even if their input JSON tries to change it.
    if [[ -f "$plan" ]]; then
      run_id=$(jq -r '.runId // empty' "$plan")
      started_at=$(jq -r '.startedAt // empty' "$plan")
      [[ -n "$run_id" ]] || run_id=$run_id_from_now
      [[ -n "$started_at" ]] || started_at=$now
    else
      run_id=$run_id_from_now
      started_at=$now
    fi
    jq --arg me "$me" --arg now "$now" --arg run_id "$run_id" --arg started_at "$started_at" \
      '.runId = $run_id | .startedAt = $started_at | .owner = $me | .heartbeat = $now' "$2" | put
    ;;
  event)
    [[ $# -eq 4 ]] || { echo 'usage: plan.sh event <item> <action> "<detail>"' >&2; exit 1; }
    jq -en --argjson actions "$actions" --arg a "$3" '$actions | index($a) != null' >/dev/null ||
      { echo "unknown event action: $3" >&2; exit 1; }
    lock
    [[ -f "$plan" ]] || { echo "no plan" >&2; exit 1; }
    [[ $(jq -r '.owner // "unknown"' "$plan") == "$me" ]] || { echo "not the owner" >&2; exit 3; }
    jq --arg now "$now" --arg item "$2" --arg action "$3" --arg detail "$4" \
      '.events = ((.events // []) + [{at: $now, item: (if $item == "null" or $item == "" then null else $item end),
                                      action: $action, detail: $detail}])' "$plan" | put
    ;;
  events)
    [[ -f "$plan" ]] || exit 0
    if [[ ${2:-} == --since ]]; then
      [[ -n ${3:-} ]] || { echo "--since needs an ISO time" >&2; exit 1; }
      jq -c --arg since "$3" '(.events // [])[] | select(.at > $since)' "$plan"
    else
      jq -c '(.events // [])[]' "$plan"
    fi
    ;;
  heartbeat)
    lock
    [[ $(jq -r '.owner // "unknown"' "$plan") == "$me" ]] || { echo "not the owner" >&2; exit 3; }
    jq --arg now "$now" '.heartbeat = $now' "$plan" | put
    ;;
  *)
    sed -n "2,28p" "$0"
    exit 1
    ;;
esac
