# Worker prompt

Built and sent by `dispatch.sh` (exact wording there).

**On Orca** only the task and its end state (Orca's preamble covers `worker_done`, `ask`,
escalation): the skill line; free-text `ask` and `notes` as below; the other items and "stay within
<ID>"; an `<F>-integrate` job, stacked base or local integration branch in a line or two each; else a
PR into the target with passing checks (none: `no PR checks; local: <command> passed`); "in your
report, say what you verified". The report becomes `checked` (a failed dispatch's: the block reason).

**On Paradev** (loop), first line (every backend leads with the skill): Claude, Hermes `/<skill>
<ID>`; Codex `$<skill> <ID>`; others `Use the <skill> skill to do <ID>.` Then, in order:

- free text: the `ask`, labelled the user's verbatim words and whole scope, then `notes`, labelled
  context adding no work (older plan: `text`, unlabelled); tracker items neither; `extras` never;
- one of several agents in parallel worktrees; the others' IDs;
- free text only: `<ID>` is a plan label, not a ticket; with an `ask`, build nothing beyond it;
- stay within `<ID>`, no drive-by changes; `<branch>` in Docker Compose project and container
  names, scratch/data dirs and temp files; no fixed host ports;
- stacked only: starts from `<branch>` (PR #<m>, unmerged); "Stacked on #<m>; merge that first" in
  the PR description; note the parent tip before the first commit; after #<m> merges, `git fetch
  origin && git rebase --onto origin/<target> <that tip> HEAD`, `git push --force-with-lease`,
  delete the "merge that first" line (squash-merge leaves the parent's commits: conflicts till then);
- `<F>-integrate` only: the sub-PR list, merge `origin/<default>` into the branch (starts at the
  feature branch), conflicts, full checks, `git push origin HEAD:feature/<slug>`, `gh pr create
  --base <default> --head feature/<slug>` listing every sub-PR and linking the issues they close;
  never merged by worker or coordinator;
- goal is an open PR: push and `gh pr create --base <target>` (integration branch, else default)
  even if the skill stops at a commit; ask a human decision plainly and stop;
- the same obstacle twice (same failing command or missing access): stop, print
  `RUNWAVES_WORKER_BLOCKED` with `reason:` and `needs:`; once the PR is open an unfixable check is
  no obstacle but goes in `checked:` (a block after the PR exists lands in `in-review`);
- before ending a turn with own background work running (e.g. review subagents) or waiting on
  something external that clears itself: `RUNWAVES_WORKER_WAITING` (below) once per wait, never per
  poll or while implementing. Waiting is not blocked (a block needs coordinator or user); what it
  waits on failing is an obstacle; a later DONE/BLOCKED replaces it;
- done = every PR check passed and mergeable; never DONE with a check pending or red. Cheaply: `gh
  pr checks <n> --watch --fail-fast >/dev/null 2>&1; echo exit=$?` (0 = all passed), only on non-zero
  `gh pr checks <n> --json name,state,bucket` filtered outside `pass`/`skipping`, tail `gh run view
  <run-id> --log-failed` (never green logs), fix, push, re-watch; confirm `gh pr view <n> --json
  mergeable,mergeStateStatus,statusCheckRollup`, merging or rebasing the base on conflict; an
  unfixable check named in `checked:`; no checks at all: run the tests locally, report in
  `checked:` ("no PR checks; local: npm test passed"), since the coordinator merges on that;
- local integration only (`local: true`, [integrations](integrations.md)): no PR, no push; covering
  suites before every commit, full command before the last; done = committed and full command
  passed, reported `pr: none (local integration)` and `checked: local: <command> passed`;
- acceptance criteria: the issue's checklist (free text: the `ask`, one per checkable sentence);
  DONE reports `criteria: <met>/<total>` after `checked:`, and when met < total one indented
  `unmet:` line per criterion not met or not verifiable, quoted, why in a few words; no checklist:
  `n/n` over derived criteria, listed in `checked:`;
- end the last message with exactly one block, the marker on its own line (`status.sh` also accepts older
  `ORCHESTRATOR_WORKER_*` markers; ignores mid-sentence markers and `<placeholder>` templates):

```text
RUNWAVES_WORKER_DONE
item: <ID>
pr: <url>
summary: <one line>
checked: <what you verified against the task, and the PR's checks in a few words ("5/5
  green"); name only the checks that were red or skipped>
criteria: <met>/<total>
  unmet: <a criterion not met or not verifiable, quoted, and why in a few words>
```

```text
RUNWAVES_WORKER_BLOCKED
item: <ID>
reason: <what stops you>
needs: <the decision or access required>
```

WAITING (not final): `status.sh` shows `waiting` with `waitingOn`/`resumesWhen`; the coordinator
skips the worker while it is the latest block; still latest after 30 minutes = `stale` (screen check).

```text
RUNWAVES_WORKER_WAITING
item: <ID>
waiting-on: <what you are waiting for>
resumes-when: <what ends the wait>
```
