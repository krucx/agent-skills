# Recovery: ownership, takeover, stale, carry-over, Close

Load on preflight exit 3 or 4, a resume, or "close".

One **active run** per repo, owned by a coordinator terminal (`$SUPERSET_TERMINAL_ID` on Paradev,
`$ORCA_TERMINAL_HANDLE` on Orca) with a heartbeat. `plan.sh claim` (on Paradev via `preflight.sh`):

- `free`: new plan (a finished run moves to `~/.agents/orchestrator/history/`). Following
  `carryOver` / `integrationCarryOver` lines: unfinished standalone items / open integrations;
  offer once to re-import.
- `resumed`: yours; a Run adds items.
- Exit 3, live owner: start nothing, name its terminal, offer a report back. Only on the user's
  take over: `plan.sh claim --takeover --force`.
- Exit 4, stale (no heartbeat for 45 min): Continue takes over (`claim --takeover`); a Run asks
  first. Say any takeover in one line.

`plan.sh write` / `heartbeat` exit 3: taken over; stop, tell the user.

Report back: `plan.sh check`: `mine`/`finished` normal; `stale` → `claim --takeover` (say so);
`other` → table only, naming the `owner`. It never starts, messages or nudges workers, and ends
with a line or two on what needs the user; ready items: "say 'runwaves continue' to start them".

**Continue** reuses `autoOnly` and the group map, never re-asks. A `waiting` item whose dependency
the user decided is applied before dispatch.

**Close**: `plan.sh close` marks the run `finished`; `carryOver` = every item not `done`/`skipped`
(ID, state, reason); `integrationCarryOver` = each open integration with all its items (incl.
`done`). The next `claim` reports both (offer once to re-import / continue) and archives the plan.
Print the final table and both lists, then `summary.sh`. Workspaces stay.

A run is `active` while any item is `in-review`/`feedback`/`blocked`/`waiting`; `finished` once all
are `done`/`skipped` and each integration's PR merged. `cycle.sh` reports `finished` (on Paradev
also `superset notifications show "Runwaves finished"`).
