---
name: orchestrator
description: Act as the master agent that plans a batch of issues (GitHub, Linear, Jira, or free-text work broken into tasks) and runs them in parallel through Paradev (formerly Superset), each in its own worktree workspace with a worker agent running an implement skill, moving workspaces between the In Progress, In Review, Done and Blocked sidebar groups as their PRs appear and merge. Also answers "orchestrator report back" with a short status table, and "orchestrator continue" to resume a run. Use whenever the user says "orchestrate", "orchestrate these issues", "orchestrate 340 to 345", "orchestrate and work", "be the master agent", "run these issues in parallel", "spin up agents for these tickets", or "orchestrator report back" / "orchestrator status" / "orchestrator continue", even if they don't mention Paradev.
compatibility: Needs bash, jq, git, the GitHub CLI (gh, signed in) and the Paradev CLI (superset or paradev) with this machine's host running. Pull requests must live on GitHub.
model: sonnet
effort: low
argument-hint: items like "340-343, 345 onwards", "ENG-12 ENG-15", free text, "report back", or "continue"
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
what is here, `superset <command> --help` is authoritative. `<skill-dir>` is the folder this
file is in (usually `~/.agents/skills/orchestrator`). Run every script from inside the repo.

## Modes

| The user says | Mode | May it start or message workers? |
| --- | --- | --- |
| items to work on ("orchestrate 340-343") | **Run** | yes |
| "orchestrator continue" / "resume" | **Continue**: pick up the existing run | yes |
| "orchestrator report back" / "status" | **Report back** | no, never |

Every mode starts with [Preflight](#preflight).

## Preflight

Stop with a clear message if any of these fail:

1. `bash`, `jq`, `git`, `gh` and `superset` are on PATH, `gh auth status` passes, and
   `superset auth whoami --json` works.
2. The repo is on GitHub: `gh repo view --json nameWithOwner`.
3. **Project ID**: in `superset projects list --json`, the project whose name matches the repo.
   The scripts take it as their first argument, so they only see this project's workspaces.
4. **Plan file**: `<skill-dir>/scripts/plan.sh path` gives `~/.agents/orchestrator/<owner>-<repo>.json`.
5. **Worker agents** (Run and Continue only): see [Worker agents and auto-approval](#worker-agents-and-auto-approval).

## The plan file and run ownership

Each repo has at most **one active run**, owned by one orchestrator at a time. The owner is the
Paradev terminal the orchestrator runs in (`$SUPERSET_TERMINAL_ID`), recorded in the plan with a
heartbeat. `plan.sh` enforces this:

- `plan.sh claim` before a Run or Continue:
  - `free`: there is no plan, or the last run finished. That run moves to
    `~/.agents/orchestrator/history/`; start a new plan.
  - `resumed`: you already own the active run. For a Run, add the new items to it; don't start
    a second plan.
  - exit 3: another orchestrator that is still alive owns the run. Don't start anything. Tell
    the user which terminal owns it, and offer a report back.
  - exit 4: the active run is stale (its owner's terminal is gone, or it hasn't sent a heartbeat
    for 45 minutes). For **Continue**, run `plan.sh claim --takeover` and say so in one line.
    For a **Run**, ask the user first whether to take over that run and add the new items.
- **Write only through `plan.sh write <file>`**: write the whole new plan to a temp file in your
  scratch space, then pass it in. The script takes a lock, refuses if someone else now owns
  the run, stamps owner and heartbeat, and swaps the file in atomically. Never edit the plan
  file in place.
- Run `plan.sh heartbeat` on every watch cycle. If `write` or `heartbeat` exits 3, another
  orchestrator has taken over: stop watching and tell the user.

Schema:

```json
{
  "repo": "owner/repo",
  "runId": "20261112-2015",
  "status": "active",
  "maxParallel": 5,
  "autoApprove": true,
  "items": [
    {"id": "#340", "title": "…", "text": null, "dependsOn": [], "why": "",
     "skill": "implement", "agent": "claude", "state": "queued", "reason": null,
     "branch": null, "workspace": null, "terminal": null, "pr": null}
  ]
}
```

`status` is `active` or `finished`; `owner`, `heartbeat` and `takenOverFrom` are added by
`plan.sh`. Item `state` is one of `queued`, `in-progress`, `in-review`, `feedback`, `done`,
`blocked`, `waiting` (a dependency failed) or `skipped`. `reason` explains `blocked`, `waiting`
and `skipped`. `text` holds a free-text task's full description.

## Sources of truth

- **Facts come from Paradev and GitHub**: whether a workspace exists, its current branch, its
  agent's state, and the PR's state.
- **Intent comes from the plan**: which items are in the run, their dependencies, skill, agent,
  and why something is waiting, blocked or skipped.
- **Groups follow from item state.** Always write the plan first and move the tag second. Then
  an interrupted update leaves the plan ahead of the tag, and the next reconcile re-applies the
  tag.
- The status table is rendered only from reconciled state, so it always matches the saved plan.

## Groups

Groups are workspace tags. Each tag files a workspace into the sidebar folder of the same name.
Use these exact names:

| Group | Item state |
| --- | --- |
| `In Progress` | `in-progress` or `feedback` |
| `In Review` | `in-review` |
| `Done` | `done` |
| `Blocked` | `blocked` |

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
  - parallelism: `with 3 agents` (default 5, never more than 5);
  - prompts: `with prompts` starts workers on the regular preset instead of an auto-approve one.

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
3. **Expand and fetch.** Turn ranges into item IDs, then read each item's title, body, labels and
   author. Drop items that are closed, are pull requests, already have an open PR, or are
   already in the plan. Mark items labelled `needs-info` or `needs-triage`, and items too vague
   to implement, as `skipped`. Name every item you drop or skip and give the reason.
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

   If a dependency is outside the run: a closed-as-completed issue counts as met. One that is
   open but not in the run, or was skipped, makes the dependent `waiting`, with that dependency
   named as the reason.
6. **Order the work into waves** of at most the parallel limit. Start independent items first;
   when choosing between them, prefer the ones that unblock others.
7. **Save the plan** with `plan.sh write`. The `runId` is the start time as `YYYYMMDD-HHMM`.
8. **Show the plan** as one short table (item, title, wave, depends on, skill, agent), then
   dispatch straight away. Stop and ask instead if the dependencies form a cycle, or if it's
   unclear whether two items should be one PR. Free-text runs have already waited for the go
   in step 4.

## Worker agents and auto-approval

Workers stall on permission prompts unless they start with auto-approve. Run
`superset agents list --local --json`; an **auto instance** has the harness's `presetId` and a
`name` containing `(auto)`, for example "Claude (auto)".

What auto mode allows depends on the harness:
- **Claude Code `--permission-mode auto`**: a safety classifier approves routine actions without
  asking, such as edits and builds, and still blocks risky ones, such as destructive commands
  or actions outside the working tree.
- **Codex `--approve-for-me`**: an automatic reviewer approves requests inside the
  workspace-write sandbox.

Either way, the user doesn't see individual commands before they run. That is acceptable for
implementing an item in its own worktree of a repo the user owns. Use the **regular preset**,
so the user approves each prompt, when any of these is true:

- the user said `with prompts`;
- the item was written by someone without write access to the repo (check with
  `gh api repos/<owner>/<repo>/collaborators/<login>/permission -q .permission`). Its text
  steers an agent that approves its own commands, so it is untrusted input;
- the item touches deployment, releases, infrastructure, credentials, or data migrations
  against real data.

Record the choice per item in the plan, and say in the plan table which items use the regular
preset. If no auto instance exists, use the regular preset everywhere and warn the user once.
The repo README explains how to create one.

## Dispatch

Start an item when every dependency has a PR (or is met), and fewer than the parallel limit of
items are `in-progress`. `feedback` items don't count.

**Choose the branch** before creating anything:

1. Branch name: `issue-340-<slug>` for a GitHub issue, the key in lowercase for other trackers
   (`eng-123-<slug>`), `task-<runId>-t1-<slug>` for a free-text task. Build `<slug>` from the
   title: lowercase ASCII, every run of other characters replaced by one hyphen, at most 4
   words, the whole branch at most 60 characters, with no leading or trailing hyphen.
2. Check for collisions: `git ls-remote --heads origin <branch>`,
   `git rev-parse --verify --quiet refs/heads/<branch>`, the other items in the plan, and
   `superset workspaces list --local --project <id> --search <branch> --json`. If the branch is
   taken, append `-2`, `-3`, … until it is free. Never reuse a branch you didn't create for this
   item.

**Write the plan first** (item `in-progress`, branch set), then create:

```bash
superset workspaces create --local --project <project-id> \
  --name "<ID> <short title>" \
  --branch <branch> --skip-branch-prefix \
  --base-branch <main, or the dependency's branch> \
  --tag "In Progress" \
  --agent <auto instance id, or preset id> \
  --prompt "<worker prompt>" \
  --json
```

- `--skip-branch-prefix` keeps the branch exactly as planned, even if Paradev is set to add a
  prefix.
- **Stacked work**: if a dependency's PR isn't merged yet, branch from the dependency's branch.
  Once it merges, use `main`.
- Don't pass `--model`. Workers use their harness's strongest default model.
- If `create` fails, set the item back to `queued`, and to `blocked` with the error as the
  reason on a second failure.
- If it succeeds, write the workspace ID, the branch Paradev actually reports, and the terminal
  ID into the plan. If the terminal ID isn't in the output, take it from
  `superset snapshot --json`: the terminal in that workspace whose `agent` is set.

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

## Reconcile

Do this at the start of every watch cycle, of Continue, and of Report back. Run
`<skill-dir>/scripts/status.sh <project-id> <plan-file>`. It prints one JSON line per workspace
that is in the plan or carries a group tag in this project, with:

- `group`;
- `inPlan`;
- `missing` (the plan has it, Paradev doesn't);
- the current `branch`;
- the agent's `state` (`working`, `idle`, `blocked` or `none`) and its terminal;
- the newest PR for the branch.

Repair the plan against these facts before applying any transition:

| Found | Do |
| --- | --- |
| Plan item started, but its workspace is `missing` | If its branch has a PR, keep following the PR: open means `in-review`, merged means `done`, with the note "workspace gone". If there's no PR, set it `blocked`, reason "workspace missing". |
| Workspace's branch differs from the plan | Store the current branch in the plan and note the rename. PR lookups follow the current branch. |
| Plan item `in-progress` with no workspace ID (a crash between writing the plan and creating the workspace) | Search for its branch with `superset workspaces list --local --project <id> --search <branch> --json`. If a workspace is found, record it. If not, set the item back to `queued`. |
| Tagged workspace that isn't in the plan | Not part of this run, so ignore it; it may be the user's own work. The exception is when its branch matches a plan item that has no workspace: then adopt it. |
| Tag is `Blocked` or `Done`, but the plan says otherwise | Plan-first ordering rules out an interrupted update, so the user moved it. Accept it: update the item's state (for `Blocked`, reason "moved by user"). |
| Any other mismatch between tag and item state | Re-apply the group for the item's state. |

## Watch and move

Run `<skill-dir>/scripts/wait-change.sh <project-id> <plan-file>`. It checks once a minute, so a
change is noticed within about a minute. It exits when any of these changes: a worker's agent
state, a group tag, a workspace disappearing, or a PR appearing, merging or closing. Otherwise
it exits after 20 minutes. If your harness can run a command in the background and tell you
when it ends, do that, so you don't spend turns polling. Otherwise run it in the foreground
with a short timeout (`wait-change.sh <project-id> <plan-file> 120`).

Each time it exits:

1. Run `plan.sh heartbeat` (stop if it exits 3), then [reconcile](#reconcile).
2. Apply the transitions below: for each change, write the plan first, then move the tag.
3. Dispatch any item that has become ready.
4. If anything changed, print the [status table](#status-table).
5. Start the waiter again, unless the run is finished.

| Seen | Do |
| --- | --- |
| `in-progress`, and the branch has a PR | Set `in-review` at once. Opening the PR is the worker's goal, so don't wait for CI or reviews. |
| `in-review`, agent `working` | The user typed feedback into the worker's chat. Set `feedback`. These don't count toward the parallel limit. |
| `feedback`, agent `idle` | Set back to `in-review`. |
| Agent `blocked` (Paradev's "needs input") | Read the screen with `superset terminals read --local --workspace <id> --terminal <tid>`. Show the user the exact question and send a desktop notification. The user answers in the worker's chat. If they answer in yours instead, pass it on with `superset terminals send --local --workspace <id> --terminal <tid> --text "<answer>"`. Never answer a permission prompt, or decide anything about scope or the product, on the user's behalf. |
| `in-progress`, agent `idle`, no PR | Read the screen. If the worker printed `ORCHESTRATOR_WORKER_BLOCKED`, or it already had one follow-up, set `blocked` with its reason, free the slot, and tell the user. Otherwise send one follow-up asking it to finish and open the PR. |
| PR `MERGED` | Set `done`. Dependents that haven't started can now branch from `main`. |
| PR `CLOSED` without merging | Set `blocked`, reason "PR closed unmerged", and tell the user. |

**When a dependency fails** (it becomes `blocked`, `skipped`, or its PR closes unmerged):

- Its queued dependents become `waiting`, with the reason "waiting on <ID>: <its reason>". Don't
  start them, re-plan them, or drop the dependency on your own.
- Dependents that already started (stacked on its branch) keep running. Add the note "built on
  <ID>, which is <state>", because the user has to decide whether that work still stands.
- Tell the user once. They can unblock the dependency, tell you to drop it ("start #345
  anyway"), or skip the dependents. Act on that in Continue, or right away if you're still
  running.
- If the dependency recovers (it becomes `in-review` or `done` again), its `waiting`
  dependents go back to `queued`.

After the move to `In Review`, the user owns the PR: they read CI and review feedback
themselves and reply in the worker's chat. Don't read PR comments or checks. Workers open PRs;
nobody in this run approves or merges them.

Never archive, delete or close a workspace, terminal or worktree. After creating a workspace,
moving its tag is the only change you make to it.

### When the run is finished

The run is finished when, after reconciling, no item is `queued` or `in-progress`. Everything
is then `in-review`, `feedback`, `done`, `blocked`, `waiting` or `skipped`. At that point:

1. Print the final status table.
2. Send `superset notifications show "Orchestrator finished" --body "<k> in review, <b> blocked" --sound`.
3. Stop the waiter.

Keep `status` `active` while anything is `in-review`, `feedback`, `blocked` or `waiting`: merges
and unblocks still come in, and Report back or Continue picks them up. Set it to `finished`
(through `plan.sh write`) only when every item is `done` or `skipped`.

## Continue

1. `plan.sh claim` (with `--takeover` if it exits 4).
2. Reconcile.
3. Apply the transitions, act on any decision the user gave about `waiting` items, and dispatch
   ready items.
4. Watch, as in a Run.

## Report back

Report back never starts, messages, or nudges a worker.

1. Load the plan file. If there is none, report on what `status.sh <project-id>` finds.
2. Reconcile and work out the transitions.
3. Persist them only if no live orchestrator owns the run. Check with `plan.sh check`, which
   changes nothing:
   - `mine` or `finished`: you may write.
   - `stale`: take over with `plan.sh claim --takeover` and say so in one line.

   Then write the plan and move the tags. If it prints `other`, a live orchestrator owns the
   run: show the reconciled table without writing, and say who owns the run (`owner` in the
   plan).
4. Print the status table, plus a line or two only about what needs the user. If items are
   ready to start, list them and add: "say 'orchestrator continue' to start them".

## Status table

Keep it this small. One row per item in the run, in plan order:

```markdown
| Item | Title | Group | Agent | PR |
| --- | --- | --- | --- | --- |
| #340 | Cache Pester in CI | In Review | done | #352 |
| #341 | Coverage floors | In Progress | running | — |
| #342 | Cancel stale CI | In Progress | waiting for input | — |
| #345 | Split backup job | Queued (after #341) | — | — |
| #346 | Backup retention | Waiting (#342 blocked) | — | — |
```

`Agent` is `running` (state `working`), `waiting for input` (Paradev state `blocked`, or the
agent asked a question), `done` (`idle` with its part finished), or `—` when no worker exists.
`Group` is the sidebar group, `Queued (after <ID>)`, `Waiting (<reason>)`, or `Skipped`. Under
the table, add only what needs the user: a worker's question, a `Blocked` reason, a dependency
decision, a closed PR, or a missing workspace.
