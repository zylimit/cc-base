#!/usr/bin/env pwsh
# Hook: SessionStart
# If the git work tree has uncommitted changes (previous session may have been
# interrupted or its context compacted, state not yet in progress.md),
# inject a reminder to /recap and reconcile progress.md before continuing.
$ErrorActionPreference = 'Stop'

if (-not $env:CLAUDE_PROJECT_DIR) { exit 0 }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { exit 0 }
Set-Location $env:CLAUDE_PROJECT_DIR
git rev-parse --is-inside-work-tree 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { exit 0 }

$status = @(git status --porcelain 2>$null | Where-Object { $_ -ne '' })
if ($status.Count -eq 0) { exit 0 }
$count = $status.Count

$msg = "Git work tree has $count uncommitted change(s) -- the previous session may have been interrupted or its context compacted, so progress.md may not reflect the real state. Run /recap to read progress.md and reconcile against actual changes (are decisions/done items recorded?) before continuing."
$out = @{ hookSpecificOutput = @{ hookEventName = 'SessionStart'; additionalContext = $msg } } | ConvertTo-Json -Compress
Write-Output $out
exit 0
