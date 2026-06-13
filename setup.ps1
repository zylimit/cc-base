#!/usr/bin/env pwsh
# setup.ps1 - install the cc-base framework assets into a target project (Windows / pure PowerShell).
# Usage: pwsh -File setup.ps1 [-Target <dir>] [-Force]    without -Target, defaults to the current directory ".".
# Key: write target/.claude/settings.json directly (Claude Code only reads that fixed name, not settings-windows.json),
#      and rewrite each hook command to: powershell.exe -Command "& \"\$env:CLAUDE_PROJECT_DIR\.claude\hooks\<name>.ps1\""
#      Why the \$ escape: on Windows the hook command runs in Git Bash (the outer shell when git is installed - a
#      cc-base prerequisite). A bare $env:CLAUDE_PROJECT_DIR has its $env eaten by bash (unset bash var -> empty,
#      leaving ":CLAUDE_PROJECT_DIR", broken). Escaping as \$env keeps a literal $ through bash, so the full
#      $env:CLAUDE_PROJECT_DIR reaches the inner powershell which expands it. -Command (not -File) is required
#      because only inside -Command does PowerShell expand $env: (a -File path is taken literally). Verified on a
#      real Windows machine (the SessionStart banner prints).
[CmdletBinding()]
param(
  [string]$Target = '.',
  [switch]$Force
)
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$srcClaude = Join-Path $root '.claude'
if (-not (Test-Path $srcClaude)) { throw "No .claude under the script directory (run from the cc-base repo root): $srcClaude" }

# target/.claude
if (-not (Test-Path $Target)) { New-Item -ItemType Directory -Path $Target -Force | Out-Null }
$targetClaude = Join-Path $Target '.claude'

Write-Host '=== cc-base setup (Windows/.ps1) ===' -ForegroundColor Cyan

# 1. Detect git / claude (advisory, not a hard block)
if (Get-Command git -ErrorAction SilentlyContinue) { Write-Host "[ok] git: $((git --version) 2>$null)" }
else { Write-Host '[!] git not detected (install: https://git-scm.com/download/win)' -ForegroundColor Yellow }
if (Get-Command claude -ErrorAction SilentlyContinue) { Write-Host '[ok] Claude Code (claude) installed' }
else { Write-Host '[!] Claude Code not detected (install: https://docs.claude.com/claude-code)' -ForegroundColor Yellow }

function Test-FilesEqual($a, $b) {
  if (-not (Test-Path $b)) { return $false }
  return (Get-FileHash $a -Algorithm SHA256).Hash -eq (Get-FileHash $b -Algorithm SHA256).Hash
}

function Copy-WithBackup($src, $dest) {
  $destDir = Split-Path $dest -Parent
  if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
  if ((Test-Path $dest) -and -not (Test-FilesEqual $src $dest)) {
    Copy-Item $dest "$dest.bak" -Force
    Write-Host "backup: $dest.bak"
  }
  Copy-Item $src $dest -Force
}

# 2. Copy the .claude framework files (skip runtime artifacts / scratch / machine-specific; settings.json is rewritten separately)
$skip = @('settings.json', 'settings-windows.json', 'settings.local.json',
  '.needs-review', '.needs-review.lock', '.tdd-exempt', '.red-verified', '.static-gate', '.degraded-review',
  'signals.jsonl')
$srcRootLen = (Resolve-Path $srcClaude).Path.Length
Get-ChildItem -Path $srcClaude -Recurse -File | ForEach-Object {
  $rel = $_.FullName.Substring($srcRootLen).TrimStart('/', '\')
  if ($skip -contains (Split-Path $rel -Leaf)) { return }
  Copy-WithBackup $_.FullName (Join-Path $targetClaude $rel)
}

# 3. Rewrite each hook command: .sh -> powershell.exe -Command "& \"\$env:CLAUDE_PROJECT_DIR\.claude\hooks\<name>.ps1\""
#    Built with single-quoted PowerShell literals so the \, ", and $ characters pass through verbatim into the
#    generated command (ConvertTo-Json escapes them for the JSON file).
function Convert-ToPs1Command([string]$cmd) {
  if ($cmd -match '[/\\]\.claude[/\\]hooks[/\\]([A-Za-z0-9_-]+)\.sh') {
    $name = $Matches[1]
    return 'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& \"\$env:CLAUDE_PROJECT_DIR\.claude\hooks\' + $name + '.ps1\""'
  }
  return $cmd
}

$src = Get-Content (Join-Path $srcClaude 'settings.json') -Raw | ConvertFrom-Json
foreach ($event in $src.hooks.PSObject.Properties) {
  foreach ($group in $event.Value) {
    foreach ($h in $group.hooks) { $h.command = Convert-ToPs1Command $h.command }
  }
}

# Recursively collect every .command value in the object (for merge dedup)
function Get-AllCommands($obj) {
  $acc = New-Object System.Collections.Generic.List[string]
  function Walk($o) {
    if ($null -eq $o) { return }
    if (($o -is [System.Collections.IEnumerable]) -and ($o -isnot [string])) {
      foreach ($i in $o) { Walk $i }
    } elseif ($o -is [pscustomobject]) {
      foreach ($p in $o.PSObject.Properties) {
        if ($p.Name -eq 'command' -and $p.Value -is [string]) { $acc.Add($p.Value) }
        Walk $p.Value
      }
    }
  }
  Walk $obj
  return $acc
}

$targetSettings = Join-Path $targetClaude 'settings.json'

if ((Test-Path $targetSettings) -and -not $Force) {
  # 4. target already has settings.json: only append hook commands not present yet, leave other user config untouched
  $tgt = Get-Content $targetSettings -Raw | ConvertFrom-Json
  $existing = Get-AllCommands $tgt
  if (-not $tgt.hooks) { $tgt | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) -Force }
  foreach ($event in $src.hooks.PSObject.Properties) {
    foreach ($group in $event.Value) {
      $newHooks = @($group.hooks | Where-Object { $_.command -and ($existing -notcontains $_.command) })
      if ($newHooks.Count -gt 0) {
        $ng = [pscustomobject]@{}
        if ($group.PSObject.Properties['matcher']) { $ng | Add-Member -NotePropertyName matcher -NotePropertyValue $group.matcher }
        $ng | Add-Member -NotePropertyName hooks -NotePropertyValue $newHooks
        if (-not $tgt.hooks.PSObject.Properties[$event.Name]) {
          $tgt.hooks | Add-Member -NotePropertyName $event.Name -NotePropertyValue @() -Force
        }
        $tgt.hooks.($event.Name) = @($tgt.hooks.($event.Name)) + $ng
      }
    }
  }
  Copy-Item $targetSettings "$targetSettings.bak" -Force
  Write-Host "backup: $targetSettings.bak"
  $tgt | ConvertTo-Json -Depth 20 | Set-Content $targetSettings -Encoding UTF8
} else {
  if ((Test-Path $targetSettings) -and $Force) {
    Copy-Item $targetSettings "$targetSettings.bak" -Force
    Write-Host "backup: $targetSettings.bak"
  }
  $targetDir = Split-Path $targetSettings -Parent
  if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
  $src | ConvertTo-Json -Depth 20 | Set-Content $targetSettings -Encoding UTF8
}

$hooksCount = (Get-ChildItem (Join-Path $srcClaude 'hooks') -Filter *.ps1 -ErrorAction SilentlyContinue).Count
Write-Host "installed: ps1_hooks=$hooksCount target=$Target" -ForegroundColor Green
Write-Host "Done. Claude Code loads the .ps1 hooks from $targetClaude\settings.json (hook commands use the escaped-dollar form so the project-dir env var survives the Git Bash outer shell and expands in the inner powershell)."
exit 0
