#!/usr/bin/env bash
# Own and update the repo's plan file safely. Only one orchestrator may run a repo's plan at a
# time: the plan records its owner (the Paradev terminal the orchestrator runs in) and a
# heartbeat. Every write is checked against that owner, made under a lock, and swapped in
# atomically, so a crash mid-write never leaves a half-written plan.
#
# Usage (run from inside the repo):
#   plan.sh path                  print the plan file path for this repo
#   plan.sh check                 read-only: print none | finished | mine | other | stale
#   plan.sh claim [--takeover]    may this session start or resume a run? (see exit codes)
#   plan.sh write <json-file>     replace the plan with <json-file> (owner and heartbeat are set)
#   plan.sh heartbeat             refresh the heartbeat without other changes
#
# Exit codes: 0 ok; 3 another live orchestrator owns the active run (details on stdout);
# 4 the active run is stale (owner gone or silent) and needs --takeover; 1 anything else.
set -euo pipefail

STALE_MINUTES=45
dir="$HOME/.agents/orchestrator"
# owner/repo from the origin remote (git@github.com:o/r.git or https://github.com/o/r), offline.
repo=$(git remote get-url origin | sed -E 's#(\.git)?/?$##; s#^.*[:/]([^/]+/[^/]+)$#\1#')
plan="$dir/${repo//\//-}.json"
me=${SUPERSET_TERMINAL_ID:-unknown}
# superset, paradev and pdev are the same Paradev CLI; use whichever is installed.
cli=$(command -v superset || command -v paradev || command -v pdev || true)
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

lock() {
  mkdir -p "$dir"
  for _ in $(seq 50); do
    mkdir "$plan.lock" 2>/dev/null && { trap 'rmdir "$plan.lock"' EXIT; return; }
    sleep 0.2
  done
  echo "plan is locked by another writer: $plan.lock (remove it if no orchestrator is running)" >&2
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
      if [[ -f "$plan" ]]; then
        mkdir -p "$dir/history"
        mv "$plan" "$dir/history/${repo//\//-}-$(jq -r .runId "$plan").json"
      fi
      echo "free"
      exit 0
    fi
    current=$(jq -r '.owner // "unknown"' "$plan")
    if [[ "$current" == "$me" ]]; then
      jq --arg now "$now" '.heartbeat = $now' "$plan" | put
      echo "resumed"
      exit 0
    fi
    if ! stale; then
      jq -c '{runId, owner, heartbeat}' "$plan"
      exit 3
    fi
    if [[ ${2:-} != --takeover ]]; then
      jq -c '{runId, owner, heartbeat, stale: true}' "$plan"
      exit 4
    fi
    jq --arg me "$me" --arg now "$now" --arg was "$current" \
      '.owner = $me | .heartbeat = $now | .takenOverFrom = $was' "$plan" | put
    echo "taken over from $current"
    ;;
  write)
    lock
    if [[ -f "$plan" && $(jq -r .status "$plan") == active && $(jq -r '.owner // "unknown"' "$plan") != "$me" ]]; then
      echo "not the owner of the active run; it belongs to $(jq -r .owner "$plan")" >&2
      exit 3
    fi
    jq --arg me "$me" --arg now "$now" '.owner = $me | .heartbeat = $now' "$2" | put
    ;;
  heartbeat)
    lock
    [[ $(jq -r '.owner // "unknown"' "$plan") == "$me" ]] || { echo "not the owner" >&2; exit 3; }
    jq --arg now "$now" '.heartbeat = $now' "$plan" | put
    ;;
  *)
    sed -n '2,16p' "$0"
    exit 1
    ;;
esac
