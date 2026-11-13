---
name: orchestrator
description: Act as the master agent that plans a batch of issues (GitHub, Linear, Jira, or free-text work broken into tasks) and runs them in parallel through Paradev (formerly Superset), each in its own worktree workspace with a worker agent running an implement skill, moving workspaces between the In Progress, In Review, Done and Blocked sidebar groups as their PRs appear and merge. Also answers "orchestrator report back" with a short status table, "orchestrator continue" to resume a run, and "orchestrator close" to end one. Use whenever the user says "orchestrate", "orchestrate these issues", "orchestrate 340 to 345", "orchestrate and work", "be the master agent", "run these issues in parallel", "spin up agents for these tickets", or "orchestrator report back" / "status" / "continue" / "close", even if they don't mention Paradev.
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

`superset`, `paradev`, `pdev`: one CLI; this file writes `superset`, use whichever is on PATH;
its `--help` is authoritative. `<skill-dir>`: this file's folder
(usually `~/.agents/skills/orchestrator`). Run scripts inside the repo.

## Modes

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
   escalation, then point the user to `superset:doctor`. Never start or restart the host yourself.
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

```json
{"repo": "owner/repo", "runId": "20261112-2015", "status": "active", "maxParallel": 5,
 "autoApprove": true, "presets": {"claude": ["auto"]}, "autoOnly": {"claude": "accepted"}, "groups": {"In Progress": "in progress", "Blocked": "new group-6", …},
 "items": [{"id": "#340", "title": "…", "text": null, "dependsOn": [], "why": "",
 "skill": "implement", "agent": "claude", "preset": "auto", "state": "queued", "branch": null, "workspace": null, "terminal": null, "pr": null,
 "checked": null, "acceptance": null, "followUp": null}]}
```

`status` `active`|`finished`; `plan.sh` adds `owner`, `heartbeat`, `takenOverFrom`, `forcedAt`,
`carryOver`. `state`: `queued`, `in-progress`, `in-review`, `feedback`, `done`, `blocked`,
`waiting` (dependency failed), `skipped`; `reason` explains the last three. `text`: free-text
task's description. `preset`: `auto`|`regular`. `presets`: per harness, which
kinds [preflight](#worker-agents-and-auto-approval) found (`auto`, `regular`). `autoOnly`: per
harness with only an auto instance, the user's answer (`"accepted"`, or `"declined"`); absent means
not asked yet. `checked`: worker's `checked:` line.
`acceptance`: `null`, `"ok"`, or the [gap](#acceptance-check). `followUp`: `null` or
`{"after": "<ID>", "message": "<text>"}` ([after a merge](#follow-ups-after-a-merge)).

Facts (workspace, branch, agent and PR state) come from Paradev and GitHub; intent (items,
dependencies, skill, agent, why waiting/blocked/skipped) from the plan. Write the plan, then the
tag, so an interruption leaves the plan ahead for reconcile to re-tag. Status tables come only
from reconciled state.

## Groups

Tags file workspaces into sidebar folders. Each workspace has exactly one; every `--tag` uses the
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
run them with auto too, or hold them until a prompting preset exists? Store it in `autoOnly`
(`accepted`: those items get `preset` `auto`; `declined`: they stay `queued`, reason "needs a
prompting preset"), so Continue and later Runs don't ask again. With no such items, still note
the case in one line and set `accepted`. A regular instance appearing later: Continue uses it for
the items the rules name; `autoOnly` stays as recorded.

No auto instance for a harness: regular preset for its items; list each instance's `label`, `command`, `args`; offer once to
create `Claude (auto)` (`claude --permission-mode auto`; Codex: `codex --approve-for-me`). Only on
yes: with the CLI if `superset agents --help` offers it, else the user adds it in Paradev's agent
settings.

## Dispatch

Start an item once each dependency has a PR (or is met) and fewer than the limit are
`in-progress` (`feedback` excluded); never stack on one in `feedback`: wait for `in-review` or
merge.

**Branch**: `issue-340-<slug>`, lowercase key (`eng-123-<slug>`), or `task-<runId>-t1-<slug>`
(free text). `<slug>`: lowercase ASCII title, other runs one hyphen, at most 4 words; branch ≤ 60
characters, no edge hyphens. Taken (`git ls-remote --heads origin`, local `refs/heads`, the plan,
or `superset workspaces list --local --project <id> --search <branch> --json`): append `-2`,
`-3`, … Never reuse a branch you didn't create for this item.

**Write the plan first** (`in-progress`, branch set), then:

```bash
superset workspaces create --local --project <project-id> \
  --name "<ID> <short title>" \
  --branch <branch> --skip-branch-prefix \
  --base-branch <main, or the dependency's branch> \
  --tag "<In Progress's tag>" \
  --agent <auto instance id, or preset id> \
  --prompt "<worker prompt>" \
  --json
```

`--skip-branch-prefix` keeps the branch as given. Stacked: base on an unmerged dependency's
branch, else `main`. No `--model`. Failure: `queued`; second failure `blocked`, error as reason.
Success: plan gets the workspace ID, Paradev's reported branch, terminal ID = `create`'s `agents[].sessionId` (`terminals` may be
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

`<skill-dir>/scripts/wait-change.sh <project-id> <plan-file>` polls each minute; exits with a
one-line summary when a plan (or adoptable) workspace's agent state, tag or PR changes or it
vanishes, else after 20 minutes. Background it if the harness notifies on exit, else
foreground with a short timeout (`wait-change.sh <project-id> <plan-file> 120`). On exit:
`plan.sh heartbeat` (stop on exit 3), [reconcile](#reconcile), apply transitions, dispatch, print
the [status table](#status-table) if changed, restart unless finished. Exit non-zero (checks
failed until timeout): check connectivity, reconcile, restart.

Read (worker block from status.sh first): `superset terminals read --local --workspace <id>
--terminal <tid> --max-lines 60`. Send: `superset terminals send … --text "<answer>"`.
`idle` is not done while background work (e.g. code-review subagents) runs: before any `idle`
row, read the screen; while it runs, skip the row (no transition, no follow-up, not counted).

| Seen | Do |
| --- | --- |
| `in-progress`, PR exists | Once `checked:` is out (or `idle`): save it, [acceptance check](#acceptance-check), `in-review` (not waiting for CI). |
| `in-review`, agent `working` | User is giving feedback: `feedback` (not counted toward the limit). |
| `feedback`, reason "follow-up sent" or "acceptance follow-up", agent `working` | Picked up: clear the reason. |
| `feedback`, agent `idle` | Reason still set (not started): wait. Else `in-review`; after an acceptance follow-up, re-compare once, keeping a remaining gap. |
| Agent `stalled` | Read the screen; tell the user, suggesting a new worker in the same workspace. Never restart it yourself. |
| Agent `blocked` with a `reason` (fatal banner: usage limit, expired sign-in…) | `blocked` with that reason, free the slot, tell the user. |
| Agent `blocked` (Paradev's "needs input") | Read the screen; show the exact question; desktop-notify. User answers in the worker's chat (relay with send if in yours). Never answer permission prompts or decide scope/product for them. |
| `in-progress`, agent `idle`, no PR | `ORCHESTRATOR_WORKER_BLOCKED` printed or one follow-up already sent: `blocked` with its reason, free the slot, tell the user. Else one follow-up: finish and open the PR. |
| PR `MERGED` | `done`; unstarted dependents base on `main`; send follow-ups waiting on it. |
| PR `CLOSED` unmerged | `blocked`, "PR closed unmerged"; tell the user. |

**Dependency fails** (`blocked`, `skipped`, PR closed unmerged): queued dependents `waiting`,
"waiting on <ID>: <its reason>"; never start, re-plan or un-depend them yourself. Started
(stacked) ones run on, noted "built on <ID>, which is <state>". Tell the user once; they unblock
it, drop it ("start #345 anyway") or skip dependents. Recovered: `waiting` dependents `queued`.

### Acceptance check

Once per item, before `in-review`: compare `checked` with the issue's acceptance criteria and the
PR's files (`gh pr view <n> --json files -q '.files[].path'`: names and counts, never code). If it
plainly covers less (whole file groups unmentioned, e.g. 4 of 24 screenshots, or criteria
unaddressed), send ONE follow-up naming the gap: `feedback`, reason "acceptance follow-up",
`acceptance` the gap. Else `acceptance` "ok". Never a second round; a gap left is noted under the
table for the human.

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
`plan.sh close`: `finished` now,
open items saved as `carryOver` (`{id, state, reason}`), offered on the next Run. Print the final
table and the carry-over; stop the waiter. Workspaces stay as they are.

## Status table

One row per run item, plan order:

```markdown
| Item | Title | Group | Agent | PR |
| --- | --- | --- | --- | --- |
| #340 | Cache Pester in CI | In Review | done | #352 |
| #341 | Coverage floors | In Progress | running | — |
| #345 | Split backup job | Queued (after #341) | — | — |
```

`Agent`: `running`, `stalled`, `waiting for input` (Paradev `blocked`, or it asked), `done`
(`idle`), `—`. `Group`: sidebar group, `Queued (after <ID>)`, `Waiting (<reason>)`, `Skipped`.
Below it only: worker questions, `Blocked` reasons, stalls, dependency decisions, closed PRs,
missing workspaces, acceptance gaps, a just-in-review item's `checked`
("#340 checked: ran the CI workflow on a fork; Pester cache hit on the second run").