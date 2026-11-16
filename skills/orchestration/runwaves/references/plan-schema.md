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

- `runId` is derived by `plan.sh write` from `startedAt` at creation, in `YYYYMMDD-HHMM` UTC format;
  later writes preserve both values. `status`: `active`|`finished`. `state`, `reason`: see SKILL.md;
  `cycle.sh` adds the transient state `accepting`
  (a DONE block arrived, `acceptance` `"pending"`; it becomes `in-review` only through `accept.sh`, and does not count against the parallel limit). `plan.sh` adds `owner`,
  `heartbeat`, `takenOverFrom`, `forcedAt`, `carryOver`, and `integrationCarryOver` on close;
  `dispatch.sh` adds `dispatchFailures`
  after a failed workspace creation.
- `integrations` (optional; older plans lack it): feature branches that collect a run's PRs.
  `branch`: `feature/<slug>`; `base`: always the repo's default branch (integrations never nest);
  `pr`: the PR that lands it on `base`, once opened; `state`: `open`|`merged`; `mergeNote`
  (optional): `"human"` when its rulesets forbid merge commits (the coordinator then leaves the
  sub-PR merges to humans), `"strict"` once the up-to-date requirement was reported, `"ok"` when `cycle.sh` read its rules and found none in the way, `"local"` for a local branch (no rules read).
  `local` (optional): `true` when the branch lives in this clone only until its final PR: no sub-PRs, no CI per item, `merge.sh` merges accepted worker branches locally ([integrations](integrations.md), "Local integration branch"). Item `integration`:
  an integration's `id`, `dropped` (optional, with state `skipped`): the user dropped it so its
  integration can finish; `epic` (optional): `{id, title, url}` of the parent issue an epic run imported; the final PR links it; `integrates`: on the synthetic `<F>-integrate` item `integrate.sh add`
  creates (no `integration`; targets the default branch, starts on integration `<F>`'s branch), or `null`/absent for an item targeting the default branch. An item's
  **target** is its integration's `branch`, else the default branch; one run may mix both.
- `pageId`: the run-summary page, once published; later [reporting](../SKILL.md#reporting) (`summary.sh`) pass
  it as `--page` to add a version.
- `ask`: a free-text task's slice of the user's request, verbatim: the task and its whole scope
  (the [acceptance check](../SKILL.md#acting-on-needs) grades against it alone). `notes`: the
  coordinator's build notes (context, out of scope), adding no work. `extras`: what it would add
  beyond the `ask`, for the human only (possible follow-ups; never sent to the worker). All three
  `null` for tracker items (the issue body is the user's text). `text`: an older plan's single
  free-text description, still loaded and dispatched; ignored when `ask` is set.
- `pr` (item and integration): `null`, or the full PR URL string (`"https://github.com/owner/repo/pull/388"`),
  never a bare number or `"#388"`; the scripts read it as a string and `plan.sh write` rejects anything else.
- `preset`: `auto`|`regular`. `presets`: per harness, the kinds
  [preflight](../SKILL.md#planning) found. `autoOnly`: per auto-only
  harness, the user's `"accepted"`/`"declined"` (absent: not asked yet).
- `checked`: the worker's `checked:` line. `acceptance`: `null`, `"ok"`, or the
  [gap](../SKILL.md#acting-on-needs). `followUp`: `null` or `{"after": "<ID>", "message": "<text>"}`
  (sent after a merge by `cycle.sh`; see [the loop](../SKILL.md#the-loop)).
- `events` (top level, optional; older plans lack it): append-only log of what the coordinator and
  its scripts did, so scripts can act without a model turn and nothing happens silently. Entry:
  `{"at": "<ISO-8601 UTC>", "item": "<ID or F1 or null>", "action": "<kind>", "detail": "<one line>"}`.
  `action` is one of `dispatched`, `pr-opened`, `in-review`, `merged` (into an integration branch,
  by us), `pr-merged` (by a human), `tag-moved`, `follow-up-sent`, `acceptance-gap`, `blocked`,
  `waiting`, `skipped`, `taken-over`, `finished`, `closed`, and the ones `cycle.sh` adds: `reconciled`,
  `stalled`, `accepting`, `held`, `queued`, `feedback`, `rules`. Append with `plan.sh event <item>
  <action> "<detail>"` (owner-checked, under the lock); read with `plan.sh events [--since <ISO>]`.
  `plan.sh close` appends `closed` and `claim --takeover` appends `taken-over` (previous owner in
  `detail`). `plan.sh write` rejects an entry missing a field or with another action, naming its index.
- `criteria` (item, optional): what the worker reported about the task's acceptance criteria in its
  DONE block: `{"met": <n>, "total": <n>, "unmet": ["<criterion>", …]}`, or `null` when it gave none.
  Written by the coordinator (later `cycle.sh`) from `status.sh`'s worker block. `plan.sh write`
  rejects non-integer `met`/`total`, `met` > `total` or a non-array `unmet`, naming the item.
