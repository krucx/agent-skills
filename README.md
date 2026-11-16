# agent-skills

Agent skills in the open [Agent Skills](https://agentskills.io/specification) format, usable
from Claude Code, Codex, OpenCode, Antigravity, Gemini CLI, Hermes and any other harness that reads `SKILL.md`.

| Skill | What it does |
| --- | --- |
| [runwaves](skills/orchestration/runwaves/SKILL.md) | Plans a batch of tracker issues, an epic ("runwaves feature #400") or free-text work into waves and runs them through parallel workers. On Orca it hands the waves to Orca's orchestration skill; small Paradev runs go through `superset:orchestrate` (1 or 2 tasks share the current workspace, 3 or more get one new sidebar workspace each); everything else gets a PR per task, a saved, resumable plan and In Progress, In Review, Done and Blocked groups. For an ad-hoc fan-out without runwaves, use those skills directly. |

## Install

```bash
git clone git@github.com:krucx/agent-skills.git
cd agent-skills
./install.sh
```

`install.sh` symlinks each skill into `~/.agents/skills/` (read by Codex and Gemini CLI, and by
Hermes once it's added to `skills.external_dirs`), and links `~/.claude/skills/` to that for
Claude Code. A skill is a folder with a `SKILL.md`, directly under `skills/` or one level down
in a group folder such as `skills/orchestration/`; it installs under its own folder name. The
clone is the single source of truth: edit it, and every harness sees the change. A `git pull` updates them all.

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

The runwaves skill's scripts are bash. On Windows, run your harness from Git Bash or WSL,
with `jq`, `gh` and `superset` (or `paradev`) on `PATH` there.

## Using runwaves

| Harness | Invoke |
| --- | --- |
| Claude Code | `/runwaves 340-343, 345 onwards` or "runwaves 340-343" |
| Codex | `$runwaves 340-343` |
| Gemini CLI | "runwaves 340-343" (Gemini picks the skill from your words) |
| OpenCode | "use the runwaves skill on issues 340 to 343" |
| Antigravity | `/runwaves 340-343` |
| Hermes | `/runwaves 340-343` |

"runwaves report back" prints the status table at any time, from any harness. It brings
the groups and the plan up to date, and never starts or messages a worker. "runwaves
continue" resumes a run: it starts items that have become ready and watches again. "runwaves
close" ends a run that still has blocked or waiting items; they're kept as carry-over, and the
next run offers to pick them up again. Workspaces are never archived or deleted.

A run follows one loop. `preflight.sh` checks tools, auth, host, project, plan ownership and
groups in one call. The coordinating agent plans (tracker lookup, free text split into tasks, dependencies,
waves) and sends one go message with every question at once. Then `watch.sh` runs `cycle.sh`
(transitions, merge gate, dispatch, tags) without the model and wakes it only with the events since
the last wake and a `needs` list: an acceptance check to eyeball (`accept`), a worker `question`,
`blocked`/`dependency-failed`/`held` items for you to decide, or a `stalled` worker. The chat shows
events only (the plan, the go, each wake, your questions, the finish); at finish, the current
plan-derived status table and complete chronological events log are printed in chat, including the
`finished` event. Empty item sets and event logs are labelled clearly. At other times, a status
table appears only when `table.sh` prints one. The run ends with `summary.sh` publishing the summary
page. Rarely needed detail lives in `references/` (`integrations.md`, `approval.md`, `recovery.md`,
`trackers.md`) and loads only for runs of that shape.

Each repo has one active run at a time. The plan lives in
`~/.agents/orchestrator/<owner>-<repo>.json` (the folder keeps its pre-rename name so existing runs resume), and finished runs move to
`~/.agents/orchestrator/history/`. The plan records which Paradev terminal owns the run:

- A second run on the same repo is refused while the owner is alive.
- A run whose owner is gone, or hasn't sent a heartbeat for 45 minutes, can be taken over. If
  the owner looks alive but is stuck (say, at a usage limit), tell the new session to "take
  over" and it forces the takeover.
- The plan carries its group-to-tag map, so whichever session picks the run up files
  workspaces into the same folders.
- Writes are locked and atomic, so an interrupted write never corrupts the plan.

### Run runwaves on a small model

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
| OpenCode (auto) | `opencode --auto` |
| Antigravity (auto) | `agy --mode auto` |

Gemini's default preset already runs with `--approval-mode=auto_edit`. Runwaves treats
an instance as auto when its name (`label`) contains `(auto)` or its command and args turn on
auto-approve (`claude --permission-mode auto`, `codex --approve-for-me`, `opencode --auto`, `agy --mode auto`). When it finds none, it
warns you and lists the instances it did find.

What auto mode means:
- **Claude's auto mode** approves routine actions through a safety classifier and still blocks
  risky ones.
- **Codex's `--approve-for-me`** has an automatic reviewer approve requests inside its
  workspace-write sandbox.

Either way, you don't see each command before it runs. Runwaves therefore uses the
regular preset, which prompts you, for an item when:
- you say `with prompts`;
- the item was written by someone without write access to the repo;
- the item touches deployment, releases, infrastructure, credentials, or migrations against
  real data.

### Groups map to your own sidebar folders

Paradev files workspaces into sidebar folders by tag, and the folder name you see can differ
from its tag (a folder you renamed "blocked" may be tagged `new group-6`). So runwaves
doesn't create duplicate folders, the first run in a project suggests which of your folders to use
for In Progress, In Review, Done and Blocked, matching folder names (it reads Paradev's internal
database once, read-only), and saves your confirmed choice in
`~/.agents/orchestrator/groups.json`, keyed by project ID. A group with no folder of that name gets
a new folder named after it. To change the mapping later, edit that file, or run:

```bash
~/.agents/skills/runwaves/scripts/groups.sh <project-id>                       # show it
~/.agents/skills/runwaves/scripts/groups.sh <project-id> suggest               # re-suggest
~/.agents/skills/runwaves/scripts/groups.sh <project-id> save '{"Blocked": "new group-6"}'
```

`save` replaces the project's whole mapping; groups it leaves out use their own names.

### Tests

The scripts have a test suite that runs against fake `superset` and `gh` commands, so it needs no
Paradev host or GitHub access:

```bash
bash skills/orchestration/runwaves/scripts/test/run.sh
```

### Requirements

`bash`, `jq`, the GitHub CLI (`gh`, signed in), and the Paradev CLI with this machine's host
running. `superset`, `paradev` and `pdev` are the same CLI, and any of the three names works; the scripts use
whichever is on PATH. Pull requests must live on GitHub; the tracker can be GitHub
Issues, Linear, or Jira (whatever the harness can reach).
