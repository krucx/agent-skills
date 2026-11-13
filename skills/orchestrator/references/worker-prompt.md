# Worker prompt

What `dispatch.sh` sends; change it in the script.

| Worker agent | First line |
| --- | --- |
| Claude, Hermes | `/<skill> <ID>` |
| Codex | `$<skill> <ID>` |
| Gemini, others | `Use the <skill> skill to do <ID>.` |

After the first line the prompt carries, in this order (exact wording lives in `dispatch.sh`):

- a free-text task's full `text` (tracker items have none);
- one of several agents in parallel worktrees, the others being <other IDs>;
- free text only: `<ID>` is a plan label, not a tracker ticket;
- stay within `<ID>`, no drive-by changes; put `<branch>` in Docker Compose project names,
  container names, scratch or data directories and temp files, and bind no fixed host ports;
- stacked only: the branch starts from `<branch>` (PR #<m>, unmerged); say "Stacked on #<m>; merge
  that first" in the PR description; note the parent tip before the first commit; after #<m>
  merges, `git fetch origin && git rebase --onto origin/main <that tip> HEAD`, `git push
  --force-with-lease`, and delete the "merge that first" line (a squash-merge leaves the parent's
  commits on the branch, so the PR conflicts until then);
- the goal is an open PR: push and `gh pr create` even if the skill stops at a commit; ask a
  human decision plainly and stop;
- the same obstacle a second time (the same failing command, the same check it can't fix, or the
  same missing access) means stop, not retry: print `ORCHESTRATOR_WORKER_BLOCKED` with `reason:`
  naming the obstacle and `needs:` what would clear it;
- done means the PR's checks have finished and it is mergeable: `gh pr checks <n> --watch
  --fail-fast` (read the exit code and failed check names only), tail `gh run view <run-id>
  --log-failed` for a failure (never green logs), fix, push, watch again; then confirm
  `gh pr view <n> --json mergeable,mergeStateStatus,statusCheckRollup`, merging or rebasing the
  base on a conflict; a check that can't be fixed goes in `checked:` by name;
- the last message ends with exactly one of:

```text
ORCHESTRATOR_WORKER_DONE
item: <ID>
pr: <url>
summary: <one line>
checked: <what you verified against the task, and the PR's checks in a few words ("5/5
  green"); name only the checks that were red or skipped>
```

```text
ORCHESTRATOR_WORKER_BLOCKED
item: <ID>
reason: <what stops you>
needs: <the decision or access required>
```
