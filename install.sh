#!/usr/bin/env bash
# Link every skill in this repo into the directories agent harnesses read:
#   ~/.agents/skills/<name>  -> <repo>/skills/[<group>/]<name>   (Codex, Gemini CLI, Hermes via config)
#   ~/.claude/skills/<name>  -> ~/.agents/skills/<name> (Claude Code)
# An existing real folder at a target is moved to ~/.agents/skill-backups/, never overwritten.
# Backups live outside the skill folders so harnesses don't load them as extra skills.
# Safe to run again.
set -euo pipefail

repo=$(cd "$(dirname "$0")" && pwd)
stamp=$(date +%Y%m%d%H%M%S)
backups="$HOME/.agents/skill-backups"

link() {
  local source=$1 target=$2
  mkdir -p "$(dirname "$target")"
  if [[ -L "$target" ]]; then
    rm "$target"
  elif [[ -e "$target" ]]; then
    local backup
    backup="$backups/$(basename "$(dirname "$(dirname "$target")")")-$(basename "$target")-$stamp"
    mkdir -p "$backups"
    mv "$target" "$backup"
    echo "backed up $target -> $backup"
  fi
  ln -s "$source" "$target"
  echo "linked $target -> $source"
}

# A skill is a folder holding SKILL.md, directly under skills/ or one level down in a group folder.
# Skills install by their own folder name; the group name is not part of it.
# The skill that was called "orchestrator" is now "runwaves". Drop what an earlier install left:
# a link into this repo (or on to ~/.agents/skills), or a copy install.ps1 made. Anything else stays.
for old in "$HOME/.agents/skills/orchestrator" "$HOME/.claude/skills/orchestrator"; do
  if [[ -L "$old" ]]; then
    to=$(readlink "$old")
    case "$to" in
      "$repo"/skills/*|"$HOME/.agents/skills/orchestrator") rm "$old"; echo "removed stale link $old" ;;
    esac
  elif [[ -f "$old/.agent-skills-install" ]]; then
    rm -rf "$old"; echo "removed stale copy $old"
  fi
done

for skill in "$repo"/skills/*/ "$repo"/skills/*/*/; do
  [[ -f "$skill/SKILL.md" ]] || continue
  name=$(basename "$skill")
  link "${skill%/}" "$HOME/.agents/skills/$name"
  link "$HOME/.agents/skills/$name" "$HOME/.claude/skills/$name"
done

if [[ -d "$HOME/.hermes" ]] && ! grep -qs '\.agents/skills' "$HOME/.hermes/config.yaml"; then
  cat <<'EOF'

Hermes: add this to ~/.hermes/config.yaml so it loads these skills:
  skills:
    external_dirs:
      - ~/.agents/skills
EOF
fi
