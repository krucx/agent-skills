# Plan file schema

```json
{"repo": "owner/repo", "runId": "20261112-2015", "status": "active", "maxParallel": 5,
 "autoApprove": true, "presets": {"claude": ["auto"]}, "autoOnly": {"claude": "accepted"}, "groups": {"In Progress": "in progress", "Blocked": "new group-6", …},
 "items": [{"id": "#340", "title": "…", "text": null, "dependsOn": [], "why": "",
 "skill": "implement", "agent": "claude", "preset": "auto", "state": "queued", "branch": null, "workspace": null, "terminal": null, "pr": null,
 "checked": null, "acceptance": null, "followUp": null}]}
```

`status`: `active`|`finished`; `plan.sh` adds `owner`, `heartbeat`, `takenOverFrom`, `forcedAt`,
`carryOver`. `state` and `reason`: see SKILL.md. `text`: a free-text
task's description. `preset`: `auto`|`regular`. `presets`: per harness, the kinds
[preflight](../SKILL.md#worker-agents-and-auto-approval) found. `autoOnly`: per harness with only an auto
instance, the user's answer (`"accepted"`/`"declined"`; absent: not asked yet). `checked`: the
worker's `checked:` line. `acceptance`: `null`, `"ok"`, or the [gap](../SKILL.md#acceptance-check).
`followUp`: `null` or `{"after": "<ID>", "message": "<text>"}`
([after a merge](../SKILL.md#follow-ups-after-a-merge)). `dispatchFailures`: set by `dispatch.sh` after a
failed workspace creation.
