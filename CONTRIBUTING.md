# Contributing

## Add a skill

A skill is a folder under `skills/` with a `SKILL.md` at its root:

```
skills/<name>/
  SKILL.md          required
  agents/openai.yaml  optional, display metadata for Codex
  scripts/, references/   optional, anything SKILL.md points to
```

The folder name is the skill's name, and `install.sh` links every folder it finds, so there is
nothing to register. `SKILL.md` starts with YAML frontmatter that the harnesses read:

```yaml
---
name: my-skill
description: What it does and when to use it, including the phrases that should trigger it.
---
```

- `name` (required): matches the folder name.
- `description` (required): the text a harness uses to decide when to load the skill, so
  say what it does and when to use it.
- Optional fields the orchestrator skill uses: `compatibility` (tools the skill needs),
  `model`, `effort`, `argument-hint`.

The body of `SKILL.md` is the instructions the agent follows once the skill loads. Add a row
for the skill to the table at the top of `README.md`.

## Run the tests

The orchestrator's scripts have a suite that runs against fake `superset` and `gh` commands, so
it needs no Paradev host or GitHub access. It needs `bash` and `jq`:

```bash
bash skills/orchestrator/scripts/test/run.sh
```

It takes about a minute and a half. CI (`.github/workflows/test.yml`) runs it on macOS with
`/bin/bash` (3.2) and on Linux, so keep scripts compatible with bash 3.2 and with both BSD and
GNU `date`.

## How `install.sh` links skills

`./install.sh` links each `skills/<name>/` folder twice:

```
~/.agents/skills/<name>  -> <repo>/skills/<name>     Codex, Gemini CLI, Hermes
~/.claude/skills/<name>  -> ~/.agents/skills/<name>  Claude Code
```

Because these are symlinks, edits in the clone show up in every harness, and `git pull`
updates them. Running it again is safe: an existing symlink is replaced, and a real folder
already at a target is moved to `~/.agents/skill-backups/` instead of being overwritten.

On Windows, `install.ps1` copies instead of linking, so run it again after each change.
