# Recovery: ownership, takeover, stale, carry-over, Close

Load when preflight exits 3 or 4, a run is resumed, or the user says "close".

One **active run** per repo, owned by an orchestrator terminal (`$SUPERSET_TERMINAL_ID`) with a
heartbeat. `preflight.sh` runs `plan.sh claim` and reports it:

- `free`: new plan (a finished run moves to `~/.agents/orchestrator/history/`). A following
  `carryOver` line is a closed run's open items: offer once to re-import them.
- `resumed`: yours; a Run adds items.
- Exit 3, live owner: start nothing, name its terminal, offer a report back. Only when the user says
  take over: `plan.sh claim --takeover --force`.
- Exit 4, stale owner (no heartbeat for 45 minutes): Continue takes over (`claim --takeover`); a Run
  asks first. Say any takeover in one line.

`plan.sh write` / `heartbeat` exit 3 mean the plan was taken over: stop, tell the user.

Report back with `plan.sh check`: `mine`/`finished` → normal; `stale` → `claim --takeover` (say
so); `other` → the table only, naming the `owner`. Report back never starts, messages or nudges
workers, and ends with a line or two on what needs the user; ready items: "say 'orchestrator
continue' to start them".

**Continue** reuses the plan's `autoOnly` and group map and never re-asks them. A `waiting`
item whose dependency was decided by the user is applied before dispatch.

**Close**: `plan.sh close` marks the run `finished`; open items go to `carryOver`, offered at the
next Run. An integration without a merged PR is carried over with its sub-items' `done` state, so a
next Run runs `integrate.sh` on it. Print the final table and carry-over, then `summary.sh`.
Workspaces stay as they are.

A run stays `active` while any item is `in-review`/`feedback`/`blocked`/`waiting`; `finished` once
all are `done`/`skipped` and each integration's PR is merged. `cycle.sh` reports `finished`, and
desktop-notifies it (`superset notifications show "Orchestrator finished"`).
