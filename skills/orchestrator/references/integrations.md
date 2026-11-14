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
- `feature: <description>`: split into tasks as for free text. Use `chains.sh share <plan-file>
  <slug>` to create one `feature/<runId-slug>` integration and assign the eligible tasks to it.
  The script chooses the integration ID and fills mechanical fields. Never hand-edit `integrations`
  or item `integration` fields.
- Chains: `chains.sh offer <plan-file>` prints each connected group of two or more dependent items
  with its branch and question ("group #340, #341, #342 into `feature/340-<slug>`?"); show them in
  the go message. Yes → `chains.sh accept <plan-file> <ID>` (one member per chain); no → the chain
  runs stacked or waiting for merges into `main`. Items already on an integration are never
  offered. If the independent items go to a feature branch, offer no chain: `chains.sh share
  <plan-file> <slug>` puts the whole run on one `feature/<runId-slug>`.
- The user may move single items ("#344 straight to main"). Do not tell the model to hand-set
  `integration`; use an owning script command for plan changes, or leave the plan unchanged if no
  command supports the requested move.

## Local integration branch (opt-in at the go)

Ask once in the go message, per integration: on GitHub (the default: the branch is pushed, every
item opens a sub-PR into it, CI runs on each) or **local**: the branch lives in
this clone only until its final PR, so there are no sub-PRs and no CI per item; faster, and CI
runs once on the feature → default PR. Set it with `chains.sh accept <plan-file> --local <ID>`,
`chains.sh share <plan-file> <slug> --local`, or `epic.sh import <plan-file> <n> --local`. Use
`chains.sh share <plan-file> <slug> --local` for a `feature: <text>` run. What changes, all in
scripts:

- `dispatch.sh` creates the branch in this clone from its base (never pushes it) and tells the
  worker: open no PR and push nothing, run the test suites that cover the change before every
  commit and the full test command before the last one, and report `pr: none (local integration)`
  with `checked: local: <command> passed`.
- `accept.sh packet` takes the files and diff from `git diff <branch>...<worker branch>`.
- `cycle.sh` records `mergeNote` `"local"` (no rulesets to read); `merge.sh` merges an accepted
  branch whose `checked` reports a passing local run into the integration branch with a merge
  commit, in a temporary worktree. A conflict is a `wait`, as for a conflicting PR, for the worker
  to resolve; no passing local run is one follow-up asking for it.
- The `<F>-integrate` worker pushes the branch for the first time and opens the final PR as
  usual; its CI is the run's only CI.

Workers must be on this machine's host (the branches live in this clone): never pair a local
integration with cloud workspaces.

## Merge gate (script-enforced)

`cycle.sh` runs `merge.sh` for green sub-PRs into an integration branch; humans merge everything
else. What you decide: once per integration, `merge.sh rules <branch>`. `no-merge-commit` or
`unknown`: say so; `cycle.sh` records the `"human"` merge note. `strict`: say once that turning
it off for `feature/*` avoids rerunning CI on every sibling's merge; merges still proceed.

## Finishing

Main is synced only at the end, never mid-run. `integrate.sh check` (run by `cycle.sh`) gives
each open integration a verdict; `ready` queues the synthetic `<F>-integrate` item whose worker
merges `origin/<default>` and opens `feature/<slug>` → default with every sub-PR listed and the
epic or issues linked. Its PR is the integration's final PR, the user's to review and merge. When it
has a PR, `cycle.sh` records the integration's `pr` URL; after it merges, `cycle.sh` records
`state` `merged`.

`held` (an item `blocked`, `waiting` or `skipped`): tell the user once, naming it. They unblock it
or drop it ("ship F1 without T3": `skipped` with `dropped: true`, which releases it); a skipped,
undropped item keeps holding. `empty` (all dropped): tell the user, nothing to land.
Report back runs `integrate.sh check` only (never `add`): report `held` ones and what holds them, a
`ready` one as "say 'orchestrator continue' to open its feature PR".

## Follow-ups after a merge

An `in-review` item that owes work after another merges: record `followUp: {"after": "<ID>",
"message": "<what to do>"}`; `cycle.sh` sends it when `<ID>` merges. `<ID>` fails: keep it, tell the
user. "follow up on <ID>: …" during review is sent at once with `send.sh`.
