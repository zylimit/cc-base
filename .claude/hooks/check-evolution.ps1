#!/usr/bin/env pwsh
# Hook: SessionStart (PowerShell equivalent of check-evolution.sh)
# Check FEEDBACK-INDEX.md for pending feedback; if any, remind to dispatch evolution-runner.
$ErrorActionPreference = 'Stop'

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
