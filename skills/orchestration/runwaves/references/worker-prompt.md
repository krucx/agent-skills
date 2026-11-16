# Worker prompt

Built and sent by `dispatch.sh` (exact wording there). First line: Claude, Hermes `/<skill> <ID>`;
Codex `$<skill> <ID>`; others `Use the <skill> skill to do <ID>.` Then, in order:

- free text: the `ask`, labelled as the user's verbatim words and the whole scope, then any
  `notes`, labelled as context adding no work (older plan: `text`, unlabelled); tracker items get
  neither; `extras` never reach the worker;
- one of several agents in parallel worktrees; the others' IDs;
- free text only: `<ID>` is a plan label, not a tracker ticket; with an `ask`, build nothing beyond
  the user's words;
- stay within `<ID>`, no drive-by changes; `<branch>` in Docker Compose project and container
  names, scratch/data dirs and temp files; no fixed host ports;
- stacked only: starts from `<branch>` (PR #<m>, unmerged); "Stacked on #<m>; merge that first" in
  the PR description; note the parent tip before the first commit; after #<m> merges,
  `git fetch origin && git rebase --onto origin/<target> <that tip> HEAD`, `git push
  --force-with-lease`, delete the "merge that first" line (squash-merge leaves the parent's commits,
  so the PR conflicts until then);
- `<F>-integrate` only: the sub-PR list, merging `origin/<default>` into the branch (which starts at
  the feature branch), conflicts, the full checks, `git push origin HEAD:feature/<slug>`, then
  `gh pr create --base <default> --head feature/<slug>` listing every sub-PR and linking the issues
  they close; never merged by the worker or coordinator;
- the goal is an open PR: push and `gh pr create --base <target>` (the item's integration branch,
  else the default branch) even if the skill stops at a commit; ask a human
  decision plainly and stop;
- the same obstacle twice (same failing command or missing access): stop, print `ORCHESTRATOR_WORKER_BLOCKED` with
  `reason:` the obstacle, `needs:` what clears it; once the PR is open, an unfixable PR check is
  not an obstacle but goes in `checked:` (a block after the PR exists would land in `in-review`);
- before ending a turn with its own background work running (e.g. code-review subagents), or
  waiting on something external that clears itself: print `ORCHESTRATOR_WORKER_WAITING` (below) once per wait, never
  per poll or while implementing. Waiting is not blocked (a block needs the coordinator or user);
  what it waits on failing is an obstacle; a later DONE/BLOCKED block replaces the wait;
- done = every PR check passed and the PR is mergeable; never DONE while a check is pending or
  red. Cheaply: `gh pr checks <n> --watch --fail-fast >/dev/null 2>&1; echo exit=$?` (0 = all
  passed; the table is noise), and only on a non-zero exit `gh pr checks <n> --json
  name,state,bucket` filtered to the checks outside the `pass` and `skipping` buckets, then tail
  `gh run view <run-id> --log-failed` (never green logs), fix, push, re-watch; confirm
  `gh pr view <n> --json mergeable,mergeStateStatus,statusCheckRollup`, merging or rebasing the
  base on conflict; an unfixable check goes in `checked:` by name; a PR with no checks at all: run
  the project's tests locally and report them in `checked:` ("no PR checks; local: npm test
  passed"), since the coordinator merges a PR into an integration branch on that;
- local integration only (`local: true`, [integrations](integrations.md)): open no PR and push
  nothing; run the covering test suites before every commit and the full test command before the
  last; done = committed and the full command passed, reported as `pr: none (local integration)`
  and `checked: local: <command> passed`;
- acceptance criteria: the issue's checklist (free text: the `ask`, one criterion per sentence the
  worker can check); DONE reports `criteria: <met>/<total>` after `checked:` and, when met < total, one
  indented `unmet:` line per criterion not met or not verifiable, quoted with why in a few words; no
  checklist: `n/n` over the criteria the worker derived, listed in `checked:`;
- end the last message with exactly one block, the marker on its own line (`status.sh` ignores
  mid-sentence markers and blocks still holding `<placeholders>`, so the prompt's own templates
  aren't read as reports):

```text
ORCHESTRATOR_WORKER_DONE
item: <ID>
pr: <url>
summary: <one line>
checked: <what you verified against the task, and the PR's checks in a few words ("5/5
  green"); name only the checks that were red or skipped>
criteria: <met>/<total>
  unmet: <a criterion not met or not verifiable, quoted, and why in a few words>
```

```text
ORCHESTRATOR_WORKER_BLOCKED
item: <ID>
reason: <what stops you>
needs: <the decision or access required>
```

WAITING (not a final report): `status.sh` shows marker `waiting` with `waitingOn`/`resumesWhen`;
the coordinator skips the worker while it's the latest block; still latest after 30 minutes =
`stale`, which gets a screen check instead.

```text
ORCHESTRATOR_WORKER_WAITING
item: <ID>
waiting-on: <what you are waiting for>
resumes-when: <what ends the wait>
```
