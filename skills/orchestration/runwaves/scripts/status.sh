#!/usr/bin/env bash
# Print one JSON object per workspace the coordinator should know about: every plan workspace,
# plus every workspace of this project carrying a group tag.
#
# Usage: status.sh [--compact] <project-id> [plan-file]   (inside the repo the PRs belong to)
#
# Fields:
#   id, name, branch  the workspace as Paradev has it now (branch may differ from the plan)
#   item              the plan item using it, or null
#   group             In Progress | In Review | Done | Blocked (tags mapped by the plan's
#                     "groups", else groups.sh), or null
#   inPlan            the plan lists this workspace ID
#   missing           the plan lists it but Paradev no longer has it
#   agent             {terminal, id, state, reason}; state: working | idle | blocked | none, or, for
#                     plan workspaces, from the screen's tail:
#                       blocked  a fatal banner (usage/rate limit, quota, context window, expired
#                                sign-in) in the last 20 lines, with no worker block; reason = it
#                       stalled  Paradev says working, screen unchanged for STALL_MINUTES (15)
#   worker            the last RUNWAVES_WORKER_DONE/BLOCKED/WAITING block on screen (the older
#                     ORCHESTRATOR_WORKER_* name too) as {marker,
#                     item, pr, summary, checked, criteria, reason, needs, waitingOn, resumesWhen}, or null.
#                     marker "waiting" = a declared wait (busy, not done); a later DONE/BLOCKED
#                     replaces it; still latest after WAIT_MINUTES (30) it adds "stale": true and
#                     "staleMinutes", so the coordinator checks the screen instead of skipping
#   pr                newest PR for the branch {number,url,state,isDraft}, or null; an open PR
#                     GitHub calls CONFLICTING adds "conflicting": true and "base" (its base branch).
#                     An <F>-integrate item's PR is its integration branch -> the item's target,
#                     whatever the worker's own branch is.
#
# --compact: one short line per workspace, for watch cycles, adding "branch <b>" or "terminal <t>"
# only when they differ from the plan's.
# Screen hashes: ~/.agents/orchestrator/screens/<plan's runId, else project>.json.
# On Orca (common.sh backend) the rows are the plan's dispatched items only: agent state from
# `orca orchestration worker-show` (working until the dispatch settles; blocked with no reason while
# it waits on a human), worker from its latest worker_done message: a worker block in it if any,
# else the report itself (marker done, or blocked when the dispatch failed; the report is `checked`,
# its subject the summary); branch read from the worker's worktree each time (the plan's when it
# can't be read or is the default, an integration or another item's branch); pr as above, on that
# branch else the plan's, for a missing dispatch too; no groups, stalls or screens.
# gh and Paradev list calls retry 3 times, RETRY_DELAY (5) seconds apart, doubling.
set -euo pipefail

compact=''
[[ ${1:-} == --compact ]] && { compact=1; shift; }
project=$1
plan=${2:-}
here=$(cd "$(dirname "$0")" && pwd)
STALL_MINUTES=${STALL_MINUTES:-15}
WAIT_MINUTES=${WAIT_MINUTES:-30}
# Last-resort agent messages that mean it can't go on; matched ignoring case.
FATAL='usage limit|rate[ -]limit(ed| reached| exceeded)|quota (exceeded|exhausted|reached)|exceeded your (current )?quota|insufficient_quota|context (window|length) (exceeded|exhausted|is full)|context_length_exceeded|out of context|(auth(entication)?|session|token|credentials?|login) (has )?expired|please (log|sign) ?in again|not logged in|invalid api key'


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

# The last RUNWAVES_WORKER_* (or older ORCHESTRATOR_WORKER_*) block in a text, as JSON (terminal-wrapped values rejoined).
# A block whose fields are still <angle-bracket> placeholders is the prompt's own template, not a report;
# the marker counts only on a line of its own, so the prompt naming it mid-sentence is not one either.
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
    { line = $0; sub(/^([[:space:]]|⏺|•|│)+/, "", line); sub(/([[:space:]]|│)+$/, "", line) }
    line ~ /^(RUNWAVES|ORCHESTRATOR)_WORKER_(DONE|BLOCKED|WAITING)$/ { keep(); n = 0; key = ""; done = 0
      marker = line; sub(/^[A-Z]+_WORKER_/, "", marker); marker = tolower(marker); delete v; next }
    marker == "" || done { next }
    line ~ /^unmet:/ { key = "unmet"; v[key] = v[key] (key in v ? "\037" : "") substr(line, 8); next }
    line ~ /^(item|pr|summary|checked|criteria|reason|needs|waiting-on|resumes-when):/ {
      key = substr(line, 1, index(line, ":") - 1); v[key] = substr(line, length(key) + 3); next }
    key != "" && (line == "" || line ~ /^(─|━|>|❯)/) { done = 1; next }
    key != "" { v[key] = v[key] " " line }
    END { keep(); if (bestmarker != "") { printf "marker\t%s\n", bestmarker; for (k in best) printf "%s\t%s\n", k, best[k] } }' |
    jq -Rsc 'split("\n") | map(select(length > 0) | split("\t") | {(.[0]): (.[1:] | join("\t"))}) | add
      | if . then
          ((.criteria // "") | capture("^(?<met>[0-9]+) */ *(?<total>[0-9]+)$")? // null) as $c
          | (.unmet // "" | split("\u001f") | map(select(length > 0))) as $unmet
          | del(.unmet)
          | (if .marker == "done"
             then .criteria = (if $c then {met: ($c.met | tonumber), total: ($c.total | tonumber), unmet: $unmet} else null end)
             else del(.criteria) end)
          | with_entries(.key |= ({"waiting-on": "waitingOn", "resumes-when": "resumesWhen"}[.] // .))
        else . end'
}

emit() { # print $out, one row per line (compact or full)
  if [[ -n $compact ]]; then
    jq -r '[(.item // .name // .id), (.group // "-"),
            (.agent.state + (if .agent.reason then " (\(.agent.reason))" else "" end)),
            (if .pr then "PR #\(.pr.number) \(.pr.state)"
              + (if .pr.conflicting then " CONFLICTING (base \(.pr.base))" else "" end)
             else "no PR" end)]
           + (if .missing then ["missing"] else [] end)
           + (if .planBranch and .branch != .planBranch then ["branch \(.branch)"] else [] end)
           + (if .inPlan and .agent.terminal and .planTerminal != .agent.terminal
              then ["terminal \(.agent.terminal) (\(.agent.id))"] else [] end)
           + (if .worker then ["worker \(.worker.marker)"
                + (if .worker.waitingOn then ", on: \(.worker.waitingOn)" else "" end)
                + (if .worker.resumesWhen then ", until: \(.worker.resumesWhen)" else "" end)
                + (if .worker.stale then ", stale wait (\(.worker.staleMinutes) minutes)" else "" end)
                + (if .worker.checked then ", checked: \(.worker.checked)" else "" end)
                + (if .worker.criteria then ", criteria \(.worker.criteria.met)/\(.worker.criteria.total)"
                    + (if (.worker.criteria.unmet | length) > 0 then ", \(.worker.criteria.unmet | length) unmet" else "" end)
                  else "" end)
                + (if .worker.reason then ", reason: \(.worker.reason)" else "" end)] else [] end)
           | join(" | ")' <<<"$out"
  else
    jq -c 'del(.screen, .planBranch, .planTerminal)' <<<"$out"
  fi
}

. "$here/common.sh"

# The item's PR: an <F>-integrate item's is $heads[item] (integration branch -> target); any other's
# the newest on the first of $branches that has one.
PR_OF='def pr_of($item; $branches; $heads; $prs; $conflicts):
  ($heads[$item // ""]) as $h
  | (if $h then [$prs[] | select(.headRefName == $h.head and .baseRefName == $h.base)][0]
     else [$branches[] as $b | $prs[] | select(.headRefName == $b)][0] end)
  | if . == null then null else
      {number, url, state, isDraft} as $pr
      | ([$conflicts[] | select(.number == $pr.number)][0]) as $c
      | if $c then $pr + {conflicting: true, base: $c.base} else $pr end end;'
heads='{}'
[[ -n "$plan" && -f "$plan" ]] && heads=$(plan_jq '. as $p | [.items[] | select(.integrates != null) | . as $it
  | {key: .id, value: {head: ([$p.integrations[]? | select(.id == $it.integrates) | .branch][0]),
                       base: target($p.integrations; $base)}}] | from_entries' "$plan" -c --arg base "$(default_branch)")

if [[ $(backend) == orca ]]; then
  prs=$(retry gh pr list --state all --limit 300 --json headRefName,baseRefName,number,url,state,isDraft)
  conflicts=$(retry gh pr list --state open --limit 300 --json number,baseRefName,mergeable |
    jq -c '[.[] | select(.mergeable == "CONFLICTING") | {number, base: .baseRefName}]')
  # Never an item's own branch: the default branch, an integration branch, another item's branch.
  # (A worktree read straight after worker-start can still be on its base.)
  shared=$([[ -n "$plan" && -f "$plan" ]] && jq -c --arg d "$(default_branch)" \
    '{d: $d, i: [.integrations[]?.branch], items: [.items[] | select(.branch != null) | {id, branch}]}' "$plan" || echo null)
  inboxes='{}'
  out=''
  [[ -n "$plan" && -f "$plan" ]] && out=$(jq -c '.items[] | select(.workspace != null) | {item: .id, id: .workspace, branch, terminal}' "$plan" |
    while IFS= read -r p; do
      d=$(jq -r .id <<<"$p")
      if ! shown=$(orca_cli orchestration worker-show --dispatch "$d" --json </dev/null 2>/dev/null) ||
          ! jq -e '.result.dispatchId' <<<"$shown" >/dev/null 2>&1; then
        jq -c --argjson prs "$prs" --argjson conflicts "$conflicts" --argjson heads "$heads" "$PR_OF"'
          {id, name: null, branch, group: null, missing: true, item, inPlan: true,
           agent: {terminal, id: null, state: "none", reason: null}, worker: null,
           pr: pr_of(.item; [.branch // empty]; $heads; $prs; $conflicts)}' <<<"$p"
        continue
      fi
      # The worktree's branch now (Orca may prefix it, a worker may switch it), else the plan's.
      wpath=$(jq -r '.result.workspace // "" | sub("^[^:]*::"; "")' <<<"$shown")
      live=''
      [[ -z $wpath || ! -d $wpath ]] || live=$(git -C "$wpath" branch --show-current 2>/dev/null || true)
      if [[ -n $live ]] && jq -e --arg b "$live" --argjson p "$p" \
          '$b == .d or (.i | index($b)) or any(.items[]; .branch == $b and .id != $p.item)' <<<"$shared" >/dev/null; then
        live=''
      fi
      run=$(jq -r '.result.runId // empty' <<<"$shown")
      body='' msg=''
      if [[ -n $run ]]; then
        if [[ $(jq -r --arg r "$run" 'has($r)' <<<"$inboxes") != true ]]; then
          mail=$(orca_cli orchestration inbox --terminal "run:$run" --limit 100 --full --json </dev/null 2>/dev/null || echo '{}')
          inboxes=$(jq -c --arg r "$run" --argjson m "$(jq -c '[.result.messages[]?]' <<<"$mail" 2>/dev/null || echo '[]')" '.[$r] = $m' <<<"$inboxes")
        fi
        msg=$(jq -c --arg r "$run" --arg d "$d" '[.[$r][] | select(.type == "worker_done" and .payload.dispatchId == $d)] | last // empty' <<<"$inboxes")
        body=$(jq -r '.body // empty' <<<"${msg:-null}")
      fi
      worker=$(printf '%s\n' "$body" | worker_block)
      if [[ ( -z $worker || $worker == null ) && -n $body ]]; then  # Orca's own report, no block
        worker=$(jq -c --argjson s "$shown" --argjson m "$msg" '
          {marker: (if $s.result.state == "failed" then "blocked" else "done" end), summary: ($m.subject // ""),
           checked: ($m.body | gsub("\\s+"; " ") | .[0:600])}
          | if .marker == "blocked" then {marker, reason: .checked} else . end' <<<"null")
      fi
      jq -c --argjson s "$shown" --argjson worker "${worker:-null}" --argjson prs "$prs" --argjson conflicts "$conflicts" \
        --argjson heads "$heads" --arg live "$live" "$PR_OF"'
        ($s.result) as $r
        | ($r.state // "") as $st
        | {id, name: null, branch: (if $live != "" then $live else .branch end), group: null, missing: false, item, inPlan: true,
           agent: {terminal: ($r.terminal // .terminal), id: null, reason: null,
                   state: (if $r.waitingOnHuman == true then "blocked"
                           elif ($st | test("^(succeeded|failed|completed|cancell?ed|stopped|exited|lost|abandoned)$")) then "idle"
                           else "working" end)},
           worker: $worker,
           pr: pr_of(.item; [$live, .branch] | map(select(. != null and . != "")); $heads; $prs; $conflicts)}' <<<"$p"
    done)
  emit
  exit 0
fi

# superset, paradev and pdev are the same Paradev CLI; use whichever is installed.
cli=$(command -v superset || command -v paradev || command -v pdev) ||
  { echo "Paradev CLI not found: install superset, paradev or pdev" >&2; exit 1; }

groups=$("$here/groups.sh" "$project" plan "$plan") || (($? == 2))
snapshot=$(retry "$cli" snapshot --json)
prs=$(retry gh pr list --state all --limit 300 --json headRefName,baseRefName,number,url,state,isDraft)
# Only the open PRs GitHub calls CONFLICTING, with their bases (a stacked PR whose parent
# squash-merged), in one call rather than a view per PR.
conflicts=$(retry gh pr list --state open --limit 300 --json number,baseRefName,mergeable |
  jq -c '[.[] | select(.mergeable == "CONFLICTING") | {number, base: .baseRefName}]')

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
  --argjson snapshot "$snapshot" --argjson prs "$prs" --argjson conflicts "$conflicts" --argjson heads "$heads" -n "$PR_OF"'
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
      pr: pr_of($p.item; [$ws.branch // empty]; $heads; $prs; $conflicts),
      planBranch: $p.branch,
      planTerminal: $p.terminal
    }')

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
    # A finished worker block wins: its summary may mention "rate limit" and the like. A declared
    # wait doesn't: the worker is still running, so a banner after it still blocks.
    banner=''
    [[ $worker == null || -z $worker || $worker == *'"marker":"waiting"'* ]] && banner=$(printf '%s\n' "$text" | tail -n 20 |
      grep -iE "$FATAL" | tail -n 1 | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | cut -c1-200 || true)
    # A declared wait is timed by its own text, not the screen, which an idle agent may redraw.
    wkey=$(printf '%s' "$worker" | cksum | tr -d ' \t')
    row=$(jq -c --arg t "$t" --arg hash "$hash" --arg banner "$banner" --argjson worker "${worker:-null}" \
      --argjson seen "$seen" --argjson now "$now" --argjson stall $((STALL_MINUTES * 60)) \
      --arg wkey "$wkey" --argjson waitlimit $((WAIT_MINUTES * 60)) '
      ($seen[$t] // {}) as $old
      | (if $old.hash == $hash and $old.state == "working" then $old.since else $now end) as $since
      | .worker = $worker
      | .screen = {hash: $hash, since: $since, state: .agent.state}
      | if .worker.marker == "waiting" then
          (if $old.wait.key == $wkey then $old.wait.since else $now end) as $ws
          | .screen.wait = {key: $wkey, since: $ws}
          | if $now - $ws >= $waitlimit
            then .worker += {stale: true, staleMinutes: (($now - $ws) / 60 | floor)} else . end
        else . end
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

emit
