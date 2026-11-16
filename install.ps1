# Copy every skill in this repo into the directories agent harnesses read (Windows):
#   %USERPROFILE%\.agents\skills\<name>  (Codex, Gemini CLI, Hermes via config)
#   %USERPROFILE%\.claude\skills\<name>  (Claude Code)
# Folders are copied, not linked, so re-run this after `git pull` to update them.
# A copy made by this installer carries a marker file and is replaced on the next run.
# Any other existing folder at a target is moved to %USERPROFILE%\.agents\skill-backups\, never
# overwritten. Backups live outside the skill folders so harnesses don't load them as extra skills.
# Safe to run again. Works in Windows PowerShell 5.1 and PowerShell 7.
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$repo = $PSScriptRoot
$userHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
$stamp = Get-Date -Format 'yyyyMMddHHmmss'
$agents = Join-Path $userHome '.agents'
$backups = Join-Path $agents 'skill-backups'
$marker = '.agent-skills-install'

function Install-Skill([string]$source, [string]$target) {
  $parent = Split-Path $target -Parent
  New-Item -ItemType Directory -Path $parent -Force | Out-Null

  # Listing the parent also finds a dangling link, which Get-Item can miss in PowerShell 5.1.
  $existing = Get-ChildItem -LiteralPath $parent -Force | Where-Object { $_.Name -eq (Split-Path $target -Leaf) }
  if ($existing) {
    if ($existing.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
      # A symlink or junction, e.g. from install.sh under WSL or Git Bash. Delete the link
      # itself; a recursive delete could follow it and remove the repo's files.
      $existing.Delete()
    } elseif (Test-Path -LiteralPath (Join-Path $target $marker) -PathType Leaf) {
      Remove-Item -LiteralPath $target -Recurse -Force
    } else {
      $configDir = Split-Path (Split-Path $parent -Parent) -Leaf
      $backup = Join-Path $backups "$configDir-$(Split-Path $target -Leaf)-$stamp"
      New-Item -ItemType Directory -Path $backups -Force | Out-Null
      Move-Item -LiteralPath $target -Destination $backup
      Write-Output "backed up $target -> $backup"
    }
  }

  Copy-Item -LiteralPath $source -Destination $target -Recurse -Force
  Set-Content -LiteralPath (Join-Path $target $marker) -Value "Copied from $source by install.ps1. Re-run it to update; this folder is replaced each time."
  Write-Output "copied $source -> $target"
}

$agentsSkills = Join-Path $agents 'skills'
$claudeSkills = Join-Path (Join-Path $userHome '.claude') 'skills'
# A skill is a folder holding SKILL.md, directly under skills\ or one level down in a group folder.
# Skills install by their own folder name; the group name is not part of it.
$skillDirs = foreach ($dir in Get-ChildItem -LiteralPath (Join-Path $repo 'skills') -Directory) {
  if (Test-Path -LiteralPath (Join-Path $dir.FullName 'SKILL.md') -PathType Leaf) { $dir }
  else { Get-ChildItem -LiteralPath $dir.FullName -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') -PathType Leaf } }
}
# The skill that was called "orchestrator" is now "runwaves". Drop what an earlier install left:
# a copy this installer made, or a link install.sh made under WSL or Git Bash. Anything else stays.
foreach ($root in @($agentsSkills, $claudeSkills)) {
  $old = Join-Path $root 'orchestrator'
  $found = Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'orchestrator' }
  if (-not $found) { continue }
  if ($found.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
    $found.Delete()
    Write-Output "removed stale link $old"
  } elseif (Test-Path -LiteralPath (Join-Path $old $marker) -PathType Leaf) {
    Remove-Item -LiteralPath $old -Recurse -Force
    Write-Output "removed stale copy $old"
  }
}
foreach ($skill in $skillDirs) {
  Install-Skill $skill.FullName (Join-Path $agentsSkills $skill.Name)
  Install-Skill $skill.FullName (Join-Path $claudeSkills $skill.Name)
}

$hermes = Join-Path $userHome '.hermes'
$hermesConfig = Join-Path $hermes 'config.yaml'
if ((Test-Path -LiteralPath $hermes -PathType Container) -and
    -not ((Test-Path -LiteralPath $hermesConfig -PathType Leaf) -and
          (Select-String -LiteralPath $hermesConfig -Pattern '\.agents[/\\]skills' -Quiet))) {
  Write-Output @'

Hermes: add this to ~/.hermes/config.yaml so it loads these skills:
  skills:
    external_dirs:
      - ~/.agents/skills
'@
}
