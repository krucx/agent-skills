# Paradev fanout

Fanout only, after the go: hand off to Paradev's `superset:orchestrate`. None of this skill's
scripts, plan file, groups or references.

- 1-2 items: agents in your current workspace (same worktree; panes or subagents fine). 3+: one new
  workspace each (in the sidebar), never the current one.
- Load `superset:orchestrate`, start every item at once. Brief: `/<skill> <ID>` (Codex `$<skill>
  <ID>`; skill from `using /<skill>`, default `implement`), then the `ask` verbatim and `notes`;
  agent from `with codex`, else default.
- Worker question: show verbatim, relay only the user's answer; never answer it yourself.
- Done: one line per item (done/blocked/failed, workspace). No PRs, acceptance or summary page; the
  user wants those → it was a loop run, say so once.
