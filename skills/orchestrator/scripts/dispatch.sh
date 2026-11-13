#!/usr/bin/env bash
# Dispatch one plan item: pick a free branch, mark the item in-progress in the plan, create the
# workspace with the worker prompt, and record workspace, terminal and branch.
#
# Usage (inside the repo): dispatch.sh <project-id> <plan-file> <item-id> [--base <branch>] [--preset <id>]
#   --base    start branch (default: the repo's default); any other base makes the item stacked
#   --preset  agent instance or preset id to start (default: the item's "agent")
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
default_base=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)
default_base=${default_base:-main}
stacked=''
[[ -z $base || $base == "$default_base" ]] || stacked=1
base=${base:-$default_base}

# --- 1. branch ------------------------------------------------------------------------------
lower=$(printf '%s' "$id" | tr 'A-Z' 'a-z')
if [[ -n $task || $lower == t[0-9]* ]]; then prefix="task-$run-$lower"
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
  claude|hermes) first="/$skill $id" ;;
  codex) first="\$$skill $id" ;;
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
  printf '%s\n' "- Stay within $id; no drive-by changes elsewhere (other branches are editing this code too)." \
    "- Keep shared machine resources apart: put $branch in Docker Compose project names, container" \
    "  names, scratch or data directories and temp files; bind no fixed host ports."
  if [[ -n $stacked ]]; then
    m=$(gh pr list --head "$base" --state all --json number --jq '.[0].number // empty' 2>/dev/null || true)
    printf '%s\n' "- Stacked: this branch starts from $base (PR #${m:-?}, unmerged). Put \"Stacked on #${m:-?}; merge" \
      "  that first\" in the PR description. Note the parent tip now (\`git rev-parse HEAD\`, before your" \
      "  first commit). When #${m:-?} merges: \`git fetch origin && git rebase --onto origin/main <that tip>" \
      "  HEAD\`, \`git push --force-with-lease\`, and delete the \"merge that first\" line (a squash-merge" \
      "  leaves the parent's commits on your branch, so the PR conflicts until then)."
  fi
  printf '%s\n' "- Your goal is an open PR: once committed, push and \`gh pr create\` yourself, even if your skill" \
    "  stops at a commit. Need a human decision? Ask it plainly and stop." \
    "- If you hit the same obstacle a second time (same failing command or missing access), don't" \
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
    "  and finish with a block below; it replaces the wait." \
    "- Done means the PR's checks finished and it's mergeable, not just open. Before" \
    "  ORCHESTRATOR_WORKER_DONE: \`gh pr checks <n> --watch --fail-fast\`, reading only its exit code" \
    "  and failed check names; for a failure tail \`gh run view <run-id> --log-failed\` (never green" \
    "  checks' logs), fix what your change caused, push, watch again. Then confirm no conflict:" \
    "  \`gh pr view <n> --json mergeable,mergeStateStatus,statusCheckRollup --jq '{mergeable," \
    "  mergeStateStatus, failing: [.statusCheckRollup[] | select(.conclusion==\"FAILURE\") | .name]}'\`;" \
    "  on a conflict merge or rebase the base and push. A check you cannot fix goes in \`checked:\`" \
    "  by name." \
    "- Finish your last message with exactly one of these, the marker on a line of its own:" \
    "  ORCHESTRATOR_WORKER_DONE" "  item: $id" "  pr: <url>" "  summary: <one line>" \
    "  checked: <what you verified against the task, and the PR's checks in a few words (\"5/5" \
    "    green\"); name only the checks that were red or skipped>" "  or" \
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
