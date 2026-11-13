#!/usr/bin/env bash
# Print one JSON object per workspace the orchestrator should know about: every workspace in
# the plan, plus every workspace of this project carrying a group tag.
#
# Usage: status.sh [--compact] <project-id> [plan-file]   (run inside the repo the PRs belong to)
#
# Fields:
#   id, name, branch       the workspace as Paradev has it now (branch may differ from the plan)
#   item                   the plan item using this workspace, or null
#   group                  its logical group (In Progress, In Review, Done, Blocked; tags mapped
#                          by the plan's "groups", else groups.sh), or null
#   inPlan                 true when the plan lists this workspace ID
#   missing                true when the plan lists it but Paradev no longer has it
#   agent                  {terminal, id, state, reason}; state is working | idle | blocked | none,
#                          or, for plan workspaces, from the tail of the screen:
#                            blocked  a fatal banner (usage or rate limit, quota, context window,
#                                     expired sign-in) is in the last 20 lines and no worker
#                                     block is; reason is that line
#                            stalled  Paradev says working but the screen hasn't changed for
#                                     STALL_MINUTES (default 15)
#   worker                 the last ORCHESTRATOR_WORKER_DONE/BLOCKED block on screen as
#                          {marker, item, pr, summary, checked, reason, needs}, or null
#   pr                     newest PR for the branch {number,url,state,isDraft}, or null
#
# --compact prints one short line per workspace instead, for watch cycles; it adds "branch <b>" or
# "terminal <t>" only when they differ from the plan's.
# Screen hashes live in ~/.agents/orchestrator/screens/<plan's runId, else project>.json.
# gh and Paradev list calls are retried 3 times, RETRY_DELAY (default 5) seconds apart, doubling.
set -euo pipefail

compact=''
[[ ${1:-} == --compact ]] && { compact=1; shift; }
project=$1
plan=${2:-}
here=$(cd "$(dirname "$0")" && pwd)
STALL_MINUTES=${STALL_MINUTES:-15}
# Last-resort agent messages that mean it can't go on; matched ignoring case.
FATAL='usage limit|rate[ -]limit(ed| reached| exceeded)|quota (exceeded|exhausted|reached)|exceeded your (current )?quota|insufficient_quota|context (window|length) (exceeded|exhausted|is full)|context_length_exceeded|out of context|(auth(entication)?|session|token|credentials?|login) (has )?expired|please (log|sign) ?in again|not logged in|invalid api key'

# superset, paradev and pdev are the same Paradev CLI; use whichever is installed.
cli=$(command -v superset || command -v paradev || command -v pdev) ||
  { echo "Paradev CLI not found: install superset, paradev or pdev" >&2; exit 1; }

# Run a gh or Paradev call, retrying transient failures (e.g. "error connecting to
# api.github.com") with backoff; print its output only once it succeeds.
retry() {
  local i out
  for i in 1 2 3; do
    out=$("$@") && { printf '%s\n' "$out"; return; }
    ((i < 3)) && sleep $((i * ${RETRY_DELAY:-5}))
  done
  return 1
}

groups=$("$here/groups.sh" "$project" plan "$plan") || (($? == 2))
snapshot=$(retry "$cli" snapshot --json)
prs=$(retry gh pr list --state all --limit 300 --json headRefName,number,url,state,isDraft)

tagged=$(jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<<"$groups" | while IFS=$'\t' read -r group tag; do
  retry "$cli" workspaces list --local --project "$project" --tag "$tag" --json |
    jq -c --arg group "$group" '.[] | {id, name, branch, group: $group}' || exit 1
done | jq -sc '.')

planned='[]'
if [[ -n "$plan" && -f "$plan" ]]; then
  planned=$(jq -c '[.items[] | select(.workspace != null)
    | {id: .workspace, branch, item: .id, terminal}]' "$plan")
fi

# Planned workspaces that carry no group tag: look them up one by one.
untagged=$(jq -c --argjson tagged "$tagged" \
  '[.[] | select(.id as $id | $tagged | map(.id) | index($id) | not)]' <<<"$planned")
extra=$(jq -c '.[]' <<<"$untagged" | while IFS= read -r p; do
  id=$(jq -r .id <<<"$p")
  if ws=$("$cli" workspaces get "$id" --local --json 2>/dev/null); then
    jq -c '{id, name, branch, group: null, missing: false}' <<<"$ws"
  # Missing only if the project's full list (retried) lacks it; if that fails too, fail.
  elif ! listed=$(retry "$cli" workspaces list --local --project "$project" --json); then
    exit 1
  elif ws=$(jq -ce --arg id "$id" '.[] | select(.id == $id)' <<<"$listed"); then
    jq -c '{id, name, branch, group: null, missing: false}' <<<"$ws"
  else
    jq -c '{id, name: null, branch, group: null, missing: true}' <<<"$p"
  fi
done | jq -sc '.')

rows=$(jq -c --argjson tagged "$tagged" --argjson extra "$extra" --argjson planned "$planned" \
  --argjson snapshot "$snapshot" --argjson prs "$prs" -n '
  ($tagged | map(. + {missing: false})) + $extra
  | .[]
  | . as $ws
  | ([$planned[] | select(.id == $ws.id)][0]) as $p
  | . + {
      item: $p.item,
      inPlan: ($p != null),
      agent: ([$snapshot.workspaces[] | select(.id == $ws.id) | .terminals[]
               | select(.agent != null)][0]
              | if . == null then {terminal: null, id: null, state: "none", reason: null}
                else {terminal: .id, id: .agent.id, state: .agent.state, reason: null} end),
      worker: null,
      pr: ([$prs[] | select(.headRefName == $ws.branch)][0]
           | if . == null then null else {number, url, state, isDraft} end),
      planBranch: $p.branch,
      planTerminal: $p.terminal
    }')

# The last ORCHESTRATOR_WORKER_* block on a screen, as JSON (terminal-wrapped values rejoined).
# A block whose fields are still <angle-bracket> placeholders is the prompt's own template, not a report.
worker_block() {
  awk '
    function keep(   k, ph) {
      if (marker == "") return
      for (k in v) if (v[k] ~ /^<.*>$/) ph = 1
      if (ph) return
      for (k in best) delete best[k]
      for (k in v) best[k] = v[k]
      bestmarker = marker
    }
    /ORCHESTRATOR_WORKER_(DONE|BLOCKED)/ { keep(); n = 0; key = ""; done = 0
      marker = ($0 ~ /DONE/) ? "done" : "blocked"; delete v; next }
    marker == "" || done { next }
    { line = $0; sub(/^([[:space:]]|⏺|•|│)+/, "", line); sub(/([[:space:]]|│)+$/, "", line) }
    line ~ /^(item|pr|summary|checked|reason|needs):/ {
      key = substr(line, 1, index(line, ":") - 1); v[key] = substr(line, length(key) + 3); next }
    key != "" && (line == "" || line ~ /^(─|━|>|❯)/) { done = 1; next }
    key != "" { v[key] = v[key] " " line }
    END { keep(); if (bestmarker != "") { printf "marker\t%s\n", bestmarker; for (k in best) printf "%s\t%s\n", k, best[k] } }' |
    jq -Rsc 'split("\n") | map(select(length > 0) | split("\t") | {(.[0]): (.[1:] | join("\t"))}) | add'
}

# Plan workspaces: read the screen's tail for the worker block, fatal banners and stalls.
key=$( [[ -n "$plan" && -f "$plan" ]] && jq -r '.runId // empty' "$plan" || true)
screens="$HOME/.agents/orchestrator/screens/${key:-$project}.json"
seen='{}'
[[ -f $screens ]] && seen=$(jq -c . "$screens" 2>/dev/null || echo '{}')
now=$(date +%s)
out=$(while IFS= read -r row; do
  [[ -n $row ]] || continue
  t=$(jq -r 'select(.inPlan and (.missing | not)) | .agent.terminal // empty' <<<"$row")
  if [[ -n $t ]] && text=$("$cli" terminals read --local --workspace "$(jq -r .id <<<"$row")" \
      --terminal "$t" --max-lines 60 --json 2>/dev/null | jq -r '.text // empty'); then
    hash=$(printf '%s' "$text" | cksum | tr -d ' \t')
    worker=$(printf '%s\n' "$text" | worker_block)
    # A finished worker block wins: its summary may mention "rate limit" and the like.
    banner=''
    [[ $worker == null || -z $worker ]] && banner=$(printf '%s\n' "$text" | tail -n 20 |
      grep -iE "$FATAL" | tail -n 1 | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | cut -c1-200 || true)
    row=$(jq -c --arg t "$t" --arg hash "$hash" --arg banner "$banner" --argjson worker "${worker:-null}" \
      --argjson seen "$seen" --argjson now "$now" --argjson stall $((STALL_MINUTES * 60)) '
      ($seen[$t] // {}) as $old
      | (if $old.hash == $hash and $old.state == "working" then $old.since else $now end) as $since
      | .worker = $worker
      | .screen = {hash: $hash, since: $since, state: .agent.state}
      | if $banner != "" then .agent.state = "blocked" | .agent.reason = $banner
        elif .agent.state == "working" and $now - $since >= $stall then
          .agent.state = "stalled"
          | .agent.reason = "screen unchanged for \(($now - $since) / 60 | floor) minutes"
        else . end' <<<"$row")
  fi
  printf '%s\n' "$row"
done <<<"$rows")

# Remember this cycle's screens (terminals not seen now are dropped).
mkdir -p "$(dirname "$screens")"
jq -sc 'map(select(.screen) | {(.agent.terminal): .screen}) | add // {}' <<<"$out" >"$screens.tmp.$$"
mv -f "$screens.tmp.$$" "$screens"

if [[ -n $compact ]]; then
  jq -r '[(.item // .name // .id), (.group // "-"),
          (.agent.state + (if .agent.reason then " (\(.agent.reason))" else "" end)),
          (if .pr then "PR #\(.pr.number) \(.pr.state)" else "no PR" end)]
         + (if .missing then ["missing"] else [] end)
         + (if .planBranch and .branch != .planBranch then ["branch \(.branch)"] else [] end)
         + (if .inPlan and .agent.terminal and .planTerminal != .agent.terminal
            then ["terminal \(.agent.terminal) (\(.agent.id))"] else [] end)
         + (if .worker then ["worker \(.worker.marker)"
              + (if .worker.checked then ", checked: \(.worker.checked)" else "" end)
              + (if .worker.reason then ", reason: \(.worker.reason)" else "" end)] else [] end)
         | join(" | ")' <<<"$out"
else
  jq -c 'del(.screen, .planBranch, .planTerminal)' <<<"$out"
fi
