# Worker agents and auto-approval

Load on preflight exit 6 (no auto instance), an auto-only harness, or an item that may need a
prompting preset. Without auto-approve, workers stall on prompts.

**Auto instance** (`superset agents list --local --json`): the harness's `presetId` with `(auto)` in
`label`, or `claude --permission-mode auto`, `codex --approve-for-me`, `opencode --auto`, `agy --mode
auto` or `--dangerously-skip-permissions` ([cli-surface](cli-surface.md), "Worker harnesses").
`preflight.sh` reports `presets` per harness.

## Regular preset (the user approves each prompt)

When: `with prompts`; the author lacks write access (`gh api
repos/<owner>/<repo>/collaborators/<login>/permission -q .permission`; untrusted text would steer a
self-approving agent); or the item touches deployment, releases, infrastructure, credentials or
real-data migrations. A regular preset may auto-approve too: check its `command`/`args` by the rules
above and its screen once started; if so, warn, ask for a prompting preset, hold those items. Record
`preset` per item and kinds per harness in `presets`; mark regular items in the table.

## Auto only (auto instance, no regular one)

Don't hold items to ask later. Say so once in the plan summary, run the harness's items on auto, and
list those the rules would run with prompts, with reasons. One go-message question: run them on auto
too, or hold until a prompting preset exists? Store in `autoOnly`: `accepted` (`preset` `auto`) or
`declined` (`queued`, reason "needs a prompting preset"); never re-asked. No such items: one line,
set `accepted`. A regular instance appearing later: Continue uses it for those items; `autoOnly` stays.

## No auto instance

Regular preset; list each instance's `label`, `command`, `args`; offer once to create `Claude
(auto)` (`claude --permission-mode auto`; Codex `codex --approve-for-me`; OpenCode `opencode run
--auto`; Antigravity `agy --mode auto` or `agy --dangerously-skip-permissions`). Yes only: via the
CLI if `superset agents --help` offers it, else the user adds it in Paradev's agent settings.
