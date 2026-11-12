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
foreach ($skill in Get-ChildItem -LiteralPath (Join-Path $repo 'skills') -Directory) {
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
