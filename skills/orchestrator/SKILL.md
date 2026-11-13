---
name: orchestrator
description: Act as the master agent that plans a batch of tracker issues (GitHub, Linear, Jira) or free-text work broken into tasks, and drives each one to its own pull request through Paradev (formerly Superset), each in its own worktree workspace with a worker agent running an implement skill, with a saved, resumable plan and workspaces moved between the In Progress, In Review, Done and Blocked sidebar groups as their PRs appear and merge. Also answers "orchestrator report back" with a short status table, "orchestrator continue" to resume a run, and "orchestrator close" to end one. Use whenever the user says "orchestrate", "orchestrate these issues", "orchestrate 340 to 345", "orchestrate and work", "be the master agent", or "orchestrator report back" / "status" / "continue" / "close", even if they don't mention Paradev. Not for small ad-hoc fan-outs with no tracker, no PRs and no need to resume (e.g. "run these 3 refactors in parallel and tell me when done"): those belong to `superset:orchestrate`.
compatibility: Needs bash, jq, git, the GitHub CLI (gh, signed in) and the Paradev CLI (superset, paradev or pdev; any one of them) with this machine's host running. Pull requests must live on GitHub.
model: sonnet
effort: low
argument-hint: items like "340-343, 345 onwards", "ENG-12 ENG-15", free text, "report back", "continue", or "close"
---

# Orchestrator

You coordinate (plan, dispatch, watch, move groups, report); never implement, even a little:
each item gets its own worker, workspace, branch and PR. Coordinating is cheap: Claude Code
picks a small or mid-sized model; elsewhere, if you're top-tier, say once in one line that a
smaller one would do (`codex -m <small model>`, `gemini -m <flash model>`).

`superset`, `paradev`, `pdev` are one CLI (this file writes `superset`; use whichever is on PATH;
its `--help` is authoritative). `<skill-dir>` is this file's folder (usually
`~/.agents/skills/orchestrator`). Run scripts inside the repo.

## Modes

Small ad-hoc fan-outs (no tracker, no PRs, no need to resume, e.g. "run these 3 refactors in parallel
and tell me when done") belong to `superset:orchestrate`; point the user there instead of starting a run.
Free-text work stays here, since it still produces one PR per task.

| The user says | Mode | Start/message workers? |
| --- | --- | --- |
| items to work on ("orchestrate 340-343") | **Run** | yes |
| "orchestrator continue" / "resume" | **Continue**: pick up the existing run | yes |
| "orchestrator report back" / "status" | **Report back** | no, never |
| "orchestrator close" | **[Close](#close)**: end the run with items open | no |

## Preflight

All modes; stop with a clear message on failure:

1. `bash`, `jq`, `git`, `gh`, CLI on PATH; `gh auth status`, `superset auth whoami --json` pass.
   `whoami` passes but host calls (`superset snapshot --json`) fail: retry with network/sandbox
   escalation, then point to `superset:doctor`. Never start or restart the host yourself.
2. Repo on GitHub: `gh repo view --json nameWithOwner`.
3. **Project ID**: repo-named project in `superset projects list --json`; scripts take it
   first, scoping them to its workspaces.
4. **Plan file**: `<skill-dir>/scripts/plan.sh path` gives `~/.agents/orchestrator/<owner>-<repo>.json`.
5. Run/Continue: [worker agents](#worker-agents-and-auto-approval); record `presets` per harness
   (Continue: reuse the plan's `autoOnly` answer, never re-ask).
6. Not Close: **group map**: the plan's `groups`, else `<skill-dir>/scripts/groups.sh <project-id>`
   (exit 2, unsaved: show `groups.sh <project-id> suggest`, ask once, `groups.sh <project-id> save
   '<json>'`); keep it in the plan's `groups`. `groups.sh <project-id> check '<map>'` exit 5 names
   tags Paradev no longer has: ask once, before any tag move.

## Plan file and ownership

One **active run** per repo, owned by an orchestrator's terminal (`$SUPERSET_TERMINAL_ID`) with
a heartbeat. `plan.sh claim` before Run/Continue/Close:

- `free`: new plan (the last run, if finished, moved to `~/.agents/orchestrator/history/`). A
  following `carryOver` line lists a closed run's open items: offer once to re-import them.
- `resumed`: yours; a Run adds items to it.
- Exit 3: a live owner (fresh heartbeat, its terminal runs an agent). Start nothing, name its
  terminal, offer a report back. If the user says take over: `claim --takeover --force`.
- Exit 4: stale. Continue takes over (`claim --takeover`); Run asks first.

Say any takeover in one line. Write **only** via `plan.sh write <file>` (whole plan in a scratch
file): it locks, refuses if another owns the run, stamps owner and heartbeat, swaps atomically.
`plan.sh heartbeat` each watch cycle. `write`/`heartbeat` exit 3 (taken over): stop, tell the user.

Schema and field meanings: [references/plan-schema.md](references/plan-schema.md). `state` values:
`queued`, `in-progress`, `in-review`, `feedback`, `done`, `blocked`, `waiting` (dependency failed),
`skipped`; `reason` explains the last three.

Facts (workspace, branch, agent and PR state) come from Paradev and GitHub; intent (items,
dependencies, skill, agent, why waiting/blocked/skipped) from the plan. Write the plan, then the
tag, so an interruption leaves the plan ahead for reconcile to re-tag. Status tables use only
reconciled state.

## Groups

Tags file workspaces into sidebar folders; each workspace has exactly one. Every `--tag` uses the
group's tag from the plan's `groups` (lookups ignore case). Move by replacing:
`superset workspaces update <id> --local --tag "<In Review's tag>"`.

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
4. **Free text → tasks** `T1`, `T2`, … (one reviewable PR each; title, dependencies). Each
   task keeps two parts: `ask`, the slice of the user's request it covers, **verbatim** (never
   reworded or widened), and `notes`, your build notes (context, what stays out of scope), adding
   no work. Anything you'd add beyond the ask (hardening, a sweep, a broader goal) goes in
   `extras`, not `notes`. Show each task with its `ask` quoted in full; **wait for the go**
   (biggest judgment call), asking only that.
   Tasks stay plan-only; after the go, separately (never in one question), offer once to file
   them; file only on yes.
5. **Dependencies**: explicit ("blocked by", "depends on", "after", parent/child) and conflicts
   (clearly same files, migration, config or schema; smaller first). Outside the run:
   closed-as-completed is met; open-not-in-run or skipped makes the dependent `waiting`, naming it.
6. **Waves** ≤ parallel limit: independent first, preferring unblockers.
7. **Save** via `plan.sh write`; `runId` = start time `YYYYMMDD-HHMM`.
8. **Show** a short table (item, title, wave, depends on, skill, agent) and dispatch at once;
   ask instead on a dependency cycle or if two items might be one PR. A harness with
   [auto only](#worker-agents-and-auto-approval) and no `autoOnly` answer yet: don't dispatch its
   items; put the question below the table and dispatch on the reply.

## Worker agents and auto-approval

Workers stall on prompts without auto-approve. In `superset agents list --local --json`
(`id`, `presetId`, `label`, `command`, `args`), an **auto instance** has the harness's
`presetId` and a `label` with `(auto)` ("Claude (auto)"), or `claude` `--permission-mode auto`
(`args` `["--permission-mode", "auto"]` or `["--permission-mode=auto"]`), or `codex`
`--approve-for-me`. Use the **regular preset** (user approves each prompt) if:

- the user said `with prompts`;
- the author lacks write access
  (`gh api repos/<owner>/<repo>/collaborators/<login>/permission -q .permission`): untrusted text
  steering a self-approving agent;
- it touches deployment, releases, infrastructure, credentials, or real-data migrations.

The regular preset may itself auto-approve (a plain Claude preset showed "auto mode on"):
check its `command`/`args` against the rules above, and the screen once started. If so, warn
the user, ask for a prompting preset, and hold those items until given one.

Record `preset` per item and, per harness, which kinds exist in `presets`; mark regular items in
the plan table.

**Auto only**: a harness has an auto instance but no regular one (a single preset renamed
"Claude (auto)", say). Don't hold the items to ask later. Say so once in the plan summary, run
every item of that harness with the auto instance, and list the items the rules above would run
with prompts (deployment, releases, infrastructure, credentials, real-data migrations, no write
access, `with prompts`), each with its reason. Ask one question, in the same message as the go:
run them with auto too, or hold them until a prompting preset exists? Store the answer in
`autoOnly` (`accepted`: those items get `preset` `auto`; `declined`: they stay `queued`, reason
"needs a prompting preset"); Continue and later Runs don't ask again. With no such items, still
note the case in one line and set `accepted`. A regular instance appearing later: Continue uses
it for the items the rules name; `autoOnly` stays as recorded.

No auto instance for a harness: regular preset for its items; list each instance's `label`,
`command`, `args`; offer once to create `Claude (auto)` (`claude --permission-mode auto`; Codex:
`codex --approve-for-me`). Only on yes: with the CLI if `superset agents --help` offers it, else
the user adds it in Paradev's agent settings.

## Dispatch

Start an item once each dependency has a PR (or is met) and fewer than the limit are
`in-progress` (`feedback` excluded); never stack on one in `feedback`: wait for `in-review` or
merge.

**Squash-merge repos**: a stacked branch still carries its parent's original commits, so it
conflicts once the parent squash-merges. Check once per run with `gh repo view --json
squashMergeAllowed,mergeCommitAllowed,rebaseMergeAllowed` (and the base branch's ruleset, if
`gh api` shows one restricting methods). When squash is the only method, don't stack: a dependent
waits for its parent to merge, then starts on `main`, unless the user says the dependency is only
a soft ordering (then start it on `main` at once). Otherwise stack; the worker prompt carries the
rebase recipe.

Run `<skill-dir>/scripts/dispatch.sh <project-id> <plan-file> <ID> [--base <branch>] [--preset <id>]`
inside the repo. It does the whole sequence and stops at the first failing step:

1. **Branch**: `issue-340-<slug>`, lowercase key (`eng-123-<slug>`), or `task-<runId>-t1-<slug>`
   (free text); `<slug>` is at most 4 words, branch ≤ 60 characters. Taken on origin
   (`git ls-remote --heads origin <branch>`), locally, in the plan, or by a PR
   (`gh pr list --head <branch> --state all`): appends `-2`, `-3`, …
2. **Plan**: the item becomes `in-progress` with the branch (via `plan.sh write`).
3. **Workspace**: `superset workspaces create` with the [worker prompt](#worker-prompt) below
   (built by the script, never echoed), the plan's In Progress tag, `--skip-branch-prefix`, no
   `--model`. On failure the item goes back to `queued`, or to `blocked` with the error as
   reason on the second failure (`dispatchFailures`).
4. **Record**: workspace ID, Paradev's reported branch, terminal ID (`create`'s
   `agents[].sessionId`, else the snapshot's terminal with `agent` set).

`--base`: the dependency's unmerged branch for a stacked item (the prompt gets the stacked line),
else omit for the default branch. `--preset`: the auto instance ID or preset ID (default: the
item's `agent`). Output: one `dispatched …` line, or `dispatch <ID> failed at <step>: …` (exit 1);
after a `rollback` or `record` failure, fix the plan by hand before going on. Dispatch nothing by
hand.

### Worker prompt

`dispatch.sh` builds and sends it; change it in the script. Contents and the
DONE/BLOCKED/WAITING report format: [references/worker-prompt.md](references/worker-prompt.md).

## Reconcile

At the start of each watch cycle, Continue and Report back, run
`<skill-dir>/scripts/status.sh [--compact] <project-id> <plan-file>` (`--compact`, a line per
workspace, in watch cycles; its header documents the fields): group, `missing`, branch, agent
`state` (`working`, `idle`, `blocked`, `stalled`, `none`) and `reason`, the worker block, PR.
Repair the plan before applying any transition:

| Found | Do |
| --- | --- |
| Started, workspace `missing` | Follow its PR (open `in-review`, merged `done`), note "workspace gone"; no PR: `blocked`, "workspace missing". |
| Branch differs from plan | Store it, note the rename; PR lookups follow it. |
| Agent terminal differs from plan | Store the terminal, `agent`, `preset` if known; note "worker replaced". |
| `in-progress`, no workspace ID (crash after plan write) | `superset workspaces list --local --project <id> --search <branch> --json`: record a found workspace, else `queued`. |
| Tagged, not in plan | Ignore (maybe the user's) unless its branch matches a workspace-less item: adopt. |
| Tag `Blocked`/`Done`, plan disagrees | User moved it (plan-first excludes interruption): accept; `Blocked` reason "moved by user". |
| Other tag/state mismatch | Re-apply the state's group. |

## Watch and move

`<skill-dir>/scripts/wait-change.sh <project-id> <plan-file>` polls each minute and wakes within seconds when a
worker settles (`superset agents wait`, where the CLI has it); exits with a
one-line summary when a plan (or adoptable) workspace's agent state, tag or PR changes or it
vanishes, else after 20 minutes. Background it if the harness notifies on exit, else
foreground with a short timeout (`wait-change.sh <project-id> <plan-file> 120`). On exit:
`plan.sh heartbeat` (stop on exit 3), [reconcile](#reconcile), apply transitions, dispatch, print
the [status table](#status-table) if changed, restart unless finished. Exit non-zero (checks
failed until timeout): check connectivity, reconcile, restart.

Read (worker block from status.sh first): `superset terminals read --local --workspace <id>
--terminal <tid> --max-lines 60`. Send: `superset terminals send … --text "<answer>"`.
**Declared wait**: an `idle` row whose latest worker block is `waiting`
(`ORCHESTRATOR_WORKER_WAITING`: its own background work, e.g. code-review subagents, or something
external that clears on its own) is busy, whatever the table below says for `idle`: skip it (no
transition, no follow-up, not counted as done), without reading the screen. A later DONE or BLOCKED
block replaces the wait. A **stale** wait (`stale`: the same wait still latest after 30 minutes)
gets a screen check each cycle: still running, skip it; nothing running, treat it as no declared
wait (the rows below apply). Waiting is not blocked: only a BLOCKED block (or a row below) needs you or
the user. Fallback, only for an `idle` row with no declared wait (no worker block, or in `feedback`
only an earlier round's): read the screen first; background work still running there is skipped
the same way.

| Seen | Do |
| --- | --- |
| `in-progress`, PR exists | Once `checked:` is out (or `idle`): save it, [acceptance check](#acceptance-check), `in-review` (not waiting for CI). |
| `in-review`, agent `working` | User is giving feedback: `feedback` (not counted toward the limit). |
| `feedback`, reason "follow-up sent" or "acceptance follow-up", agent `working` | Picked up: clear the reason. |
| `feedback`, agent `idle` | Reason still set (not started): wait. Else `in-review`; after an acceptance follow-up, re-compare once, keeping a remaining gap. |
| Agent `stalled` | Read the screen; tell the user, suggesting a new worker in the same workspace. Never restart it yourself. |
| Agent `blocked` with a `reason` (fatal banner: usage limit, expired sign-in…) | `blocked` with that reason, free the slot, tell the user. |
| Agent `blocked` (Paradev's "needs input") | Read the screen; show the exact question; desktop-notify. User answers in the worker's chat (relay with send if in yours). Never answer permission prompts or decide scope/product for them. |
| `in-progress`, agent `idle`, no PR, no declared wait | `ORCHESTRATOR_WORKER_BLOCKED` printed or one follow-up already sent: `blocked` with its reason, free the slot, tell the user. Else one follow-up: finish and open the PR. |
| PR `MERGED` | `done`; unstarted dependents base on `main`; send follow-ups waiting on it. |
| PR `CLOSED` unmerged | `blocked`, "PR closed unmerged"; tell the user. |
| Stacked item's PR `conflicting` (status.sh: `CONFLICTING (base <parent branch>)`) and its parent is `done` | Send the worker, unasked, the rebase follow-up: `git fetch origin && git rebase --onto origin/main <parent tip> HEAD`, `git push --force-with-lease`, remove "merge <parent> first" from the PR description. `feedback`, reason "follow-up sent". Once per item; still `CONFLICTING` after it, tell the user. |

**Dependency fails** (`blocked`, `skipped`, PR closed unmerged): queued dependents `waiting`,
"waiting on <ID>: <its reason>"; never start, re-plan or un-depend them yourself. Started
(stacked) ones run on, noted "built on <ID>, which is <state>". Tell the user once; they unblock
it, drop it ("start #345 anyway") or skip dependents. Recovered: `waiting` dependents `queued`.

### Acceptance check

Once per item, before `in-review`: compare `checked` with the issue's acceptance criteria (a
free-text task: its `ask` only, never `notes` or `extras`; an older plan's `text`) and the PR's
files (`gh pr view <n> --json files -q '.files[].path'`: names and counts, never code). If it
plainly covers less (whole file groups unmentioned, e.g. 4 of 24 screenshots, or criteria
unaddressed), or `checked` says nothing about the PR's checks (CI not mentioned, or "not
checked"), send ONE follow-up naming the gap (for CI: wait for `gh pr checks <n> --watch
--fail-fast` and report the result): `feedback`, reason "acceptance follow-up",
`acceptance` the gap. Else `acceptance` "ok". Never a second round; a gap left is noted under the
table for the human. Work the PR lacks that the `ask` never asked for is not a gap: never send it to
the worker; keep it in `extras` and note it under the table as possible follow-up work.

### Follow-ups after a merge

If the user or a worker's summary says an `in-review` item owes work after a merge ("redo the
config change once #341 lands"), record `followUp: {"after": "<ID>", "message": "<what to do>"}`.
When `<ID>` merges, **send a follow-up**: plan `feedback`, reason "follow-up sent", `followUp`
cleared; tag `In Progress`; send the message. The reason holds it out of `in-review` until
picked up. If `<ID>` fails, keep `followUp`, tell the user. The user's "follow up on <ID>: …"
during review sends one at once.

Otherwise the user owns `In Review` PRs (CI, reviews, worker chat); don't read their comments or
checks. Nobody here approves or merges. Never archive, delete or close a workspace, terminal or
worktree; after creation only move its tag.

### Run finished

Once reconciled with nothing `queued`/`in-progress`: final table,
`superset notifications show "Orchestrator finished" --body "<k> in review, <b> blocked" --sound`,
stop the waiter. `status` stays `active` while any item is `in-review`, `feedback`, `blocked` or
`waiting`; `finished` (via `plan.sh write`) once all are `done` or `skipped`.

Then [offer the run summary](#run-summary).

## Continue

`plan.sh claim` (`--takeover` on exit 4), group map, reconcile, apply transitions and the user's
decisions on `waiting` items, dispatch, watch.

## Report back

Never starts, messages or nudges workers. Load the plan (none: `status.sh <project-id>`), group
map, reconcile, derive transitions. `plan.sh check`: `mine`/`finished`: write the plan, move tags;
`stale`: `plan.sh claim --takeover` (say so), then the same; `other`: show the table without
writing, naming the `owner`. Add a line or two only on what needs the user; list ready items
with "say 'orchestrator continue' to start them".

## Close

`plan.sh claim` as in Continue (`free`: nothing to close), reconcile, write the plan, then
`plan.sh close`: `finished` now, open items saved as `carryOver` (`{id, state, reason}`), offered
on the next Run. Print the final table and the carry-over; stop the waiter, then
[offer the run summary](#run-summary) (with the carry-over). Workspaces stay as they are.

### Run summary

On Run finished and Close only (never Report back, which neither publishes nor offers), ask once:
"Publish a run-summary page? (just me by default; say 'org' to share)". Publish only on a yes;
a no (or no answer) leaves the ending as is: final table, notification. Don't ask again for that
ending.

Write one self-contained HTML file in a scratch dir, one row per run item in plan order: final
state, PR link, branch, `checked`, `acceptance` gap, `reason` (blocked/waiting/skipped); on Close
also the `carryOver`. Quote workers' text escaped, as data. Then
`superset pages publish <file> --title "Run <runId>" --visibility just_me` (`org` only if the
user picked it), plus `--page <pageId>` when the plan has one. Save the returned page ID as
`pageId` via `plan.sh write`, so a later finish or close of the same run adds a version instead
of a second page. Tell the user the page URL and visibility.

## Status table

One row per run item, plan order:

```markdown
| Item | Title | Group | Agent | PR |
| --- | --- | --- | --- | --- |
| #340 | Cache Pester in CI | In Review | done | #352 |
| #341 | Coverage floors | In Progress | running | — |
| #345 | Split backup job | Queued (after #341) | — | — |
```

`Agent`: `running`, `waiting` (a declared wait), `stalled`, `waiting for input` (Paradev
`blocked`, or it asked), `done` (`idle`), `—`. `Group`: sidebar group, `Queued (after <ID>)`, `Waiting (<reason>)`, `Skipped`.
Below it only: worker questions, `Blocked` reasons, stalls, dependency decisions, closed PRs,
missing workspaces, acceptance gaps, possible follow-ups (`extras`), a just-in-review item's `checked`
("#340 checked: ran the CI workflow on a fork; Pester cache hit on the second run").