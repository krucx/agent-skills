#!/usr/bin/env bash
# One watch cycle: everything SKILL.md's Reconcile and Watch-and-move tables do that is a pure
# function of the plan and the status rows, so the model only sees what needs judgment.
#
# Usage (inside the repo): cycle.sh [--dry-run] <project-id> <plan-file>
#
# In order: heartbeat; status.sh once; reconcile; transitions; acceptance hand-off; merge gate;
# integrations; dispatch; tags re-applied; finished detection. Every action appends a plan event;
# the plan is written through plan.sh write (before the steps that read it from disk, and at the end).
#
# Output, one JSON object: {"events": [new events], "needs": [...], "finished": bool, "table": <md|null>}
#   needs: {"kind", "item", "detail"}, kind one of accept | question | blocked | dependency-failed |
#          stalled | stale-wait | held | closed-pr (the judgment calls; "table" is table.sh's render
#          when it changed, else null)
# Exit: 0 nothing needs the model; 10 something does; 3 taken over (prints `taken-over`); 1 a
# failure stopped the cycle. --dry-run computes the same and writes, sends, merges, dispatches
# and tags nothing (the plan file is not touched).
#
# An item whose DONE block arrived (or that is idle with a PR) moves to the state `accepting`,
# outside the parallel limit, and becomes `in-review` only through accept.sh. Tests: test/run.sh.
set -uo pipefail

dry=''
[[ ${1:-} == --dry-run ]] && { dry=1; shift; }
(($# == 2)) || { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }
project=$1 plan=$2
here=$(cd "$(dirname "$0")" && pwd)
cli=$(command -v superset || command -v paradev || command -v pdev) ||
  { echo "cycle: Paradev CLI not found" >&2; exit 1; }
scratch=$(mktemp -d "${TMPDIR:-/tmp}/cycle.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

die() { echo "cycle: $*" >&2; exit 1; }
taken() { echo taken-over; exit 3; }

P='' ROWS='[]' EV='[]' NEEDS='[]'

# --- plan helpers -----------------------------------------------------------------------------
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

ev() { # ev <item|null> <action> <detail>: append to the plan's events and to this cycle's
  local e
  e=$(jq -nc --arg at "$(now)" --arg i "$1" --arg a "$2" --arg d "$3" \
    '{at: $at, item: (if $i == "null" then null else $i end), action: $a, detail: $d}')
  P=$(jq -c --argjson e "$e" '.events = ((.events // []) + [$e])' <<<"$P")
  EV=$(jq -c --argjson e "$e" '. + [$e]' <<<"$EV")
}

once() { # once <item|null> <action> <detail>: ev, unless the same entry is already in the log
  if jq -e --arg i "$1" --arg a "$2" --arg d "$3" '(.events // [])
      | any(.item == (if $i == "null" then null else $i end) and .action == $a and .detail == $d)' <<<"$P" >/dev/null; then
    return 1
  fi
  ev "$@"
}

need() { # need <kind> <item> <detail>
  NEEDS=$(jq -c --arg k "$1" --arg i "$2" --arg d "$3" \
    'if any(.[]; .kind == $k and .item == $i) then . else . + [{kind: $k, item: $i, detail: $d}] end' <<<"$NEEDS")
}

upd() { # upd <item-id> <jq filter on the item> [jq args...]
  local id=$1 filter=$2
  shift 2
  P=$(jq -c --arg _id "$id" "$@" "(.items[] | select(.id == \$_id)) |= ($filter)" <<<"$P")
}

field() { jq -r --arg id "$1" ".items[] | select(.id == \$id) | $2 // empty" <<<"$P"; }
rowfield() { jq -r --arg id "$1" "[.[] | select(.item == \$id)][0] | $2 // empty" <<<"$ROWS"; }

# Write the plan (owner-checked, atomic) before anything that reads it from disk.
flush() {
  [[ -z $dry ]] || return 0
  printf '%s' "$P" >"$scratch/plan.json"
  "$here/plan.sh" write "$scratch/plan.json" >"$scratch/out" 2>&1
  case $? in 0) ;; 3) taken ;; *) die "plan write failed: $(head -n 3 "$scratch/out")" ;; esac
  P=$(jq -c . "$plan")
}
reload() { [[ -n $dry ]] || P=$(jq -c . "$plan"); }

default_base=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)
default_base=${default_base:-main}

target_of() { # the item's integration branch, else the default branch
  local integ
  integ=$(field "$1" .integration)
  if [[ -n $integ ]]; then jq -r --arg i "$integ" '[.integrations[]? | select(.id == $i) | .branch][0] // empty' <<<"$P"
  else echo "$default_base"; fi
}

send() { # send <item-id> <text>: 0 once the worker has it (always, dry-run)
  local ws t
  [[ -z $dry ]] || return 0
  ws=$(field "$1" .workspace); t=$(rowfield "$1" .agent.terminal); [[ -n $t ]] || t=$(field "$1" .terminal)
  [[ -n $ws && -n $t ]] || return 1
  "$cli" terminals send --workspace "$ws" --local --terminal "$t" --text "$2" </dev/null >/dev/null 2>&1
}

started() { [[ $1 == in-progress || $1 == accepting || $1 == in-review || $1 == feedback ]]; }

group_of_state() {
  case $1 in
    in-progress|feedback|accepting) echo "In Progress" ;;
    in-review) echo "In Review" ;;
    done) echo Done ;;
    blocked) echo Blocked ;;
  esac
}

# --- 1. heartbeat -----------------------------------------------------------------------------
if [[ -n $dry ]]; then
  [[ $("$here/plan.sh" check) == mine ]] || taken
else
  "$here/plan.sh" heartbeat >"$scratch/out" 2>&1
  case $? in 0) ;; 3) taken ;; *) die "heartbeat failed: $(head -n 3 "$scratch/out")" ;; esac
fi
[[ -f $plan ]] || die "no plan file $plan"
P=$(jq -c . "$plan") || die "unreadable plan"

# --- 2. status, once --------------------------------------------------------------------------
"$here/status.sh" "$project" "$plan" >"$scratch/rows" 2>"$scratch/err" || die "status.sh failed: $(head -n 3 "$scratch/err")"
ROWS=$(jq -sc . "$scratch/rows") || die "status.sh printed no JSON"

# --- 3. reconcile -----------------------------------------------------------------------------
reconcile() {
  local id row state missing prstate prurl rb rt ra g ws found
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    state=$(field "$id" .state)
    row=$(jq -c --arg id "$id" '[.[] | select(.item == $id)][0] // empty' <<<"$ROWS")
    if [[ $state == in-progress && -z $(field "$id" .workspace) ]]; then
      # Dispatched but never recorded: look the workspace up by branch.
      local branch; branch=$(field "$id" .branch); found=''
      if [[ -n $branch ]] && found=$("$cli" workspaces list --local --project "$project" --search "$branch" --json 2>/dev/null </dev/null |
          jq -r --arg b "$branch" '[.[] | select(.branch == $b) | .id][0] // empty'); [[ -n $found ]]; then
        upd "$id" '.workspace = $w' --arg w "$found"
        ev "$id" reconciled "adopted workspace $found for branch $branch"
      else
        upd "$id" '.state = "queued" | .branch = null | .reason = null'
        ev "$id" reconciled "no workspace for the in-progress item; back to queued"
      fi
      continue
    fi
    [[ -n $row ]] || continue
    started "$state" || [[ $state == blocked ]] || continue
    missing=$(jq -r '.missing // false' <<<"$row")
    prstate=$(jq -r '.pr.state // empty' <<<"$row")
    if [[ $missing == true ]]; then
      started "$state" || continue
      case $prstate in
        MERGED) upd "$id" '.state = "done" | .reason = null'; ev "$id" pr-merged "workspace gone; PR merged" ;;
        CLOSED) upd "$id" '.state = "blocked" | .reason = "PR closed unmerged"'
                ev "$id" blocked "workspace gone; PR closed unmerged"; need closed-pr "$id" "PR closed unmerged, workspace gone" ;;
        OPEN)
          prurl=$(jq -r '.pr.url' <<<"$row")
          if [[ $state == in-review || $state == feedback ]]; then upd "$id" '.pr = $u' --arg u "$prurl"
          else upd "$id" '.pr = $u | .state = "accepting" | .acceptance = "pending"' --arg u "$prurl"
            need accept "$id" "workspace gone; PR $prurl open"; fi
          ev "$id" reconciled "workspace gone; following its open PR" ;;
        *) upd "$id" '.state = "blocked" | .reason = "workspace missing"'
           ev "$id" blocked "workspace missing, no PR"; need blocked "$id" "workspace missing" ;;
      esac
      continue
    fi
    # branch renamed, worker replaced
    rb=$(jq -r '.branch // empty' <<<"$row")
    if [[ -n $rb && $rb != "$(field "$id" .branch)" ]]; then
      upd "$id" '.branch = $b' --arg b "$rb"; ev "$id" reconciled "branch renamed to $rb"
    fi
    rt=$(jq -r '.agent.terminal // empty' <<<"$row")
    if [[ -n $rt && $rt != "$(field "$id" .terminal)" ]]; then
      ra=$(jq -r '.agent.id // empty' <<<"$row")
      upd "$id" '.terminal = $t | (if $a != "" then .agent = $a else . end)' --arg t "$rt" --arg a "$ra"
      ev "$id" reconciled "worker replaced (terminal $rt)"
    fi
    # the user moved it to Blocked or Done
    g=$(jq -r '.group // empty' <<<"$row")
    if [[ $g == Blocked && $state != blocked ]]; then
      upd "$id" '.state = "blocked" | .reason = "moved by user"'; ev "$id" blocked "moved to Blocked by the user"
    elif [[ $g == Done && $state != done ]]; then
      upd "$id" '.state = "done" | .reason = null'; ev "$id" pr-merged "moved to Done by the user"
    fi
  done < <(jq -r '.items[].id' <<<"$P")
  # A tagged workspace the plan lacks: adopt it when its branch matches a workspace-less item.
  while IFS= read -r row; do
    [[ -n $row ]] || continue
    ws=$(jq -r '.id' <<<"$row")
    id=$(jq -r --arg b "$(jq -r .branch <<<"$row")" \
      '[.items[] | select(.workspace == null and .branch == $b and .state != "done" and .state != "skipped") | .id][0] // empty' <<<"$P")
    [[ -n $id ]] || continue
    upd "$id" '.workspace = $w | (if .state == "queued" then .state = "in-progress" else . end)' --arg w "$ws"
    ev "$id" reconciled "adopted tagged workspace $ws"
  done < <(jq -c '.[] | select(.inPlan | not) | select(.item == null)' <<<"$ROWS")
}
reconcile

# --- 4/5. transitions and the acceptance hand-off ---------------------------------------------
criteria_from() { # the DONE block's criteria count out of `checked` ("criteria 4/5; unmet: a; b"), or null
  jq -c '(.checked // "") as $c
    | [$c | match("(?i)(?:criteria:?\\s*(\\d+)\\s*(?:/|of)\\s*(\\d+))|(?:(\\d+)\\s*/\\s*(\\d+)\\s+criteria)").captures[].string
       | select(. != null) | tonumber] as $n
    | if ($n | length) == 2 and $n[0] <= $n[1] then
        {met: $n[0], total: $n[1],
         unmet: (($c | capture("(?i)unmet:\\s*(?<u>.*)$")? | .u // "") | split(";") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)))}
      else null end'
}

to_accepting() { # to_accepting <id> <why>: the DONE block (or an idle worker with a PR) arrived
  local id=$1 checked crit
  checked=$(rowfield "$id" .worker.checked)
  crit=$(jq -c --arg id "$id" '[.[] | select(.item == $id)][0].worker.criteria // empty' <<<"$ROWS")  # status.sh parses the DONE block's
  [[ -n $crit ]] || crit=$(jq -nc --arg c "$checked" '{checked: $c}' | criteria_from)  # else the count quoted in checked:
  upd "$id" '.state = "accepting" | .acceptance = "pending" | .reason = null
    | (if $c != "" then .checked = $c else . end)
    | (if $k != null then .criteria = $k else . end)' --arg c "$checked" --argjson k "$crit"
  once "$id" accepting "$2" || true
}

transition() {
  local id=$1 state row ast areason marker stale prstate prurl prnum it_pr reason
  state=$(field "$id" .state)
  started "$state" || return 0
  row=$(jq -c --arg id "$id" '[.[] | select(.item == $id)][0] // empty' <<<"$ROWS")
  [[ -n $row ]] || return 0
  [[ $(jq -r '.missing // false' <<<"$row") != true ]] || return 0
  ast=$(jq -r '.agent.state // "none"' <<<"$row"); areason=$(jq -r '.agent.reason // empty' <<<"$row")
  marker=$(jq -r '.worker.marker // empty' <<<"$row"); stale=$(jq -r '.worker.stale // false' <<<"$row")
  prstate=$(jq -r '.pr.state // empty' <<<"$row"); prurl=$(jq -r '.pr.url // empty' <<<"$row")
  prnum=$(jq -r '.pr.number // empty' <<<"$row")
  reason=$(field "$id" .reason)

  case $prstate in
    MERGED) upd "$id" '.state = "done" | .reason = null | .pr = (if .pr == null then $u else .pr end)' --arg u "$prurl"
            ev "$id" pr-merged "PR #$prnum merged"; return 0 ;;
    CLOSED) upd "$id" '.state = "blocked" | .reason = "PR closed unmerged"'
            ev "$id" blocked "PR #$prnum closed unmerged"; need closed-pr "$id" "PR #$prnum closed unmerged"; return 0 ;;
  esac

  if [[ $ast == idle && $marker == waiting ]]; then
    if [[ $stale == true ]]; then
      once "$id" stalled "stale wait" || true
      need stale-wait "$id" "waiting on: $(jq -r '.worker.waitingOn // "?"' <<<"$row") (stale $(jq -r '.worker.staleMinutes // "?"' <<<"$row") minutes); check the screen"
    fi
    return 0  # a declared wait is busy: no transition, no follow-up
  fi

  it_pr=$(field "$id" .pr)
  if [[ -z $it_pr && -n $prurl ]]; then
    upd "$id" '.pr = $u' --arg u "$prurl"; ev "$id" pr-opened "PR #$prnum $prurl"
  fi

  case $ast in
    blocked)
      if [[ -n $areason && $state != in-review ]]; then
        upd "$id" '.state = "blocked" | .reason = $r' --arg r "$areason"
        ev "$id" blocked "$areason"; need blocked "$id" "$areason"; return 0
      elif [[ -z $areason ]]; then need question "$id" "the worker is waiting for input"; return 0; fi ;;
    stalled)
      once "$id" stalled "stalled" || true
      need stalled "$id" "$areason"; return 0 ;;
  esac

  case $state in
    in-progress)
      [[ $ast == idle ]] || return 0
      if [[ $marker == blocked ]]; then
        local why; why=$(jq -r '.worker.reason // "worker reported BLOCKED"' <<<"$row")
        upd "$id" '.state = "blocked" | .reason = $r' --arg r "$why"
        ev "$id" blocked "$why"; need blocked "$id" "$why (needs: $(jq -r '.worker.needs // "?"' <<<"$row"))"
      elif [[ $marker == done || -n $prurl || -n $(field "$id" .pr) ]]; then
        to_accepting "$id" "DONE block arrived${prurl:+, PR #$prnum}"
        need accept "$id" "checked: $(rowfield "$id" .worker.checked)"
      elif [[ $reason == "follow-up sent" ]]; then
        upd "$id" '.state = "blocked" | .reason = "no PR after the follow-up"'
        ev "$id" blocked "idle with no PR after one follow-up"; need blocked "$id" "idle with no PR after one follow-up"
      elif send "$id" "Please finish: commit, push and open the PR (gh pr create --base $(target_of "$id")), then print your ORCHESTRATOR_WORKER_DONE block."; then
        upd "$id" '.reason = "follow-up sent"'
        ev "$id" follow-up-sent "idle with no PR: asked it to finish and open the PR"
      fi ;;
    accepting)
      need accept "$id" "checked: $(field "$id" .checked)" ;;
    in-review)
      if [[ $ast == working ]]; then
        upd "$id" '.state = "feedback"'; ev "$id" feedback "worker is working again (user feedback)"
      else rebase_followup "$id" "$row"; fi ;;
    feedback)
      if [[ $ast == working ]]; then
        if [[ $reason == "follow-up sent" || $reason == "acceptance follow-up" ]]; then upd "$id" '.reason = null'; fi
      elif [[ $ast == idle && -z $reason ]]; then
        if [[ -n $(field "$id" .acceptance) && $(field "$id" .acceptance) != ok && $(field "$id" .acceptance) != pending ]]; then
          upd "$id" '.state = "accepting" | .acceptance = "pending"'
          ev "$id" accepting "follow-up round finished; re-compare once"; need accept "$id" "re-compare after the acceptance follow-up"
        else upd "$id" '.state = "in-review"'; ev "$id" in-review "worker idle again"; fi
      fi ;;
  esac
}

rebase_followup() { # a stacked PR whose parent is done now conflicts: the rebase follow-up, once
  local id=$1 row=$2 base parent target
  [[ $(jq -r '.pr.conflicting // false' <<<"$row") == true ]] || return 0
  base=$(jq -r '.pr.base // empty' <<<"$row")
  parent=$(jq -r --arg id "$id" --arg b "$base" '. as $p | [.items[] | select(.id == $id) | .dependsOn[]?
    | . as $d | $p.items[] | select(.id == $d and .state == "done" and .branch == $b) | .id][0] // empty' <<<"$P")
  [[ -n $parent ]] || return 0
  target=$(target_of "$id")
  if jq -e --arg i "$id" '(.events // []) | any(.item == $i and .action == "follow-up-sent" and (.detail | startswith("rebase")))' <<<"$P" >/dev/null; then
    need blocked "$id" "still conflicting after the rebase follow-up (base $base)"; return 0
  fi
  if send "$id" "$parent has merged. Run: git fetch origin && git rebase --onto origin/$target <$parent's tip you noted> HEAD, then git push --force-with-lease, and drop the \"merge $parent first\" line from the PR description."; then
    upd "$id" '.state = "feedback" | .reason = "follow-up sent"'
    ev "$id" follow-up-sent "rebase onto $target after $parent merged"
  fi
}

while IFS= read -r id; do transition "$id"; done < <(jq -r '.items[].id' <<<"$P")

# Follow-ups owed after another item merges.
while IFS=$'\t' read -r id after; do
  [[ -n $id ]] || continue
  state=$(field "$id" .state)
  [[ $(field "$after" .state) == done ]] || continue
  [[ $state == in-review ]] || continue
  msg=$(field "$id" .followUp.message)
  if send "$id" "$msg"; then
    upd "$id" '.state = "feedback" | .reason = "follow-up sent" | .followUp = null'
    ev "$id" follow-up-sent "$after merged: $msg"
  fi
done < <(jq -r '.items[] | select(.followUp != null) | [.id, .followUp.after] | @tsv' <<<"$P")

# Dependency failures and recoveries.
failed() { jq -e --arg d "$1" '.items[] | select(.id == $d and (.state == "blocked" or .state == "skipped"))' <<<"$P" >/dev/null; }
while IFS= read -r id; do
  [[ $(field "$id" .state) == queued ]] || continue
  for d in $(jq -r --arg id "$id" '.items[] | select(.id == $id) | .dependsOn[]?' <<<"$P"); do
    if failed "$d"; then
      r="waiting on $d: $(field "$d" .reason)"
      [[ -n $(field "$d" .reason) ]] || r="waiting on $d: $(field "$d" .state)"
      upd "$id" '.state = "waiting" | .reason = $r' --arg r "$r"
      ev "$id" waiting "$r"; need dependency-failed "$id" "$r"
      break
    fi
  done
done < <(jq -r '.items[].id' <<<"$P")
while IFS= read -r id; do
  [[ $(field "$id" .state) == waiting ]] || continue
  d=$(field "$id" .reason | sed -nE 's/^waiting on ([^:]+):.*/\1/p')
  [[ -n $d ]] || continue
  jq -e --arg d "$d" '.items[] | select(.id == $d)' <<<"$P" >/dev/null || continue
  failed "$d" && continue
  upd "$id" '.state = "queued" | .reason = null'
  ev "$id" queued "$d recovered"
done < <(jq -r '.items[].id' <<<"$P")

# --- 6. merge gate ----------------------------------------------------------------------------
flush
while IFS= read -r f; do
  [[ -n $f ]] || continue
  [[ -z $(jq -r --arg f "$f" '[.integrations[] | select(.id == $f) | .mergeNote][0] // empty' <<<"$P") ]] || continue
  branch=$(jq -r --arg f "$f" '[.integrations[] | select(.id == $f) | .branch][0]' <<<"$P")
  rules=$("$here/merge.sh" rules "$branch" 2>/dev/null </dev/null)
  note=ok
  case $rules in
    *no-merge-commit*|*unknown*) note=human ;;
    *strict*) note=strict ;;
  esac
  P=$(jq -c --arg f "$f" --arg n "$note" '(.integrations[] | select(.id == $f)) |= (.mergeNote = $n)' <<<"$P")
  ev "$f" rules "$branch: $note ($(printf '%s' "$rules" | head -n 1 | cut -c1-120))"
done < <(jq -r '[.items[] | select(.state == "in-review" and .integration != null) | .integration] | unique[]' <<<"$P")
flush

while IFS= read -r id; do
  [[ -n $id ]] || continue
  [[ $(field "$id" .state) == in-review ]] || continue
  if [[ -n $dry ]]; then
    v=$("$here/merge.sh" check "$plan" "$id" 2>/dev/null </dev/null); rc=$?
    [[ $rc == 0 ]] && ev "$id" merged "would merge $(field "$id" .pr) (dry run)"
  else
    v=$("$here/merge.sh" run "$plan" "$id" 2>/dev/null </dev/null); rc=$?
    if [[ $rc == 0 ]]; then
      upd "$id" '.state = "done" | .reason = null'; ev "$id" merged "merged $(field "$id" .pr) into $(target_of "$id")"
    fi
  fi
  if [[ $rc == 3 ]]; then
    gap=${v#followup: }
    if [[ $(field "$id" .acceptance) != "$gap" ]] && send "$id" "Run the project's tests locally (the PR has no checks) and report the result in \`checked:\`; then print your ORCHESTRATOR_WORKER_DONE block again."; then
      upd "$id" '.state = "feedback" | .reason = "acceptance follow-up" | .acceptance = $g' --arg g "$gap"
      ev "$id" acceptance-gap "$gap"; ev "$id" follow-up-sent "asked for a local test run"
    fi
  fi
done < <(jq -r '.items[] | select(.state == "in-review" and .integration != null) | .id' <<<"$P")
flush

# --- 7. integrations --------------------------------------------------------------------------
while IFS= read -r line; do
  [[ -n $line ]] || continue
  verdict=${line%% *}; rest=${line#* }; f=${rest%%:*}
  case $verdict in
    ready)
      if [[ -n $dry ]]; then ev "$f" dispatched "would add $f-integrate (dry run)"
      elif flush; "$here/integrate.sh" add "$plan" "$f" >"$scratch/out" 2>&1 </dev/null; then
        reload; ev "$f" dispatched "queued $f-integrate"
      else
        echo "cycle: integrate add $f: $(head -n 1 "$scratch/out")" >&2
      fi ;;
    held) if once "$f" held "$line"; then need held "$f" "$line"; fi ;;
  esac
done < <("$here/integrate.sh" check "$plan")
# The final PR's URL and merge, as SKILL.md's Finishing an integration says.
P=$(jq -c '. as $p | .integrations = [(.integrations // [])[] | . as $i
  | ([$p.items[] | select(.integrates == $i.id)][0]) as $it
  | if $it == null then $i
    else (if $it.pr != null and $i.pr == null then .pr = $it.pr else . end)
         | (if $it.state == "done" then .state = "merged" else . end) end]' <<<"$P")
flush

# --- 8. dispatch ------------------------------------------------------------------------------
squash_only=$(jq -r '(((.repo | objects | .mergeMethods) // .mergeMethods // []) == ["squash"])' <<<"$P")

next_startable() { # "<id>\t<base>" of the first queued item whose dependencies allow a start, else nothing
  jq -r --argjson squash "$squash_only" --arg tried "$1" '
    . as $p | ($p.maxParallel // 5) as $max
    | ([.items[] | select(.state == "in-progress")] | length) as $running
    | if $running >= $max then empty else
      [.items[] | . as $it
       | select($it.state == "queued" and $it.reason == null and (($tried | split(" ")) | index($it.id) | not))
       | [($it.dependsOn // [])[] | . as $d | ([$p.items[] | select(.id == $d)][0]) as $dep
          | if $dep == null or $dep.state == "done" then "met"
            elif $dep.pr != null and ($dep.state == "in-review" or $dep.state == "accepting" or $dep.state == "in-progress")
                 and ($squash | not) then "stack:\($dep.branch)"
            else "wait" end] as $v
       | select(($v | index("wait") | not) and ([$v[] | select(startswith("stack:"))] | length) <= 1)
       | [$it.id, ([$v[] | select(startswith("stack:")) | sub("^stack:"; "")][0] // "")] | @tsv][0] // empty end' <<<"$P"
}

tried='' fresh=''
while :; do
  pick=$(next_startable "$tried")
  [[ -n $pick ]] || break
  IFS=$'\t' read -r id base <<<"$pick"
  tried="$tried $id"
  if [[ -n $dry ]]; then
    upd "$id" '.state = "in-progress"'; ev "$id" dispatched "would dispatch${base:+ stacked on $base} (dry run)"; continue
  fi
  args=(); [[ -z $base ]] || args=(--base "$base")
  if out=$("$here/dispatch.sh" "$project" "$plan" "$id" ${args[@]+"${args[@]}"} 2>"$scratch/err" </dev/null); then
    reload; ev "$id" dispatched "${out#dispatched }"; fresh="$fresh $id "
  else
    reload; need blocked "$id" "dispatch failed: $(head -n 1 "$scratch/err" | cut -c1-200)"
    [[ $(field "$id" .state) != blocked ]] || ev "$id" blocked "workspace creation failed twice"
  fi
  flush
done

# --- 9. tags, finished ------------------------------------------------------------------------
flush
while IFS=$'\t' read -r id ws state; do
  [[ -n $id && -n $ws ]] || continue
  [[ $fresh != *" $id "* ]] || continue  # dispatch.sh tagged it
  want=$(group_of_state "$state"); [[ -n $want ]] || continue
  have=$(jq -r --arg id "$id" '[.[] | select(.item == $id)][0].group // empty' <<<"$ROWS")
  [[ $have != "$want" ]] || continue
  [[ $(jq -r --arg id "$id" '[.[] | select(.item == $id)][0].missing // false' <<<"$ROWS") != true ]] || continue
  tag=$(jq -r --arg g "$want" '.groups[$g] // $g' <<<"$P")
  if [[ -z $dry ]]; then
    "$cli" workspaces update "$ws" --local --tag "$tag" >/dev/null 2>"$scratch/err" </dev/null ||
      { echo "cycle: tag $id: $(head -n 1 "$scratch/err")" >&2; continue; }
  fi
  ROWS=$(jq -c --arg id "$id" --arg g "$want" 'map(if .item == $id then .group = $g else . end)' <<<"$ROWS")
  ev "$id" tag-moved "${have:-no group} -> $want ($tag)"
done < <(jq -r '.items[] | select(.workspace != null) | [.id, .workspace, .state] | @tsv' <<<"$P")

finished=false
# finished: nothing queued/in-progress/accepting/feedback, and every open integration has its
# <F>-integrate item (a held or not-yet-integrated one keeps the run active).
if jq -e '(.items | length) > 0
    and all(.items[]; .state != "queued" and .state != "in-progress" and .state != "accepting" and .state != "feedback")
    and (. as $p | all((.integrations // [])[] | select((.state // "open") == "open");
          .id as $f | any($p.items[]; .id == ($f + "-integrate"))))' <<<"$P" >/dev/null; then
  finished=true
  review=$(jq '[.items[] | select(.state == "in-review")] | length' <<<"$P")
  blocked=$(jq '[.items[] | select(.state == "blocked")] | length' <<<"$P")
  if jq -e '(.events // []) | any(.action == "finished") | not' <<<"$P" >/dev/null; then
    ev null finished "$review in review, $blocked blocked"
    [[ -n $dry ]] || "$cli" notifications show "Orchestrator finished" --body "$review in review, $blocked blocked" --sound >/dev/null 2>&1 || true
  fi
  if jq -e 'all(.items[]; .state == "done" or .state == "skipped")
      and all((.integrations // [])[]; .state == "merged")' <<<"$P" >/dev/null; then
    P=$(jq -c '.status = "finished"' <<<"$P")
  fi
fi
flush

table=null
if [[ -z $dry ]]; then
  t=$(jq -c '.[]' <<<"$ROWS" | "$here/table.sh" --rows - "$project" "$plan" 2>/dev/null) || t=''
  [[ -z $t || $t == unchanged ]] || table=$(jq -Rsc . <<<"$t")
fi

jq -nc --argjson events "$EV" --argjson needs "$NEEDS" --argjson finished "$finished" --argjson table "$table" \
  --arg dry "$dry" '{events: $events, needs: $needs, finished: $finished, table: $table}
    + (if $dry != "" then {dryRun: true} else {} end)'
[[ $NEEDS == '[]' ]] || exit 10
exit 0
