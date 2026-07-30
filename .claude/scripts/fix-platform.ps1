#!/usr/bin/env pwsh
# fix-platform.ps1 -Normalize hook commands in .claude/settings.json to the current platform (.ps1) form.
# After cross-platform moves, old (.sh) commands coexist with new platform commands and error; run this once after moving to Windows.
# No dependency on the cc-base repo or jq -uses pwsh built-in ConvertFrom-Json/ConvertTo-Json.
# Usage: pwsh -File fix-platform.ps1 [-Target <dir>]    -Target defaults to "." or reads CLAUDE_PROJECT_DIR.
[CmdletBinding()]
param(
  [string]$Target = '.'
)
$ErrorActionPreference = 'Stop'

# Locate project root: CLAUDE_PROJECT_DIR first, then -Target (defaults to current dir).
$projectRoot = $env:CLAUDE_PROJECT_DIR
if (-not $projectRoot) { $projectRoot = (Resolve-Path $Target).Path }
$settings = Join-Path $projectRoot '.claude\settings.json'
if (-not (Test-Path $settings)) { throw "settings.json not found: $settings (run from project root, or set CLAUDE_PROJECT_DIR)" }

Write-Host '=== fix-platform (Windows/.ps1) ===' -ForegroundColor Cyan

# pwsh interpreter probe (ported from setup.ps1:113-121): pwsh 7 absolute path first, then Get-Command pwsh, then powershell.exe.
# pwsh 7 uses absolute path (quoted if spaces) -powershell.exe 5.1 inherits Git Bash-polluted PATH and hangs (noted in setup.ps1).
$pwsh7Path = 'C:\Program Files\PowerShell\7\pwsh.exe'
if (Test-Path $pwsh7Path) {
  $hookInterp = '"' + ($pwsh7Path -replace '\\', '/') + '"'
} else {
  $pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
  if ($pwshCmd) { $hookInterp = '"' + ($pwshCmd.Source -replace '\\', '/') + '"' }
  else { $hookInterp = 'powershell.exe'; Write-Host '[!] pwsh 7 not found, hook commands fall back to powershell.exe 5.1' -ForegroundColor Yellow }
}
Write-Host "[ok] hook interpreter: $hookInterp"

# Convert-ToPs1Command (ported from setup.ps1:122-128): rewrite a .sh command into .ps1 form.
# Single-quote literal construction; \, ", $ pass through into the generated command (ConvertTo-Json escapes them).
function Convert-ToPs1Command([string]$cmd) {
  if ($cmd -match '[/\\]\.claude[/\\]hooks[/\\]([A-Za-z0-9_-]+)\.sh') {
    $name = $Matches[1]
    return $hookInterp + ' -NoProfile -ExecutionPolicy Bypass -Command "& \"\$env:CLAUDE_PROJECT_DIR\.claude\hooks\' + $name + '.ps1\""'
  }
  return $cmd
}

# .sh residue detection (ported from setup.ps1:164-170 Test-IsShResidue):
# Conservative: only framework .sh forms -no powershell/pwsh, points at .claude/hooks/<name>.sh, no $env/-Command (.ps1 markers).
# All three conditions met = .sh residue; user-defined .sh (pointing elsewhere) or .ps1 forms are left alone.
function Test-IsShResidue([string]$cmd) {
  if (-not $cmd) { return $false }
  if ($cmd -match 'powershell|pwsh') { return $false }
  if ($cmd -notmatch '\.claude[/\\]hooks[/\\][A-Za-z0-9_-]+\.sh') { return $false }
  if ($cmd -match '\$env' -or $cmd -match '-Command') { return $false }
  return $true
}

# Extract hook name from command (supports .sh and .ps1, used for dedup).
function Get-HookName([string]$cmd, [string]$ext) {
  if ($cmd -match ('\.claude[/\\]hooks[/\\]([A-Za-z0-9_-]+)\.' + $ext)) { return $Matches[1] }
  return $null
}

$data = Get-Content $settings -Raw | ConvertFrom-Json
$deletedSh = 0
$addedPs1 = 0

if ($data.hooks) {
  foreach ($event in $data.hooks.PSObject.Properties) {
    $groups = $event.Value
    if (-not $groups) { continue }
    foreach ($group in $groups) {
      if (-not $group.hooks) { continue }
      # Collect existing .ps1 hook names in this group first (avoid dupes) -use a hashtable as a set, to avoid
      # the PSToObjectArrayBinder binding bug in pwsh 7.6 when casting List[object]/HashSet[string] to arrays.
      $existingPs1 = @{}
      foreach ($h in $group.hooks) {
        $n = Get-HookName $h.command 'ps1'
        if ($n) { $existingPs1[$n] = $true }
      }
      $newList = @()
      $deletedEntries = @()
      foreach ($h in $group.hooks) {
        if (Test-IsShResidue $h.command) {
          $n = Get-HookName $h.command 'sh'
          $deletedEntries += [pscustomobject]@{ Name = $n; Entry = $h }
          $deletedSh++
        } else {
          $newList += $h
        }
      }
      # For each deleted name, if no matching .ps1 in the same group, add one (preserve type/timeout etc. from the original entry)
      foreach ($de in $deletedEntries) {
        if ($de.Name -and $existingPs1.ContainsKey($de.Name)) { continue }
        $newEntry = [pscustomobject]@{}
        foreach ($p in $de.Entry.PSObject.Properties) {
          if ($p.Name -eq 'command') {
            $newEntry | Add-Member -NotePropertyName command -NotePropertyValue (Convert-ToPs1Command $de.Entry.command) -Force
          } else {
            $newEntry | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
          }
        }
        if (-not $newEntry.PSObject.Properties['command']) {
          $newEntry | Add-Member -NotePropertyName command -NotePropertyValue (Convert-ToPs1Command $de.Entry.command) -Force
        }
        # Match setup.ps1:135: if timeout exists, normalize to 30 (pwsh starts slower than bash; setup.ps1 also force-writes 30)
        if ($newEntry.PSObject.Properties['timeout']) { $newEntry.timeout = 30 }
        $newList += $newEntry
        if ($de.Name) { $existingPs1[$de.Name] = $true }
        $addedPs1++
      }
      $group.hooks = $newList
    }
  }
}

# Backup then write back
Copy-Item $settings "$settings.bak" -Force
Write-Host "backup: $settings.bak"
$data | ConvertTo-Json -Depth 20 | Set-Content $settings -Encoding UTF8
Write-Host "fix-platform: deleted .sh residue commands=$deletedSh, added .ps1 commands=$addedPs1" -ForegroundColor Green
Write-Host "Done. settings.json normalized to .ps1 form (Windows). Path: $settings" -ForegroundColor Green
exit 0
