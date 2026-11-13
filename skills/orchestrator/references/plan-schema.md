# Plan file schema

```json
{"repo": "owner/repo", "runId": "20261112-2015", "status": "active", "maxParallel": 5,
 "autoApprove": true, "presets": {"claude": ["auto"]}, "autoOnly": {"claude": "accepted"}, "groups": {"In Progress": "in progress", "Blocked": "new group-6", …},
 "items": [{"id": "#340", "title": "…", "ask": null, "notes": null, "extras": null, "dependsOn": [], "why": "",
 "skill": "implement", "agent": "claude", "preset": "auto", "state": "queued", "branch": null, "workspace": null, "terminal": null, "pr": null,
 "checked": null, "acceptance": null, "followUp": null}]}
```

`status`: `active`|`finished`; `pageId`: the run-summary page's ID once published (absent: none; later
[summaries](../SKILL.md#run-summary) pass it as `--page` to add a version); `plan.sh` adds `owner`, `heartbeat`, `takenOverFrom`, `forcedAt`,
`carryOver`. `state` and `reason`: see SKILL.md. `ask`: a free-text
task's slice of the user's request, verbatim (the task and its whole scope; the [acceptance
check](../SKILL.md#acceptance-check) grades against it alone). `notes`: the orchestrator's build
notes for it (context, out of scope), adding no work. `extras`: what the orchestrator would add
beyond the `ask`, for the human only (possible follow-up work, never sent to the worker). All three
`null` for tracker items, whose issue body is already the user's text. `text`: an older plan's
single free-text description, still loaded and dispatched as before (no `ask`). `preset`: `auto`|`regular`. `presets`: per harness, the kinds
[preflight](../SKILL.md#worker-agents-and-auto-approval) found. `autoOnly`: per harness with only an auto
instance, the user's answer (`"accepted"`/`"declined"`; absent: not asked yet). `checked`: the
worker's `checked:` line. `acceptance`: `null`, `"ok"`, or the [gap](../SKILL.md#acceptance-check).
`followUp`: `null` or `{"after": "<ID>", "message": "<text>"}`
([after a merge](../SKILL.md#follow-ups-after-a-merge)). `dispatchFailures`: set by `dispatch.sh` after a
failed workspace creation.
