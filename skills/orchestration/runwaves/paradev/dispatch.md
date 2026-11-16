# Paradev dispatch

Loop backend only: preflight and dispatch. Read after the plan is approved (preflight: when
`preflight.sh` exits non-zero). `<skill-dir>` = the folder holding SKILL.md; run scripts inside the
repo. Never write jq against the plan: only `plan.sh write` changes it.

## Preflight

`<skill-dir>/scripts/preflight.sh [--mode run|continue|report|close] [--harness <name>…]`.
Exit 0 go on; 1 tool/auth/host failure, stop and say which (host trouble: `superset:doctor`;
never start the host); 2 not a GitHub repo or no project; 3 live owner: name its terminal, offer
a report back (takeover only if the user says so); 4 stale owner: Continue takes over, a Run
asks; 5 group map unsaved or a tag lost: ask once; 6 a harness with no auto instance (see the go
message). Owners, takeover, carry-over, close: [recovery](../references/recovery.md).

## Save and dispatch

After `plan.sh write` ([schema](../references/plan-schema.md)), dispatch is `dispatch.sh`, never by
hand. Auto and regular presets, auto-only: [approval](../references/approval.md). Then start the
watch in [loop.md](loop.md).
