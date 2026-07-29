#!/usr/bin/env pwsh
# Hook: PreToolUse(Bash) (PowerShell equivalent of kill-dev-ports.sh)
# Before starting the dev server, free up common ports so old processes do not block startup.
# Windows uses netstat + taskkill instead of lsof + kill.
# Self-gates: commands that are not "pnpm dev" pass through (exit 0).
$ErrorActionPreference = 'Stop'

# Fast-mode master switch via shared lib: unexpired expires_epoch -> pass through silently (lib missing => fail-closed, never passes)
try { . (Join-Path $PSScriptRoot 'lib-fast-mode.ps1'); if (Test-FastModeActive) { exit 0 } } catch {}

[Console]::InputEncoding = [System.Text.UTF8Encoding]::new()
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
