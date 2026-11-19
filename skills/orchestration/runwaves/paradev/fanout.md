# Paradev fanout

Fanout backend only: small runs handed to Paradev's `superset:orchestrate` skill. Read after the
go. Uses none of this skill's scripts, plan file, groups or references.

- **Where items run**: 1 or 2 items run as agents in your current workspace (same worktree; panes
  or subagents are fine). 3 or more get one new workspace each, visible in the Paradev sidebar;
  never the current one.
- Load `superset:orchestrate` and start every item at once. Brief = first line `/<skill> <ID>` (Codex `$<skill> <ID>`;
  skill from `using /<skill>`, default `implement`), then the item's `ask` verbatim and `notes`;
  agent from `with codex`, else the default.
- A worker's question: show it verbatim; relay only the user's answer. Never answer it yourself.
- Done: one line per item (done, blocked or failed, with its workspace). No PRs, acceptance or
  summary page; the user wants any of those → it was a loop run, say so once.
