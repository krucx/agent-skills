# agent-skills

Agent skills in the open [Agent Skills](https://agentskills.io/specification) format, usable
from Claude Code, Codex, Gemini CLI, Hermes and any other harness that reads `SKILL.md`.

| Skill | What it does |
| --- | --- |
| [orchestrator](skills/orchestrator/SKILL.md) | Plans a batch of issues or free-text work into waves and runs them in parallel Paradev worktree workspaces, moving each between the In Progress, In Review, Done and Blocked groups. |

## Install

```bash
git clone git@github.com:krucx/agent-skills.git
cd agent-skills
./install.sh
```

`install.sh` symlinks each skill into `~/.agents/skills/` (read by Codex and Gemini CLI, and by
Hermes once it's added to `skills.external_dirs`), and links `~/.claude/skills/` to that for
Claude Code. The clone is the single source of truth: edit it, and every harness sees the
change. A `git pull` updates them all.

## Using the orchestrator

| Harness | Invoke |
| --- | --- |
| Claude Code | `/orchestrator 340-343, 345 onwards` or "orchestrate 340 to 343" |
| Codex | `$orchestrator 340-343` |
| Gemini CLI | "orchestrate issues 340 to 343" (Gemini picks the skill from your words) |
| Hermes | `/orchestrator 340-343` |

"orchestrator report back" prints the status table at any time, from any harness. The plan
for each repo lives in `~/.agents/orchestrator/<owner>-<repo>.json`.

### Run the orchestrator on a small model

Coordinating doesn't need a top-tier model. Claude Code switches to Sonnet on its own. In
other harnesses, start the session on a smaller model:

```bash
codex -m <small model>
gemini -m <flash model>
```

### Give workers an auto-approve agent (once, in the Paradev app)

Workers stall on permission prompts unless they start with auto-approve flags. In the Paradev
desktop app, add an agent instance per harness whose name contains `(auto)`:

| Name | Command and args |
| --- | --- |
| Claude (auto) | `claude --permission-mode auto` |
| Codex (auto) | `codex --approve-for-me` |

Gemini's default preset already runs with `--approval-mode=auto_edit`. The orchestrator finds
these instances by name and warns you when one is missing.

### Requirements

`bash`, `jq`, the GitHub CLI (`gh`, signed in), and the Paradev CLI (`superset` or `paradev`)
with this machine's host running. Pull requests must live on GitHub; the tracker can be GitHub
Issues, Linear, or Jira (whatever the harness can reach).
