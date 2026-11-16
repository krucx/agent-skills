# Worker agents and auto-approval

Load when preflight reports a harness with no auto instance (exit 6), an auto-only harness, or an
item that may need a prompting preset. Without auto-approve, workers stall on prompts.

An **auto instance** (`superset agents list --local --json`) has the harness's `presetId` and
`(auto)` in `label`, or is `claude --permission-mode auto`, `codex --approve-for-me`, `opencode
--auto`, or `agy` with `--mode auto` or `--dangerously-skip-permissions` (see
[cli-surface](cli-surface.md), "Worker harnesses"). `preflight.sh` reports `presets` per harness.

## Regular preset (the user approves each prompt)

Use it when: the user said `with prompts`; the author lacks write access
(`gh api repos/<owner>/<repo>/collaborators/<login>/permission -q .permission`; untrusted text
would steer a self-approving agent); or the item touches deployment, releases, infrastructure,
credentials or real-data migrations. A regular preset may auto-approve too: check its
`command`/`args` by the rules above and its screen once started; if so, warn the user, ask for a
prompting preset, hold those items. Record `preset` per item and the kinds per harness in
`presets`; mark regular items in the plan table.

## Auto only (auto instance, no regular one)

Don't hold items to ask later. Say so once in the plan summary, run the harness's items on the auto
instance, and list those the rules would run with prompts, with reasons. One question, in the go
message: run them on auto too, or hold until a prompting preset exists? Store in `autoOnly`:
`accepted` (`preset` `auto`) or `declined` (`queued`, reason "needs a prompting preset"); never
re-asked. No such items: note it in one line, set `accepted`. A regular instance appearing later:
Continue uses it for those items; `autoOnly` stays.

## No auto instance

Regular preset; list each instance's `label`, `command`, `args`; offer once to create `Claude
(auto)` (`claude --permission-mode auto`; Codex `codex --approve-for-me`; OpenCode `opencode run
--auto`; Antigravity `agy --mode auto` or `agy --dangerously-skip-permissions`). On yes only: via the CLI if `superset agents --help`
offers it, else the user adds it in Paradev's agent settings.
