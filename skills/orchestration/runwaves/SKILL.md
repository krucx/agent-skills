---
name: runwaves
description: Plans tracker issues (GitHub, Linear, Jira), an epic ("runwaves feature #400", one integration branch) or free-text tasks into waves and drives each to its own PR in a parallel Paradev (formerly Superset) worktree worker, with a saved, resumable plan and In Progress, In Review, Done and Blocked sidebar groups. Also "runwaves report back" (status table), "runwaves continue" (resume a run), "runwaves close" (end one). Use whenever the user says "runwaves 340-343", "plan runwaves", "runwaves feature #400", "runwaves report back", "runwaves continue" or "runwaves close", even without mentioning Paradev. Not Orca's built-in skills and not Paradev's own multi-agent skill (the `superset:` one): small ad-hoc fan-outs with no tracker, PRs or need to resume (e.g. "run these 3 refactors in parallel and tell me when done") belong to those.
compatibility: Needs bash, jq, git, the GitHub CLI (gh, signed in) and the Paradev CLI (superset, paradev or pdev) with this machine's host running. PRs must live on GitHub. Workers run on Claude Code, Codex, OpenCode or Antigravity.
model: sonnet
effort: low
argument-hint: items like "340-343, 345 onwards", "ENG-12 ENG-15", "feature #400" (an epic), "feature: <description>", free text, "report back", "continue", or "close"
---

# Runwaves

You plan; scripts run. `<skill-dir>` = this folder. "continue", "report back"/"status", "close":
go straight to [paradev/loop.md](paradev/loop.md).

## Plan

First `<skill-dir>/scripts/preflight.sh`; non-zero exit: read [paradev/fanout.md](paradev/fanout.md).

- **Refs** mix: `340-343`, `345 onwards`, `#350`, `ENG-123`, free text. Options: `using /<skill>`
  (`implement`), `with codex`, `with N agents` (default and max 5), `with prompts` (regular preset).
- **Tracker**: `## Agent skills` in `AGENTS.md`/`CLAUDE.md`, else `#n` GitHub (`gh`), `ABC-123`
  Linear/Jira ([trackers](references/trackers.md); unreachable: say how to connect, never connect).
- **Fetch** title, body, labels, author. Drop closed, PRs, open-PR or already-planned items;
  skip `needs-info`/`needs-triage`/too vague. Name each drop and why.
- **Free text** → `T1`, `T2`… one PR each. `ask` = the user's slice **verbatim**; `notes` add no
  work; more → `extras`. Show tasks with `ask` quoted, wait for the go, then offer once to file them.
- **Epic** (`feature #400`, `feature: <text>`): one integration branch, see
  [integrations](references/integrations.md) (chains, **local**, merge gate, `held`).
- **Dependencies**: explicit (blocked by, after, parent/child) or conflicts (same files, migration,
  schema; smaller first). Outside the run: closed-completed is met, else the dependent `waiting`.
  Large chain link: suggest once a small interface/stub task.
- **Waves** ≤ the limit, independent and unblockers first; `runId` = `YYYYMMDD-HHMM`. Table: item,
  title, wave, depends on, target, skill, agent. Squash-only repos: dependents wait for the merge.

## Go message

Dispatch at once unless there is an integration, a chain, an auto-only harness or regular-preset
items. Then ask **once, all at once**: where independents go (`main` or `feature/<slug>`); each
chain (`chains.sh offer`/`accept`, or `share` if independents share a branch); per integration
branch **local** (`--local`, `"local": true`: no sub-PRs or per-item CI, `merge.sh` merges here) or
GitHub; auto-only; regular-preset items ([approval](references/approval.md)). Apply per-item moves
and reshow the table. Ask instead on a cycle or two items that may be one PR.

## Backend

After the go: Paradev. Read [paradev/fanout.md](paradev/fanout.md), then
[paradev/loop.md](paradev/loop.md), not before. Never implement, decide scope, connect anything or
re-ask.
