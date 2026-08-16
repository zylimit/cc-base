#!/usr/bin/env pwsh
# Hook: UserPromptExpansion(release-builder) (PowerShell equivalent of release-gate.sh)
# Pre-expansion gate for the release command -- upgrades "pass the test checkpoint before
# packaging" from skill prose into a machine gate. When the user types /release-builder
# (the only entry once disable-model-invocation is set), check BEFORE the skill content
# expands into context:
#   - .needs-review has pending files -> block (the review->fix loop is unfinished; do not
#     enter the release flow)
#   - clean -> pass, and inject additionalContext reminding the release preconditions
#     (green test run list / no skipped packaging steps / independent triple-check of the
#     deployment)
# The release checkpoint does NOT honor fast-mode (CLAUDE.md: Fast Mode is not a deploy or
# push authorization).
# Fail-open: internal errors release this gate (the release flow still has the
# test-builder checkpoint and HIGH-tier approval behind it).
$ErrorActionPreference = 'Stop'
trap { exit 0 }

[Console]::InputEncoding = [System.Text.UTF8Encoding]::new()
$raw = [Console]::In.ReadToEnd()
$cmdName = ''
try { $cmdName = ($raw | ConvertFrom-Json).command_name } catch { $cmdName = '' }
# matcher already filters by command name; on parse failure or another command, never block
if ($cmdName -and ($cmdName -ne 'release-builder')) { exit 0 }

$root = $env:CLAUDE_PROJECT_DIR
if (-not $root) { $root = (Get-Location).Path }
$stateFile = Join-Path $root '.claude/.needs-review'
$pending = @()
if (Test-Path $stateFile) {
  $pending = @(Get-Content $stateFile -ErrorAction SilentlyContinue | Where-Object { $_.Trim() -ne '' -and $_ -ne 'clean' })
}

if ($pending.Count -gt 0) {
  $inline = ($pending -join ', ')
  $reason = "Release pre-gate: the pending review list is not cleared ($($pending.Count) file(s) awaiting code review: $inline). Finish the review->fix loop first (then echo clean > .claude/.needs-review), and run /release-builder again."
  try { . (Join-Path $PSScriptRoot 'lib-gate-log.ps1'); Write-GateLog 'release-gate' $reason } catch { }
  Write-Output ([pscustomobject]@{ decision = 'block'; reason = $reason } | ConvertTo-Json -Compress)
  exit 0
}

$ctx = 'Release checkpoint reminder (injected by release-gate): (1) the test checkpoint is mandatory before packaging -- test-builder runs the full suite, a green report must list which files ran and each result, evidence = the runner''s real output; (2) Fast Mode does not exempt release checkpoints; (3) after deployment the main Agent independently verifies the triple-check (container creation timestamp + image tag / health endpoint / live smoke test) -- never trust the deployer''s self-report.'
$obj = [pscustomobject]@{ hookSpecificOutput = [pscustomobject]@{ hookEventName = 'UserPromptExpansion'; additionalContext = $ctx } }
Write-Output ($obj | ConvertTo-Json -Compress)
exit 0
