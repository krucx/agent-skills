# Integration branches

Load for an epic, `feature:`, a dependency chain, or an integration needing a decision. Never
hand-edit `integrations` or item `integration`: only scripts do; a move no script supports leaves
the plan unchanged.

An item's **target** is its integration's `branch`, else the default branch; a run may mix both.
Integrations never nest (`base` = default branch), except a
[local chain branch](#local-chain-branch-opt-in-at-the-go) inside a GitHub integration.

## Where integrations come from

- **Epic** (`feature #400` / `feature ENG-40`): its sub-issues are the items, on one
  `feature/<n>-<slug>` with `epic` set (the final PR links it); the parent is never an item.
  `scripts/epic.sh fetch <n> <plan-file>` lists filtered GitHub sub-issues; `epic.sh import
  <plan-file> <n>` adds the integration and queued items. Linear/Jira: [trackers](trackers.md).
  Then set dependencies among the children.
- `feature: <description>`: split as free text; `chains.sh share <plan-file> <slug>` creates one
  `feature/<runId-slug>` and assigns eligible tasks.
- **Chains**: `chains.sh offer <plan-file>` prints each connected group of 2+ dependent items with
  branch and question ("group #340, #341, #342 into `feature/340-<slug>`?"); show in the go message.
  Yes → `chains.sh accept <plan-file> <ID>` (one member per chain); no → stacked or waiting for
  merges into `main`. Items already on an integration are never offered. Independents going to a
  feature branch: offer no chain; `chains.sh share <plan-file> <slug>` puts the run on one branch.
- The user may move single items ("#344 straight to main") via an owning script command.

## Local integration branch (opt-in at the go)

Ask once per integration in the go message: GitHub (default: pushed, a sub-PR and CI per item) or
**local** (lives in this clone until its final PR: no sub-PRs or per-item CI; faster; CI runs once on
the feature → default PR). Set with `chains.sh accept <plan-file> --local <ID>`, `chains.sh share
<plan-file> <slug> --local` (also for `feature: <text>`), or `epic.sh import <plan-file> <n> --local`.
Scripts then:

- `dispatch.sh` creates the branch here from its base (never pushes) and tells the worker: no PR, no
  push, covering tests before every commit and the full test command before the last, report `pr:
  none (local integration)` and `checked: local: <command> passed`.
- `accept.sh packet` diffs `git diff <branch>...<worker branch>`.
- `cycle.sh` records `mergeNote` `"local"`; `merge.sh` merges an accepted branch whose `checked`
  shows a passing local run, with a merge commit in a temp worktree. Conflict = `wait` for the
  worker; no passing local run = one follow-up asking for it.
- The `<F>-integrate` worker pushes the branch first time and opens the final PR; its CI is the
  run's only CI.

## Local chain branch (opt-in at the go)

In a GitHub integration, CI on every critical-path chain link is the wait. So for each chain of 2+
queued critical-path items linked one to one (each the next's only dependency, the next its only
dependent; a fork or join ends it), `chains.sh offer` also prints `{"items", "branch":
"chain/<id>-<slug>", "parent": "F1", "question"}` ("run #2, #3 on the local branch chain/2-<slug>,
one PR into feature/<slug>?"). Not offered: off the critical path, inside a local integration, or
taking every item of its integration (make that integration local instead). Ask in the go message.
Yes → `chains.sh accept <plan-file> <ID>` adds a nested integration (`parent` the GitHub one, `base`
its branch, `local: true`) holding the chain's items:

- Items run as on a local integration; `merge.sh` merges each into the chain branch here. Conflict =
  `wait`; red or missing local test run = the follow-up asking for a passing one.
- `dispatch.sh` creates the parent branch on origin if missing, and the chain branch here from it.
- Chain done: `integrate.sh` queues its `<F>-integrate` with `integration` the parent; its worker
  pushes and opens one PR into the parent's branch, merged by the merge gate when green like any
  sub-PR. A red chain PR holds only that chain. After merge `cycle.sh` records the chain `merged`.
- An outside item depending on a chain item waits for the chain to merge into the parent; a
  diamond's join waits for every chain it joins.
- The parent stays open (or `held`) until each chain lands; an all-dropped chain releases it.

## Merge gate (script-enforced)

`cycle.sh` runs `merge.sh` for green sub-PRs into an integration branch; humans merge everything
else. Once per integration: `merge.sh rules <branch>`. `no-merge-commit` or `unknown`: say so
(`cycle.sh` records `"human"`). `strict`: say once that turning it off for `feature/*` avoids CI
reruns on every sibling merge; merges still proceed.

## Finishing

Main syncs only at the end. `integrate.sh check` (via `cycle.sh`) gives each open integration a
verdict; `ready` queues the synthetic `<F>-integrate` item, whose worker merges `origin/<default>`
and opens `feature/<slug>` → default listing every sub-PR and linking the epic or issues: the final
PR, the user's to review and merge. `cycle.sh` records its `pr`, then `state` `merged`.

`held` (an item `blocked`, `waiting` or `skipped`): tell the user once, naming it. They unblock or
drop it ("ship F1 without T3": `skipped`, `dropped: true`, which releases it); a skipped undropped
item keeps holding. `empty` (all dropped): tell the user, nothing to land. Report back runs
`integrate.sh check` only (never `add`): report `held` ones and what holds them, `ready` as "say
'runwaves continue' to open its feature PR".

## Follow-ups after a merge

An `in-review` item owing work after another merges: `followUp: {"after": "<ID>", "message":
"<what to do>"}`; `cycle.sh` sends it when `<ID>` merges. `<ID>` fails: keep it, tell the user.
"follow up on <ID>: …" during review: `send.sh` at once.
