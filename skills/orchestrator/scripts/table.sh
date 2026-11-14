#!/usr/bin/env bash
# Render the run's status table (SKILL.md, "Status table") from the plan and status.sh rows.
#
# Usage: table.sh [--force] [--rows <file|->] <project-id> <plan-file>   (inside the repo the PRs belong to)
#
# Rows come from status.sh (run here unless --rows gives its JSON lines: a file, or - for stdin, so
# a cycle that already ran status.sh doesn't run it again). Facts (agent state, PR, sidebar group)
# come from the rows; the plan supplies order, titles, integrations and the states of items that
# have no workspace yet.
# The last render is remembered in ~/.agents/orchestrator/tables/<plan's runId, else project>.md;
# a render equal to it prints the single line `unchanged` unless --force is given.
set -euo pipefail

force=''
rows_from=''
while [[ ${1:-} == --* ]]; do
  case $1 in
    --force) force=1; shift ;;
    --rows) rows_from=${2:?--rows needs a file or -}; shift 2 ;;
    *) echo "table.sh: unknown option $1" >&2; exit 1 ;;
  esac
done
project=${1:?usage: table.sh [--force] [--rows <file|->] <project-id> <plan-file>}
plan=${2:?usage: table.sh [--force] [--rows <file|->] <project-id> <plan-file>}
here=$(cd "$(dirname "$0")" && pwd)

if [[ -z $rows_from ]]; then rows=$("$here/status.sh" "$project" "$plan")
elif [[ $rows_from == - ]]; then rows=$(cat)
else rows=$(cat "$rows_from")
fi

table=$(jq -rn --slurpfile plan "$plan" --argjson rows "$(jq -sc . <<<"${rows:-}")" '
  $plan[0] as $p
  | ($p.items // []) as $items
  | def esc: tostring | gsub("\\|"; "\\|") | gsub("\n"; " ");
    def row($id): [$rows[] | select(.item == $id)][0];
    def prnum($it; $r):
      if $r.pr then "#\($r.pr.number)"
      elif ($it.pr | type) == "string" then ($it.pr | capture("(?<n>[0-9]+)/?$").n // null | if . then "#" + . else "—" end)
      else "—" end;
    def agent($r):
      if $r == null then "—"
      elif $r.worker.marker == "waiting" and $r.agent.state == "idle" then "waiting"
      elif $r.agent.state == "working" then "running"
      elif $r.agent.state == "stalled" then "stalled"
      elif $r.agent.state == "blocked" then "waiting for input"
      elif $r.worker.marker == "blocked" and $r.agent.state == "idle" then "waiting for input"
      elif $r.agent.state == "idle" then "done"
      else "—" end;
    def stategroup($it):
      {"in-progress": "In Progress", "in-review": "In Review", "feedback": "In Review",
       "done": "Done", "blocked": "Blocked", "skipped": "Skipped"}[$it.state];
    def group($it; $r):
      if $it.state == "queued" then
        ([($it.dependsOn // [])[] as $d | select(([$items[] | select(.id == $d)][0].state // "") != "done") | $d]) as $open
        | if ($open | length) > 0 then "Queued (after \($open | join(", ")))" else "Queued" end
      elif $it.state == "waiting" then "Waiting (\($it.reason // "dependency failed"))"
      elif $it.state == "skipped" then "Skipped"
      else ($r.group // stategroup($it) // $it.state) end;
    def line($it): row($it.id) as $r
      | "| \($it.id | esc) | \($it.title // "" | esc) | \(group($it; $r) | esc) | \(agent($r)) | \(prnum($it; $r)) |";
    def held($f): [$items[] | select(.integration == $f.id)
      | select(.state == "blocked" or .state == "waiting" or (.state == "skipped" and (.dropped // false | not)))
      | "\(.id) \(.state)"];
    ($p.integrations // []) as $integs
    | def header($f): "| **\($f.id) \($f.branch)**\(if (held($f) | length) > 0 then " (held: \(held($f) | join(", ")))" else "" end) | | | | |";
    # Table lines in plan order: an integration group opens at its first item, `<F>-integrate` last.
    (reduce $items[] as $it ({out: [], seen: []};
      if $it.integrates then .
      elif ($it.integration != null) and ([$integs[] | select(.id == $it.integration)] | length) > 0 then
        if (.seen | index($it.integration)) then .
        else ([$integs[] | select(.id == $it.integration)][0]) as $f
          | .seen += [$f.id]
          | .out += [header($f)]
            + [$items[] | select(.integration == $f.id) | line(.)]
            + [$items[] | select(.integrates == $f.id) | line(.)]
        end
      else .out += [line($it)] end) | .out) as $lines
    # Below the table: only what SKILL.md allows.
    | ([$items[] | . as $it | row($it.id) as $r
        | (if $r != null and $r.missing then "\($it.id) workspace missing" else empty end),
          (if $it.state == "blocked" then "\($it.id) blocked: \($it.reason // $r.agent.reason // "no reason recorded")" else empty end),
          (if $r.agent.state == "stalled" then "\($it.id) stalled: \($r.agent.reason)" else empty end),
          (if $r.agent.state == "blocked" and $it.state != "blocked" then "\($it.id) waiting for input\(if $r.agent.reason then ": \($r.agent.reason)" else "" end)" else empty end),
          (if $r.worker.marker == "blocked" then "\($it.id) worker blocked: \($r.worker.reason // "—")\(if $r.worker.needs then " (needs: \($r.worker.needs))" else "" end)" else empty end),
          (if $it.state == "waiting" then "\($it.id) \($it.reason // "waiting on a failed dependency"): start it anyway or skip it?" else empty end),
          (if $r.pr.state == "CLOSED" then "\($it.id) PR #\($r.pr.number) closed unmerged" else empty end),
          (if ($it.acceptance // "ok") != "ok" then "\($it.id) acceptance gap: \($it.acceptance)" else empty end),
          (if $it.extras then "\($it.id) possible follow-up: \($it.extras)" else empty end),
          (if $it.state == "in-review" and ($it.checked // $r.worker.checked) then "\($it.id) checked: \($it.checked // $r.worker.checked)" else empty end)
      ]) as $notes
    | ["| Item | Title | Group | Agent | PR |", "| --- | --- | --- | --- | --- |"] + $lines
      + (if ($notes | length) > 0 then [""] + $notes else [] end)
    | .[]')

key=$(jq -r '.runId // empty' "$plan")
last="$HOME/.agents/orchestrator/tables/${key:-$project}.md"
if [[ -z $force && -f $last && $(cat "$last") == "$table" ]]; then
  echo unchanged
  exit 0
fi
mkdir -p "$(dirname "$last")"
printf '%s\n' "$table" >"$last.tmp.$$"
mv -f "$last.tmp.$$" "$last"
printf '%s\n' "$table"
