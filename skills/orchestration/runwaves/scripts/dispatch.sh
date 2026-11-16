#!/usr/bin/env bash
# Dispatch one plan item: pick a free branch, mark the item in-progress in the plan, create the
# workspace with the worker prompt, and record workspace, terminal and branch.
#
# Usage (inside the repo): dispatch.sh <project-id> <plan-file> <item-id> [--base <branch>] [--preset <id>]
#   --base    start branch (default: the item's target); any other base makes the item stacked
#
# The target is the item's integration branch (plan "integrations", item "integration"), else the
# repo's default branch. A missing integration branch is created on the remote from its base.
# An <F>-integrate item (integrate.sh; "integrates": "<F>") starts on the integration branch and
# targets the default branch: its worker merges the default branch in and opens the feature PR.
# A local chain branch (`parent` on a local integration) is cut here from its parent's branch,
# which is created on the remote first when missing; its <F>-integrate item targets the parent's
# branch, and its PR is one the merge gate merges, not the user.
#   --preset  agent instance or preset id to start (default: the item's "agent")
# A local integration (`local: true` on the integration) lives in this clone only: the branch is
# created here from its base and never pushed, there are no sub-PRs and no CI per item; the worker
# runs the tests before each commit, and the <F>-integrate worker pushes the branch for the final PR.
#
# Steps: SKILL.md's Dispatch. The first failing step stops the run; nothing is written before
# the plan write. Prints one summary line, or "dispatch <id> failed at <step>: <reason>", exit 1.
# Works with bash 3.2 (no associative arrays) and zsh.
set -euo pipefail

(($# >= 3)) || { sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
project=$1 plan=$2 id=$3
shift 3
base='' preset=''
while (($#)); do
  case $1 in
    --base) base=${2:?--base needs a branch}; shift 2 ;;
    --preset) preset=${2:?--preset needs an id}; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
# superset, paradev and pdev are the same Paradev CLI; use whichever is installed.
cli=$(command -v superset || command -v paradev || command -v pdev) ||
  { echo "dispatch $id failed at preflight: Paradev CLI not found" >&2; exit 1; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/dispatch.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

fail() { echo "dispatch $id failed at $1: $(printf '%s' "$2" | head -n 1 | cut -c1-200)" >&2; exit 1; }
item() { jq -r --arg id "$id" ".items[] | select(.id == \$id) | $1" "$plan"; }

# --- the item -------------------------------------------------------------------------------
[[ -f $plan ]] || fail preflight "no plan file $plan"
[[ -n $(item .id) ]] || fail preflight "no item $id in the plan"
state=$(item .state)
[[ $state == queued ]] || fail preflight "item is $state, not queued"
title=$(item '.title // ""')
text=$(item '.text // ""')  # an older plan's single free-text description
ask=$(item '.ask // ""')    # a free-text task's slice of the user's request, verbatim
notes=$(item '.notes // ""')
task=''  # where a free-text task's prompt finds the task; empty for tracker items
if [[ -n $ask ]]; then task="the user's words above; build nothing beyond them"
elif [[ -n $text ]]; then task='the text above'; fi
skill=$(item '.skill // "implement"')
agent=$(item '.agent // "claude"')
run=$(jq -r '.runId' "$plan")
[[ -n $preset ]] || preset=$agent
default_base=$(default_branch)
# The target: where the item's PR goes. Only a local chain branch nests: its base is its parent's
# branch, on origin; any other integration's base is the default branch.
ilocal=false iparent='' integrated_parent='' integ=$(item '.integration // ""')
target=$(plan_jq '. as $p | [.items[] | select(.id == $id)][0] | target($p.integrations; $base) // empty' \
  "$plan" -r --arg id "$id" --arg base "$default_base")
if [[ -n $integ ]]; then
  [[ -n $target ]] || fail preflight "item $id names integration $integ, not in the plan"
  ibase=$(jq -r --arg i "$integ" '[.integrations[] | select(.id == $i) | .base][0] // empty' "$plan")
  ibase=${ibase:-$default_base}
  ilocal=$(jq -r --arg i "$integ" '[.integrations[] | select(.id == $i) | .local // false][0]' "$plan")
  iparent=$(jq -r --arg i "$integ" '[.integrations[] | select(.id == $i) | .parent // empty][0] // empty' "$plan")
fi
target_local=$ilocal  # an <F>-integrate item's ilocal becomes the integrated branch's below
integrates=$(item '.integrates // ""')
if [[ -n $integrates ]]; then
  ibranch=$(jq -r --arg i "$integrates" '[.integrations[]? | select(.id == $i) | .branch][0] // empty' "$plan")
  [[ -n $ibranch ]] || fail preflight "item $id integrates $integrates, not in the plan"
  ilocal=$(jq -r --arg i "$integrates" '[.integrations[] | select(.id == $i) | .local // false][0]' "$plan")
  integrated_parent=$(jq -r --arg i "$integrates" '[.integrations[] | select(.id == $i) | .parent // empty][0] // empty' "$plan")
  base=${base:-$ibranch}
  task='the integration job below'
fi
base=${base:-$target}
stacked=''
[[ $base == "$target" || -n $integrates ]] || stacked=1

# --- 0. integration branch ------------------------------------------------------------------
on_origin() { # on_origin <branch> <base>: create the branch on origin from its base when missing
  local out
  out=$(git ls-remote --heads origin "$1") || fail integration "git ls-remote failed"
  if [[ -z $out ]]; then
    git fetch -q origin "$2" >"$tmp/err" 2>&1 && git push -q origin "FETCH_HEAD:refs/heads/$1" >>"$tmp/err" 2>&1 ||
      fail integration "cannot create $1 from $2: $(cat "$tmp/err")"
  fi
}
if [[ $target != "$default_base" ]]; then
  if [[ $target_local == true ]]; then
    # local: in this clone from its base, never on origin; a chain's base is its parent's branch
    [[ -z $iparent ]] || on_origin "$ibase" "$(jq -r --arg i "$iparent" '[.integrations[] | select(.id == $i) | .base][0] // empty' "$plan")"
    if ! git show-ref --verify --quiet "refs/heads/$target"; then
      git fetch -q origin "$ibase" >"$tmp/err" 2>&1 && git branch -q "$target" FETCH_HEAD >>"$tmp/err" 2>&1 ||
        fail integration "cannot create local $target from $ibase: $(cat "$tmp/err")"
    fi
  else
    on_origin "$target" "$ibase"
  fi
fi

# --- 1. branch ------------------------------------------------------------------------------
lower=$(printf '%s' "$id" | tr 'A-Z' 'a-z')
if [[ (-n $task && -z $integrates) || $lower == t[0-9]* ]]; then prefix="task-$run-$lower"
elif [[ $lower == \#* ]]; then prefix="issue-${lower#\#}"
else prefix=$lower; fi
slug=$(printf '%s' "$title" | tr 'A-Z' 'a-z' | LC_ALL=C sed 's/[^a-z0-9]\{1,\}/ /g' |
  awk '{ for (i = 1; i <= 4 && i <= NF; i++) printf "%s%s", (i > 1 ? "-" : ""), $i }')
root=${prefix}${slug:+-$slug}

taken() { # taken <branch>: 0 when the branch is in use anywhere we can see
  local b=$1 out n
  out=$(git ls-remote --heads origin "$b") || fail branch "git ls-remote failed"
  [[ -z $out ]] || return 0
  ! git show-ref --verify --quiet "refs/heads/$b" || return 0
  [[ $(jq -r --arg b "$b" --arg id "$id" '[.items[] | select(.branch == $b and .id != $id)] | length' "$plan") == 0 ]] || return 0
  n=$(gh pr list --head "$b" --state all --json number --jq length) || fail branch "gh pr list failed"
  [[ $n != 0 ]]
}

branch='' n=1
while :; do
  suffix=''; ((n == 1)) || suffix="-$n"
  cand=$(printf '%s' "${root:0:$((60 - ${#suffix}))}" | sed 's/-*$//')$suffix
  if ! taken "$cand"; then branch=$cand; break; fi
  n=$((n + 1))
  ((n < 50)) || fail branch "no free branch name for $root"
done

# --- 2. plan --------------------------------------------------------------------------------
# edit <jq-filter> [jq args...]: rewrite the item through plan.sh write (locked, owner-checked)
edit() {
  local filter=$1; shift
  jq --arg id "$id" "$@" "(.items[] | select(.id == \$id)) |= ($filter)" "$plan" >"$tmp/plan.json" &&
    "$here/plan.sh" write "$tmp/plan.json"
}
edit '.state = "in-progress" | .branch = $branch | .reason = null' --arg branch "$branch" >"$tmp/err" 2>&1 ||
  fail plan "$(cat "$tmp/err")"

# --- 3. workspace ---------------------------------------------------------------------------
tag=$(jq -r '.groups["In Progress"] // empty' "$plan")
[[ -n $tag ]] || tag=$("$here/groups.sh" "$project" plan "$plan" 2>/dev/null | jq -r '.["In Progress"] // empty' || true)
tag=${tag:-In Progress}

case $agent in
  claude|hermes|agy|antigravity) first="/$skill $id" ;;
  codex) first="\$$skill $id" ;;
  opencode) first="Use the $skill skill to do $id." ;;  # no skill slash command; verified in cli-surface.md
  *) first="Use the $skill skill to do $id." ;;
esac
others=$(jq -r --arg id "$id" '[.items[] | select(.id != $id) | .id] | join(", ")' "$plan")
{
  printf '%s\n\n' "$first"
  if [[ -n $ask ]]; then
    printf '%s\n%s\n\n' \
      "The user's words (verbatim; this is the task and the whole of its scope):" "$ask"
    [[ -z $notes ]] || printf '%s\n%s\n\n' \
      "Orchestrator's notes (context and what stays out of scope; they add no work):" "$notes"
  else
    [[ -z $text ]] || printf '%s\n\n' "$text"
  fi
  printf '%s\n' "You're one of several agents, each in its own worktree of this repo, coordinated by an" \
    "orchestrator; the others work on ${others:-no other items}."
  [[ -z $task ]] || printf '%s\n' "- $id is a label in this run's plan only, not a tracker ticket; don't fetch it. The task" \
    "  is $task."
  if [[ -n $integrates ]]; then
    epic=$(jq -r --arg i "$integrates" '[.integrations[]? | select(.id == $i) | .epic.url // empty][0] // empty' "$plan")
    prs=$(jq -r --arg i "$integrates" '.items[] | select(.integration == $i) | "  - \(.id) \(.title)\(if .pr then ": " + .pr else "" end)\(if .state == "skipped" then " (dropped, not included)" else "" end)"' "$plan")
    if [[ $ilocal == true ]]; then subs="its tasks' branches are already merged into it in this clone (a local integration: no sub-PRs)"
    else subs="its sub-PRs are already merged into it"; fi
    printf '%s\n' "Integration job: land the feature branch $ibranch on $target with ONE PR; $subs. They are:" "$prs" \
      "- Your branch starts at $ibranch. Merge origin/$target into it (\`git fetch origin && git merge origin/$target\`)," \
      "  resolve conflicts, run the project's tests locally, then \`git push origin HEAD:$ibranch\`." \
      "- Open $ibranch -> $target (\`gh pr create --base $target --head $ibranch\`), its description listing every" \
      "  item above (with its PR where there is one) and linking the epic or issues they close (\`Closes #n\`)${epic:+, and the epic $epic}. Then run the full CI" \
      "  (the PR's checks; none: the local run counts). Push to $ibranch only for the merge and fixes." \
      "- $target is synced only here: don't merge it into $ibranch at any other time."
    if [[ -n $integrated_parent ]]; then
      printf '%s\n' "  Do not merge the PR yourself: the orchestrator merges it into $target once its checks pass." ""
    else printf '%s\n' "  Do not merge the final PR; the user reviews and merges it." ""; fi
  fi
  printf '%s\n' "- Stay within $id; no drive-by changes elsewhere (other branches are editing this code too)." \
    "- Keep shared machine resources apart: put $branch in Docker Compose project names, container" \
    "  names, scratch or data directories and temp files; bind no fixed host ports."
  if [[ -n $stacked ]]; then
    m=$(gh pr list --head "$base" --state all --json number --jq '.[0].number // empty' 2>/dev/null || true)
    printf '%s\n' "- Stacked: this branch starts from $base (PR #${m:-?}, unmerged). Put \"Stacked on #${m:-?}; merge" \
      "  that first\" in the PR description. Note the parent tip now (\`git rev-parse HEAD\`, before your" \
      "  first commit). When #${m:-?} merges: \`git fetch origin && git rebase --onto origin/$target <that tip>" \
      "  HEAD\`, \`git push --force-with-lease\`, and delete the \"merge that first\" line (a squash-merge" \
      "  leaves the parent's commits on your branch, so the PR conflicts until then)."
  fi
  if [[ $ilocal == true && -z $integrates ]]; then
    printf '%s\n' "- $target is a local integration branch (no sub-PRs, no CI per task): open no PR and push nothing." \
      "  Commit on $branch and leave it there; the orchestrator merges it into $target on this machine, and" \
      "  CI runs once on the final $target PR. Need a human decision? Ask it plainly and stop."
  else
    printf '%s\n' "- Your goal is an open PR: once committed, push and \`gh pr create --base $target\` yourself, even if your skill" \
      "  stops at a commit. Need a human decision? Ask it plainly and stop."
  fi
  printf '%s\n' "- If you hit the same obstacle a second time (same failing command or missing access), don't" \
    "  retry: print ORCHESTRATOR_WORKER_BLOCKED, \`reason:\` the obstacle, \`needs:\` what would clear" \
    "  it, and stop. Once the PR is open, a PR check you cannot fix is not an obstacle: it goes in" \
    "  \`checked:\`." \
    "- Before ending a turn with your own background work running (e.g. code-review subagents), or" \
    "  while waiting on something external that finishes by itself, print this once per wait (not" \
    "  per check, never while actively implementing), the marker on a line of its own:" \
    "  ORCHESTRATOR_WORKER_WAITING" "  item: $id" "  waiting-on: <what you are waiting for>" \
    "  resumes-when: <what ends the wait>" \
    "  Waiting is not blocked: a wait clears on its own, a block needs the orchestrator or a human." \
    "  If what you wait on fails or stops, that's an obstacle as above. When the wait ends, carry on" \
    "  and finish with a block below; it replaces the wait."
  if [[ $ilocal == true && -z $integrates ]]; then
    printf '%s\n' "- Before every commit run the test suites that cover what you changed, and the project's full test" \
      "  command before your last commit; a red test is yours to fix before committing." \
      "- Done means the branch is committed and the full test command passed. In the DONE block put" \
      "  \`pr: none (local integration)\` and in \`checked:\` the exact test command and its result, e.g." \
      "  \"local: npm test passed\"; the orchestrator merges your branch into $target only on that."
  else
    printf '%s\n' "- Done means every PR check passed and the PR is mergeable, not just open: never print" \
      "  ORCHESTRATOR_WORKER_DONE while a check is pending or red. Check cheaply: \`gh pr checks <n>" \
      "  --watch --fail-fast >/dev/null 2>&1; echo exit=\$?\` (0 = all passed; the table itself is noise), and" \
      "  only on a non-zero exit \`gh pr checks <n> --json name,state,bucket --jq '.[] | select(.bucket != \"pass\"" \
      "  and .bucket != \"skipping\") | \"\\(.name): \\(.state)\"'\` for the failed names; then tail" \
      "  \`gh run view <run-id> --log-failed\` (never green checks' logs), fix what your change caused," \
      "  push, watch again. Then confirm no conflict:" \
      "  \`gh pr view <n> --json mergeable,mergeStateStatus,statusCheckRollup --jq '{mergeable," \
      "  mergeStateStatus, failing: [.statusCheckRollup[] | select(.conclusion==\"FAILURE\") | .name]}'\`;" \
      "  on a conflict merge or rebase the base and push. A check you cannot fix goes in \`checked:\`" \
      "  by name. If the PR has no checks at all (common on PRs into a feature branch), run the" \
      "  project's test command locally and report it in \`checked:\`, e.g. \"no PR checks; local: npm" \
      "  test passed\"; the orchestrator merges a PR into an integration branch only on that."
  fi
  printf '%s\n' "- criteria: the issue's acceptance checklist (for free text, the ask, one criterion per sentence you can" \
    "  check). Report <met>/<total>; when met < total add one indented \`unmet:\` line per criterion not" \
    "  met or not verifiable. No checklist: report n/n over the criteria you derived and list them in" \
    "  \`checked:\`. Omit the \`unmet:\` lines when all are met." \
    "- Finish your last message with exactly one of these, the marker on a line of its own:" \
    "  ORCHESTRATOR_WORKER_DONE" "  item: $id" "  pr: <url>" "  summary: <one line>" \
    "  checked: <what you verified against the task, and the PR's checks in a few words (\"5/5" \
    "    green\"); name only the checks that were red or skipped>" \
    "  criteria: <met>/<total>" \
    "  unmet: <a criterion not met or not verifiable, quoted, and why in a few words>" "  or" \
    "  ORCHESTRATOR_WORKER_BLOCKED" "  item: $id" "  reason: <what stops you>" \
    "  needs: <the decision or access required>"
} >"$tmp/prompt"

if ! "$cli" workspaces create --local --project "$project" --name "$id $(printf '%s' "$title" | cut -c1-50)" \
  --branch "$branch" --skip-branch-prefix --base-branch "$base" --tag "$tag" \
  --agent "$preset" --prompt "$(cat "$tmp/prompt")" --json >"$tmp/created" 2>"$tmp/err"; then
  reason=$(head -n 1 "$tmp/err" | cut -c1-200)
  [[ -n $reason ]] || reason=$(head -n 1 "$tmp/created" | cut -c1-200)
  edit '.dispatchFailures = ((.dispatchFailures // 0) + 1)
        | if .dispatchFailures >= 2 then .state = "blocked" | .reason = $reason
          else .state = "queued" | .branch = null | .reason = null end' \
    --arg reason "workspace creation failed: ${reason:-unknown error}" >/dev/null 2>"$tmp/err" ||
    fail rollback "item $id is still in-progress in the plan: $(cat "$tmp/err")"
  fail workspace "${reason:-unknown error} ($(item .state))"
fi

# --- 4. record ------------------------------------------------------------------------------
ws=$(jq -r '(.workspace // .) | .id // empty' "$tmp/created")
got=$(jq -r '(.workspace // .) | .branch // empty' "$tmp/created")
term=$(jq -r '[(.agents // [])[] | .sessionId // empty] | first // empty' "$tmp/created")
[[ -n $ws ]] || fail record "workspace id missing from create's output; reconcile will find it"
if [[ -z $term ]]; then
  term=$("$cli" snapshot --json | jq -r --arg w "$ws" \
    '[.workspaces[] | select(.id == $w) | .terminals[] | select(.agent != null) | .id] | first // empty') || term=''
fi
edit '.workspace = $ws | .terminal = (if $t == "" then null else $t end) | .branch = (if $b == "" then .branch else $b end)' \
  --arg ws "$ws" --arg t "$term" --arg b "$got" >/dev/null 2>"$tmp/err" ||
  fail record "workspace $ws was created but not recorded: $(cat "$tmp/err")"
echo "dispatched $id -> ${got:-$branch} (workspace $ws, terminal ${term:-none})"
