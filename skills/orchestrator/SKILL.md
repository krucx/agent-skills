---
name: orchestrator
description: Act as the master agent that plans a batch of issues (GitHub, Linear, Jira, or free-text work broken into tasks) and runs them in parallel through Paradev (formerly Superset), each in its own worktree workspace with a worker agent running an implement skill, moving workspaces between the In Progress, In Review, Done and Blocked sidebar groups as their PRs appear and merge. Also answers "orchestrator report back" with a short status table. Use whenever the user says "orchestrate", "orchestrate these issues", "orchestrate 340 to 345", "orchestrate and work", "be the master agent", "run these issues in parallel", "spin up agents for these tickets", or "orchestrator report back" / "orchestrator status", even if they don't mention Paradev.
compatibility: Needs bash, jq, the GitHub CLI (gh, signed in) and the Paradev CLI (superset or paradev) with this machine's host running. Pull requests must live on GitHub.
model: sonnet
effort: low
argument-hint: items like "340-343, 345 onwards", "ENG-12 ENG-15", free text, or "report back"
---

# Orchestrator

You are the coordinator. You plan, dispatch, watch, move workspaces between groups, and report.
You never implement work yourself, even a small change: each item gets its own worker,
workspace, branch and PR.

Coordinating is cheap work, so this skill is meant to run on a small or mid-sized model.
Claude Code switches to one automatically. Other harnesses keep the model the session started
with. If you can tell you are on a top-tier model there, say once in one line that a smaller
model would do (the repo README has the launch command), then carry on.

`paradev` and `superset` are the same CLI; this skill writes `superset`. For CLI details beyond
what is here, `superset <command> --help` is authoritative.

`<skill-dir>` below is the folder this file is in (usually `~/.agents/skills/orchestrator`).

Two modes:

- **Run**: the user names work to do. Follow every section in order.
- **Report back**: the user says "orchestrator report back" or asks for status. Do
  [Preflight](#preflight), then go to [Report back](#report-back).

## Preflight

Check these before creating anything, and stop with a clear message if one fails:

1. `bash`, `jq`, `gh` and `superset` are on PATH, `gh auth status` passes, and
   `superset auth whoami --json` works.
2. The repo is on GitHub: `gh repo view --json nameWithOwner -q .nameWithOwner`.
3. Paradev project: in `superset projects list --json`, the project whose name matches the
   repo.
4. Plan file:
   `~/.agents/orchestrator/$(gh repo view --json nameWithOwner -q .nameWithOwner | tr / -).json`.
   It belongs to this repo, and runs started from any harness share it.
5. Worker agents: run `superset agents list --local --json`. For each harness, use the
   instance whose `presetId` is that harness and whose `name` contains `(auto)`, for example
   "Claude (auto)". Those instances start with auto-approve flags, so workers don't stall on
   permission prompts. If there's no auto instance, use the plain preset and warn the user once
   that its workers may stop for approvals (the repo README explains how to create one).

## Groups

Groups are workspace tags. Each tag files a workspace into the sidebar folder of the same name.
Use these exact names:

| Group | A workspace is here when |
| --- | --- |
| `In Progress` | its worker is implementing, or is working on feedback the user typed into its chat |
| `In Review` | its PR exists |
| `Done` | its PR is merged |
| `Blocked` | its worker can't continue and needs the user to look at it |

To move a workspace, replace its tags:
`superset workspaces update <id> --local --tag "In Review"`.
A workspace carries exactly one of these tags at a time.

## What the user can ask for

- **Tracker references**: `340-343` (both ends included), `345 onwards` (every open item from
  345 up), `#350`, `ENG-123`, `PROJ-7`. Mixed lists are fine.
- **Free text**: "orchestrate: add CSV export, fix the login redirect, …".
- **Per-run options**, which may also apply to a subset of items:
  - the worker skill: `using /implement-spec` (default `implement`);
  - the worker agent: `with codex` (default: the harness you are running in);
  - parallelism: `with 3 agents` (default 5, never more than 5).

  For example, "340-343 using /implement, 344-345 using /implement-spec" gives each item its
  own skill.

## Plan

1. **Find the tracker.** Read the `## Agent skills` section of the repo's `AGENTS.md` or
   `CLAUDE.md`. It points to an issue-tracker doc (often `docs/agents/issue-tracker.md`) that
   says which tracker the repo uses and how to read it. With no such doc, go by the reference
   shape: `#340` or a bare number means GitHub Issues through `gh`; `ABC-123` means Linear or
   Jira, so ask which if you can't tell.
2. **Check that you can reach the tracker** with whatever this harness has: `gh` for GitHub,
   `superset tasks get <KEY> --tracker linear --json` for Linear, or the harness's own Linear or
   Jira tools. If you can't reach it, stop before planning and tell the user how to connect it
   (for example connecting Linear in Paradev, or `superset plugins install linear`). Don't
   install or connect anything yourself.
3. **Expand and fetch.** Turn ranges into item IDs, then read each item's title, body and
   labels. Drop items that are closed, are pull requests, already have an open PR, or already
   have an orchestrated workspace. Leave out items labelled `needs-info` or `needs-triage` and
   items too vague to implement. Name every item you drop and give the reason.
4. **Free text becomes tasks.** Split the text into tasks that each make one reviewable PR, with
   IDs `T1`, `T2`, …, a title, the full task text a worker needs, and dependencies. Show the
   breakdown and **wait for the user's go**: splitting free text is the biggest judgment call in
   a run. Tasks stay plan-only. After the go, offer once to file them in the tracker; file them
   only if the user says yes.
5. **Find dependencies.**
   - *Explicit*: "blocked by", "depends on", "after", parent and child links.
   - *Conflicts*: items that will clearly edit the same files, migration, config or schema.
     Treat these as a dependency, smaller item first, so the user doesn't end up untangling
     merge conflicts.
6. **Order the work into waves** of at most the parallel limit. Start independent items first;
   when choosing between them, prefer the ones that unblock others.
7. **Write the plan file.** Overwrite any finished earlier run for this repo, and update the
   file whenever an item's state changes:

   ```json
   {
     "repo": "owner/repo",
     "created": "2026-11-12",
     "maxParallel": 5,
     "items": [
       {"id": "#340", "title": "…", "text": null, "dependsOn": [], "why": "",
        "skill": "implement", "agent": "claude", "state": "queued",
        "branch": null, "workspace": null, "terminal": null, "pr": null}
     ]
   }
   ```

   `text` holds a free-text task's full description (`null` for tracker items). `state` is one
   of `queued`, `in-progress`, `in-review`, `feedback`, `done`, `blocked` or `skipped`.

8. **Show the plan** as one short table (item, title, wave, depends on, skill, agent), then
   dispatch straight away. Stop and ask instead if the dependencies form a cycle, or if it's
   unclear whether two items should be one PR. Free-text runs have already waited for the go
   in step 4.

## Dispatch

Start an item when every dependency has at least a PR and fewer than the parallel limit are in
state `in-progress`:

```bash
superset workspaces create --local --project <project-id> \
  --name "<ID> <short title>" \
  --branch <branch> \
  --base-branch <main, or the dependency's branch> \
  --tag "In Progress" \
  --agent <auto instance id, or preset id> \
  --prompt "<worker prompt>" \
  --json
```

- **Branch**: `issue-340-<slug>` for a GitHub issue, the key in lowercase for other trackers
  (`eng-123-<slug>`), and `task-<slug>` for a free-text task. `<slug>` is 2-4 lowercase words
  from the title, joined by hyphens.
- **Stacked work**: if a dependency's PR isn't merged yet, branch from the dependency's branch
  so the worker builds on that code. Once it merges, use `main`.
- Don't pass `--model`. Workers use their harness's strongest default model.
- Record the workspace ID, branch and terminal ID in the plan file. If `create` doesn't return
  the terminal ID, take it from `superset snapshot --json`: the terminal in that workspace whose
  `agent` is set.

### Worker prompt

Start the prompt with the skill invocation in the worker's own syntax:

| Worker agent | First line |
| --- | --- |
| Claude, Hermes | `/<skill> <ID>` |
| Codex | `$<skill> <ID>` |
| Gemini, others | `Use the <skill> skill to do <ID>.` |

For a free-text task, put its full `text` straight after the first line.

Fill in the rest and drop the stacked line when it doesn't apply:

```text
<first line>

You are one of several agents working on this repo in parallel, each in its own worktree. An
orchestrator coordinates the run; the others are working on <other IDs>.
- Stay within <ID>. Don't make drive-by changes elsewhere: other branches are editing this code
  at the same time.
- Keep shared machine resources apart from the other workers: put <branch> in Docker Compose
  project names, container names, scratch or data directories and temp files, and don't bind
  fixed host ports that another worker might also use.
- Stacked: this branch starts from <branch> (PR #<m>, not merged yet). Say "Stacked on #<m>;
  merge that first" in your PR description.
- Your goal is an open pull request. If you need a decision from a human, ask it plainly and
  stop.
- Finish your last message with exactly one of:
  ORCHESTRATOR_WORKER_DONE
  item: <ID>
  pr: <url>
  summary: <one line>
  or
  ORCHESTRATOR_WORKER_BLOCKED
  item: <ID>
  reason: <what stops you>
  needs: <the decision or access required>
```

## Watch and move

Run `<skill-dir>/scripts/wait-change.sh` from the repo. It exits when any orchestrated worker
changes state, or after 20 minutes. If your harness can run a command in the background and
tell you when it ends, do that, so you don't spend turns polling. Otherwise run it in the
foreground with a short timeout (`wait-change.sh 120`).

Each time it exits:

1. Run `<skill-dir>/scripts/status.sh` from the repo. It prints one JSON line per orchestrated
   workspace: ID, branch, group, the agent's state (`working`, `idle`, `blocked`) with its
   terminal, and the branch's PR (number, URL, state, draft). Match lines to plan items by
   workspace ID.
2. Apply the transitions below and update the plan file.
3. Dispatch any item that has become ready.
4. If anything changed, print the [status table](#status-table).
5. Start the waiter again, unless the run is finished.

| Seen | Do |
| --- | --- |
| `In Progress`, and the branch has a PR | Move to `In Review` at once. Opening the PR is the worker's goal, so don't wait for CI or reviews. |
| `In Review`, agent `working` | The user typed feedback into the worker's chat. Move to `In Progress` and set state `feedback`. These don't count toward the parallel limit. |
| State `feedback`, agent `idle` | Move back to `In Review`. |
| Agent `blocked` (Paradev's "needs input") | Read the screen with `superset terminals read --local --workspace <id> --terminal <tid>`. Show the user the exact question and send a desktop notification. The user answers in the worker's chat. If they answer in yours instead, pass it on with `superset terminals send --local --workspace <id> --terminal <tid> --text "<answer>"`. Never answer a permission prompt, or decide anything about scope or the product, on the user's behalf. |
| `In Progress`, agent `idle`, no PR | Read the screen. If the worker printed `ORCHESTRATOR_WORKER_BLOCKED`, or it already had one follow-up, move to `Blocked`, free the slot, and tell the user why. Otherwise send one follow-up asking it to finish and open the PR. |
| PR `MERGED` | Move to `Done`. Dependents that haven't started can now branch from `main`. |
| PR `CLOSED` without merging | Move to `Blocked` and tell the user. |

After the move to `In Review`, the user owns the PR: they read CI and review feedback
themselves and reply in the worker's chat. Don't read PR comments or checks. Workers open PRs;
nobody in this run approves or merges them.

Never archive, delete or close a workspace, terminal or worktree. Moving tags is the only
change you make to a workspace after creating it.

### When the run is finished

The run is finished when every item is `In Review`, `Done`, `Blocked` or skipped, and nothing
is queued that could still start. Then print the final status table, send
`superset notifications show "Orchestrator finished" --body "<k> in review, <b> blocked" --sound`,
and stop the waiter. Merges come in later. "orchestrator report back" picks them up.

## Report back

1. Load the plan file. If there isn't one, report on whatever `status.sh` finds.
2. Run `status.sh`, apply the transitions, and dispatch any item that has become ready. The
   user asked only for a report, so if that means starting more than one new worker, list them
   and ask first.
3. Print the status table, plus a line or two only about what needs the user. If any worker is
   running, start the waiter again.

## Status table

Keep it this small. One row per item in the run, in plan order:

```markdown
| Item | Title | Group | Agent | PR |
| --- | --- | --- | --- | --- |
| #340 | Cache Pester in CI | In Review | done | #352 |
| #341 | Coverage floors | In Progress | running | — |
| #342 | Cancel stale CI | In Progress | waiting for input | — |
| #345 | Split backup job | Queued (after #341) | — | — |
```

`Agent` is `running` (state `working`), `waiting for input` (Paradev state `blocked`, or the
agent asked a question), `done` (`idle` with its part finished), or `—` when no worker exists.
`Group` is the sidebar group, `Queued (after <ID>)`, or `Skipped`. Under the table, add only
what needs the user: a worker's question, a `Blocked` reason, or a closed PR.
