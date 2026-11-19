---
name: runwaves
description: Plans tracker issues (GitHub, Linear, Jira), an epic ("runwaves feature #400", one integration branch) or free-text tasks into waves and drives them through parallel workers, one PR and worktree each, with a saved, resumable plan; on Orca via Orca workers, on Paradev (formerly Superset) via its CLI and sidebar groups. Use for "runwaves 340-343", "plan runwaves", "runwaves feature #400", "runwaves report back", "runwaves continue", "runwaves close", even without mentioning Paradev. Not for ad-hoc fan-outs with no tracker, PRs or resume ("run these 3 refactors in parallel"): Orca's built-in skills or Paradev's `superset:` multi-agent skill.
compatibility: Needs bash, jq, git, gh (signed in), and the orca CLI on Orca or the Paradev CLI (superset, paradev or pdev) with this host running. PRs on GitHub. Workers: Claude Code, Codex, OpenCode, Antigravity.
model: sonnet
effort: low
argument-hint: items like "340-343, 345 onwards", "ENG-12 ENG-15", "feature #400" (an epic), "feature: <description>", free text, "report back", "continue", or "close"
---

# Runwaves

You plan; a backend runs. `<skill-dir>` = this folder. "continue", "report back"/"status", "close":
go to [orca.md](orca.md) on Orca, else [paradev/loop.md](paradev/loop.md). Never implement, decide
scope, connect anything or re-ask.

## Backend

First match wins; open its file only after the go:

1. **orca** (`ORCA_WORKSPACE_ID` set), any run → [orca.md](orca.md); one child worktree per item.
2. **fanout**: Paradev, free text, ≤5 tasks, no dependencies, nothing to resume, no PRs,
   acceptance or summary page wanted. Split as in **Free
   text**, show each `ask` quoted; no script, plan file or reference. On the go:
   [paradev/fanout.md](paradev/fanout.md). A dependency appears: it is a loop run.
3. **loop**: anything else → [paradev/dispatch.md](paradev/dispatch.md), then [paradev/loop.md](paradev/loop.md).

## Plan

Loop: first `<skill-dir>/scripts/preflight.sh` (non-zero: [paradev/dispatch.md](paradev/dispatch.md)).
Orca: `<skill-dir>/scripts/plan.sh claim` (exit 3/4: [recovery](references/recovery.md)).

- **Refs** mix `340-343`, `345 onwards`, `#350`, `ENG-123`, free text. Options: `using /<skill>`
  (`implement`), `with codex`, `with N agents` (default and max 5), `with prompts` (regular preset).
- **Tracker**: `## Agent skills` in `AGENTS.md`/`CLAUDE.md`, else `#n` GitHub (`gh`), `ABC-123`
  Linear/Jira ([trackers](references/trackers.md); unreachable: say how to connect, never connect).
- **Fetch** title, body, labels, author. Drop closed, PRs, open-PR or already-planned items; skip
  `needs-info`/`needs-triage`/too vague. Name each drop and why.
- **Free text** → `T1`, `T2`…, one PR each. `ask` = the user's slice **verbatim**; `notes` add no
  work; more → `extras`. Show with `ask` quoted, wait for the go, then offer once to file them.
- **Epic** (`feature #400`, `feature: <text>`): one integration branch,
  [integrations](references/integrations.md) (chains, **local**, merge gate, `held`).
- **Dependencies**: explicit (blocked by, after, parent/child) or conflicts (same files, migration,
  schema; smaller first). Outside the run: closed-completed is met, else the dependent `waiting`.
  Large chain link: suggest once a small interface/stub task.
- **Waves** ≤ the limit, independents and unblockers first; `runId` = `YYYYMMDD-HHMM`. Show
  `<skill-dir>/scripts/table.sh --go <plan-file>` output as printed. To move an item, change its
  `dependsOn` or state and reshow; never edit the table. Squash-only repos: dependents wait for the
  merge. Before the go `<plan-file>` is a draft JSON in your scratch folder (`runId`, `items` with
  `id`, `title`, `state` `planned`, `dependsOn`; [schema](references/plan-schema.md)); loop saves
  it with `plan.sh write`, orca at the go. The write queues `planned` items; never set `queued`
  yourself.

## Go message

Open with the backend (`Backend: loop, 6 items`). Dispatch at once unless there is an integration or
chain (loop, orca), or an auto-only harness or regular-preset items (loop). Else ask **once, all
together**: where independents go (`main` or `feature/<slug>`); each chain (`chains.sh
offer`/`accept`, or `share` if independents share a branch); per integration **local** (`--local`:
no sub-PRs or per-item CI, `merge.sh` merges here) or GitHub; each local chain branch `offer`
proposes in a GitHub integration; auto-only; regular-preset items ([approval](references/approval.md)).
Apply per-item moves, reshow the table. A cycle, or two items that may be one PR: ask instead.
