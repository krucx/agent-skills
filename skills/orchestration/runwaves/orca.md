# Orca backend

Orca host only (`ORCA_WORKSPACE_ID` is set). Read after the go. Hand the approved waves to Orca's
built-in `orchestration` skill as they are: no preflight, none of this skill's scripts, plan file
or groups.

- Load that skill and its version-matched guide (`orca skills get orchestration`); its CLI, wake
  and message rules win over anything here.
- **Where items run**: 1 or 2 items stay in your workspace (`--worktree current`, or your own
  subagents in the same worktree). 3 or more get one new worktree and workspace each, visible in
  Orca's sidebar: `orca orchestration worker-start --spec "<brief>" --worktree new-child
  --name <runId>-<ID> --agent <agent>`; never `--worktree current`.
- Brief = the item's ref, title and `ask` verbatim, target branch, `using /<skill>` if set, and
  "open a PR" for tracker items. Agent: `with codex` → `codex`, else the agent you run as.
- Start every item whose dependencies are met, then end your turn. When Orca wakes you with a
  `worker_done`, start the items it unblocked; a failed dependency: tell the user, skip nothing alone.
- Worker questions: show them verbatim, relay only the user's answer with `orchestration send`.
- "report back": one line per item from Orca's dispatch state. "continue"/"close": Orca keeps no
  runwaves plan; say so and show the report instead.
