#!/usr/bin/env pwsh
# statusline.ps1 - Claude Code status line (PowerShell equivalent of statusline.sh;
# registered via settings.json statusLine, reads the session JSON from stdin).
# Makes framework governance state visible all session long (session-rules-banner only
# prints once at start; this line stays):
#   [Model] ctx NN% | $cost | FAST-MODE 3.2h | pending-review N | harness ON
# Sources: stdin JSON (model/context_window/cost/workspace) + project runtime files
# (.claude/.fast-mode expires_epoch / .claude/.needs-review / harness/module-catalog.json).
# Must stay cheap and silent -- the status line runs on every render; on any internal
# error print a static tag, never an error.
$ErrorActionPreference = 'Stop'
trap { Write-Output 'cc-base'; exit 0 }

[Console]::InputEncoding = [System.Text.UTF8Encoding]::new()
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$raw = [Console]::In.ReadToEnd()
$d = $null
try { $d = $raw | ConvertFrom-Json } catch { $d = $null }

$root = $env:CLAUDE_PROJECT_DIR
if ($d -and $d.workspace) {
  if ($d.workspace.project_dir) { $root = $d.workspace.project_dir }
  elseif ($d.workspace.current_dir) { $root = $d.workspace.current_dir }
}
if (-not $root) { $root = (Get-Location).Path }

$esc = [char]27
$segs = @()

if ($d -and $d.model -and $d.model.display_name) { $segs += "[$($d.model.display_name)]" }

if ($d -and $d.context_window -and ($null -ne $d.context_window.used_percentage)) {
  $p = [int]$d.context_window.used_percentage
  $seg = "ctx $p%"
  if ($p -ge 80) { $seg = "$esc[31m$seg$esc[0m" }
  $segs += $seg
}

if ($d -and $d.cost -and ($null -ne $d.cost.total_cost_usd) -and ($d.cost.total_cost_usd -gt 0)) {
  $segs += ('$' + ('{0:N2}' -f [double]$d.cost.total_cost_usd))
}

# fast-mode: on only while expires_epoch is unexpired (same rule as lib-fast-mode); yellow so it is not forgotten
$fmFile = Join-Path $root '.claude/.fast-mode'
if (Test-Path $fmFile) {
  $line = (Get-Content $fmFile -ErrorAction SilentlyContinue | Where-Object { $_ -match '^expires_epoch=\d+$' } | Select-Object -First 1)
  if ($line) {
    $exp = [int]($line -replace '^expires_epoch=', '')
    $now = [int][double]::Parse((Get-Date -UFormat %s))
    if ($exp -gt $now) {
      $h = [math]::Round(($exp - $now) / 3600.0, 1)
      $segs += "$esc[33mFAST-MODE ${h}h$esc[0m"
    }
  }
}

# pending-review debt: entries remaining after dropping blanks and "clean" (same rule as stop-gate); red
$nrFile = Join-Path $root '.claude/.needs-review'
if (Test-Path $nrFile) {
  $n = @(Get-Content $nrFile -ErrorAction SilentlyContinue | Where-Object { $_.Trim() -ne '' -and $_ -ne 'clean' }).Count
  if ($n -gt 0) { $segs += "$esc[31mpending-review $n$esc[0m" }
}

# large-repo governance switch (enabled iff the catalog exists)
if (Test-Path (Join-Path $root '.claude/harness/module-catalog.json')) {
  $segs += "$esc[32mharness ON$esc[0m"
}

if ($segs.Count -gt 0) { Write-Output ($segs -join ' | ') } else { Write-Output 'cc-base' }
exit 0
