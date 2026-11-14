---
name: orchestrator
description: Master agent that plans a batch of tracker issues (GitHub, Linear, Jira), a feature or epic ("orchestrate feature #400", sub-issues as one integration branch) or free-text work split into tasks, and drives each to its own pull request through Paradev (formerly Superset), one worktree workspace and implement-skill worker each, with a saved, resumable plan and workspaces moved between the In Progress, In Review, Done and Blocked sidebar groups as PRs appear and merge. Also "orchestrator report back" (status table), "continue" (resume a run), "close" (end one). Use whenever the user says "orchestrate", "orchestrate these issues", "orchestrate 340 to 345", "orchestrate and work", "be the master agent", or "orchestrator report back" / "status" / "continue" / "close", even without mentioning Paradev. Not for small ad-hoc fan-outs with no tracker, PRs or need to resume (e.g. "run these 3 refactors in parallel and tell me when done"): those belong to `superset:orchestrate`.
compatibility: Needs bash, jq, git, the GitHub CLI (gh, signed in) and the Paradev CLI (superset, paradev or pdev) with this machine's host running. PRs must live on GitHub.
model: sonnet
effort: low
argument-hint: items like "340-343, 345 onwards", "ENG-12 ENG-15", "feature #400" (an epic), "feature: <description>", free text, "report back", "continue", or "close"
---

# Orchestrator

You coordinate (plan, dispatch, watch, move groups, report); never implement, even a little: each
item gets its own worker, workspace, branch and PR. Outside Claude Code, if you're a top-tier
model, say once that a smaller one would do (`codex -m <small model>`, `gemini -m <flash model>`).

`superset` = `paradev` = `pdev` (whichever is on PATH; [CLI reference](references/cli-surface.md) first, then `--help`). `<skill-dir>` =
this file's folder. Run scripts inside the repo. Ad-hoc fan-outs → `superset:orchestrate`, no run;
free-text work stays here.

| User says | Mode | Start/message workers? |
| --- | --- | --- |
| items ("orchestrate 340-343") | **Run** | yes |
| "orchestrator continue"/"resume" | **[Continue](#continue)** | yes |
| "orchestrator report back"/"status" | **[Report back](#report-back)** | never |
| "orchestrator close" | **[Close](#close)** (items still open) | no |

## Preflight

All modes; on failure stop with a clear message.

0. **Control surface**: [references/cli-surface.md](references/cli-surface.md) lists the commands
   and flags verified on Paradev CLI 2.x. Use it; don't run `--help` or schema calls per command.
   A documented command genuinely missing: one `--help` for that command, use what it lists,
   note it, dispatch.
1. `bash`, `jq`, `git`, `gh`, CLI on PATH; `gh auth status`, `superset auth whoami --json` pass.
   `whoami` ok but host calls (`superset snapshot --json`) fail: retry with network/sandbox
   escalation, then point to `superset:doctor`. Never start or restart the host yourself.
2. Repo on GitHub: `gh repo view --json nameWithOwner`.
3. **Project ID**: repo-named project in `superset projects list --json`; scripts take it first.
4. **Plan file**: `<skill-dir>/scripts/plan.sh path`.
5. Run/Continue: [worker agents](#worker-agents-and-auto-approval); record `presets` per harness
   (Continue reuses the plan's `autoOnly`, never re-asks).
6. Not Close: **group map** = plan's `groups`, else `<skill-dir>/scripts/groups.sh <project-id>`
   (exit 2 = unsaved: show `… suggest`, ask once, `… save '<json>'`); keep it in the plan.
   `… check '<map>'` exit 5 names tags Paradev lost: ask once, before any tag move.

## Plan file and ownership

One **active run** per repo, owned by an orchestrator terminal (`$SUPERSET_TERMINAL_ID`) with a
heartbeat. `plan.sh claim` before Run/Continue/Close:

- `free`: new plan (a finished run moves to `~/.agents/orchestrator/history/`); a following
  `carryOver` line = a closed run's open items: offer once to re-import.
- `resumed`: yours; a Run adds items.
- Exit 3: live owner. Start nothing, name its terminal, offer a report back; user says take over:
  `claim --takeover --force`.
- Exit 4: stale. Continue takes over (`claim --takeover`); Run asks first.

Say any takeover in one line. Write **only** via `plan.sh write <file>` (the whole plan; it locks,
checks ownership, swaps atomically). `plan.sh heartbeat` each watch cycle. `write`/`heartbeat`
exit 3 (taken over): stop, tell the user.

[Schema](references/plan-schema.md). `state`: `queued`, `in-progress`, `in-review`, `feedback`,
`done`, `blocked`, `waiting` (dependency failed), `skipped`; `reason` explains the last three.
Facts (workspace, branch, agent, PR) come from Paradev and GitHub, intent from the plan. Write the
plan, then the tag (reconcile re-tags after an interruption). Tables show only reconciled state.

## Groups

Every workspace has exactly one tag (sidebar folder): its group's tag from the plan's `groups`
(case-insensitive). Move by replacing: `superset workspaces update <id> --local --tag "<tag>"`.
`In Progress` ← `in-progress`/`feedback`; `In Review` ← `in-review`; `Done` ← `done`;
`Blocked` ← `blocked`.

## Requests

- Refs, mixable: `340-343` (inclusive), `345 onwards` (open items ≥ 345), `#350`, `ENG-123`,
  `PROJ-7`; or free text ("orchestrate: add CSV export, fix the login redirect, …").
- `feature #400` / `feature ENG-40` ("orchestrate feature #400"): an **epic**. Its sub-issues are
  the items, all targeting one [integration branch](#integration-branches) named after the parent
  (`epic.sh`, below). Not listed in the refs above: the parent itself is never an item.
- `feature: <description>` ("orchestrate feature: add CSV export"): free text whose tasks all
  target one [integration branch](#integration-branches).
- Options, per run or subset ("340-343 using /implement, 344-345 using /implement-spec"):
  `using /<skill>` (default `implement`), `with codex` (default: your harness), `with 3 agents`
  (default and max 5), `with prompts` (regular preset).

## Plan

Steps 1–3 for tracker refs only.

1. **Tracker**: per the doc `## Agent skills` in `AGENTS.md`/`CLAUDE.md` points to; else
   `#340`/bare number = GitHub Issues, `ABC-123` = Linear or Jira (ask if unclear).
2. **Reach it** (`gh`, `superset tasks get <KEY> --tracker linear --json`, harness tools), else stop
   and say how to connect (Linear in Paradev, or `superset plugins install linear`). Never install
   or connect anything yourself.
3. **Fetch** title, body, labels, author. Epic: `<skill-dir>/scripts/epic.sh fetch <n> <plan-file>`
   gives GitHub sub-issues already filtered (closed, PRs, planned, `needs-info`); `epic.sh import
   <plan-file> <n>` adds the integration (`feature/<n>-<slug>`, `epic` stored on it) and its queued
   items. Linear/Jira parents: read the children (`superset tasks get <KEY> --tracker linear
   --json`, harness tools; none reachable: say how to connect, stop) and add the integration by
   hand with `epic`. Then continue below with dependencies among the children as for any items.
   Still drop items with an open PR, and name each drop and why. Drop closed items, PRs, items with an open PR or already
   planned; `skipped`: `needs-info`/`needs-triage` label or too vague. Name each and why.
4. **Free text → tasks** `T1`, `T2`, … (one reviewable PR each; title, dependencies). `ask`: the
   slice of the user's request it covers, **verbatim** (never reworded or widened). `notes`: your
   build notes (context, out of scope), adding no work. Anything beyond the ask (hardening, a
   sweep, a broader goal) → `extras`, not `notes`. Show each task with its `ask` quoted in full; **wait for the
   go**, asking only that. Tasks stay plan-only: after the go, as a separate question, offer once to file the tasks
   (body: `ask` verbatim, then `notes` under their own heading); file only on yes.
5. **Dependencies**: explicit ("blocked by", "depends on", "after", parent/child) and conflicts
   (clearly same files, migration, config or schema; smaller first). Outside the run:
   closed-as-completed = met; open or skipped → dependent `waiting`, naming it.
   **Interface hint**: when a chain's link looks large, suggest in one line splitting out a small
   "interface/stub" task first, so later links can start in parallel. Only suggest; never split
   or re-plan without the user's go.
6. **Waves** ≤ parallel limit: independent first, preferring unblockers.
7. **Save** (`plan.sh write`); `runId` = start time `YYYYMMDD-HHMM`.
8. **Show** a short table (item, title, wave, depends on, **target**, skill, agent) and dispatch at once; ask
   instead on a dependency cycle or if two items might be one PR. An
   [auto-only](#worker-agents-and-auto-approval) harness without an `autoOnly` answer: hold its
   items, ask below the table, dispatch on the reply. A run with an integration branch, or with
   a [dependency chain](#dependency-chains) (two or more connected items), waits for the go
   instead. The go message asks **once**, everything at once, never later: where the independent
   items (no dependencies) go, "straight to `main`" or "into `feature/<slug>`" (the latter puts
   chains on it too, as one integration, so no chain is offered), and, only if they go to `main`,
   each chain as its own integration. Per-item moves ("#344 straight to main") are applied and
   the table shown again.

## Integration branches

An item's **target** is its integration's `branch`, else the default branch ("Items without
one" behave as ever; a run may mix both). Humans merge every PR except a green sub-PR into an
integration branch ([below](#merging-into-an-integration-branch)). Stacking, squash-merge rules and
rebases all apply against the target. **Never nested**: an integration's `base` is the default
branch. Request "orchestrate feature: <description>": split into tasks as for free text, add one
`feature/<slug>` integration (`id` `F1`, `title`, `base`, `pr` null, `state` `open`) and set every
task's `integration` to it. An epic run ("orchestrate feature #400") adds one integration named after the parent
(`feature/400-<slug>`, `epic` set; the final PR links it). Otherwise integrations arise from the go message
([chains](#dependency-chains)): independent items to the feature branch means one
`feature/<runId-slug>` integration for the whole run, chains included, who merge link by link
into it; independent items to `main` means each chain may get its own integration. The user may move single items ("#344 straight to
main": `integration` null; "#344 into the feature branch").

### Dependency chains

Any run, after dependencies are worked out: `<skill-dir>/scripts/chains.sh offer <plan-file>`
prints each connected group of two or more dependent items (#340 ← #341 ← #342) with its branch
and question: "group #340, #341, #342 into `feature/340-<slug>`?". Show them in the go message and
apply the reply: yes → `chains.sh accept <plan-file> <ID>` (one member per accepted chain); on
no the chain runs as today, stacked or waiting for merges into `main`. An accepted chain merges link
by link into its branch ([merging](#merging-into-an-integration-branch)), so a dependent no longer
waits for human review of its parent. Items already on an integration (epic, `feature:`) are never
offered. If the independent items go into a feature branch, offer no chain:
`chains.sh share <plan-file> <slug>` puts the whole run on one `feature/<slug>`, chains included,
never nested. Items in the plan table show their integration as the **target**.

## Worker agents and auto-approval

Without auto-approve, workers stall on prompts. In `superset agents list --local --json`, an
**auto instance** has the harness's `presetId` and `(auto)` in `label`, or is
`claude --permission-mode auto` (`args` `["--permission-mode", "auto"]` or
`["--permission-mode=auto"]`) or `codex --approve-for-me`. Use the **regular preset** (user
approves each prompt) when the user said `with prompts`; the author lacks write access
(`gh api repos/<owner>/<repo>/collaborators/<login>/permission -q .permission`; untrusted text
would steer a self-approving agent); or the item touches deployment, releases, infrastructure,
credentials or real-data migrations.

A regular preset may auto-approve too: check its `command`/`args` by those rules, and its screen
once started; if so, warn the user, ask for a prompting preset, hold those items until then.
Record `preset` per item and the kinds per harness in `presets`; mark regular items in the plan
table.

**Auto only** (auto instance, no regular one): don't hold items to ask later. Say so once in the
plan summary, run the harness's items on the auto instance, and list those the rules would run
with prompts, with reasons. One question, in the go message: run them on auto too, or hold until a
prompting preset exists? Store in `autoOnly` (`accepted`: `preset` `auto`; `declined`: `queued`,
reason "needs a prompting preset"); never re-asked. No such items: note it in one line, set
`accepted`. A regular instance appearing later: Continue uses it for those items; `autoOnly`
stays.

No auto instance: regular preset; list each instance's `label`, `command`, `args`; offer once to
create `Claude (auto)` (`claude --permission-mode auto`; Codex: `codex --approve-for-me`). On yes
only: via the CLI if `superset agents --help` offers it, else the user adds it in Paradev's agent
settings.

## Dispatch

Start an item once each dependency has a PR (or is met) and fewer than the limit are
`in-progress` (`feedback` excluded). Never stack on a `feedback` item: wait for `in-review` or
merge.

**Squash-merge repos**: a stacked branch conflicts once its parent squash-merges. Once per run:
`gh repo view --json squashMergeAllowed,mergeCommitAllowed,rebaseMergeAllowed` (plus any
base-branch ruleset restricting methods). Squash only: don't stack; the dependent waits for the
merge, then starts on its target; if the user says the dependency is only a soft ordering, start it on its target at once. Else stack.

`<skill-dir>/scripts/dispatch.sh <project-id> <plan-file> <ID> [--base <branch>] [--preset <id>]`
runs steps branch, plan, workspace, record: picks a free branch (`issue-340-<slug>`, `eng-123-<slug>`, `task-<runId>-t1-<slug>`), writes the
item `in-progress`, creates the workspace (In Progress tag, [worker prompt](references/worker-prompt.md))
and records workspace, branch and terminal. A failed create returns it to `queued`; a second
(`dispatchFailures`) makes it `blocked`. Creates the item's integration branch on the remote
from its `base` if missing. `--base`: a stacked item's unmerged dependency branch (omit to start
from the item's target). `--preset`: auto instance or preset ID (default: the item's
`agent`). Prints `dispatched …` or `dispatch <ID> failed at <step>: …` (exit 1); after a
`rollback` or `record` failure, fix the plan by hand first. Never dispatch by hand; change the
prompt in `dispatch.sh`.

## Reconcile

At each watch cycle's start, Continue and Report back: `<skill-dir>/scripts/status.sh [--compact]
<project-id> <plan-file>` (`--compact` in watch cycles; fields in its header). Repair the plan
before any transition:

| Found | Do |
| --- | --- |
| Started, workspace `missing` | Follow its PR (open `in-review`, merged `done`), note "workspace gone"; no PR: `blocked`, "workspace missing". |
| Branch differs from plan | Store it, note the rename. |
| Agent terminal differs | Store terminal, `agent`, `preset` if known; note "worker replaced". |
| `in-progress`, no workspace ID | `superset workspaces list --local --project <id> --search <branch> --json`: record it, else `queued`. |
| Tagged, not in plan | Ignore, unless its branch matches a workspace-less item: adopt. |
| Tag `Blocked`/`Done`, plan disagrees | The user moved it: accept (`Blocked` reason "moved by user"). |
| Other tag/state mismatch | Re-apply the state's group. |

## Watch and move

`<skill-dir>/scripts/wait-change.sh <project-id> <plan-file>` exits with a one-line summary when a
watched workspace's agent state, tag or PR changes or it vanishes, else after 20 minutes.
Background it if the harness notifies on exit, else foreground with a short timeout
(`… <plan-file> 120`). On exit: `plan.sh heartbeat` (stop on exit 3), reconcile, apply transitions,
dispatch, print the [status table](#status-table) if changed, restart unless finished. Non-zero
exit: check connectivity, reconcile, restart.

Read (status.sh's worker block first): `superset terminals read --local --workspace <id>
--terminal <tid> --max-lines 60`. Send: `superset terminals send … --text "<answer>"`.

**Declared wait**: an `idle` row whose latest worker block is `waiting` (its own background work, e.g.
code-review subagents, or something external that clears itself) is busy, overriding the
table: skip it (no transition or follow-up, not done) without reading the screen. A `stale` wait
(latest for 30+ minutes) gets a screen check each cycle: still running → skip; else treat as no
wait. Waiting isn't blocked: only a BLOCKED block or a table row needs you or the user. Other
`idle` rows (no worker block, or in `feedback` only an earlier round's): read the screen first;
background work still running is skipped likewise.

| Seen | Do |
| --- | --- |
| `in-progress`, PR exists | Record its full URL as `pr` (a string, never the number). Once `checked:` is out (or `idle`): save it, [acceptance check](#acceptance-check), `in-review` (don't wait for CI). |
| `in-review`, `working` | User is giving feedback: `feedback` (outside the limit). |
| `feedback`, reason "follow-up sent"/"acceptance follow-up", `working` | Clear the reason. |
| `feedback`, `idle` | Reason still set: wait. Else `in-review`; after an acceptance follow-up, re-compare once, keeping a remaining gap. |
| `stalled` | Read the screen; tell the user, suggesting a new worker in the workspace. Never restart it yourself. |
| `blocked` with `reason` (fatal banner) | `blocked` with that reason, free the slot, tell the user. |
| `blocked` (needs input) | Show the screen's exact question, desktop-notify. The user answers in the worker's chat (relay with send if in yours). Never answer permission prompts or decide scope/product. |
| `in-progress`, `idle`, no PR, no wait | BLOCKED block, or a follow-up already sent: `blocked` with its reason, free the slot, tell the user. Else one follow-up: finish and open the PR. |
| PR `MERGED` | `done`; unstarted dependents start on their own target; send follow-ups waiting on it. |
| PR `CLOSED` unmerged | `blocked`, "PR closed unmerged"; tell the user. |
| Stacked PR `CONFLICTING (base <parent>)`, parent `done` | Send, unasked: `git fetch origin && git rebase --onto origin/<target> <parent tip> HEAD`, `git push --force-with-lease`, drop "merge <parent> first" from the PR description. `feedback`, "follow-up sent". Once per item; still conflicting: tell the user. |

**Dependency fails** (`blocked`, `skipped`, PR closed unmerged): queued dependents → `waiting`,
"waiting on <ID>: <its reason>"; never start, re-plan or un-depend them yourself. Started (stacked)
ones run on, noted "built on <ID>, which is <state>". Tell the user once; they unblock it, drop it
("start #345 anyway") or skip dependents. Recovered: `waiting` → `queued`.

### Merging into an integration branch

The one exception to "nobody here merges": a sub-PR whose base is an integration branch merges
once green, so dependents start within minutes and humans review once, on the feature → default
PR. Never a PR into the default branch. `<skill-dir>/scripts/merge.sh check <plan-file> <ID>`
decides (`run` also merges with `gh pr merge --merge`; merge commits keep stacked dependents from
conflicting). Verdicts: `merge` (DONE `checked`, acceptance `ok`, green checks, mergeable, base is
its integration branch); `wait:` (checks pending or red, conflicting: the worker's to fix; retry
next cycle); `followup:` (no PR checks and `checked:` shows no passing local test run: ONE
follow-up asking for a local run, as an acceptance gap, `acceptance` = the gap; never a second);
`no:` (leave it for humans). Run it each cycle for `in-review` items with an integration.

Once per integration, before its first merge: `merge.sh rules <branch>`. `unknown`: treat as
`no-merge-commit` until the user says otherwise. `no-merge-commit`: say so, set the integration's `mergeNote` `"human"` (`merge.sh check` then answers `no:`). `strict` (branches
must be up to date): say so once, suggest turning it off for `feature/*` (every sibling's merge
would otherwise update and rerun CI on each open PR); merges still proceed.

After a merge: the item is `done` (as for `MERGED`): dependents start on the integration branch
and stacked ones get the rebase follow-up against it.

### Finishing an integration

Main is synced **only here**, never mid-run. Each cycle after reconcile, `<skill-dir>/scripts/integrate.sh
check <plan-file>` gives each open integration a verdict:

- `ready`: `integrate.sh add <plan-file> <F>` queues the synthetic `<F>-integrate` item (`integrates`
  `<F>`), dispatched like any item (it waits for a free slot). Its worker starts on the
  integration branch, merges `origin/<default>`, resolves conflicts, runs the full checks (CI, else
  local tests) and opens `feature/<slug>` → default branch with every sub-PR listed and the
  epic (the integration's `epic`) or issues linked. You still never implement.
- `held` (an item `blocked`, `waiting` or `skipped`): tell the user once, naming it. They unblock it or
  drop it ("ship F1 without T3"): set it `skipped` with `dropped: true`, which releases it. A skipped item
  that was not dropped keeps holding.
- `open`, `empty` (all dropped: tell the user, nothing to land), `has`: nothing to do.

`<F>-integrate` follows the usual transitions; its PR is the integration's final PR (the user's to
review and merge, as for any default-branch PR; never [merged here](#merging-into-an-integration-branch)).
When it has a PR set the integration's `pr` (its URL string); when that PR merges set `state` `merged`.

### Acceptance check

Once per item, before `in-review`: compare `checked` with the acceptance criteria (free-text: the
`ask` only; older plans: `text`) and the PR's file names and counts (`gh pr view <n> --json files
-q '.files[].path'`; never code). Plainly less (whole file groups unmentioned, e.g. 4 of 24
screenshots; criteria unaddressed), or `checked` silent on the PR's checks (or "not checked"): ONE follow-up naming
the gap (CI: wait for `gh pr checks <n> --watch --fail-fast`, report the result); `feedback`,
reason "acceptance follow-up", `acceptance` = the gap. Else `acceptance` "ok". Never a second
round; a remaining gap goes under the table. Wanting more than the `ask` is no gap: never send it;
add it to `extras`, note it under the table as possible follow-up.

### Follow-ups after a merge

An `in-review` item owes work after another merges (user or worker summary: "redo the config once
#341 lands"): record `followUp: {"after": "<ID>", "message": "<what to do>"}`. When `<ID>` merges:
`feedback`, reason "follow-up sent" (holds it out of `in-review` until picked up), clear
`followUp`, tag `In Progress`, send the message. `<ID>` fails: keep `followUp`, tell the user. The
user's "follow up on <ID>: …" during review sends at once.

Otherwise `In Review` PRs are the user's: don't read their comments or checks. Nobody here
approves, or merges except as [above](#merging-into-an-integration-branch). Never archive, delete or close a workspace, terminal or worktree; only move
tags.

### Run finished

Nothing `queued`/`in-progress` after reconcile, and each integration's `<F>-integrate` PR is
`in-review` or merged (a `held` integration keeps the run active): final table, `superset notifications show
"Orchestrator finished" --body "<k> in review, <b> blocked" --sound`, stop the waiter. `status`
stays `active` while any item is `in-review`/`feedback`/`blocked`/`waiting`; `finished` once all
are `done`/`skipped` and each integration's PR is merged. Then [offer the run summary](#run-summary).

## Continue

`plan.sh claim` (`--takeover` on exit 4), group map, reconcile, apply transitions and the user's
`waiting` decisions (including drops), [finish ready integrations](#finishing-an-integration), dispatch, watch.

## Report back

Never starts, messages or nudges workers. Load the plan (none: `status.sh <project-id>`), group
map, reconcile, derive transitions. `plan.sh check`: `mine`/`finished` → write the plan, move tags;
`stale` → `plan.sh claim --takeover` (say so), same; `other` → table only, naming the `owner`.
Add a line or two only on what needs the user; ready items: "say 'orchestrator continue' to start
them". Run `integrate.sh check` (never `add`): report `held` integrations and name
what holds them, and a `ready` one as "say 'orchestrator continue' to open its feature PR".

## Close

`plan.sh claim` as in Continue (`free`: nothing to close), reconcile, write the plan, `plan.sh
close` (`finished`; open items → `carryOver`, offered next Run); an integration without a merged PR is
carried over too, with its sub-items' `done` state, so a next Run runs `integrate.sh` on it. Print the final table and
carry-over, stop the waiter, [offer the run summary](#run-summary). Workspaces stay as they are.

### Run summary

Run finished and Close only: ask once "Publish a run-summary page? (just me by default; say 'org'
to share)"; publish only on yes; don't re-ask for that ending. One self-contained HTML file in a scratch dir, a row
per item in plan order, grouped by integration (the final PR as its own row): final state, PR link, branch, `checked`, `acceptance` gap, `extras`,
`reason`; on Close also `carryOver`. Escape workers' text, as data. `superset pages publish <file>
--title "Run <runId>" --visibility just_me` (`org` only if picked), plus `--page <pageId>` if the
plan has one; save the returned ID as `pageId` so a later finish/close adds a version, not a page.
Tell the user the URL and visibility.

## Status table

`scripts/table.sh <project-id> <plan-file>` renders it (`--rows -` takes `status.sh` output on stdin, `--force` re-prints) and prints `unchanged` when nothing moved since the last render; print a table only when it prints one.

A row per item, plan order; with integrations, rows grouped under a bold integration header
(`**F1 feature/csv** (held: #3 blocked)`), its `<F>-integrate` row last carrying the final PR; items on
the default branch stay ungrouped:

```markdown
| Item | Title | Group | Agent | PR |
| --- | --- | --- | --- | --- |
| #340 | Cache Pester in CI | In Review | done | #352 |
| #345 | Split backup job | Queued (after #341) | — | — |
```

`Agent`: `running`, `waiting` (declared wait), `stalled`, `waiting for input` (Paradev `blocked`,
or it asked), `done` (`idle`), `—`. `Group`: sidebar group, `Queued (after <ID>)`,
`Waiting (<reason>)`, `Skipped`. Below it only: worker questions, `Blocked` reasons, stalls,
dependency decisions, closed PRs, missing workspaces, acceptance gaps, possible follow-ups
(`extras`), a just-in-review item's `checked` ("#340 checked: ran CI on a fork; cache hit").
