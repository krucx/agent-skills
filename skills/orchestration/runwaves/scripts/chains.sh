#!/usr/bin/env bash
# Offer dependency chains as integration branches at plan approval, and apply the user's answer.
#
# Usage: chains.sh offer  <plan-file>                      one JSON line per chain: {"items": [...], "branch": ...}
#        chains.sh critical <plan-file>                    {"length", "items", "paths", "pathCount"} (planlib.jq)
#        chains.sh waves    <plan-file>                    {"<ID>": <wave>, ...} under maxParallel (default 5)
#        chains.sh accept <plan-file> [--local] <ID>...    make the chain containing each ID its own integration
#        chains.sh share  <plan-file> <slug> [--local]     one feature/<slug> integration for every item
# --local marks the integration `local: true`: the branch lives in this clone only, with no sub-PRs
# (references/integrations.md, "Local integration branch"). A plan with `cloud: true` (cloud
# workspaces cannot reach this clone's branches) refuses --local and offers no local chain branch.
#
# A chain is a connected group of two or more items linked by dependsOn (#340 <- #341 <- #342, or a
# diamond). Only items without an integration (and not an <F>-integrate item) are chained, so once a
# run shares one feature branch (share) only local chain branches (below) are left to offer. The
# branch is feature/<root id>-<root title slug>, the root being the chain's first item in plan
# order with no dependency inside it. accept and share write through plan.sh.
#
# Inside a GitHub integration, offer also lists its local chain branches (planlib.jq local_chains:
# runs of two or more critical items linked one to one) as {"items", "branch", "parent", "question"}.
# accept on one adds a nested integration: branch chain/<first id>-<slug>, `local: true`, `parent`
# the GitHub integration, `base` its branch. Its items merge in this clone with no sub-PRs; the chain
# lands on the parent with one PR, through the <F>-integrate item (integrate.sh).
#
# critical and waves cover the items neither done nor skipped (planlib.jq has the rules); both exit 1
# on a dependency cycle.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
default_base=$(default_branch)

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

branch_for() { # branch_for <root id> <title> [prefix]
  local id
  id=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/^#//')
  echo "${3:-feature}/$id-$(slug "$2" 40)"
}

local_chains() { # each local chain as {items, parent, root, title, into}
  plan_jq '. as $p | local_chains[] | . as $c | ($p.items[] | select(.id == $c.items[0])) as $r
    | $c + {root: $r.id, title: $r.title, into: [$p.integrations[] | select(.id == $c.parent) | .branch][0]}' "$1" -c
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
    done
    ! is_cloud "$2" || exit 0
    local_chains "$2" | while IFS= read -r c; do
      jq -c --arg b "$(branch_for "$(jq -r .root <<<"$c")" "$(jq -r .title <<<"$c")" chain)" \
        '{items, branch: $b, parent, question: "run \(.items | join(", ")) on the local branch \($b), one PR into \(.into)?"}' <<<"$c"
    done ;;
  critical)
    plan_jq 'critical(5)' "$2" -c ;;
  waves)
    plan_jq 'waves(.maxParallel // 5; critical(0).items)' "$2" -c ;;
  accept)
    plan=$2
    shift 2
    islocal=false; [[ ${1:-} != --local ]] || { islocal=true; shift; }
    ! $islocal || no_cloud "$plan"
    for id in "$@"; do
      c=$(chains "$plan" | jq -c --arg id "$id" 'select(.items | index($id))')
      if [[ -z $c ]]; then
        c=$(local_chains "$plan" | jq -c --arg id "$id" 'select(.items | index($id))')
        [[ -n $c ]] || { echo "$id is in no offered chain" >&2; exit 1; }
        no_cloud "$plan"
        f=$(next_id "$plan")
        b=$(branch_for "$(jq -r .root <<<"$c")" "$(jq -r .title <<<"$c")" chain)
        apply "$plan" --arg f "$f" --arg b "$b" --argjson c "$c" \
          '.integrations += [{id: $f, title: $c.title, branch: $b, base: $c.into, parent: $c.parent, pr: null,
                              state: "open", local: true}]
           | .items |= map(if (.id as $x | $c.items | index($x)) then .integration = $f else . end)'
        echo "added $f $b (local, into $(jq -r .into <<<"$c")): $(jq -r '.items | join(", ")' <<<"$c")"
        continue
      fi
      f=$(next_id "$plan")
      b=$(branch_for "$(jq -r .root <<<"$c")" "$(jq -r .title <<<"$c")")
      apply "$plan" --arg f "$f" --arg b "$b" --arg base "$default_base" --argjson c "$c" --argjson local "$islocal" \
        '.integrations = (.integrations // []) + [{id: $f, title: $c.title, branch: $b, base: $base, pr: null, state: "open"}
                                                  + (if $local then {local: true} else {} end)]
         | .items |= map(if (.id as $x | $c.items | index($x)) then .integration = $f else . end)'
      echo "added $f $b: $(jq -r '.items | join(", ")' <<<"$c")"
    done ;;
  share)
    plan=$2 slug=$(slug "${3:?usage: chains.sh share <plan-file> <slug> [--local]}" 50)
    [[ -n $slug ]] || { echo "empty slug" >&2; exit 1; }
    islocal=false; [[ ${4:-} != --local ]] || { islocal=true; no_cloud "$plan"; }
    f=$(next_id "$plan")
    apply "$plan" --arg f "$f" --arg b "feature/$slug" --arg base "$default_base" --argjson local "$islocal" \
      '.integrations = (.integrations // []) + [{id: $f, title: $b, branch: $b, base: $base, pr: null, state: "open"}
                                                + (if $local then {local: true} else {} end)]
       | .items |= map(if (.integration // null) == null and (.integrates // null) == null and .state != "skipped"
                       then .integration = $f else . end)'
    echo "added $f feature/$slug" ;;
  *) echo "usage: chains.sh offer <plan-file> | critical <plan-file> | waves <plan-file> | accept <plan-file> [--local] <ID>... | share <plan-file> <slug> [--local]" >&2; exit 64 ;;
esac
