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
# A local chain branch (an integration with a `parent`) is the exception: its <F>-integrate item's
# `integration` is the parent, so its one PR is a sub-PR of the parent that merge.sh merges when
# green. A parent waits for its open chains: one not yet integrated is listed as open (or held,
# when the chain is held) under the parent, then its <F>-integrate item is the parent's like any
# other; an empty chain releases it.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)

verdicts() {
  jq -r '(.items // []) as $all | (.integrations // []) as $ints
    | def status($f): [$all[] | select(.integration == $f.id)] as $its
        | [$ints[] | select(.parent == $f.id and (.state // "open") == "open") | . as $c
           | select(all($all[]; .id != ($c.id + "-integrate"))) | {id: $c.id, v: status($c).v} | select(.v != "empty")] as $kids
        | ([$its[] | select(.state == "blocked" or .state == "waiting"
            or (.state == "skipped" and (.dropped // false | not))) | "\(.id) \(.state)"]
           + [$kids[] | select(.v == "held") | .id]) as $held
        | ([$its[] | select(.state != "done" and .state != "blocked" and .state != "waiting" and .state != "skipped") | .id]
           + [$kids[] | select(.v != "held") | .id]) as $open
        | {held: $held, open: $open,
           v: (if ($held | length) > 0 then "held" elif ($open | length) > 0 then "open"
               elif all($its[]; .state == "skipped") then "empty" else "ready" end)};
      $ints[] | select((.state // "open") == "open") | . as $f | ($f.id + "-integrate") as $iid
    | if any($all[]; .id == $iid) then "has \($f.id): \($iid) is \([$all[] | select(.id == $iid) | .state][0])"
      else status($f) as $s
        | if $s.v == "held" then "held \($f.id): \($s.held | join(", "))"
          elif $s.v == "open" then "open \($f.id): \($s.open | join(", "))"
          else "\($s.v) \($f.id)" end end' "$1"
}

case ${1:-} in
  check) verdicts "$2" ;;
  add)
    plan=$2 f=$3
    [[ $(verdicts "$plan" | awk -v f="$f" '{ sub(/:$/, "", $2) } $2 == f { print $1 }') == ready ]] ||
      { echo "$f is not ready for $f-integrate" >&2; exit 1; }
    tmp=$(mktemp "${TMPDIR:-/tmp}/integrate.XXXXXX")
    trap 'rm -f "$tmp"' EXIT
    jq --arg f "$f" '(.integrations[] | select(.id == $f)) as $i
      | .items += [{id: "\($f)-integrate", title: "Integrate \($i.title)", integrates: $f, integration: ($i.parent // null),
          dependsOn: [], skill: ([.items[] | select(.integration == $f) | .skill][0] // "implement"),
          agent: ([.items[] | select(.integration == $f) | .agent][0] // "claude"),
          preset: ([.items[] | select(.integration == $f) | .preset][0] // "auto"),
          state: "queued", branch: null, workspace: null, terminal: null, pr: null,
          checked: null, acceptance: null, followUp: null}]' "$plan" >"$tmp"
    "$here/plan.sh" write "$tmp"
    echo "added $f-integrate" ;;
  *) echo "usage: integrate.sh check <plan-file> | add <plan-file> <F>" >&2; exit 64 ;;
esac
