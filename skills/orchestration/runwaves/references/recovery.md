# Recovery: ownership, takeover, stale, carry-over, Close

Load when preflight exits 3 or 4, a run is resumed, or the user says "close".

One **active run** per repo, owned by a coordinator terminal (`$SUPERSET_TERMINAL_ID` on Paradev,
`$ORCA_TERMINAL_HANDLE` on Orca) with a heartbeat. `plan.sh claim` (on Paradev through
`preflight.sh`) reports it:

- `free`: new plan (a finished run moves to `~/.agents/orchestrator/history/`). Following
  `carryOver` and `integrationCarryOver` lines report unfinished standalone items and open
  integrations respectively; offer once to re-import them.
- `resumed`: yours; a Run adds items.
- Exit 3, live owner: start nothing, name its terminal, offer a report back. Only when the user says
  take over: `plan.sh claim --takeover --force`.
- Exit 4, stale owner (no heartbeat for 45 minutes): Continue takes over (`claim --takeover`); a Run
  asks first. Say any takeover in one line. Continue then resumes the old run as it is; a Run's
  `plan.sh write` of a new draft starts a fresh run instead: the old one is closed into history
  and `write` prints its `carryOver` and `integrationCarryOver` line, as `free` does.

`plan.sh write` / `heartbeat` exit 3 mean the plan was taken over: stop, tell the user.

Report back with `plan.sh check`: `mine`/`finished` → normal; `stale` → `claim --takeover` (say
so); `other` → the table only, naming the `owner`. Report back never starts, messages or nudges
workers, and ends with a line or two on what needs the user; ready items: "say 'runwaves
continue' to start them".

**Continue** reuses the plan's `autoOnly` and group map and never re-asks them. A `waiting`
item whose dependency was decided by the user is applied before dispatch.

**Close**: `plan.sh close` marks the run `finished`. `carryOver` contains every item whose state is
neither `done` nor `skipped`, with its ID, state, and reason. Separately, `integrationCarryOver`
contains each integration whose state is open, along with all items assigned to it (including
`done` items). On the next `plan.sh claim`, these are reported as `carryOver` and
`integrationCarryOver`; offer the user once to re-import the standalone items and continue the open
integrations. `claim` archives the closed plan in history. Print the final table and both carry-over
lists, then `summary.sh`.
Workspaces stay as they are.

A run stays `active` while any item is `in-review`/`feedback`/`blocked`/`waiting`; `finished` once
all are `done`/`skipped` and each integration's PR is merged. `cycle.sh` reports `finished`, and
desktop-notifies it on Paradev (`superset notifications show "Runwaves finished"`).
