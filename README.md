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

### Windows

```powershell
git clone git@github.com:krucx/agent-skills.git
cd agent-skills
powershell -ExecutionPolicy Bypass -File .\install.ps1
# or, in PowerShell 7: pwsh -File .\install.ps1
```

`install.ps1` runs in Windows PowerShell 5.1 or PowerShell 7 (`pwsh`). It copies each skill
into `%USERPROFILE%\.agents\skills\` and `%USERPROFILE%\.claude\skills\` instead of
symlinking, so **run it again after every `git pull`** to update the copies. Its own earlier
copies are replaced; any other folder already at a target is moved to
`%USERPROFILE%\.agents\skill-backups\`, never overwritten.

The orchestrator skill's scripts are bash. On Windows, run your harness from Git Bash or WSL,
with `jq`, `gh` and `superset` (or `paradev`) on `PATH` there.

## Using the orchestrator

| Harness | Invoke |
| --- | --- |
| Claude Code | `/orchestrator 340-343, 345 onwards` or "orchestrate 340 to 343" |
| Codex | `$orchestrator 340-343` |
| Gemini CLI | "orchestrate issues 340 to 343" (Gemini picks the skill from your words) |
| Hermes | `/orchestrator 340-343` |

"orchestrator report back" prints the status table at any time, from any harness. It brings
the groups and the plan up to date, and never starts or messages a worker. "orchestrator
continue" resumes a run: it starts items that have become ready and watches again.

Each repo has one active run at a time. The plan lives in
`~/.agents/orchestrator/<owner>-<repo>.json`, and finished runs move to
`~/.agents/orchestrator/history/`. The plan records which Paradev terminal owns the run:

- A second orchestrator on the same repo is refused while the owner is alive.
- A run whose owner is gone, or hasn't sent a heartbeat for 45 minutes, can be taken over.
- Writes are locked and atomic, so an interrupted write never corrupts the plan.

### Run the orchestrator on a small model

Coordinating doesn't need a top-tier model. Claude Code switches to Sonnet on its own. In
other harnesses, start the session on a smaller model:

```bash
codex -m <small model>
gemini -m <flash model>
```

### Give workers an auto-approve agent (once, in the Paradev app)

Workers stall on permission prompts unless they start with auto-approve flags. In the Paradev
desktop app, add an agent instance per harness that runs with auto-approve, for example:

| Name | Command and args |
| --- | --- |
| Claude (auto) | `claude --permission-mode auto` |
| Codex (auto) | `codex --approve-for-me` |

Gemini's default preset already runs with `--approval-mode=auto_edit`. The orchestrator treats
an instance as auto when its name (`label`) contains `(auto)` or its command and args turn on
auto-approve (`claude --permission-mode auto`, `codex --approve-for-me`). When it finds none, it
warns you and lists the instances it did find.

What auto mode means:
- **Claude's auto mode** approves routine actions through a safety classifier and still blocks
  risky ones.
- **Codex's `--approve-for-me`** has an automatic reviewer approve requests inside its
  workspace-write sandbox.

Either way, you don't see each command before it runs. The orchestrator therefore uses the
regular preset, which prompts you, for an item when:
- you say `with prompts`;
- the item was written by someone without write access to the repo;
- the item touches deployment, releases, infrastructure, credentials, or migrations against
  real data.

### Groups map to your own sidebar folders

Paradev files workspaces into sidebar folders by tag, and the folder name you see can differ
from its tag (a folder you renamed "blocked" may be tagged `new group-6`). So the orchestrator
doesn't create duplicate folders, the first run in a project suggests which of your folders to use
for In Progress, In Review, Done and Blocked, matching folder names (it reads Paradev's internal
database once, read-only), and saves your confirmed choice in
`~/.agents/orchestrator/groups.json`, keyed by project ID. A group with no folder of that name gets
a new folder named after it. To change the mapping later, edit that file, or run:

```bash
~/.agents/skills/orchestrator/scripts/groups.sh <project-id>                       # show it
~/.agents/skills/orchestrator/scripts/groups.sh <project-id> suggest               # re-suggest
~/.agents/skills/orchestrator/scripts/groups.sh <project-id> save '{"Blocked": "new group-6"}'
```

`save` replaces the project's whole mapping; groups it leaves out use their own names.

### Requirements

`bash`, `jq`, the GitHub CLI (`gh`, signed in), and the Paradev CLI with this machine's host
running. `superset`, `paradev` and `pdev` are the same CLI, and any of the three names works; the scripts use
whichever is on PATH. Pull requests must live on GitHub; the tracker can be GitHub
Issues, Linear, or Jira (whatever the harness can reach).
