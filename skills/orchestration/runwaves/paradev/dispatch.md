# Paradev dispatch

Loop only, after the plan is approved (preflight: when `preflight.sh` exits non-zero). `<skill-dir>`
= SKILL.md's folder; run scripts in the repo. Only `plan.sh write` changes the plan: never jq it.

## Preflight

`<skill-dir>/scripts/preflight.sh [--mode run|continue|report|close] [--harness <name>…]`. Exit 0
go on; 1 tool/auth/host failure: stop, say which (host: `superset:doctor`; never start it); 2 not a
GitHub repo or no project; 3 live owner: name its terminal, offer a report back (takeover only if
the user says so); 4 stale owner: Continue takes over, a Run asks; 5 group map unsaved or a tag
lost: ask once; 6 harness with no auto instance (go message). Owners, takeover, carry-over, close:
[recovery](../references/recovery.md).

## Save and dispatch

After `plan.sh write` ([schema](../references/plan-schema.md)), dispatch only via `dispatch.sh`.
Presets, auto-only: [approval](../references/approval.md). Then the watch in [loop.md](loop.md).
