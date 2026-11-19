# Paradev loop

Loop only: watch, act, report, finish, after dispatch ([dispatch.md](dispatch.md)). `<skill-dir>` =
SKILL.md's folder; run scripts in the repo. Only `plan.sh write` changes the plan: never jq it.

| User says | Mode |
| --- | --- |
| items, `feature #400`, `feature: <text>`, free text | SKILL.md planning, dispatch, steps 1-3 |
| "continue" | preflight `--mode continue`, steps 1-3 on the saved plan |
| "report back" / "status" | `preflight.sh --mode report`, `table.sh`; never starts or messages a worker |
| "close" | `preflight.sh --mode close`, `plan.sh close`, step 3 |

## The loop

1. **Watch**: `<skill-dir>/scripts/watch.sh <project-id> <plan-file>` in the background (foreground
   with a short timeout if the harness lacks background notifications). It runs `cycle.sh`
   (transitions, merge gate, integrations, dispatch, tags) and exits with new events and `needs`
   JSON; `cycle.sh` alone for a one-off pass.
2. **Act on each `needs`** (below), restart `watch.sh`. `finished`: step 3; `taken-over`: stop,
   report it. No judgment or user action needed: restart silently.
3. **Finish**: `finish.sh <project-id> <plan-file>` prints the status table and full events log;
   then `summary.sh <plan-file>` publishes the summary page without asking; give the URL.

## Acting on `needs`

| kind | You |
| --- | --- |
| `accept` | `accept.sh packet <plan-file>`, read it, then one Bash call of `accept.sh verdict <plan-file> <ID> ok` or `… gap "<text>"` per item. Gap = plainly less (file groups unmentioned, criteria unaddressed) or `checked` silent on the PR's checks; a second gap is refused: note it under the table. More than the `ask` is no gap: add to `extras` as a possible follow-up. Never fetch the issue or PR yourself. |
| `question` | Show the exact question; relay the user's answer with `send.sh <plan-file> <ID> "<text>"`. Never answer it yourself. |
| `blocked`, `dependency-failed`, `held`, `closed-pr` | Tell the user once (item, reason); apply their decision (unblock, drop, "start #345 anyway", skip dependents, "ship F1 without T3"). Never re-plan or un-depend on your own. |
| `stalled`, `stale-wait` | Read the screen once (`superset terminals read --local --workspace <id> --terminal <tid> --max-lines 60`), tell the user, suggest a new worker in the workspace. Never restart it. |

Other user messages to a worker: `send.sh`; one waiting on another item's merge ("redo the config
once #341 lands") becomes the item's `followUp`.

## Reporting

Chat is events-only: the plan and go message, a wake needing judgment or user action (one concise
update, no recap), a user question, report back, finish. Never narrate polling, waiting, unchanged
status or watcher restarts; the plan's events log is the record. No status table of your own: only
what `table.sh <project-id> <plan-file>` prints (`unchanged` otherwise; `finish.sh` forces one).
Below it only what needs the user: questions, blocked reasons, stalls, dependency decisions,
acceptance gaps, `extras`, a just-in-review item's `checked`.

## Never

Implement, even a little. Approve, or merge into the default branch (only `merge.sh` merges green
sub-PRs into an integration branch). Answer permission prompts. Decide scope or product. Start or
restart the host. Archive, delete or close a workspace, terminal or worktree. Install or connect
anything. Re-ask a settled question. Outside Claude Code, as a top-tier model, say once a smaller
one would do (`codex -m <small model>`, `gemini -m <flash model>`).
