# Paradev CLI control surface

Verified against Paradev CLI **2.0.8** on **2026-11-14** (local-only machine, no cloud workspaces).
Use this instead of probing; every row below was checked with `--help` or a call on that version.
`superset` = `paradev` = `pdev`. All commands take `--json` (on by default under agents) and
`--local` for this machine's host.

| Need | Command that works on 2.x |
| --- | --- |
| Signed in | `superset auth whoami --json` |
| Host up, every workspace/terminal/agent state | `superset snapshot --json` (`--workspace <id>` narrows) |
| Project ID | `superset projects list --local --json` |
| Workspaces | `superset workspaces list --local --project <id> [--search <s>] [--tag <t>] --json`; `get <id>` |
| Create + start worker | `superset workspaces create --local --project <id> --name <n> --branch <b> [--base-branch <b>] --agent <preset-or-uuid> --prompt <p> [--tag <t>]` (`--prompt` required with `--agent`) |
| Move sidebar group | `superset workspaces update <id> --local --tag "<tag>"` (replaces the tag set; `--clear-tags` removes all) |
| Agent presets | `superset agents list --local --json` (fields `presetId`, `label`, `command`, `args`) |
| Add agent to a workspace | `superset agents create --workspace <id> --local --agent <preset> --prompt <p>` |
| Wait on an agent | `superset agents wait`, or `terminals send … --wait --until settled\|idle\|blocked\|working --timeout <s>` |
| Terminals in a workspace | `superset terminals list --workspace <id> --local --json` |
| Read a screen | `superset terminals read --workspace <id> --local --terminal <tid> --max-lines 60` |
| Answer a worker | `superset terminals send --workspace <id> --local --terminal <tid> --text "<answer>"` (`--keys` for raw keys, `--no-submit` to stage) |
| Linear/Paradev task | `superset tasks get <KEY> --tracker linear --json` |
| Notify | `superset notifications show` |
| Publish a page | `superset pages publish <file> [--title t] [--label l]` |

## Where 2.x differs from the documented 1.x surface

- **`agents list` rejects `--workspace`** ("Unknown option"). It lists the host's configured agent
  presets only (`--local` or `--host`, nothing else). Per-workspace agent state comes from
  `snapshot --workspace <id>` or `terminals list`.
- **`hosts list` returns `[]` on a local-only machine.** That is normal, not a failure: use
  `--local` everywhere and never require a host ID.
- **`superset schema` nests subcommands.** Top-level `commands[]` entries (`terminals`, `agents`,
  `hosts`) carry their leaves in their own `commands`; a flat scan for `terminals read` finds
  nothing. `terminals` exists on 2.0.8. Prefer this table over reading the schema.
- **Terminal flags need a location**: `terminals list|read|send` take `--workspace` plus `--local`
  (or `--host`). Without either, the default is the cloud when the account has cloud workspaces.
- `workspaces create` needs `--project` with `--local`, and `--branch` unless `--pr`, `--task` or
  `--checkout local` is given.

## Worker harnesses

Verified on **2026-11-14** against the installed CLIs: OpenCode **2.3.0**, Antigravity **1.5.8**
(`agy`; its help names itself `antigravity`), Paradev presets from `agents list`. Claude and Codex
rows are the existing documented forms. The plan item's `agent` is the preset's `presetId`
(`agy` for Antigravity; `antigravity` is accepted as an alias).

| Harness | Command | First prompt line | Auto-approve args | Regular preset |
| --- | --- | --- | --- | --- |
| Claude Code | `claude` | `/<skill> <id>` | `--permission-mode auto` (or `=auto`) | no such args |
| Codex | `codex` | `$<skill> <id>` | `--approve-for-me` | no such args |
| OpenCode | `opencode` | `Use the <skill> skill to do <id>.` (its help lists no skill slash command; skills load by name from plain text) | `--auto` | preset default, `args: []` |
| Antigravity | `agy` | `/<skill> <id>` (help: `--disable-slash-commands` turns off "slash command and skill expansion", so it is on by default) | `--mode auto` or `--dangerously-skip-permissions` | default preset runs `--mode accept-edits`: asks for anything beyond edits, so regular |

Gemini (`--approval-mode=auto_edit`, plain-text first line) and Hermes (`/<skill> <id>`,
`chat --yolo`) are unchanged. An instance is auto by its args whatever its `label` says.

## Version-dependent

Everything above is 2.0.8. On another major version, treat each row as unverified until its
`--help` agrees. `superset status` showing `running: false, stale: true` means the host is down;
never start it (see Preflight).

## When a documented command is missing

Bounded, no probing loop: run `--help` once for that one command, take the flags it lists, add
the working form to this file in the run's notes, and dispatch. Do not `--help` the neighbours.
