#!/usr/bin/env bash
# Offer dependency chains as integration branches at plan approval, and apply the user's answer.
#
# Usage: chains.sh offer  <plan-file>            one JSON line per chain: {"items": [...], "branch": ...}
#        chains.sh accept <plan-file> <ID>...    make the chain containing each ID its own integration
#        chains.sh share  <plan-file> <slug>     one feature/<slug> integration for every item
#
# A chain is a connected group of two or more items linked by dependsOn (#340 <- #341 <- #342, or a
# diamond). Only items without an integration (and not an <F>-integrate item) are chained, so once a
# run shares one feature branch (share) nothing is left to offer: integrations never nest. The
# branch is feature/<root id>-<root title slug>, the root being the chain's first item in plan
# order with no dependency inside it. accept and share write through plan.sh.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
default_base=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)
default_base=${default_base:-main}

# Each chain as {items: [ids in plan order], root: <item>}.
chains() {
  jq -c '[.items[] | select((.integration // null) == null and (.integrates // null) == null
        and .state != "skipped")] as $its
    | ($its | map(.id)) as $ids
    | def edges: [$its[] | . as $i | ($i.dependsOn // [])[] | select(. as $d | $ids | index($d)) | [$i.id, .]];
      (edges) as $e
    | def comp($s): ([$e[] | select(.[0] as $a | .[1] as $b | ($s | index($a)) or ($s | index($b))) | .[]] + $s | unique) as $n
        | if ($n | length) == ($s | length) then $s else comp($n) end;
      reduce $ids[] as $id ({seen: [], out: []};
        if (.seen | index($id)) then .
        else comp([$id]) as $c | .seen += $c
          | if ($c | length) >= 2 then .out += [$c] else . end end)
    | .out[] | . as $c | [$ids[] | select(. as $x | $c | index($x))] as $ordered
    | [$its[] | select(.id as $x | $ordered | index($x))] as $m
    | ([$m[] | select(([(.dependsOn // [])[] | select(. as $d | $ordered | index($d))] | length) == 0)][0]) as $root
    | {items: $ordered, root: $root.id, title: $root.title}' "$1"
}

slug() { # slug <text> <max>
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-"$2" | sed -E 's/-+$//'
}

branch_for() { # branch_for <root id> <title>
  local id
  id=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/^#//')
  echo "feature/$id-$(slug "$2" 40)"
}

next_id() { jq -r '"F\(([.integrations[]?.id | ltrimstr("F") | tonumber? ] | max // 0) + 1)"' "$1"; }

apply() { # apply <plan> <jq filter taking $f, $branch, $title, $ids>
  local plan=$1 tmp
  shift
  tmp=$(mktemp "${TMPDIR:-/tmp}/chains.XXXXXX")
  jq "$@" "$plan" >"$tmp" && "$here/plan.sh" write "$tmp" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
}

case ${1:-} in
  offer)
    chains "$2" | while IFS= read -r c; do
      jq -c --arg b "$(branch_for "$(jq -r .root <<<"$c")" "$(jq -r .title <<<"$c")")" \
        '{items, branch: $b, question: "group \(.items | join(", ")) into \($b)?"}' <<<"$c"
    done ;;
  accept)
    plan=$2
    shift 2
    for id in "$@"; do
      c=$(chains "$plan" | jq -c --arg id "$id" 'select(.items | index($id))')
      [[ -n $c ]] || { echo "$id is in no offered chain" >&2; exit 1; }
      f=$(next_id "$plan")
      b=$(branch_for "$(jq -r .root <<<"$c")" "$(jq -r .title <<<"$c")")
      apply "$plan" --arg f "$f" --arg b "$b" --arg base "$default_base" --argjson c "$c" \
        '.integrations = (.integrations // []) + [{id: $f, title: $c.title, branch: $b, base: $base, pr: null, state: "open"}]
         | .items |= map(if (.id as $x | $c.items | index($x)) then .integration = $f else . end)'
      echo "added $f $b: $(jq -r '.items | join(", ")' <<<"$c")"
    done ;;
  share)
    plan=$2 slug=$(slug "${3:?usage: chains.sh share <plan-file> <slug>}" 50)
    [[ -n $slug ]] || { echo "empty slug" >&2; exit 1; }
    f=$(next_id "$plan")
    apply "$plan" --arg f "$f" --arg b "feature/$slug" --arg base "$default_base" \
      '.integrations = (.integrations // []) + [{id: $f, title: $b, branch: $b, base: $base, pr: null, state: "open"}]
       | .items |= map(if (.integration // null) == null and (.integrates // null) == null and .state != "skipped"
                       then .integration = $f else . end)'
    echo "added $f feature/$slug" ;;
  *) echo "usage: chains.sh offer <plan-file> | accept <plan-file> <ID>... | share <plan-file> <slug>" >&2; exit 64 ;;
esac
