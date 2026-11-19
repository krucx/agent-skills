# Orca backend

Orca host (`ORCA_WORKSPACE_ID` set), every run shape, after the go. `<skill-dir>` = SKILL.md's
folder; run scripts in the repo; project ID is `-`. Only scripts change the plan: never jq it.

- Load Orca's `orchestration` skill and guide once (`orca skills get orchestration`) for wake and
  reply rules. Never run `worker-start`, `task-create` or `task-update` yourself: `cycle.sh` starts
  each worker via `dispatch.sh` (one child worktree and branch per item, in the sidebar), keeps
  every item as a Task with the plan's dependencies in one Orca Run, and marks a Task completed
  only once its item is done (a worker reports before acceptance and merge), failed once skipped.
  The spec: `/<skill> <ID>` (default `/implement #44`; Codex `$implement`), then the task and its
  end state (a PR into the target with passing checks) only; the `worker_done` report is what
  `accept` shows you.
- **Go**: `plan.sh write <draft>` (then `<plan-file>` = `plan.sh path`), the go answers
  (`chains.sh accept|share`, `epic.sh import`, per [integrations](references/integrations.md)),
  `cycle.sh - <plan-file>`. End your turn.
- **Each wake** (`worker_done`, question, escalation): `cycle.sh - <plan-file>` once, act on its
  `needs` per [loop.md](paradev/loop.md#acting-on-needs), end your turn. Never loop it or run
  `watch.sh`: Orca wakes you.
- **Questions**: show verbatim; relay only the user's answer: `orca orchestration reply --id
  <message_id> --body "<answer>"`. Other messages to a worker: `send.sh`.
- Human merges don't wake you: "continue" reruns `cycle.sh`. No `stalled` here; a worker Orca
  reports gone is `blocked`.
- **report back**: `table.sh - <plan-file>`. **continue**: `plan.sh claim`, then a wake. **close**:
  `plan.sh close`, `finish.sh - <plan-file>`.
- **Finish** (`finished`): `finish.sh - <plan-file>`; no summary page.
- Reporting and never-rules: [loop.md](paradev/loop.md#reporting).
