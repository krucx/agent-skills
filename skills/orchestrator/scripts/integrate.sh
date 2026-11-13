#!/usr/bin/env bash
# When an integration is ready for its feature -> default-branch PR, and the synthetic
# <F>-integrate item that a worker uses to open it.
#
# Usage: integrate.sh check <plan-file>        one line per open integration (verdicts below)
#        integrate.sh add   <plan-file> <F>    if <F> is ready, add its queued <F>-integrate item
#
# check verdicts (first word; the integration's id follows):
#   ready   every item is `done` or dropped (`dropped: true`, state skipped) and at least one is done
#   open    items are still queued, in progress or in review: nothing to do yet
#   held    an item is blocked, waiting or skipped without being dropped: tell the user, who unblocks
#           it or drops it ("ship F1 without T3": state skipped, dropped true), which releases it
#   empty   every item was dropped: nothing to integrate
#   has     the <F>-integrate item exists (its state follows)
# The item's `integrates` names the integration; it has no `integration` of its own, so its PR
# targets the default branch and merge.sh leaves it to humans. add writes through plan.sh.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)

verdicts() {
  jq -r '(.items // []) as $all | .integrations[]? | select((.state // "open") == "open") | . as $f
    | ($f.id + "-integrate") as $iid
    | [$all[] | select(.integration == $f.id)] as $its
    | [$its[] | select(.state == "blocked" or .state == "waiting"
        or (.state == "skipped" and (.dropped // false | not))) | "\(.id) \(.state)"] as $held
    | [$its[] | select(.state != "done" and .state != "blocked" and .state != "waiting" and .state != "skipped") | .id] as $open
    | if any($all[]; .id == $iid) then "has \($f.id): \($iid) is \([$all[] | select(.id == $iid) | .state][0])"
      elif ($held | length) > 0 then "held \($f.id): \($held | join(", "))"
      elif ($open | length) > 0 then "open \($f.id): \($open | join(", "))"
      elif all($its[]; .state == "skipped") then "empty \($f.id)"
      else "ready \($f.id)" end' "$1"
}

case ${1:-} in
  check) verdicts "$2" ;;
  add)
    plan=$2 f=$3
    [[ $(verdicts "$plan" | awk -v f="$f" '{ sub(/:$/, "", $2) } $2 == f { print $1 }') == ready ]] ||
      { echo "$f is not ready for $f-integrate" >&2; exit 1; }
    tmp=$(mktemp "${TMPDIR:-/tmp}/integrate.XXXXXX")
    trap 'rm -f "$tmp"' EXIT
    jq --arg f "$f" '.integrations[] | select(.id == $f) as $i
      | .items += [{id: "\($f)-integrate", title: "Integrate \($i.title)", integrates: $f, integration: null,
          dependsOn: [], skill: ([.items[] | select(.integration == $f) | .skill][0] // "implement"),
          agent: ([.items[] | select(.integration == $f) | .agent][0] // "claude"),
          preset: ([.items[] | select(.integration == $f) | .preset][0] // "auto"),
          state: "queued", branch: null, workspace: null, terminal: null, pr: null,
          checked: null, acceptance: null, followUp: null}]' "$plan" >"$tmp"
    "$here/plan.sh" write "$tmp"
    echo "added $f-integrate" ;;
  *) echo "usage: integrate.sh check <plan-file> | add <plan-file> <F>" >&2; exit 64 ;;
esac
