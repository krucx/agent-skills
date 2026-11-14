# Integration branches

Load when a run has an epic, `feature:`, a dependency chain, or an integration needing a decision.

An item's **target** is its integration's `branch`, else the default branch; a run may mix both.
Integrations are **never nested**: an integration's `base` is the default branch.

## Where integrations come from

- `feature #400` / `feature ENG-40` (an **epic**): its sub-issues are the items, on one
  integration `feature/<n>-<slug>` with `epic` set (the final PR links it). The parent is never an
  item. `scripts/epic.sh fetch <n> <plan-file>` lists GitHub sub-issues already filtered;
  `epic.sh import <plan-file> <n>` adds the integration and its queued items. Linear/Jira
  parents: see [trackers](trackers.md). Set dependencies among the children afterwards.
- `feature: <description>`: split into tasks as for free text, one `feature/<slug>` integration
  (`id` `F1`, `title`, `base`, `pr` null, `state` `open`), every task's `integration` set to it.
- Chains: `chains.sh offer <plan-file>` prints each connected group of two or more dependent items
  with its branch and question ("group #340, #341, #342 into `feature/340-<slug>`?"); show them in
  the go message. Yes → `chains.sh accept <plan-file> <ID>` (one member per chain); no → the chain
  runs stacked or waiting for merges into `main`. Items already on an integration are never
  offered. If the independent items go to a feature branch, offer no chain: `chains.sh share
  <plan-file> <slug>` puts the whole run on one `feature/<runId-slug>`.
- The user may move single items ("#344 straight to main": `integration` null).

## Merge gate (script-enforced)

`cycle.sh` runs `merge.sh` for green sub-PRs into an integration branch; humans merge everything
else. What you decide: once per integration, `merge.sh rules <branch>`. `no-merge-commit` or
`unknown`: say so and set the integration's `mergeNote` `"human"`. `strict`: say once that turning
it off for `feature/*` avoids rerunning CI on every sibling's merge; merges still proceed.

## Finishing

Main is synced only at the end, never mid-run. `integrate.sh check` (run by `cycle.sh`) gives
each open integration a verdict; `ready` queues the synthetic `<F>-integrate` item whose worker
merges `origin/<default>` and opens `feature/<slug>` → default with every sub-PR listed and the
epic or issues linked. Its PR is the integration's final PR, the user's to review and merge. When it
has a PR set the integration's `pr` (URL string); when it merges set `state` `merged`.

`held` (an item `blocked`, `waiting` or `skipped`): tell the user once, naming it. They unblock it
or drop it ("ship F1 without T3": `skipped` with `dropped: true`, which releases it); a skipped,
undropped item keeps holding. `empty` (all dropped): tell the user, nothing to land.
Report back runs `integrate.sh check` only (never `add`): report `held` ones and what holds them, a
`ready` one as "say 'orchestrator continue' to open its feature PR".

## Follow-ups after a merge

An `in-review` item that owes work after another merges: record `followUp: {"after": "<ID>",
"message": "<what to do>"}`; `cycle.sh` sends it when `<ID>` merges. `<ID>` fails: keep it, tell the
user. "follow up on <ID>: …" during review is sent at once with `send.sh`.
