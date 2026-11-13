# Plan file schema

```json
{"repo": "owner/repo", "runId": "20261112-2015", "status": "active", "maxParallel": 5,
 "autoApprove": true, "presets": {"claude": ["auto"]}, "autoOnly": {"claude": "accepted"},
 "groups": {"In Progress": "in progress", "Blocked": "new group-6", …},
 "items": [{"id": "#340", "title": "…", "ask": null, "notes": null, "extras": null, "dependsOn": [],
 "why": "", "skill": "implement", "agent": "claude", "preset": "auto", "state": "queued",
 "branch": null, "workspace": null, "terminal": null, "pr": null, "checked": null,
 "acceptance": null, "followUp": null}]}
```

- `status`: `active`|`finished`. `state`, `reason`: see SKILL.md. `plan.sh` adds `owner`,
  `heartbeat`, `takenOverFrom`, `forcedAt`, `carryOver`; `dispatch.sh` adds `dispatchFailures`
  after a failed workspace creation.
- `pageId`: the run-summary page, once published; later [summaries](../SKILL.md#run-summary) pass
  it as `--page` to add a version.
- `ask`: a free-text task's slice of the user's request, verbatim: the task and its whole scope
  (the [acceptance check](../SKILL.md#acceptance-check) grades against it alone). `notes`: the
  orchestrator's build notes (context, out of scope), adding no work. `extras`: what it would add
  beyond the `ask`, for the human only (possible follow-ups; never sent to the worker). All three
  `null` for tracker items (the issue body is the user's text). `text`: an older plan's single
  free-text description, still loaded and dispatched; ignored when `ask` is set.
- `preset`: `auto`|`regular`. `presets`: per harness, the kinds
  [preflight](../SKILL.md#worker-agents-and-auto-approval) found. `autoOnly`: per auto-only
  harness, the user's `"accepted"`/`"declined"` (absent: not asked yet).
- `checked`: the worker's `checked:` line. `acceptance`: `null`, `"ok"`, or the
  [gap](../SKILL.md#acceptance-check). `followUp`: `null` or `{"after": "<ID>", "message": "<text>"}`
  ([after a merge](../SKILL.md#follow-ups-after-a-merge)).
