---
name: runwaves
description: Plans tracker issues or free-text tasks into waves (dependencies, critical path), then hands the run to Orca's orchestration (one worker and PR per item) or, on Paradev, small free-text runs to `superset:orchestrate`. Use when the user says "runwaves 340-343", "plan runwaves", "runwaves report back", "runwaves continue" or "runwaves close". Not for small ad-hoc fan-outs with no tracker or PRs; those go straight to Orca's `orchestration` or Paradev's `superset:orchestrate`.
compatibility: Orca (ORCA_WORKSPACE_ID set) with the orca CLI, git and gh signed in; or Paradev with its CLI.
model: sonnet
effort: low
argument-hint: items like "340-343, 345 onwards", "ENG-12", free text, "report back", "continue", or "close"
---

# Runwaves

You plan; Orca or Paradev runs. Pick the path from the request, before planning:

- **Orca** (`ORCA_WORKSPACE_ID` set): [Plan](#plan), then [Go on Orca](#go-on-orca).
- **Paradev fanout**: free text only, 5 or fewer tasks, nothing to resume. [Plan](#plan), then
  [Go on Paradev fanout](#go-on-paradev-fanout). Planning finds a dependency: switch to the loop.
- **Paradev loop**: anything else (tracker items, epic, `feature:`, 6 or more, "continue", "report back",
  "close") → follow [paradev/plan.md](paradev/plan.md) instead.

## Plan

- **Refs**: `340-343`, `345 onwards`, `#350`, `ENG-123` ([trackers](references/trackers.md)), or free text.
  Options: `using /<skill>` (default `implement`), `with codex`, `with N agents` (default and max 5).
- **Fetch** each issue once: `gh issue view <n> --json title,state,labels,body`. Drop closed issues, PRs,
  issues with an open PR, `needs-info`/`needs-triage` and too-vague ones; name each drop and why.
- **Free text**: tasks `T1`, `T2`, one worker each; each keeps the user's words for its slice verbatim.
- **Dependencies**: explicit (blocked by, after, parent/child) or conflicts (same files, migration,
  schema; the smaller one goes first). A dependency outside the run that is still open: drop the item or ask.
- **Waves**: wave = 1 + the highest wave among its dependencies. Mark `*` every item on a longest chain
  (the critical path). Show one table and wait for the go:

  ```text
  wave  item  deps  title
  1*    #340  -     …
  ```

## Go on Orca

Load Orca's `orchestration` skill (`orca skills get orchestration`, once) and
`orca skills get orchestration --reference references/coordinator-loop.md`, then follow them as the
coordinator. Runwaves sends no plan files or scripts; Orca's Run is the plan.

1. `orca orchestration run-create --objective "runwaves <refs>"`.
2. One `task-create` per item in wave order: `--task-title "<id> <title>"`, `--deps` the dependencies' task
   IDs, and `--spec`:
   - tracker item: `Use the <skill> skill to do <id>.`; free text: `<id> is a run label, not a ticket. The
     user's words, verbatim, are the whole scope: <words>`;
   - `Stay within <id>; other workers change this repo in parallel.`;
   - `Done = a PR whose checks pass, into the branch you started from (gh pr create --base <it>) when that
     is another task's branch, else the default branch. No checks: run the tests locally. Report the PR URL
     and what you verified.`
3. Start the ready tasks, up to the agent limit: `worker-start --task <id> --worktree new-child --name
   rw-<id> --agent <agent>`, adding `--base-branch <branch>` with the branch of the first dependency's
   worker when the task has dependencies. End your turn.

Each wake: act as Orca's skill says, then start what `task-list --ready` shows, within the limit.
Questions go to the user unless the task or the user's words answer them. Never implement, merge or re-plan.

**report back**: `task-list` with each done task's PR. **continue**: start what is ready. **close**: stop
or abandon running workers as Orca's recovery reference says, then list what was left.
At the end, one line per item: outcome and PR.

## Go on Paradev fanout

Load `superset:orchestrate` and hand it every task at once; nothing else from this skill (no scripts,
plan file or references). 1 or 2 tasks run as agents in the current workspace; 3 or more get one new
workspace each. Brief = the task's words verbatim, plus `using /<skill>` if set; agent from `with codex`,
else the default. A worker's question: show it verbatim, relay only the user's answer. Done: one line per
task (done, blocked or failed, with its workspace). No PRs, acceptance or summary page: wanting any of
those makes it a loop run, so say that once.
