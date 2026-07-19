#!/usr/bin/env pwsh
# Hook: PreToolUse(Bash) (PowerShell equivalent of kill-dev-ports.sh)
# Before starting the dev server, free up common ports so old processes do not block startup.
# Windows uses netstat + taskkill instead of lsof + kill.
# Self-gates: commands that are not "pnpm dev" pass through (exit 0).
$ErrorActionPreference = 'Stop'

# Fast-mode master switch: flag file carries an unexpired expires_epoch -> pass through silently (missing/invalid line never passes)
try { if ($env:CLAUDE_PROJECT_DIR) { $fmLine = Select-String -LiteralPath (Join-Path $env:CLAUDE_PROJECT_DIR '.claude/.fast-mode') -Pattern '^expires_epoch=(\d+)$' -ErrorAction Stop | Select-Object -First 1; if ($fmLine -and [int64]$fmLine.Matches[0].Groups[1].Value -gt [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) { exit 0 } } } catch {}

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
