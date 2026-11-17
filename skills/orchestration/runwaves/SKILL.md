---
name: runwaves
description: Plans tracker issues (GitHub, Linear, Jira), an epic ("runwaves feature #400", one integration branch) or free-text tasks into waves and drives them through parallel workers, each to its own PR in its own worktree, with a saved, resumable plan: on Orca every run, using Orca workers; on Paradev (formerly Superset) through its CLI with In Progress, In Review, Done and Blocked sidebar groups, small free-text runs through `superset:orchestrate`. Also "runwaves report back" (status table), "runwaves continue" (resume a run), "runwaves close" (end one). Use whenever the user says "runwaves 340-343", "plan runwaves", "runwaves feature #400", "runwaves report back", "runwaves continue" or "runwaves close", even without mentioning Paradev. Not Orca's built-in skills and not Paradev's own multi-agent skill (the `superset:` one): small ad-hoc fan-outs with no tracker, PRs or need to resume (e.g. "run these 3 refactors in parallel and tell me when done") belong to those.
compatibility: Needs bash, jq, git and the GitHub CLI (gh, signed in), plus the orca CLI on Orca, or on Paradev its CLI (superset, paradev or pdev) with this machine's host running. PRs must live on GitHub. Workers run on Claude Code, Codex, OpenCode or Antigravity.
model: sonnet
effort: low
argument-hint: items like "340-343, 345 onwards", "ENG-12 ENG-15", "feature #400" (an epic), "feature: <description>", free text, "report back", "continue", or "close"
---

# Runwaves

You plan; a backend runs. `<skill-dir>` = this folder. "continue", "report back"/"status",
"close": go straight to [orca.md](orca.md) on an Orca host, else [paradev/loop.md](paradev/loop.md).
For a new run, open no backend file (`orca.md`, `paradev/fanout.md`, `paradev/loop.md`) until
the user gives the go: planning needs none of them.

**Fanout** (Paradev, free text only, 5 or fewer tasks, no dependencies, nothing to resume): split the
tasks as in **Free text** below and show them with each `ask` quoted. Run no script, write no plan file
and open no reference. On the go, follow [paradev/fanout.md](paradev/fanout.md). A dependency turns up:
it is a loop run, so plan it in full.

## Plan

On Paradev (loop), first `<skill-dir>/scripts/preflight.sh`; non-zero exit: read
[paradev/dispatch.md](paradev/dispatch.md). On Orca
(`ORCA_WORKSPACE_ID` set) run `<skill-dir>/scripts/plan.sh claim` instead (exit 3 or 4:
[recovery](references/recovery.md)).

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
- **Waves** ≤ the limit, independent and unblockers first; `runId` = `YYYYMMDD-HHMM`. Show the
  table `<skill-dir>/scripts/table.sh --go <plan-file>` prints, as printed: waves, critical marks
  (every longest dependency chain) and targets come from the plan. To move an item, change its
  `dependsOn` or state and reshow; never edit the table. Squash-only repos: dependents wait for the
  merge. `<plan-file>` before the go is a draft JSON in your scratch folder (`runId`, `items` with
  `id`, `title`, `state` `planned`, `dependsOn`; [schema](references/plan-schema.md)): loop saves it
  with `plan.sh write`, orca saves it at the go.

## Go message

Open with the chosen [backend](#backend) in one line (`Backend: loop, 6 items`). Dispatch at once
unless there is an integration or a chain (loop and orca), or an auto-only harness or
regular-preset items (loop only); fanout dispatches at once. Then ask **once, all at once**: where independents go (`main` or
`feature/<slug>`); each chain (`chains.sh offer`/`accept`, or `share` if independents share a
branch); per integration branch **local** (`--local`, `"local": true`: no sub-PRs or per-item CI,
`merge.sh` merges here) or GitHub; each local chain branch `offer` proposes inside a GitHub
integration (critical-path chains: one PR into it per chain); auto-only; regular-preset items
([approval](references/approval.md)). Apply per-item moves and reshow the table. Ask instead on a
cycle or two items that may be one PR.

## Backend

Pick exactly one, first match wins, and read its file after the go, not before:

1. **orca**: Orca host, any run → [orca.md](orca.md).
2. **fanout**: Paradev, 5 or fewer items, no dependencies, no tracker, nothing to resume →
   [paradev/fanout.md](paradev/fanout.md).
3. **loop**: anything else (dependency chain, epic, `feature:`, 6 or more items, PRs wanted,
   acceptance, summary page, resume) → [paradev/dispatch.md](paradev/dispatch.md), then
   [paradev/loop.md](paradev/loop.md).

Orca: one new child worktree per item. Fanout: 1 or 2 items run in the current workspace; 3 or
more get one new workspace each. Both show in the host's sidebar. Never implement, decide scope, connect anything or re-ask.
