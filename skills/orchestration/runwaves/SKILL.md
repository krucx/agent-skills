---
name: runwaves
description: Plans a batch of tracker issues (GitHub, Linear, Jira), a feature or epic ("runwaves feature #400", sub-issues as one integration branch) or free-text work split into tasks, and drives each to its own pull request through Paradev (formerly Superset), one worktree workspace and implement-skill worker each, with a saved, resumable plan and workspaces moved between the In Progress, In Review, Done and Blocked sidebar groups as PRs appear and merge. Also "runwaves report back" (status table), "runwaves continue" (resume a run), "runwaves close" (end one). Use whenever the user says "runwaves 340-343", "plan runwaves", "runwaves feature #400", "runwaves report back", "runwaves continue" or "runwaves close", even without mentioning Paradev. Not Orca's built-in skills and not Paradev's own multi-agent skill (the `superset:` one): small ad-hoc fan-outs with no tracker, PRs or need to resume (e.g. "run these 3 refactors in parallel and tell me when done") belong to those.
compatibility: Needs bash, jq, git, the GitHub CLI (gh, signed in) and the Paradev CLI (superset, paradev or pdev) with this machine's host running. PRs must live on GitHub. Workers run on Claude Code, Codex, OpenCode or Antigravity.
model: sonnet
effort: low
argument-hint: items like "340-343, 345 onwards", "ENG-12 ENG-15", "feature #400" (an epic), "feature: <description>", free text, "report back", "continue", or "close"
---

# Runwaves

You coordinate; scripts do the mechanics, you judge. `<skill-dir>` = this file's folder; run
scripts inside the repo. Never write jq against the plan: only `plan.sh write` changes it.

| User says | Mode |
| --- | --- |
| items ("runwaves 340-343"), `feature #400`, `feature: <text>`, free text | Run |
| "continue" | Run steps 1 and 4-6 on the saved plan |
| "report back" / "status" | `preflight.sh --mode report`, then `table.sh`; never starts or messages a worker |
| "close" | `preflight.sh --mode close`, `plan.sh close`, then step 6 |

## The loop

1. **Preflight**: `<skill-dir>/scripts/preflight.sh [--mode run|continue|report|close] [--harness <name>…]`.
   Exit 0 go on; 1 tool/auth/host failure, stop and say which (host trouble: `superset:doctor`;
   never start the host); 2 not a GitHub repo or no project; 3 live owner: name its terminal, offer
   a report back (takeover only if the user says so); 4 stale owner: Continue takes over, a Run
   asks; 5 group map unsaved or a tag lost: ask once; 6 a harness with no auto instance (see the go
   message). Owners, takeover, carry-over, close: [recovery](references/recovery.md).
2. **Plan**: rules below, then `plan.sh write`; [schema](references/plan-schema.md).
3. **Go message**: one message with everything at once.
4. **Watch**: start `<skill-dir>/scripts/watch.sh <project-id> <plan-file>` in the background
   (foreground with a short timeout where the harness has no background notifications). It runs
   `cycle.sh` (transitions, merge gate, integrations, dispatch, tags) and exits with new events and
   the `needs` JSON. `cycle.sh` alone for a one-off pass. Starting the watcher and waiting are
   mechanical: do not narrate them in chat.
5. **Act on each `needs`** (below), then restart `watch.sh`. Exit `finished`: step 6;
   `taken-over`: stop and report that event. If a wake has no new events requiring judgment or user
   action, restart the watcher silently. A timeout or routine state change is not a chat event.
6. **Finish**: `finish.sh <project-id> <plan-file>` prints the current plan-derived status table
   and complete chronological events log in chat (including the `finished` event; empty items and
   events are called out explicitly). Then `summary.sh <plan-file>` publishes the run summary page
   without asking; tell the user the URL.

## Planning

- Refs, mixable: `340-343`, `345 onwards`, `#350`, `ENG-123`; or free text. Options:
  `using /<skill>` (default `implement`), `with codex`, `with 3 agents` (default and max 5),
  `with prompts` (regular preset).
- **Tracker**: per `## Agent skills` in `AGENTS.md`/`CLAUDE.md`, else `#n` is GitHub, `ABC-123`
  Linear or Jira (ask if unclear). GitHub stays inline: `gh`. If Linear or Jira cannot be reached,
  stop and say how to connect; never install or connect anything. Linear/Jira reach and parents:
  [trackers](references/trackers.md).
- **Fetch** title, body, labels, author. Drop closed items, PRs, items with an open PR or already
  planned; `skipped`: `needs-info`/`needs-triage` or too vague. Name each drop and why.
- **Free text → tasks** `T1`, `T2`… one reviewable PR each. `ask`: the user's slice
  **verbatim**, never reworded or widened. `notes`: your build notes, adding no work. Anything
  beyond the ask → `extras`. Show each task with its `ask` quoted; wait for the go. After it, offer
  once, separately, to file the tasks (ask verbatim, notes under their own heading); only on yes.
- `feature #400` (epic) and `feature: <text>`: all items go to one integration branch:
  [integrations](references/integrations.md) (also chains, the **local** branch option, the merge
  gate, finishing, `held`).
- **Dependencies**: explicit ("blocked by", "after", parent/child) and clear conflicts (same
  files, migration, schema; smaller first). Outside the run: closed-as-completed is met; open or
  skipped → the dependent `waiting`, naming it. **Interface hint**: if a chain's link looks large,
  suggest once splitting out a small interface/stub task; never split without the go.
- **Waves** ≤ the parallel limit, independent first, unblockers first. `runId` = start time
  `YYYYMMDD-HHMM`. Show a short table (item, title, wave, depends on, target, skill, agent). Squash-only
  repos (`repo.mergeMethods`): a dependent waits for its parent's merge, never stacks.

## The go message

Dispatch at once unless the run has an integration, a dependency chain, an auto-only harness or
regular-preset items; then wait for the go. Ask **once, everything at once, never later**:
where independent items go (`main` or `feature/<slug>`), each chain (`chains.sh offer`; accept
with `chains.sh accept`; none offered if the independent items share a feature branch:
`chains.sh share`), for each integration branch whether it is **local** (no sub-PRs and no CI per
item: workers test before every commit, `merge.sh` merges in this clone, CI runs once on the final
PR; `--local` on `chains.sh accept|share` and `epic.sh import`, `"local": true` in the plan for
`feature: <text>`) or on GitHub (the default), the auto-only question, and which items run on the
regular preset.
Per-item moves ("#344 straight to main") are applied and the table shown again. Ask instead on a
dependency cycle or two items that might be one PR. Dispatch is `dispatch.sh`, never by hand.
Auto and regular presets, auto-only: [approval](references/approval.md).

## Acting on `needs`

| kind | You |
| --- | --- |
| `accept` | `accept.sh packet <plan-file>`, read it, then one Bash call of `accept.sh verdict <plan-file> <ID> ok` or `… gap "<text>"` per item. A gap is plainly less (file groups unmentioned, criteria unaddressed) or `checked` silent on the PR's checks; the second gap is refused: note it under the table. More than the `ask` is no gap: add it to `extras`, note it as a possible follow-up. Never fetch the issue or PR yourself. |
| `question` | Show the worker's exact question. If the user answers it, relay with `send.sh <plan-file> <ID> "<text>"`. Never answer it yourself. |
| `blocked`, `dependency-failed`, `held`, `closed-pr` | Tell the user once, with the reason and the item; apply their decision (unblock, drop it, "start #345 anyway", skip dependents, "ship F1 without T3"). Never re-plan or un-depend on your own. |
| `stalled`, `stale-wait` | Read the screen once (`superset terminals read --local --workspace <id> --terminal <tid> --max-lines 60`) and tell the user; suggest a new worker in the workspace. Never restart it. |

Anything else the user says to a worker goes through `send.sh`; one that waits on another item's
merge ("redo the config once #341 lands") is recorded as the item's `followUp` instead.

## Reporting

Chat is events-only. Speak for the plan and go message, a judgment or user-action event from a
watch wake, a user question, an explicit report-back, and the finish. On a judgment wake, report the
new events needed to explain the judgment in one concise update; do not add a progress recap. If the
wake contains only mechanical events that need no user action or model judgment, take the scripted
action and restart the watcher without a chat message. Never narrate routine polling, waiting,
unchanged status, or a watcher restart. The watcher output and plan event log are the record of
mechanical progress. At finish, `finish.sh` prints both the current status table (using
`table.sh --force`) and the complete events log from the plan. At other times, no status table of
your own: print one only when `table.sh <project-id> <plan-file>` prints one (it prints `unchanged`
otherwise). Below it, only what needs the user:
worker questions, blocked reasons, stalls, dependency decisions, acceptance gaps, possible
follow-ups (`extras`), a just-in-review item's `checked`.

## Never

Implement, even a little. Approve, or merge a PR into the default branch (only `merge.sh` merges a
green sub-PR into an integration branch). Answer permission prompts. Decide scope or product. Start
or restart the host. Archive, delete or close a workspace, terminal or worktree. Install or connect
anything. Re-ask a settled question. Outside Claude Code, if you're a top-tier model, say once that
a smaller one would do (`codex -m <small model>`, `gemini -m <flash model>`).
