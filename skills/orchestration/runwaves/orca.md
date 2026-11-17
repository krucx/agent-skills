# Orca backend

Orca host only (`ORCA_WORKSPACE_ID` is set). Read after the go. Every run shape (tracker items,
free text, epics, `feature:`, chains, local branches) runs here with the saved plan and this
skill's scripts; Orca starts the workers and wakes you. `<skill-dir>` = the folder holding
SKILL.md; run scripts inside the repo; the project ID is `-`. Never write jq against the plan:
only the scripts change it.

- Load Orca's `orchestration` skill and its guide once (`orca skills get orchestration`) for its
  wake and reply rules. Never run its `worker-start` yourself: `cycle.sh` starts every worker
  through `dispatch.sh`, one new child worktree per item on its own branch, visible in Orca's
  sidebar, and records the dispatch in the plan. The spec is the task and its end state (a PR
  into the target with passing checks) only; Orca's own preamble covers how the worker reports,
  and its `worker_done` report is what `accept` shows you.
- **Dependencies live in Orca too**: `cycle.sh` puts every item in one Orca Run as a Task with the
  plan's dependencies, and starts each worker as that Task's child. Orca's "completed" is not
  enough on its own: a worker reports before acceptance and the merge gate. So `cycle.sh` marks
  a Task completed only once its item is done, and failed once it is skipped. Never run
  `task-create`, `task-update` or `worker-start` yourself.
- **Go**: `plan.sh write <draft>` (from then on `<plan-file>` is `plan.sh path`), the go
  message's answers (`chains.sh accept|share`, `epic.sh import`, as in
  [integrations](references/integrations.md)), then `cycle.sh - <plan-file>`. End your turn.
- **Each Orca wake** (a `worker_done`, a question, an escalation): run `cycle.sh - <plan-file>`
  once, act on its `needs` as in [loop.md](paradev/loop.md#acting-on-needs), and end your turn.
  It moves states, merges green sub-PRs into integration branches, queues `<F>-integrate`, and
  starts what became ready. Never loop it or run `watch.sh`: Orca wakes you.
- **Questions**: show the worker's question verbatim; relay only the user's answer, with `orca
  orchestration reply --id <message_id> --body "<answer>"`. Other messages to a worker:
  `send.sh`.
- Merges a human makes don't wake you: "continue" runs `cycle.sh` again, which marks merged items
  done and starts what they unblocked. `stalled` never comes up here; a worker Orca reports gone
  shows as `blocked`.
- **report back**: `table.sh - <plan-file>`. **continue**: `plan.sh claim`, then a wake.
  **close**: `plan.sh close`, then `finish.sh - <plan-file>`.
- **Finish** (`finished` in the cycle output): `finish.sh - <plan-file>`. No summary page: it
  publishes to Paradev.
- Reporting and never-do rules: [loop.md](paradev/loop.md#reporting).
