#!/usr/bin/env bash
# Relay one message to an item's worker: resolves the workspace and terminal from the plan, records
# a follow-up-sent event (and, with --reason, moves the item to feedback with that reason) in one
# plan write, then sends with `terminals send`. The write comes first, so a failed write sends nothing.
#
# Usage (inside the repo):
#   send.sh <plan-file> <ID> "<text>" [--reason <r>]
#   send.sh --check   <plan-file> <ID>           exit 1 unless the item has a workspace and terminal
#   send.sh --deliver <plan-file> <ID> "<text>"  only send, for callers that recorded it in their own write
# Exit: 0 sent; 3 not the plan's owner; 1 anything else (no workspace or terminal, a failed write or send).
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
die() { echo "send: $*" >&2; exit 1; }
usage() { sed -n '6,10p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

mode=send
case ${1:-} in --check) mode=check; shift ;; --deliver) mode=deliver; shift ;; esac
case $mode in
  check) (($# == 2)) || usage ;;
  deliver) (($# == 3)) || usage ;;
  *) (($# == 3 || $# == 5)) || usage ;;
esac
plan=$1 id=$2 text=${3:-} reason=''
if [[ $mode == send && $# == 5 ]]; then
  [[ $4 == --reason && -n $5 ]] || usage
  reason=$5
fi

[[ -f $plan ]] || die "no plan file $plan"
P=$(jq -c . "$plan") || die "unreadable plan"
jq -e --arg id "$id" 'any(.items[]; .id == $id)' <<<"$P" >/dev/null || die "no item $id in the plan"
ws=$(jq -r --arg id "$id" '.items[] | select(.id == $id) | .workspace // empty' <<<"$P")
term=$(jq -r --arg id "$id" '.items[] | select(.id == $id) | .terminal // empty' <<<"$P")
[[ -n $ws ]] || die "$id has no workspace in the plan"
[[ -n $term ]] || die "$id has no terminal in the plan"
[[ $mode != check ]] || exit 0

cli=$(command -v superset || command -v paradev || command -v pdev) || die "Paradev CLI not found"

if [[ $mode == send ]]; then
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/send.XXXXXX")
  trap 'rm -rf "$scratch"' EXIT
  jq -c --arg id "$id" --arg r "$reason" --arg text "$text" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    (if $r != "" then (.items[] | select(.id == $id)) |= (.state = "feedback" | .reason = $r) else . end)
    | .events = ((.events // []) + [{at: $at, item: $id, action: "follow-up-sent", detail: $text}])' <<<"$P" >"$scratch/plan.json"
  "$here/plan.sh" write "$scratch/plan.json" >"$scratch/out" 2>&1
  case $? in
    0) ;;
    3) echo taken-over; exit 3 ;;
    *) die "plan write failed: $(head -n 3 "$scratch/out")" ;;
  esac
fi

"$cli" terminals send --workspace "$ws" --local --terminal "$term" --text "$text" </dev/null >/dev/null 2>&1 ||
  die "could not send to $id (workspace $ws, terminal $term)"
