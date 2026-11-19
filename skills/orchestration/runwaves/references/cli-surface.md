# Paradev CLI control surface

Verified on Paradev CLI **2.0.8**, **2026-11-14** (local-only machine); use instead of probing.
`superset` = `paradev` = `pdev`. All take `--json` (default under agents) and `--local` (this host).

| Need | Command (2.x) |
| --- | --- |
| Signed in | `superset auth whoami --json` |
| Host up, all workspace/terminal/agent state | `superset snapshot --json` (`--workspace <id>` narrows) |
| Project ID | `superset projects list --local --json` |
| Workspaces | `superset workspaces list --local --project <id> [--search <s>] [--tag <t>] --json`; `get <id>` |
| Create + start worker | `superset workspaces create --local --project <id> --name <n> --branch <b> [--base-branch <b>] --agent <preset-or-uuid> --prompt <p> [--tag <t>]` (`--prompt` required with `--agent`) |
| Move sidebar group | `superset workspaces update <id> --local --tag "<tag>"` (replaces tags; `--clear-tags` removes all) |
| Agent presets | `superset agents list --local --json` (`presetId`, `label`, `command`, `args`) |
| Add agent to a workspace | `superset agents create --workspace <id> --local --agent <preset> --prompt <p>` |
| Wait on an agent | `superset agents wait`, or `terminals send … --wait --until settled\|idle\|blocked\|working --timeout <s>` |
| Terminals | `superset terminals list --workspace <id> --local --json` |
| Read a screen | `superset terminals read --workspace <id> --local --terminal <tid> --max-lines 60` |
| Answer a worker | `superset terminals send --workspace <id> --local --terminal <tid> --text "<answer>"` (`--keys` raw keys, `--no-submit` stages) |
| Linear/Paradev task | `superset tasks get <KEY> --tracker linear --json` |
| Notify | `superset notifications show` |
| Publish a page | `superset pages publish <file> [--title t] [--visibility just_me\|org] [--page <id>]` (summary.sh) |

## 2.x vs documented 1.x

- `agents list` rejects `--workspace`; it lists host presets only (`--local`/`--host`). Per-workspace
  agent state: `snapshot --workspace <id>` or `terminals list`.
- `hosts list` is `[]` on a local-only machine: normal; use `--local`, never require a host ID.
- `superset schema` nests subcommands (leaves under each top-level entry's `commands`); prefer this table.
- `terminals list|read|send` need `--workspace` plus `--local` (or `--host`); else they default to
  the cloud when the account has cloud workspaces.
- `workspaces create` needs `--project` with `--local`, and `--branch` unless `--pr`, `--task` or
  `--checkout local`.

## Worker harnesses

Verified 2026-11-14: OpenCode **2.3.0**, Antigravity **1.5.8** (`agy`), Paradev presets from
`agents list`; Claude and Codex are the documented forms. Item `agent` = the preset's `presetId`
(`agy`; alias `antigravity`).

| Harness | Command | First prompt line | Auto-approve args | Regular preset |
| --- | --- | --- | --- | --- |
| Claude Code | `claude` | `/<skill> <id>` | `--permission-mode auto` (or `=auto`) | no such args |
| Codex | `codex` | `$<skill> <id>` | `--approve-for-me` | no such args |
| OpenCode | `opencode` | `Use the <skill> skill to do <id>.` (no skill slash command) | `--auto` | preset default, `args: []` |
| Antigravity | `agy` | `/<skill> <id>` (slash/skill expansion on by default) | `--mode auto` or `--dangerously-skip-permissions` | default `--mode accept-edits` asks beyond edits: regular |

Gemini (`--approval-mode=auto_edit`, plain-text first line) and Hermes (`/<skill> <id>`, `chat
--yolo`) unchanged. An instance is auto by its args whatever its `label`.

## Other versions; missing commands

Another major version: each row unverified until its `--help` agrees. `superset status` `running:
false, stale: true` = host down; never start it. A documented command missing: `--help` once for
that command only, use its flags, note the working form in the run's notes, dispatch; no probing.
