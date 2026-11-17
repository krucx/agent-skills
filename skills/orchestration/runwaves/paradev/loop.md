# Paradev loop

Loop backend only: watch, act, report, finish. Read after the plan is approved and dispatched
([dispatch.md](dispatch.md)). `<skill-dir>` = the folder holding SKILL.md; run scripts inside the repo.
Never write jq against the plan: only `plan.sh write` changes it.

| User says | Mode |
| --- | --- |
| items, `feature #400`, `feature: <text>`, free text | Run: SKILL.md planning, dispatch, then steps 1-3 |
| "continue" | Run preflight (`--mode continue`), then steps 1-3 on the saved plan |
| "report back" / "status" | `preflight.sh --mode report`, then `table.sh`; never starts or messages a worker |
| "close" | `preflight.sh --mode close`, `plan.sh close`, then step 3 |

## The loop

1. **Watch**: start `<skill-dir>/scripts/watch.sh <project-id> <plan-file>` in the background
   (foreground with a short timeout where the harness has no background notifications). It runs
   `cycle.sh` (transitions, merge gate, integrations, dispatch, tags) and exits with new events and
   the `needs` JSON. `cycle.sh` alone for a one-off pass. Starting the watcher and waiting are
   mechanical: do not narrate them in chat.
2. **Act on each `needs`** (below), then restart `watch.sh`. Exit `finished`: step 3;
   `taken-over`: stop and report that event. If a wake has no new events requiring judgment or user
   action, restart the watcher silently. A timeout or routine state change is not a chat event.
3. **Finish**: `finish.sh <project-id> <plan-file>` prints the current plan-derived status table
   and complete chronological events log in chat (including the `finished` event; empty items and
   events are called out explicitly). Then `summary.sh <plan-file>` publishes the run summary page
   without asking; tell the user the URL.

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
