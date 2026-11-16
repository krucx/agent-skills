#!/usr/bin/env bash
# The merge gate for sub-PRs into an integration branch.
#
# Usage: merge.sh check <plan-file> <ID>   print the verdict, exit by it
#        merge.sh run   <plan-file> <ID>   check, and on `merge` run gh pr merge --merge
#        merge.sh rules <branch>           what the branch's rulesets allow (once per integration)
#
# check verdicts (first word of the line; exit code):
#   merge                      0  the item has a DONE (`checked`), acceptance ok, green checks and a
#                                 mergeable PR whose base is its integration branch
#   wait: <why>                2  checks pending or red, or mergeability unknown or conflicting
#                                 (the worker fixes red checks and conflicts)
#   followup: <gap>            3  no PR checks and `checked` shows no passing local test run: one
#                                 follow-up, like an acceptance gap
# A local integration (`local: true`) has no sub-PRs: check wants in-review, a DONE, acceptance ok
# and a passing local test run in `checked`; run then merges the worker's branch into the local
# integration branch with a merge commit (a conflict is `wait`, like a conflicting PR).
#   no: <why>                  4  never merged here: base is not the item's integration branch (so
#                                 never the default branch), PR not open, no DONE, acceptance gap
# rules prints `ok`, and/or `no-merge-commit: <why>` (merge commits forbidden: human merges for this
# integration), `unknown: <why>` (rules unreadable) and `strict: <why>` (branches must be up to date: suggest turning it off for feature/*).
set -euo pipefail

retry() {
  local i out
  for i in 1 2 3; do
    out=$("$@") && { printf '%s\n' "$out"; return; }
    ((i < 3)) && sleep $((i * ${RETRY_DELAY:-5}))
  done
  return 1
}

local_run_passed() { # local_run_passed <item-json>: `checked` names a passing local test run
  jq -e '.checked | test("local:[^;]*\\b(pass(ed|es)?|green|ok)\\b"; "i")
    and (test("local:[^;]*(\\b(fail\\w*|red|errors?)\\b|not (pass|ok)|n.t pass)"; "i") | not)' <<<"$1" >/dev/null
}

is_local() { # is_local <plan> <ID>: the item's integration is a local branch
  [[ $(jq -r --arg id "$2" '(.items[] | select(.id == $id) | .integration) as $i
    | [.integrations[]? | select(.id == $i) | .local // false][0] // false' "$1") == true ]]
}

local_merge() { # local_merge <plan> <ID>: the worker's branch into the local integration branch, in a temporary worktree
  local plan=$1 id=$2 wb ib wt
  wb=$(jq -r --arg id "$id" '.items[] | select(.id == $id) | .branch' "$plan")
  ib=$(jq -r --arg id "$id" '(.items[] | select(.id == $id) | .integration) as $i | [.integrations[] | select(.id == $i) | .branch][0]' "$plan")
  wt=$(mktemp -d "${TMPDIR:-/tmp}/merge.XXXXXX"); rmdir "$wt"
  git worktree add -q "$wt" "$ib" >/dev/null 2>&1 || { echo "wait: cannot check out $ib for the merge (checked out elsewhere?)"; return 2; }
  if git -C "$wt" merge -q --no-ff --no-edit "$wb" >/dev/null 2>&1; then
    git worktree remove --force "$wt" >/dev/null 2>&1 || true
    echo "merged $wb into $ib"
  else
    git -C "$wt" merge --abort >/dev/null 2>&1 || true
    git worktree remove --force "$wt" >/dev/null 2>&1 || true
    echo "wait: $wb conflicts with $ib"; return 2
  fi
}

check() {
  local plan=$1 id=$2 item integ branch n pr wb
  item=$(jq -c --arg id "$id" '.items[] | select(.id == $id)' "$plan")
  [[ -n $item ]] || { echo "no: $id is not in the plan"; return 4; }
  integ=$(jq -r '.integration // empty' <<<"$item")
  branch=$(jq -r --arg i "$integ" '[.integrations[]? | select(.id == $i) | .branch][0] // empty' "$plan")
  [[ -n $branch ]] || { echo "no: $id targets the default branch; humans merge those"; return 4; }
  [[ $(jq -r --arg i "$integ" '[.integrations[] | select(.id == $i) | .mergeNote][0] // empty' "$plan") != human ]] ||
    { echo "no: $integ's rulesets forbid merge commits; humans merge its PRs"; return 4; }
  [[ $(jq -r .state <<<"$item") == in-review ]] || { echo "no: $id is not in-review"; return 4; }
  if is_local "$plan" "$id"; then
    wb=$(jq -r '.branch // empty' <<<"$item")
    [[ -n $wb ]] || { echo "no: $id has no branch"; return 4; }
    [[ -n $(jq -r '.checked // empty' <<<"$item") ]] || { echo "no: no DONE block from $id's worker"; return 4; }
    [[ $(jq -r '.acceptance // empty' <<<"$item") == ok ]] || { echo "no: acceptance is not ok"; return 4; }
    git show-ref --verify --quiet "refs/heads/$wb" || { echo "wait: branch $wb is not in this clone"; return 2; }
    if local_run_passed "$item"; then echo merge; return 0; fi
    echo "followup: $id's checked: shows no passing local test run ($branch is local; there are no PR checks)"
    return 3
  fi
  n=$(jq -r '.pr // empty' <<<"$item"); n=${n##*/}
  [[ -n $n ]] || { echo "no: $id has no PR"; return 4; }
  [[ -n $(jq -r '.checked // empty' <<<"$item") ]] || { echo "no: no DONE block from $id's worker"; return 4; }
  [[ $(jq -r '.acceptance // empty' <<<"$item") == ok ]] || { echo "no: acceptance is not ok"; return 4; }
  pr=$(retry gh pr view "$n" --json state,baseRefName,mergeable,mergeStateStatus,statusCheckRollup) ||
    { echo "wait: cannot read PR #$n"; return 2; }
  [[ $(jq -r .state <<<"$pr") == OPEN ]] || { echo "no: PR #$n is not open"; return 4; }
  [[ $(jq -r .baseRefName <<<"$pr") == "$branch" ]] ||
    { echo "no: PR #$n targets $(jq -r .baseRefName <<<"$pr"), not $branch"; return 4; }
  case $(jq -r .mergeable <<<"$pr") in
    MERGEABLE) ;;
    CONFLICTING) echo "wait: PR #$n conflicts with $branch"; return 2 ;;
    *) echo "wait: PR #$n mergeability unknown"; return 2 ;;
  esac
  case $(jq -r .mergeStateStatus <<<"$pr") in
    DIRTY|BLOCKED) echo "wait: PR #$n is $(jq -r .mergeStateStatus <<<"$pr") (reviews or rules)"; return 2 ;;
  esac
  if [[ $(jq '.statusCheckRollup | length' <<<"$pr") == 0 ]]; then
    # No PR checks: only a worker-reported passing local test run counts.
    if jq -e '.checked | test("no PR checks"; "i")' <<<"$item" >/dev/null && local_run_passed "$item"; then
      echo merge
    else
      echo "followup: PR #$n has no checks and checked: shows no passing local test run"
      return 3
    fi
    return 0
  fi
  jq -r '[.statusCheckRollup[] | (.conclusion // .state // "") | ascii_upcase] as $c
    | if any($c[]; . == "" or . == "PENDING" or . == "IN_PROGRESS" or . == "QUEUED" or . == "EXPECTED") then "wait: checks still running"
      elif all($c[]; . == "SUCCESS" or . == "NEUTRAL" or . == "SKIPPED") then "merge"
      else "wait: checks red: \([.statusCheckRollup[] | select((.conclusion // .state) | ascii_upcase | IN("SUCCESS","NEUTRAL","SKIPPED") | not) | .name] | join(", "))" end' <<<"$pr" |
    { read -r v; echo "$v"; [[ $v == merge ]]; } || return 2
}

rules() {
  local branch=$1 repo rs clean=1
  repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)
  rs=$(retry gh api "repos/$repo/rules/branches/$branch") || { echo "unknown: cannot read rulesets for $branch"; return 1; }
  if jq -e 'any(.[]; .type == "required_linear_history"
      or (.type == "pull_request" and (.parameters.allowed_merge_methods // ["merge"] | index("merge") | not)))' <<<"$rs" >/dev/null; then
    echo "no-merge-commit: $branch's rules forbid merge commits"; clean=''
  fi
  if jq -e 'any(.[]; .type == "required_status_checks" and .parameters.strict_required_status_checks_policy == true)' <<<"$rs" >/dev/null; then
    echo "strict: $branch requires branches to be up to date before merging"; clean=''
  fi
  [[ -z $clean ]] || echo ok
}

cmd=${1:-}
case $cmd in
  check) check "$2" "$3" ;;
  run)
    rc=0; v=$(check "$2" "$3") || rc=$?
    echo "$v"
    ((rc == 0)) || exit "$rc"
    if is_local "$2" "$3"; then local_merge "$2" "$3"; exit $?; fi
    n=$(jq -r --arg id "$3" '.items[] | select(.id == $id) | .pr' "$2"); n=${n##*/}
    gh pr merge "$n" --merge || { echo "wait: gh pr merge failed"; exit 2; } ;;
  rules) rules "$2" ;;
  *) echo "usage: merge.sh check|run <plan-file> <ID> | rules <branch>" >&2; exit 64 ;;
esac
