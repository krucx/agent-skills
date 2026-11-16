# Plan-derived facts shared by the runwaves scripts; load with plan_jq (common.sh), which includes it.

# Where an item's PR goes: its integration's branch, else $base (integrations never nest). null when
# the item names an integration the plan doesn't have.
def target($integrations; $base):
  if (.integration // null) == null then $base
  else . as $it | [$integrations[]? | select(.id == $it.integration) | .branch][0] end;

# The dependency graph of the work still to do: items neither done nor skipped, dependsOn on anything
# else dropped (done and outside dependencies are met or the item is `waiting`).
def graph: [.items[] | select(.state != "skipped" and .state != "done")] as $its | ($its | map(.id)) as $ids
  | ($its | map({key: .id, value: [(.dependsOn // [])[] | select(. as $d | $ids | index($d))]}) | from_entries) as $deps
  | {ids: $ids, deps: $deps, states: ($its | map({key: .id, value: .state}) | from_entries),
     dependents: ($ids | map(. as $id | {key: $id, value: [$ids[] | select(. as $x | $deps[$x] | index($id))]}) | from_entries)};

# The longest chain through $edges ending at each id, 1 with none, relaxed until stable; still
# changing after one pass per item means a cycle.
def depth($ids; $edges):
  def pass: . as $m | reduce $ids[] as $id ($m; .[$id] = 1 + ([$edges[$id][] | $m[.]] | max // 0));
  def settle($n): pass as $next | if $next == . then . elif $n == 0 then error("dependency cycle") else $next | settle($n - 1) end;
  $ids | map({key: ., value: 1}) | from_entries | settle($ids | length);

# The critical path: every longest dependsOn chain. items: each item on one, in plan order; paths: the
# first $shown of them, first to last, in plan order; pathCount: how many there are (counted, not
# listed). No item is critical when no chain has two items.
def critical($shown): graph as $g | depth($g.ids; $g.deps) as $upto | depth($g.ids; $g.dependents) as $onward
  | ([$upto[]] | max // 0) as $len
  | (if $len < 2 then [] else [$g.ids[] | select($upto[.] + $onward[.] - 1 == $len)] end) as $crit
  | def next($id): $g.dependents[$id][] | select(. as $r | ($crit | index($r)) and $upto[$r] == $upto[$id] + 1);
    def chain_from($id): if $onward[$id] == 1 then [$id] else next($id) | [$id] + chain_from(.) end;
    (reduce ($crit | sort_by(-$upto[.]))[] as $id ({};
      .[$id] = (if $onward[$id] == 1 then 1 else ([next($id) as $r | .[$r]] | add) end))) as $count
  | [$crit[] | select($upto[.] == 1)] as $starts
  | {length: $len, items: $crit, paths: [limit($shown; $starts[] | chain_from(.))],
     pathCount: ([$starts[] | $count[.]] | add // 0)};

# Waves: each wave takes up to $limit items whose dependencies are all in earlier waves, critical
# items first, then the longest chain still ahead, then plan order. A `waiting` item and everything
# after it get no wave.
def waves($limit; $crit): graph as $g | depth($g.ids; $g.deps) as $upto | depth($g.ids; $g.dependents) as $onward
  | (reduce ($g.ids | sort_by($upto[.]))[] as $id ({};
      .[$id] = ($g.states[$id] == "waiting" or ([$g.deps[$id][] as $d | .[$d]] | any)))) as $held
  | ($g.ids | map(select($held[.] | not)) | sort_by((. as $x | $crit | index($x) | not), -$onward[.],
      (. as $x | $g.ids | index($x)))) as $order
  | ([$limit, 1] | max | floor) as $per
  | {waves: {}, n: 0}
  | until((.waves | length) == ($order | length);
      .n += 1 | .n as $n | .waves as $w
      | .waves += ([$order[] | select($w[.] == null and all($g.deps[.][]; $w[.] != null))][:$per]
                   | map({key: ., value: $n}) | from_entries))
  | .waves;
