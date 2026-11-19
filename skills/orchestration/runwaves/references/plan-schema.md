# Plan file schema

```json
{"repo": "owner/repo", "runId": "20261112-2015", "startedAt": "2026-11-12T20:15:03Z", "status": "active", "maxParallel": 5,
 "autoApprove": true, "presets": {"claude": ["auto"]}, "autoOnly": {"claude": "accepted"},
 "groups": {"In Progress": "in progress", "Blocked": "new group-6", …},
 "integrations": [{"id": "F1", "title": "…", "branch": "feature/<slug>", "base": "main", "pr": null,
 "state": "open"}],
 "items": [{"id": "#340", "title": "…", "integration": null, "ask": null, "notes": null, "extras": null, "dependsOn": [],
 "why": "", "skill": "implement", "agent": "claude", "preset": "auto", "state": "queued",
 "branch": null, "workspace": null, "terminal": null, "pr": null, "checked": null,
 "acceptance": null, "followUp": null, "criteria": null}],
 "events": [{"at": "2026-11-12T20:15:03Z", "item": "#340", "action": "dispatched", "detail": "workspace w340, claude auto"}]}
```

- `runId`: `plan.sh write` derives it from `startedAt` at creation (`YYYYMMDD-HHMM` UTC); later
  writes keep both. `status`: `active`|`finished`. Item `state`: `planned` (draft), `queued`,
  `in-progress`, `accepting`, `in-review`, `feedback` (follow-up being worked), `waiting`,
  `blocked`, `done`, `skipped`; `reason`: one line for `blocked`, `waiting`, `skipped`, `feedback`.
  After the go only scripts move states. `accepting` (by `cycle.sh`): a DONE block arrived,
  `acceptance` `"pending"`; becomes `in-review` only via `accept.sh`; not counted against the
  parallel limit. `plan.sh` adds `owner`, `heartbeat`, `takenOverFrom`, `forcedAt`, and on close
  `carryOver`, `integrationCarryOver`; `dispatch.sh` adds `dispatchFailures` after a failed
  workspace creation.
- `integrations` (optional; older plans lack it): feature branches collecting a run's PRs.
  `branch`: `feature/<slug>` (`chain/<id>-<slug>` for a local chain branch); `base`: the default
  branch, except a local chain branch's: its `parent`'s branch; `pr`: the PR landing it on `base`,
  once opened; `state`: `open`|`merged`; `mergeNote` (optional): `"human"` (rulesets forbid merge
  commits; humans merge its sub-PRs), `"strict"` (up-to-date requirement reported), `"ok"` (rules
  read, none in the way), `"local"` (no rules read). `local` (optional): `true` = lives in this
  clone until its final PR ([integrations](integrations.md), "Local integration branch"). `parent`
  (optional, with `local: true`): a local chain branch's GitHub integration ("Local chain branch");
  its `<F>-integrate` item has `integration` the parent; outside the chain, a dependency on a chain
  item is met only once the chain is `merged`.
- Item `integration`: an integration `id`, or `null`/absent (default branch). `dropped` (optional,
  with `skipped`): the user dropped it so its integration can finish. `epic` (optional): `{id,
  title, url}` of an imported epic's parent; the final PR links it. `integrates`: on the synthetic
  `<F>-integrate` item `integrate.sh add` creates (no `integration`; targets the default branch,
  starts on `<F>`'s branch).
- `orcaRun` (Orca): the Orca Run holding the task graph. Item `orcaTask`: its Task there, created by
  `cycle.sh` with the item's dependencies as Task deps; the worker's Task is its child.
  `orcaStatus`: what `cycle.sh` last set (`completed` once `done`, `failed` once `skipped`).
- `pageId`: the summary page once published; later `summary.sh` passes it as `--page`.
- `ask`: a free-text task's slice of the user's request, verbatim: its whole scope (the
  [acceptance check](../paradev/loop.md#acting-on-needs) grades against it alone). `notes`:
  coordinator's build notes, adding no work. `extras`: beyond the `ask`, for the human only (never
  sent to the worker). All three `null` for tracker items. `text`: an older plan's free-text
  description, still dispatched; ignored when `ask` is set.
- `workspace`, `terminal`: Paradev workspace and agent terminal; on Orca the dispatch ID (`ctx_…`)
  and terminal handle (`term_…`). `owner`: the coordinator's terminal, likewise.
- `pr` (item, integration): `null` or the full PR URL string, never a number or `"#388"`;
  `plan.sh write` rejects anything else.
- `preset`: `auto`|`regular`. `presets`: per harness, the kinds preflight found. `autoOnly`: per
  auto-only harness, `"accepted"`/`"declined"` (absent: not asked).
- `checked`: the worker's `checked:` line. `acceptance`: `null`, `"ok"`, or the gap. `followUp`:
  `null` or `{"after": "<ID>", "message": "<text>"}` (sent by `cycle.sh` after that merge).
- `events` (optional; older plans lack it): append-only log of what the coordinator and scripts did.
  Entry `{"at": "<ISO-8601 UTC>", "item": "<ID or F1 or null>", "action": "<kind>", "detail": "<one
  line>"}`. `action`: `dispatched`, `pr-opened`, `in-review`, `merged` (into an integration, by
  us), `pr-merged` (by a human), `tag-moved`, `follow-up-sent`, `acceptance-gap`, `blocked`,
  `waiting`, `skipped`, `taken-over`, `finished`, `closed`, `reconciled`, `stalled`, `accepting`,
  `held`, `queued`, `feedback`, `rules`, `graph` (Orca task graph). Append: `plan.sh event <item>
  <action> "<detail>"` (owner-checked, locked); read: `plan.sh events [--since <ISO>]`. `plan.sh
  close` appends `closed`, `claim --takeover` `taken-over` (previous owner in `detail`). `plan.sh
  write` rejects an entry missing a field or with another action, naming its index.
- `criteria` (optional): the DONE block's `{"met": <n>, "total": <n>, "unmet": ["<criterion>", …]}`,
  or `null`; from `status.sh`'s worker block. `plan.sh write` rejects non-integer `met`/`total`,
  `met` > `total` or non-array `unmet`, naming the item.
