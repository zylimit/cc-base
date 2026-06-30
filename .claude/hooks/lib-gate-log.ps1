#!/usr/bin/env pwsh
# Fail-safe gate block ledger (PowerShell equivalent of lib-gate-log.sh).
# Dot-source this file and call Write-GateLog <hook> <reason> from block hooks.

function Write-GateLog {
  param(
    [string]$Hook = 'unknown',
    [string]$Reason = ''
  )
  try {
    $projectDir = $env:CLAUDE_PROJECT_DIR
    if (-not $projectDir) { return }
    $firstLine = ($Reason -split "`r?`n")[0]
    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $dir = Join-Path $projectDir '.claude/evidence'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $line = "{0}`t{1}`t{2}" -f $ts, $Hook, $firstLine
    Add-Content -Path (Join-Path $dir 'gate-block.log') -Value $line -ErrorAction SilentlyContinue
  } catch { }
}
