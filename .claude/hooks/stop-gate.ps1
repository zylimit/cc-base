#!/usr/bin/env pwsh
# Hook: Stop (PowerShell equivalent of stop-gate.sh)
# Block stopping when there is project code pending review. State file: .needs-review
# (registered per file, one relative path per line).
#   - After removing blank lines and the "clean" line, any remaining files = block and list them
#   - Otherwise (only clean / all blank / not present) = allow and clean up
# Release contract: after review passes, run `echo clean > .claude/.needs-review`.
$ErrorActionPreference = 'Stop'

if (-not $env:CLAUDE_PROJECT_DIR) { exit 0 }
$stateFile = Join-Path $env:CLAUDE_PROJECT_DIR '.claude/.needs-review'
if (-not (Test-Path $stateFile)) { exit 0 }

$files = @(Get-Content $stateFile | Where-Object { $_.Trim() -ne '' -and $_ -ne 'clean' })
if ($files.Count -eq 0) {
  Remove-Item $stateFile -ErrorAction SilentlyContinue
  Remove-Item "$stateFile.lock" -ErrorAction SilentlyContinue
  exit 0
}

$count = $files.Count
$inline = $files -join ', '
$reason = "Code was modified but not code-reviewed ($count files pending: $inline). Dispatch the code-reviewer sub-agent for the two-stage review; after it passes, run 'echo clean > .claude/.needs-review' to release."
try { . (Join-Path $PSScriptRoot 'lib-gate-log.ps1'); Write-GateLog 'stop-gate' $reason } catch { }
$json = [pscustomobject]@{ decision = 'block'; reason = $reason } | ConvertTo-Json -Compress
Write-Output $json
exit 0
