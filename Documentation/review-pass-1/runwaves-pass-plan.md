# Runwaves pass: gaps and a token plan (2026-11-14)

Scope: `skills/orchestration/runwaves` (named `orchestrator` until #87). Sections 1-10 are the plan
written at commit 9baa3eb; sections 11-13 record what was built and measured after it.

## Current status (2026-11-17)

- **Built**: every step of section 9, then the backends (#88, #89) and nested local chain branches
  (#91). Script tests: 706 passed, 0 failed. SKILL.md is about 1.3K tokens (6.7K before).
- **Backends**: on an Orca host, `orca` runs every run, large or small, epics and chains
  included (decided 2026-11-17). It uses the same plan file and scripts as `loop`: `cycle.sh`
  runs once per Orca wake instead of under `watch.sh`, `dispatch.sh` starts each worker with
  `orca orchestration worker-start` in its own child worktree, `status.sh` reads Orca's dispatch
  state and `worker_done` reports, `send.sh` uses `orca orchestration send`, and `plan.sh` owns the
  run by the Orca terminal handle. Orca workers get only the task and its end state (about 300
  characters against 3.5K for a Paradev loop worker): Orca's preamble covers reporting, and the
  `worker_done` report stands in for the DONE block. Fanout briefs were already the task only. On Paradev, `fanout` takes 5 or fewer independent free-text
  items, `loop` everything else.
- **Routing**: 18/18 fresh sessions chose the expected skill (section 13), before the Orca change.
- **Token target** (coordinator under 10% of worker spend): not shown yet. The dry runs (sections
  11 and 13) used tiny tasks, so the coordinator's fixed cost dominates them. The verdict waits
  for a run on real issues that need implementing; no run is planned until then.
- **Open**:
  - The Orca backend is covered by the shim tests only; no live Orca run has used the plan yet.
    The Orca dispatch states it maps (`succeeded`, `failed` and the like settle a worker) were
    read from Orca 1.4.259; others count as working.
  - A merge a human makes does not wake an Orca coordinator; "runwaves continue" picks it up.
  - Kept on purpose: `~/.agents/orchestrator/` (saved runs resume from it). Paradev loop workers now
    print `RUNWAVES_WORKER_*`; `status.sh` still reads the older `ORCHESTRATOR_WORKER_*`.

## 1. Baseline, measured from Claude Code transcripts

| Run | Orchestrator turns | Orchestrator output tokens | Orchestrator cache-read tokens | Peak context | Workers (output / cache-read) |
| --- | --- | --- | --- | --- | --- |
| 12 issues, 2026-11-13 (Sonnet) | 151 | 114K | 20.2M | 191K | 12 workers: 278K / 42.7M |
| 4-issue epic, 2026-11-14 (Sonnet) | 73 | 26K | 6.2M | 103K | 4 workers: 20K / 2.4M |

Reproduced with `python3 -I skills/orchestration/runwaves/scripts/usage.py` (issue #55). A turn is one assistant transcript line with usage. The 4-issue run matches exactly (73 turns, 26K output, 6.2M cache-read, 103K peak). The 12-issue run's first 151 turns (`--turns 151` on the 2026-11-13 session, the orchestrator portion) give 114K output, 724K cache-write, 20.2M cache-read and a 191K peak at that point (224K later in the session), 37 minutes. The row above uses those like-for-like figures. The first recording said 25.6M cache-read and a 224K peak, which do not reproduce from those 151 turns: 25.6M only appears at about turn 178, so it counted a longer window. With all twelve worker transcripts found by branch name (`--run 20261113-1424`), workers total 516 turns, 278K output and 42.7M cache-read, so the orchestrator was 41% of worker output and 47% of worker cache-read (the first recording measured only 8 of the 12 workers: 129K / 18.3M).

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

Turns ≈ 2 (preflight, plan) + 1 (go) + judgment events (0.3–0.5 per item) + 1 (finish), each at ≤ 40K context. For the 12-item run: roughly 12–15 turns, about 0.5M cache-read, about 10K output, against 151 / 20.2M / 114K today. Orchestrator at 3–5% of worker spend, and no model-written plan data.

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

## 11. After-numbers (issue #55)

Same columns as the section 1 baseline. Target: orchestrator under 10% of worker output and cache-read, no `jq … | plan.sh write` in the transcript, chat output only on events.

| Run | Orchestrator turns | Orchestrator output tokens | Orchestrator cache-read tokens | Peak context | Workers (output / cache-read) | Orchestrator share (output / cache-read) |
| --- | --- | --- | --- | --- | --- | --- |
| Dry run, agent-skills, free text, 3 tasks (2026-11-14, Sonnet, run 20261114-1200) | 37 | 10K | 1.8M | 58K | 3 workers: 22K / 2.3M | 45% / 78% |
| Real run, krucx/Mortgage-Management-App, 4+ items with a chain | not run | not run | not run | not run | not run | not run |

- Dry run, measured with `usage.py <orchestrator transcript> <worker transcripts>` (the orchestrator was a Sonnet subagent of a Claude Code session, so its transcript sits under the session's `subagents/` folder, which `--run` does not search). Tasks: install.sh `--uninstall` (#69), a root `test.sh` (#71), CONTRIBUTING.md (#70); all three accepted on the first eyeball, 0 hand-written plan writes, 6 `watch.sh` wakes, 27 minutes end to end, peak context 58K. Per item against the 12-issue baseline: 12.3 turns (12.6 before), 3.3K output (9.5K), 0.6M cache-read (1.7M). The share target is not met here because the workers were tiny (13–18 turns, 2–7 minutes each), so the orchestrator's fixed cost (reading SKILL.md, the plan, the go exchange, 17 of its 37 turns were chat with no tool call) dominates; the share should be read on the Mortgage run, whose items are real.
- The Mortgage-Management-App run is deferred to the user. No issues are filed for it.

Acceptance criteria of #55:

- [x] `usage.py` reproduces the Nov 13 baseline from the existing transcript: 151 turns and 114K output match; cache-read is 20.2M, not 25.6M (see section 1).
- [x] `--run` pairs the orchestrator with its workers and prints the percentage (checked against the 2026-11-13 run).
- [ ] Both measured runs recorded in this document: partly met. The dry run is recorded above; the Mortgage run is deferred to the user.
- [ ] The real run's transcript has no hand-written plan writes and a table only at go, wakes with changed rows and finish: unmet, depends on the Mortgage run, deferred to the user.
- [ ] Misses filed as issues and linked here: unmet, depends on the measured runs; none filed.

## 12. Events-only follow-up (#78)

The larger available transcript is run `20261114-2058`, orchestrating #45–#55 and the F1 integration
worker on `feature/45-events-log-and-criteria-in-plan-schema`. It has 11 issue workers, a dependency
chain through #49/#50 → #52/#53 → #54 → #55, and an integration worker. That is representative in
workflow depth and worker volume: 476 worker turns and 443K output tokens, compared with 3 workers
and 22K output tokens in the earlier dry run. The earlier run has no dependency chain and is too
small to use for the efficiency target.

Measured with `python3 -I skills/orchestration/runwaves/scripts/usage.py --run 20261114-2058`:

| Run | Orchestrator turns | Chat-only turns | Orchestrator output | Worker output | Output share | Orchestrator cache-read | Worker cache-read | Cache-read share | Peak context |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `20261114-2058` (11 issues + integration; pre-#78 protocol) | 192 | 41 | 73K | 443K | 16.6% | 22.1M | 46.4M | 47.7% | 157K |

The output target is under 10%, so this baseline misses it. `usage.py` counts chat-only turns as
non-empty assistant text messages without a tool call; the previous counter included 45 empty
assistant continuation turns in its count of 86 no-tool turns. Transcript review found routine
wait/status narration (for example, messages saying the watcher was still running or nothing had
changed). Those are the misses this issue addresses; no separate follow-up issue was filed because
they fall within #78's scope. The events-only rule in `skills/orchestration/runwaves/SKILL.md` now prohibits
that narration, requires silent restarts when a wake needs no judgment or user action, and limits
judgment updates to the new events that explain the decision. Mechanical progress remains in the
watcher output and event log.

This transcript predates #78, so it establishes the problem and workload size; it does not verify
the revised rule. A post-change representative run has not been recorded: the current agent-skills
orchestration plan already owns this repository, and starting another run here would collide with
that active plan. Re-measure after that run releases the plan. The post-change transcript must show
that every non-empty orchestrator chat message is a plan/go, event-driven judgment or user action,
user question, explicit report-back, or finish; record any violations as linked follow-up issues.

## 13. Dry run and routing after #89 and #91 (#92)

### Routing, checked 2026-11-17

Each phrase ran twice in a fresh headless session (`claude -p "<phrase>" --allowedTools Skill
--max-turns 3`, Claude Code 2.1.311, stdin closed) from an empty scratch repo whose
`.claude/skills/runwaves` links to this branch's skill. The session also loaded the global
`orchestration` (Orca) and `superset:orchestrate` skills, so all three competed. Only the Skill tool
was allowed, so the first Skill call is the routing decision and nothing ran after it. The sessions
inherited this Orca session's environment, including `ORCA_WORKSPACE_ID`.

| Phrase | Expected | Routed (2 sessions) |
| --- | --- | --- |
| `runwaves 340-343` | runwaves | runwaves, runwaves |
| `plan runwaves for 340-343, 345 onwards` | runwaves | runwaves, runwaves |
| `runwaves feature #400` | runwaves | runwaves, runwaves |
| `runwaves report back` | runwaves | runwaves, runwaves |
| `runwaves continue` | runwaves | runwaves, runwaves |
| `runwaves close` | runwaves | runwaves, runwaves |
| `plan these issues into waves and run them with parallel workers: #12 #13 #14, each to its own PR` | runwaves | runwaves, runwaves |
| `run these 3 refactors in parallel and tell me when done` | not runwaves | none, none (asked which refactors) |
| `have Codex review this branch and report back` | orchestration | orchestration, orchestration |

All 18 sessions routed as expected. Two limits: the ad-hoc fan-out phrase invoked no skill (the
scratch repo is empty, so the session asked which refactors), which shows runwaves is not chosen but
not that `superset:orchestrate` is; and the skill was linked per project, not installed. One install
gap: `~/.claude/skills/orchestrator` links to `~/.agents/skills/orchestrator`, which links to the old
`skills/orchestrator` path in the main clone, which no longer exists. A fresh session outside
this repo therefore had no runwaves skill. Fixed the same day by running `install.sh` from the main
clone, which removed both stale links and linked `runwaves`.

### Orca dry run on dummy data, 2026-11-17

Run `20261117-0730` on a throwaway local repo (no remote, registered in Orca as `runwaves-dummy`, with
the skill linked in), so no plan file, branch or PR touched a real repo. The coordinator was a Claude
Code terminal in an Orca workspace of that repo, given four free-text tasks: T1 `--help` for
`add.sh`, T2 a `test.sh` that "comes after T1", T3 a README section, T4 an `.editorconfig`.

- Planning: `runwaves` loaded, `table.sh --go` showed waves 1 (T1, T3, T4) and 2 (T2), critical
  path T1 → T2, "Backend: orca, 4 items" after the go. Only `orchestration` was loaded; the
  coordinator never loaded `superset:orchestrate` or any `paradev/` file.
- Dispatch: T1, T3 and T4 started at once in their own worktrees; T2 started on T1's branch when
  T1's `worker_done` arrived. All four succeeded; one final per-task report; no PRs (free text).
- Found: `<plan-file>` before the go was undefined for every backend, so the coordinator read
  `table.sh` and `plan.sh` to improvise one. SKILL.md now says the draft lives in the scratch folder.
  It also read `orca.md` before the go, which SKILL.md already forbids; not changed.

Measured with `usage.py <coordinator transcript> <worker transcripts>`:

| Run | Orchestrator turns | Chat-only turns | Orchestrator output | Worker output | Output share | Orchestrator cache-read | Worker cache-read | Cache-read share | Peak context |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Orca dry run `20261117-0730` (4 tiny tasks, 1 chain) | 27 | 5 | 9K | 5K | 180% | 1.4M | 0.85M | 165% | 66K |

The share is far above target for the same reason as section 11's dry run: each worker took 5 or 6
turns, so the coordinator's fixed cost (skill, `orchestration` guide, plan, go) dominates. Per item
it is 6.8 turns, 2.3K output and 0.35M cache-read, against 12.3, 3.3K and 0.6M in section 11 and
12.6, 9.5K and 1.7M in the 12-issue baseline.

### Measured runs: not run

The loop run with a nested local chain and the small fanout run both need a Paradev host. The
backend rule picks **orca** first whenever `ORCA_WORKSPACE_ID` is set. The session that did this
check ran inside Orca, and Paradev was not running, so neither run could start there. Start both
from a Paradev workspace, then record them here with `usage.py --run <runId>`, using the columns in
section 12:

| Run | Orchestrator turns | Chat-only turns | Orchestrator output | Worker output | Output share | Orchestrator cache-read | Worker cache-read | Cache-read share | Peak context |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Loop, nested local chain | not run | not run | not run | not run | not run | not run | not run | not run | not run |
| Fanout, 3 free-text tasks | not run | not run | not run | not run | not run | not run | not run | not run | not run |
| Baseline: 12 issues, 2026-11-13 (section 1) | 151 | not measured | 114K | 278K | 41% | 20.2M | 42.7M | 47% | 191K |
| Baseline: `20261114-2058` (section 12) | 192 | 41 | 73K | 443K | 16.6% | 22.1M | 46.4M | 47.7% | 157K |

Acceptance criteria of #92:

The section 1 row uses the like-for-like figures at turn 151 (20.2M cache-read, 191K peak), not the
25.6M and 224K first recorded for the baseline.

- [ ] Measurement recorded and compared with the Nov 2026 baseline: unmet, deferred to the user. Needs
  a Paradev host (above).
- [x] Each trigger phrase routes correctly in a fresh session: met for every phrase in the
  description, with the skill linked per project (limits above).
