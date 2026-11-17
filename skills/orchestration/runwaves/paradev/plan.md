# Runwaves on Paradev: planning

You plan; a backend runs. `<skill-dir>` = the folder holding SKILL.md. "continue", "report back"/"status",
"close": go straight to [loop.md](loop.md).
For a new run, open no backend file until the go. Fanout runs never come here: they follow SKILL.md.

## Plan

First `<skill-dir>/scripts/preflight.sh`; non-zero exit: read [dispatch.md](dispatch.md).

- **Refs** mix: `340-343`, `345 onwards`, `#350`, `ENG-123`, free text. Options: `using /<skill>`
  (`implement`), `with codex`, `with N agents` (default and max 5), `with prompts` (regular preset).
- **Tracker**: `## Agent skills` in `AGENTS.md`/`CLAUDE.md`, else `#n` GitHub (`gh`), `ABC-123`
  Linear/Jira ([trackers](../references/trackers.md); unreachable: say how to connect, never connect).
- **Fetch** title, body, labels, author. Drop closed, PRs, open-PR or already-planned items;
  skip `needs-info`/`needs-triage`/too vague. Name each drop and why.
- **Free text** → `T1`, `T2`… one PR each. `ask` = the user's slice **verbatim**; `notes` add no
  work; more → `extras`. Show tasks with `ask` quoted, wait for the go, then offer once to file them.
- **Epic** (`feature #400`, `feature: <text>`): one integration branch, see
  [integrations](../references/integrations.md) (chains, **local**, merge gate, `held`).
- **Dependencies**: explicit (blocked by, after, parent/child) or conflicts (same files, migration,
  schema; smaller first). Outside the run: closed-completed is met, else the dependent `waiting`.
  Large chain link: suggest once a small interface/stub task.
- **Waves** ≤ the limit, independent and unblockers first; `runId` = `YYYYMMDD-HHMM`. Show the
  table `<skill-dir>/scripts/table.sh --go <plan-file>` prints, as printed: waves, critical marks
  (every longest dependency chain) and targets come from the plan. To move an item, change its
  `dependsOn` or state and reshow; never edit the table. Squash-only repos: dependents wait for the
  merge. `<plan-file>` before the go is a draft JSON in your scratch folder (`runId`, `items` with
  `id`, `title`, `state` `planned`, `dependsOn`; [schema](../references/plan-schema.md)): the go saves it
  with `plan.sh write`.

## Go message

Open with `Backend: loop, <n> items`. Dispatch at once unless there is an integration, a chain, an
auto-only harness or regular-preset items. Then ask **once, all at once**: where independents go (`main` or
`feature/<slug>`); each chain (`chains.sh offer`/`accept`, or `share` if independents share a
branch); per integration branch **local** (`--local`, `"local": true`: no sub-PRs or per-item CI,
`merge.sh` merges here) or GitHub; each local chain branch `offer` proposes inside a GitHub
integration (critical-path chains: one PR into it per chain); auto-only; regular-preset items
([approval](../references/approval.md)). Apply per-item moves and reshow the table. Ask instead on a
cycle or two items that may be one PR.

## Backend

After the go: [dispatch.md](dispatch.md), then [loop.md](loop.md). Never implement, decide scope,
connect anything or re-ask.
