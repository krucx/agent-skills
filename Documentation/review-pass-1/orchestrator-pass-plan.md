# Orchestrator pass: gaps and a token plan (2026-11-14)

Scope: `skills/orchestrator` at commit 9baa3eb. Plan only; nothing changed.

## 1. Baseline, measured from Claude Code transcripts

| Run | Orchestrator turns | Orchestrator output tokens | Orchestrator cache-read tokens | Peak context | Workers (output / cache-read) |
| --- | --- | --- | --- | --- | --- |
| 12 issues, 2026-11-13 (Sonnet) | 151 | 114K | 25.6M | 224K | 8 of 12 measured: 129K / 18.3M (≈190K / 27M for all 12) |
| 4-issue epic, 2026-11-14 (Sonnet) | 73 | 26K | 6.2M | 103K | 4 workers: 20K / 2.4M |

So the orchestrator spends about as much as all its workers combined. The bar ("comparable to running the items myself") means the orchestrator should be a small fraction of worker spend, say under 10%.

Per watch cycle today (from the traces): 4 model turns.
1. `cat` the waiter output, `plan.sh heartbeat`, `status.sh --compact` (300–400 output tokens, 1–3K chars back).
2. Hand-written jq surgery on the plan, tag moves, often `gh pr view --json files` and `gh issue view` for the acceptance check (600–2,200 output tokens).
3. Restart `wait-change.sh`.
4. A full status table in chat (300–850 output tokens).

17–20 cycles in the 12-item run; about 5 of them needed a judgment (one acceptance gap, two rebase follow-ups, one user request, the finish). The rest were mechanical.

## 2. Where the tokens go

1. **Prose is the program.** The reconcile table (7 rows), transitions table (12 rows), merge verdicts, integrate verdicts and tag rules are executed by the model every cycle, by writing ad-hoc jq. One run: 41 `plan.sh` calls, 25 ad-hoc Bash calls. This is also the bug source: three data errors in two runs (plan write failed before launch, `checked` omitted, `pr` stored as a number), each costing extra turns and one needing the user.
2. **Every event is a model turn.** `wait-change.sh` exits on any change, including noise: `idle->working` on an in-review item, `none->working` right after dispatch.
3. **Context bloat.** SKILL.md (6.7K tokens) plus references (2.7K) sit in every turn; over 150 turns that is about 1.4M cache-read tokens on the rulebook alone. Per-cycle results and tables accrete to 224K and force compaction, after which the rules themselves may be summarized away.
4. **Narration.** A full table every cycle although SKILL.md says "if changed".
5. **Preflight** is 3–4 turns of ad-hoc checks (tools, auth, project, claim, groups, presets, `--help` probing).
6. **Acceptance check** costs two `gh` calls plus reasoning per item. It caught one real gap in 16 items (#362). Worth keeping, not worth its current price.
7. `effort: low` Sonnet running a 40-rule program each cycle is the wrong split: the mechanics should be in bash, the judgment in the model.

## 3. Gaps (behaviour, not just cost)

- G1 Model-written plan data drifts from the schema (pr as number, missing `checked`). Fix: scripts write every mechanical field; the model only ever passes a verdict string.
- G2 Status table drawn from the model's memory, not the plan. Fix: `table.sh` renders it.
- G3 Noise wakeups (see 2.2).
- G4 After compaction the model loses the rule tables; a Continue mid-run then relies on a summary of a summary. Scripts owning the mechanics make the run robust to this.
- G5 Rebase-after-squash follow-up is deterministic but composed by the model each time.
- G6 The go message bundles up to four decisions (where independents go, each chain, auto-only, regular-preset items). Fine once per run, but the text that drives it is a third of SKILL.md and loads for runs that have none of it.
- G7 No built-in measurement. A `scripts/usage.py` that reports orchestrator vs worker spend from the transcripts would make regressions visible.
- G8 Run-summary page asks a question at every finish and close. Low value per ask.

## 4. Plan

### A. Scripts own the mechanics (biggest win, do first)

- `cycle.sh <project> <plan>`: heartbeat; `status.sh`; the reconcile repairs; the deterministic transitions (both tables); `merge.sh run` for green sub-PRs into integration branches; `integrate.sh add` when `ready`; dispatch everything startable (squash/stack rule included); the scripted rebase follow-up; tag moves; finished detection and the desktop notification. Output: JSON of events that need judgment only: acceptance packets, worker questions, fatal blocks, dependency failures, stalls, `finished`. Exit 0 = nothing for the model; exit 10 = model needed.
- `watch.sh`: loop `wait-change.sh` → `cycle.sh` until exit 10 or 20 minutes. Backgrounded once; the model wakes only on judgment or the periodic heartbeat summary.
- `table.sh`: renders the status table from plan + status; remembers the last render and prints `unchanged` when nothing moved.
- `preflight.sh`: one call, one JSON (tools, auth, repo, project ID, plan claim result, group map, presets by harness, squash rules). Distinct exit codes for each ask-once branch (no groups saved, no auto preset, live owner, stale owner).
- `accept.sh <ID>`: builds the acceptance packet under 1K chars (criteria from issue checkboxes or `ask`, PR file list and count, `checked`). `accept.sh <ID> ok` or `accept.sh <ID> gap "<text>"` writes the plan and sends the follow-up.
- `send.sh <ID> "<text>"`: relay to a worker, with the plan state change, replacing hand-assembled sends.
- Tests: each transition-table row becomes a `cycle.sh` test case in `test/run.sh`. That is also the proof of parity with today's prose.

### B. SKILL.md: rulebook → protocol (6.7K → about 2K tokens)

Keep: modes table; the loop (preflight → plan → go → dispatch → watch → act on events → finish); what needs judgment and what is never done (implement, approve, merge default-branch PRs, answer permission prompts, restart hosts, archive workspaces); the planning rules (tracker lookup, dependencies, waves, free-text `ask` verbatim, one go message); the go-message contract.

Move to references, loaded only when the run has that shape: `integrations.md` (epic, `feature:`, chains, merge gate, finishing), `approval.md` (auto/regular/autoOnly), `recovery.md` (takeover, stale, carry-over), `summary-page.md`. `plan-schema.md` and `worker-prompt.md` stay. `cli-surface.md` becomes script-only knowledge.

Delete from SKILL.md: everything `cycle.sh` now does (reconcile table, transitions table, verdict handling, tag moves, rebase recipe, pr-as-URL warnings), repeated "never" lines, multi-harness detail beyond one line.

### C. Reporting rules

Chat output only on: plan and go, judgment events, user questions, finished. Table only on go, report back, finished, and when a row changed state (`table.sh` decides). Run-summary page on request only ("orchestrator summary"); drop the question.

### D. Watcher noise

`wait-change.sh` ignores `working<->idle` on in-review and done items unless a PR state changes, and `none->working` within a minute of dispatch. With `watch.sh` looping silently this matters less, but it cuts CLI churn too.

### E. Shift the acceptance comparison to the worker (recommended; your call)

The worker already holds the issue and the diff. Add to the DONE block: `criteria: 5/5` plus one line per unmet criterion. The orchestrator gate becomes mechanical (all met → in-review; unmet → one follow-up). Model judgment only when the worker reports partial. The orchestrator stops re-fetching issue bodies and file lists per item.

### F. Smaller

- `model: sonnet` stays; try Haiku for Report back and Continue once scripts carry the logic.
- `scripts/usage.py` (G7) in the repo, with the numbers above as the baseline.
- `groups.sh` unchanged; its ask surfaces through `preflight.sh`'s exit code.

## 5. Expected result

Turns ≈ 2 (preflight, plan) + 1 (go) + judgment events (0.3–0.5 per item) + 1 (finish), each at ≤ 40K context. For the 12-item run: roughly 12–15 turns, about 0.5M cache-read, about 10K output, against 151 / 25.6M / 114K today. Orchestrator at 3–5% of worker spend, and no model-written plan data.

## 6. Order of work

1. `cycle.sh` + `table.sh` + tests, SKILL.md untouched. Run it against the current prose for a real run to confirm parity.
2. `watch.sh`, `preflight.sh`, `accept.sh`, `send.sh`.
3. SKILL.md rewrite and references split; README update.
4. Dry run on agent-skills itself (free text, 3 tasks), measure with `usage.py`; then a real run on the Mortgage repo.

## 7. Decisions (2026-11-14)

1. **Scripts act on their own, but every action is an event.** `cycle.sh` merges green sub-PRs, dispatches dependents, moves tags and sends the scripted rebase follow-up without a model turn. Each action appends to an `events` log in the plan (`{at, item, action, detail}`: dispatched, pr-opened, merged-into-F1, tag-moved, follow-up-sent, blocked, finished). `watch.sh` prints the events since the last wake; when the model wakes it relays them in one or two lines; `report back` and the finish show the full log. Nothing happens silently.
2. **Acceptance is hybrid: the worker reports, the orchestrator eyeballs.** The DONE block gains `criteria: <met>/<total>` plus one line per unmet or unclear criterion. `accept.sh <ID>` then builds the eyeball packet: the criteria, the worker's criteria lines and `checked`, the PR's file list with added/removed counts (`gh pr view --json files`), and the diff itself only when the PR is small (under about 150 changed lines; otherwise names only). The model eyeballs every DONE item that arrived since the last wake in **one** turn, answers `ok` or `gap: <text>` per item, and `accept.sh` writes the plan and sends the one follow-up. Still never a second round; a remaining gap goes under the table.
3. **Workers: Claude, Codex, OpenCode, Antigravity.** The harness → first-line and auto-approve rules live in `dispatch.sh` and `preflight.sh`, not in SKILL.md; SKILL.md keeps one line. Add OpenCode and Antigravity to `dispatch.sh`'s first-line case and to the auto-instance detection, after verifying each one's skill-invocation syntax and auto-approve flag against its current CLI (open task; today only `claude`, `hermes` and `codex` are named). Trackers: GitHub Issues and free text stay in the core; Linear/Jira move to `references/trackers.md`.
4. **Summary page stays, at zero model cost.** `summary.sh <plan>` renders the HTML from the plan alone (items, PRs, `checked`, acceptance, extras, events, carry-over) and publishes with `superset pages publish --visibility just_me`, reusing `pageId` for a new version. The finish runs it and prints the URL; no question is asked. "org" visibility on request.
5. **Chat is events-only.** Plan, go, judgment wakes (with the events since the last one), user questions, finish. Table only on go, report back, finish, and when `table.sh` says a row changed.

## 8. Amendments to section 4 from the decisions

- A: `cycle.sh` writes the `events` log; `watch.sh` prints new events on every wake; `accept.sh` batches all pending DONE items into one packet.
- B: SKILL.md keeps a one-line harness list and points to `dispatch.sh`; Linear/Jira go to `references/trackers.md`.
- C: the summary question is gone; `summary.sh` runs at finish.
- E: adopted as the hybrid in decision 2; the "never code" rule relaxes to "diff only when small, via `accept.sh`".
- Worker prompt (`worker-prompt.md`, `dispatch.sh`): add the `criteria:` lines to the DONE block; `status.sh` parses them.
- Schema (`plan-schema.md`): add `events` (array) and `criteria` (item: `{met, total, unmet: [...]}`).

## 9. Order of work (final)

1. `cycle.sh` with the `events` log, `table.sh`, tests per transition row. SKILL.md untouched; run one real cycle alongside the prose to confirm parity.
2. `watch.sh`, `preflight.sh`, `accept.sh` (batched eyeball packet), `send.sh`, `summary.sh`; worker DONE block gains `criteria:`; `status.sh` parses it.
3. OpenCode and Antigravity in `dispatch.sh` and auto detection, after checking their CLIs.
4. SKILL.md rewrite and references split (`integrations.md`, `approval.md`, `recovery.md`, `trackers.md`); README update.
5. `scripts/usage.py`; dry run on agent-skills (free text, 3 tasks), measured; then a real GitHub-issues run on the Mortgage repo, measured against the section 1 baseline.

## 10. Issues (krucx/agent-skills, filed 2026-11-14)

| Step | Issue | Blocked by |
| --- | --- | --- |
| Schema: `events` log and `criteria` | #45 | — |
| `table.sh` | #46 | — |
| `preflight.sh` | #47 | — |
| OpenCode and Antigravity workers | #48 | — |
| Worker DONE block reports `criteria:` | #49 | #45 |
| `cycle.sh` | #50 | #45, #46 |
| `summary.sh` | #51 | #45 |
| `watch.sh` and the waiter noise filter | #52 | #50 |
| `accept.sh` and `send.sh` | #53 | #49, #50 |
| SKILL.md rewrite and references split | #54 | #47, #48, #52, #53, #51 |
| `usage.py` and the measured runs | #55 | #54 |

Wave 1: #45, #46, #47, #48. Wave 2: #49, #50, #51. Wave 3: #52, #53. Then #54, then #55.
