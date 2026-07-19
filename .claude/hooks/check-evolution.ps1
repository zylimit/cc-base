#!/usr/bin/env pwsh
# Hook: SessionStart (PowerShell equivalent of check-evolution.sh)
# Check FEEDBACK-INDEX.md for pending feedback; if any, remind to dispatch evolution-runner.
$ErrorActionPreference = 'Stop'

# Fast-mode master switch: flag file carries an unexpired expires_epoch -> pass through silently (missing/invalid line never passes)
try { if ($env:CLAUDE_PROJECT_DIR) { $fmLine = Select-String -LiteralPath (Join-Path $env:CLAUDE_PROJECT_DIR '.claude/.fast-mode') -Pattern '^expires_epoch=(\d+)$' -ErrorAction Stop | Select-Object -First 1; if ($fmLine -and [int64]$fmLine.Matches[0].Groups[1].Value -gt [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) { exit 0 } } } catch {}

if (-not $env:CLAUDE_PROJECT_DIR) { exit 0 }
$feedbackIndex = Join-Path $env:CLAUDE_PROJECT_DIR '.claude/feedback/FEEDBACK-INDEX.md'
if (-not (Test-Path $feedbackIndex)) { exit 0 }

$lines = Get-Content $feedbackIndex
# Pending = index entries without the graduated prefix (line starts with "- [")
$pending = @($lines | Where-Object { $_ -match '^- \[' }).Count
# Total = all feedback entry lines: start with "- " and contain "](" (the entry link)
$total = @($lines | Where-Object { $_ -match '^-\s' -and $_ -match '\]\(' }).Count

if ($pending -gt 0) {
  Write-Output "[i] Project has $pending pending feedback ($total total). Consider dispatching evolution-runner to check for evolution proposals."
}
exit 0
