---
name: orchestrator
description: Act as the master agent that plans a batch of issues (GitHub, Linear, Jira, or free-text work broken into tasks) and runs them in parallel through Paradev (formerly Superset), each in its own worktree workspace with a worker agent running an implement skill, moving workspaces between the In Progress, In Review, Done and Blocked sidebar groups as their PRs appear and merge. Also answers "orchestrator report back" with a short status table, and "orchestrator continue" to resume a run. Use whenever the user says "orchestrate", "orchestrate these issues", "orchestrate 340 to 345", "orchestrate and work", "be the master agent", "run these issues in parallel", "spin up agents for these tickets", or "orchestrator report back" / "orchestrator status" / "orchestrator continue", even if they don't mention Paradev.
compatibility: Needs bash, jq, git, the GitHub CLI (gh, signed in) and the Paradev CLI (superset, paradev or pdev; any one of them) with this machine's host running. Pull requests must live on GitHub.
model: sonnet
effort: low
argument-hint: items like "340-343, 345 onwards", "ENG-12 ENG-15", free text, "report back", or "continue"
---

# Orchestrator

You coordinate (plan, dispatch, watch, move groups, report); never implement, even a little:
each item gets its own worker, workspace, branch and PR. Coordinating is cheap: Claude Code
picks a small or mid-sized model; elsewhere, if you're top-tier, say once in one line that a
smaller one would do (README has the launch command).

`superset`, `paradev`, `pdev`: one CLI (scripts try that order); this file writes `superset`,
use whichever is on PATH; its `--help` is authoritative. `<skill-dir>`: this file's folder
(usually `~/.agents/skills/orchestrator`). Run scripts inside the repo.

## Modes

| The user says | Mode | Start/message workers? |
| --- | --- | --- |
| items to work on ("orchestrate 340-343") | **Run** | yes |
| "orchestrator continue" / "resume" | **Continue**: pick up the existing run | yes |
| "orchestrator report back" / "status" | **Report back** | no, never |

## Preflight

All modes; stop with a clear message on failure:

1. `bash`, `jq`, `git`, `gh`, CLI on PATH; `gh auth status`, `superset auth whoami --json` pass.
2. Repo on GitHub: `gh repo view --json nameWithOwner`.
3. **Project ID**: repo-named project in `superset projects list --json`; scripts take it
   first, scoping them to its workspaces.
4. **Plan file**: `<skill-dir>/scripts/plan.sh path` gives `~/.agents/orchestrator/<owner>-<repo>.json`.
5. Run/Continue: [worker agents](#worker-agents-and-auto-approval).

## Plan file and ownership

One **active run** per repo, owned by an orchestrator's terminal (`$SUPERSET_TERMINAL_ID`) with
a heartbeat. `plan.sh claim` before Run/Continue: `free` (no plan, or last run finished, now in
`~/.agents/orchestrator/history/`): new plan. `resumed`: yours; a Run adds items to it. Exit 3:
a live orchestrator owns it; start nothing, name its terminal, offer a report back. Exit 4:
stale (terminal gone, or no heartbeat for 45 minutes); Continue runs `plan.sh claim --takeover`
and says so in one line, Run first asks the user whether to take over and add its items.

Write **only** via `plan.sh write <file>` (whole plan in a scratch temp file, never in place):
it locks, refuses if another now owns the run, stamps owner and heartbeat, swaps atomically.
`plan.sh heartbeat` each watch cycle. `write`/`heartbeat` exit 3 (taken over): stop, tell the user.

```json
{"repo": "owner/repo", "runId": "20261112-2015", "status": "active", "maxParallel": 5,
 "autoApprove": true, "items": [{"id": "#340", "title": "…", "text": null, "dependsOn": [],
 "why": "", "skill": "implement", "agent": "claude", "preset": "auto", "state": "queued",
 "reason": null, "branch": null, "workspace": null, "terminal": null, "pr": null,
 "checked": null, "followUp": null}]}
```

`status` `active`|`finished`; `plan.sh` adds `owner`, `heartbeat`, `takenOverFrom`. `state`:
`queued`, `in-progress`, `in-review`, `feedback`, `done`, `blocked`, `waiting` (dependency
failed), `skipped`; `reason` explains `blocked`/`waiting`/`skipped`. `text`: free-text task
description. `preset`: `auto`|`regular`. `checked`: worker's `checked:` line. `followUp`: `null`
or `{"after": "<ID>", "message": "<text>"}` ([after a merge](#follow-ups-after-a-merge)).

Facts (workspace, branch, agent and PR state) come from Paradev and GitHub; intent (items,
dependencies, skill, agent, why waiting/blocked/skipped) from the plan. Write the plan, then the
tag, so an interruption leaves the plan ahead for reconcile to re-tag. Status tables come only
from reconciled state.

## Groups

Tags file workspaces into same-named sidebar folders; one each, exact names (shown lowercase,
`in progress`/`in review`; lookups ignore case). Move by replacing:
`superset workspaces update <id> --local --tag "In Review"`.

| Group | Item state |
| --- | --- |
| `In Progress` | `in-progress` or `feedback` |
| `In Review` | `in-review` |
| `Done` | `done` |
| `Blocked` | `blocked` |

## Requests

- Refs, mixable: `340-343` (inclusive), `345 onwards` (open items from 345 up), `#350`,
  `ENG-123`, `PROJ-7`; or free text ("orchestrate: add CSV export, fix the login redirect, …").
- Options, per run or subset ("340-343 using /implement, 344-345 using /implement-spec"):
  `using /implement-spec` (default `implement`); `with codex` (default: your harness);
  `with 3 agents` (default 5, never more than 5); `with prompts` (regular preset).

## Plan

Steps 1–3 only for tracker refs (free-text-only runs start at 4).

1. **Tracker**: per the doc that `## Agent skills` in `AGENTS.md`/`CLAUDE.md` points to (often
   `docs/agents/issue-tracker.md`); else `#340`/bare number is GitHub Issues (`gh`), `ABC-123`
   Linear or Jira (ask if unclear).
2. **Reach it** (`gh`, `superset tasks get <KEY> --tracker linear --json`, harness tools), else
   stop before planning and say how to connect (Linear in Paradev, or
   `superset plugins install linear`). Never install or connect anything yourself.
3. **Fetch** expanded items' title, body, labels, author. Drop closed ones, pull requests, ones
   with an open PR or already planned; `skipped`: `needs-info`/`needs-triage` labels or too
   vague. Name each dropped/skipped item and why.
4. **Free text → tasks** `T1`, `T2`, … (one reviewable PR each; title, full text,
   dependencies). Show them; **wait for the go** (biggest judgment call), asking only that.
   Tasks stay plan-only; after the go, separately (never in one question), offer once to file
   them; file only on yes.
5. **Dependencies**: explicit ("blocked by", "depends on", "after", parent/child) and conflicts
   (clearly same files, migration, config or schema; smaller first). Outside the run:
   closed-as-completed is met; open-not-in-run or skipped makes the dependent `waiting`, naming it.
6. **Waves** ≤ parallel limit: independent first, preferring unblockers.
7. **Save** via `plan.sh write`; `runId` = start time `YYYYMMDD-HHMM`.
8. **Show** a short table (item, title, wave, depends on, skill, agent) and dispatch at once;
   ask instead on a dependency cycle or if two items might be one PR.

## Worker agents and auto-approval

Workers stall on prompts without auto-approve. In `superset agents list --local --json`
(`id`, `presetId`, `label`, `command`, `args`), an **auto instance** has the harness's
`presetId` and a `label` with `(auto)` ("Claude (auto)"), or `claude` `--permission-mode auto`
(`args` `["--permission-mode", "auto"]` or `["--permission-mode=auto"]`), or `codex`
`--approve-for-me`. Claude's classifier approves routine actions (edits, builds), blocking risky
ones (destructive, outside the worktree); Codex's reviewer approves inside the workspace-write
sandbox. Unseen commands are fine for an item in its own worktree of the user's repo. Use the
**regular preset** (user approves each prompt) if:

- the user said `with prompts`;
- the author lacks write access
  (`gh api repos/<owner>/<repo>/collaborators/<login>/permission -q .permission`): untrusted text
  steering a self-approving agent;
- it touches deployment, releases, infrastructure, credentials, or real-data migrations.

The regular preset may itself auto-approve (a plain Claude preset showed "auto mode on"):
check its `command`/`args` against the rules above, and the screen once started. If so, warn
the user, ask for a prompting preset, and hold those items until given one.

Record `preset` per item; mark regular ones in the plan table. No auto instance for a harness:
regular preset for its items; warn once, listing each instance's `label`, `command`, `args`
(README explains creating one).

## Dispatch

Start an item once each dependency has a PR (or is met) and fewer than the limit are
`in-progress` (`feedback` excluded); never stack on one in `feedback`: wait for `in-review` or
merge.

**Branch**: `issue-340-<slug>`, lowercase key (`eng-123-<slug>`), or `task-<runId>-t1-<slug>`
(free text). `<slug>`: lowercase ASCII title, runs of other characters replaced by one hyphen, at
most 4 words; branch at most 60 characters, no edge hyphens. Taken in
`git ls-remote --heads origin <branch>`, `git rev-parse --verify --quiet refs/heads/<branch>`,
the plan, or `superset workspaces list --local --project <id> --search <branch> --json`: append
`-2`, `-3`, … Never reuse a branch you didn't create for this item.

**Write the plan first** (`in-progress`, branch set), then:

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

`--skip-branch-prefix` keeps the branch even if Paradev adds a prefix. Stacked: base on an
unmerged dependency's branch, else `main`. No `--model` (harness default is strongest). Failure:
`queued`; second failure `blocked`, error as reason. Success: plan gets the workspace ID,
Paradev's reported branch, terminal ID = `create`'s `agents[].sessionId` (`terminals` may be
empty); only without `sessionId`, `superset snapshot --json`'s terminal there with `agent` set.

### Worker prompt

| Worker agent | First line |
| --- | --- |
| Claude, Hermes | `/<skill> <ID>` |
| Codex | `$<skill> <ID>` |
| Gemini, others | `Use the <skill> skill to do <ID>.` |

`<task text>`: a free-text task's full `text`; tracker items drop it and the free-text line.
Drop the stacked line if not stacked.

```text
<first line>

<task text>

You are one of several agents working on this repo in parallel, each in its own worktree. An
orchestrator coordinates the run; the others are working on <other IDs>.
- Free text: <ID> is a label in this run's plan only (T1, T2, …), not a tracker ticket. The
  task is the text above; don't fetch <ID> from any tracker.
- Stay within <ID>. Don't make drive-by changes elsewhere: other branches are editing this code
  at the same time.
- Keep shared machine resources apart from the other workers: put <branch> in Docker Compose
  project names, container names, scratch or data directories and temp files, and don't bind
  fixed host ports that another worker might also use.
- Stacked: this branch starts from <branch> (PR #<m>, not merged yet). Say "Stacked on #<m>;
  merge that first" in your PR description.
- Your goal is an open pull request. When the work is committed, push the branch and open the
  PR yourself (`gh pr create`), even if your skill stops at a commit. If you need a decision
  from a human, ask it plainly and stop.
- Finish your last message with exactly one of:
  ORCHESTRATOR_WORKER_DONE
  item: <ID>
  pr: <url>
  summary: <one line>
  checked: <how you verified the work against the task>
  or
  ORCHESTRATOR_WORKER_BLOCKED
  item: <ID>
  reason: <what stops you>
  needs: <the decision or access required>
```

## Reconcile

Each watch cycle, Continue, Report back: `<skill-dir>/scripts/status.sh <project-id> <plan-file>`
gives a JSON line per planned or group-tagged workspace: `group`, `inPlan`, `missing` (planned,
not in Paradev), `branch`, agent `state` (`working`, `idle`, `blocked`, `none`), terminal,
newest PR. Repair the plan first:

| Found | Do |
| --- | --- |
| Started, workspace `missing` | Follow its PR (open `in-review`, merged `done`), note "workspace gone"; no PR: `blocked`, "workspace missing". |
| Branch differs from plan | Store it, note the rename; PR lookups follow it. |
| `in-progress`, no workspace ID (crash after plan write) | Search as in collisions above: record it, else `queued`. |
| Tagged, not in plan | Ignore (maybe the user's) unless its branch matches a workspace-less item: adopt. |
| Tag `Blocked`/`Done`, plan disagrees | User moved it (plan-first excludes interruption): accept; `Blocked` reason "moved by user". |
| Other tag/state mismatch | Re-apply the state's group. |

## Watch and move

`<skill-dir>/scripts/wait-change.sh <project-id> <plan-file>` polls each minute; exits when an
agent state, group tag or PR (appears, merges, closes) changes or a workspace vanishes, else
after 20 minutes. Background it if the harness notifies on exit, else foreground with a short
timeout (`wait-change.sh <project-id> <plan-file> 120`). On exit: `plan.sh heartbeat` (stop on
exit 3), [reconcile](#reconcile), apply transitions, dispatch, print the
[status table](#status-table) if changed, restart unless finished.

Read: `superset terminals read --local --workspace <id> --terminal <tid>`. Send an answer or
message: `superset terminals send --local --workspace <id> --terminal <tid> --text "<answer>"`.

| Seen | Do |
| --- | --- |
| `in-progress`, PR exists | `in-review` now (not waiting for CI/reviews). Save the `ORCHESTRATOR_WORKER_DONE` block's `checked:` line to `checked`; not printed yet: re-read once `idle`. |
| `in-review`, agent `working` | User is giving feedback: `feedback` (not counted toward the limit). |
| `feedback`, reason "follow-up sent", agent `working` | Picked up: clear the reason. |
| `feedback`, agent `idle` | `in-review`, unless reason is still "follow-up sent" (not started): wait. |
| Agent `blocked` (Paradev's "needs input") | Read the screen; show the exact question; desktop-notify. User answers in the worker's chat (relay with send if in yours). Never answer permission prompts or decide scope/product for them. |
| `in-progress`, agent `idle`, no PR | Read the screen first. Background work running (e.g. its code-review subagents): don't nudge or count it; keep watching. `ORCHESTRATOR_WORKER_BLOCKED` printed or one follow-up already sent: `blocked` with its reason, free the slot, tell the user. Else one follow-up: finish and open the PR. |
| PR `MERGED` | `done`; unstarted dependents base on `main`; send follow-ups waiting on it. |
| PR `CLOSED` unmerged | `blocked`, "PR closed unmerged"; tell the user. |

**Dependency fails** (`blocked`, `skipped`, PR closed unmerged): queued dependents `waiting`,
"waiting on <ID>: <its reason>"; never start, re-plan or drop it yourself. Started (stacked)
ones run on, noted "built on <ID>, which is <state>" for the user to judge. Tell the user once;
they unblock it, tell you to drop it ("start #345 anyway"), or skip dependents; act in Continue,
or now if running. Recovered (`in-review`/`done`): `waiting` dependents back to `queued`.

### Follow-ups after a merge

If the user or a worker's summary says an `in-review` item owes work after a merge ("rebase
onto main and redo the config change once #341 lands"), record
`followUp: {"after": "<ID>", "message": "<what the worker must do>"}`. When `<ID>` merges: plan
`feedback`, reason "follow-up sent", `followUp` cleared; tag `In Progress`; send the message. The
reason keeps it from `in-review` while still `idle`; once worked and `idle` again it returns
like any `feedback`. If `<ID>` fails, keep `followUp`, tell the user.

From `In Review` the user owns the PR (CI, reviews, worker chat); don't read its comments or
checks. Nobody here approves or merges. Never archive, delete or close a
workspace, terminal or worktree; after creation only move its tag.

### Run finished

Once reconciled with nothing `queued`/`in-progress`: final table,
`superset notifications show "Orchestrator finished" --body "<k> in review, <b> blocked" --sound`,
stop the waiter. `status` stays `active` while any item is `in-review`, `feedback`, `blocked` or
`waiting`; `finished` (via `plan.sh write`) once all are `done` or `skipped`.

## Continue

`plan.sh claim` (`--takeover` on exit 4), reconcile, apply transitions and the user's decisions
on `waiting` items, dispatch, watch.

## Report back

Never starts, messages or nudges workers. Load the plan (none: use `status.sh <project-id>`),
reconcile, derive transitions. `plan.sh check` (read-only): `mine`/`finished` write; `stale`
`plan.sh claim --takeover` (say so in one line), write; `other`: show unwritten, name the
`owner`. Print the table and only what needs the user; list ready items with
"say 'orchestrator continue' to start them".

## Status table

One row per run item, plan order:

```markdown
| Item | Title | Group | Agent | PR |
| --- | --- | --- | --- | --- |
| #340 | Cache Pester in CI | In Review | done | #352 |
| #341 | Coverage floors | In Progress | running | — |
| #342 | Cancel stale CI | In Progress | waiting for input | — |
| #345 | Split backup job | Queued (after #341) | — | — |
| #346 | Backup retention | Waiting (#342 blocked) | — | — |
```

`Agent`: `running` (`working`), `waiting for input` (`blocked`, or asked), `done` (`idle`, part
finished), `—` (no worker). `Group`: sidebar group, `Queued (after <ID>)`, `Waiting (<reason>)`,
`Skipped`. Below it only: worker questions, `Blocked` reasons, dependency decisions, closed PRs,
missing workspaces, a just-in-review item's `checked` ("#340 checked: ran the CI workflow on a
fork; Pester cache hit on the second run").
