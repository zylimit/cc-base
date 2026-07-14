#!/usr/bin/env pwsh
# Hook: PreToolUse(Bash) (PowerShell equivalent of kill-dev-ports.sh)
# Before starting the dev server, free up common ports so old processes do not block startup.
# Windows uses netstat + taskkill instead of lsof + kill.
# Self-gates: commands that are not "pnpm dev" pass through (exit 0).
$ErrorActionPreference = 'Stop'

# Fast-mode master switch: flag file present (and younger than the 24h TTL) -> pass through silently
if ($env:CLAUDE_PROJECT_DIR -and (Test-Path (Join-Path $env:CLAUDE_PROJECT_DIR '.claude/.fast-mode')) -and ((Get-Date) - (Get-Item (Join-Path $env:CLAUDE_PROJECT_DIR '.claude/.fast-mode')).LastWriteTime).TotalHours -lt 24) { exit 0 }

$raw = [Console]::In.ReadToEnd()
try { $cmd = ($raw | ConvertFrom-Json).tool_input.command } catch { $cmd = $raw }
if (-not $cmd) { exit 0 }
if ($cmd -notmatch 'pnpm\s+dev') { exit 0 }

foreach ($port in 3000, 3001, 4173, 5173, 8080) {
  $listening = netstat -ano 2>$null | Select-String ":$port\s+.*LISTENING"
  foreach ($line in $listening) {
    $procId = ($line.ToString().Trim() -split '\s+')[-1]
    if ($procId -match '^\d+$') {
      taskkill /PID $procId /F *> $null
    }
  }
}
Start-Sleep -Seconds 1
exit 0
