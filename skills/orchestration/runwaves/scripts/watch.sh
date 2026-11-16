#!/usr/bin/env bash
# The watch loop without the model: cycle.sh, then wait-change.sh before the next cycle, until
# cycle.sh reports a need, the run finishes, the plan is taken over, or the timeout passes. Every
# cycle refreshes the plan's heartbeat, so a long quiet watch keeps it owned. Background it once;
# wake only on exit.
#
# Usage: watch.sh [--all-changes] <project-id> <plan-file> [timeout-seconds]   (default 1200)
#   --all-changes   wait-change.sh without its noise filter
#
# On exit, in this order:
#   the events cycle.sh recorded since start, one line each "HH:MM item action detail" (UTC; the single
#     line "events: none" when there were none), then the needs JSON array if any, then one line:
#   needs <n> | finished | taken-over | timeout | error: <why>
# Exit: 0 timeout or finished with nothing to do; 10 needs; 3 taken over; 1 error.
set -uo pipefail

flags=()
[[ ${1:-} == --all-changes ]] && { flags=(--all-changes); shift; }
(($# >= 2 && $# <= 3)) || { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }
project=$1 plan=$2 timeout=${3:-1200}
here=$(cd "$(dirname "$0")" && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/issue-74-orchestrator-verify-watch-sh.watch.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

EV='[]' NEEDS='[]'

finish() { # finish <exit code> <last line>
  if [[ $EV == '[]' ]]; then echo "events: none"
  else jq -r '.[] | "\(.at[11:16]) \(.item // "-") \(.action) \(.detail)"' <<<"$EV"; fi
  [[ $NEEDS == '[]' ]] || echo "$NEEDS"
  echo "$2"
  exit "$1"
}
fail() { finish 1 "error: $*"; }

deadline=$((SECONDS + timeout))
first=1
while :; do
  left=$((deadline - SECONDS))
  ((left > 0)) || finish 0 timeout
  if [[ -z $first ]]; then
    "$here/wait-change.sh" ${flags[@]+"${flags[@]}"} "$project" "$plan" "$left" >"$scratch/wait" 2>"$scratch/err" ||
      fail "wait-change.sh: $(tail -n 1 "$scratch/err")"
  else
    first=''
  fi

  "$here/cycle.sh" "$project" "$plan" >"$scratch/cycle" 2>"$scratch/err"
  rc=$?
  case $rc in
    0 | 10) ;;
    3) finish 3 taken-over ;;
    *) fail "cycle.sh: $(tail -n 1 "$scratch/err")" ;;
  esac
  out=$(tail -n 1 "$scratch/cycle")
  jq -e 'type == "object"' <<<"$out" >/dev/null 2>&1 || fail "cycle.sh printed no JSON"
  EV=$(jq -c --argjson e "$EV" '$e + .events' <<<"$out")
  NEEDS=$(jq -c .needs <<<"$out")
  if ((rc == 10)); then finish 10 "needs $(jq length <<<"$NEEDS")"; fi
  if [[ $(jq -r .finished <<<"$out") == true ]]; then finish 0 finished; fi
done
