#!/usr/bin/env pwsh
# Hook: Stop (PowerShell equivalent of stop-gate.sh)
# Block stopping when there is project code pending review. State file: .needs-review
# (registered per file, one relative path per line).
#   - After removing blank lines and the "clean" line, any remaining files = block and list them
#   - Otherwise (only clean / all blank / not present) = allow and clean up
#   - Consecutive-block cap (anti-deadlock): .stop-gate-strikes (self-describing sig=/count=
#     lines; corrupt = no state, rebuild) counts blocks of the SAME pending list; 3 blocks in
#     a row -> the 4th attempt is released with a notice, the pending list itself stays.
#     A clean pass or any change of the list resets the count.
#   - Fail-closed: an internal script error blocks with a self-check message; it never
#     silently releases the gate.
# Release contract: after review passes, run `echo clean > .claude/.needs-review`.
$ErrorActionPreference = 'Stop'

# Fast-mode master switch: flag file carries an unexpired expires_epoch -> pass through silently (missing/invalid line never passes)
try { if ($env:CLAUDE_PROJECT_DIR) { $fmLine = Select-String -LiteralPath (Join-Path $env:CLAUDE_PROJECT_DIR '.claude/.fast-mode') -Pattern '^expires_epoch=(\d+)$' -ErrorAction Stop | Select-Object -First 1; if ($fmLine -and [int64]$fmLine.Matches[0].Groups[1].Value -gt [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) { exit 0 } } } catch {}

# Fail-closed: never let an internal error silently release the gate.
trap {
  $r = "stop-gate self-check failed: $($_.Exception.Message). Failing closed -- fix the gate/state, then retry stopping."
  Write-Output ([pscustomobject]@{ decision = 'block'; reason = $r } | ConvertTo-Json -Compress)
  exit 0
}

if (-not $env:CLAUDE_PROJECT_DIR) { exit 0 }
$stateFile = Join-Path $env:CLAUDE_PROJECT_DIR '.claude/.needs-review'
$strikeFile = Join-Path $env:CLAUDE_PROJECT_DIR '.claude/.stop-gate-strikes'
if (-not (Test-Path $stateFile)) {
  Remove-Item $strikeFile -ErrorAction SilentlyContinue
  exit 0
}

$files = @(Get-Content $stateFile | Where-Object { $_.Trim() -ne '' -and $_ -ne 'clean' })
if ($files.Count -eq 0) {
  Remove-Item $stateFile -ErrorAction SilentlyContinue
  Remove-Item "$stateFile.lock" -ErrorAction SilentlyContinue
  Remove-Item $strikeFile -ErrorAction SilentlyContinue
  exit 0
}

$count = $files.Count
$inline = $files -join ', '

# Strike accounting: the count only accumulates while the pending-list fingerprint is
# identical; any change starts over at 1. Anti-deadlock for subagent sessions that cannot
# dispatch the reviewer themselves and would loop against this gate forever.
$sha = [System.Security.Cryptography.SHA256]::Create()
$sig = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes((($files | Sort-Object) -join '|'))) | ForEach-Object { $_.ToString('x2') })
$strikes = 0
if (Test-Path $strikeFile) {
  $prev = @(Get-Content $strikeFile -ErrorAction SilentlyContinue)
  $prevSig = @($prev | Where-Object { $_ -like 'sig=*' })[0] -replace '^sig=', ''
  $prevCount = @($prev | Where-Object { $_ -like 'count=*' })[0] -replace '^count=', ''
  if ($prevSig -eq $sig) { [void][int]::TryParse($prevCount, [ref]$strikes) }
}
if ($strikes -ge 3) {
  Remove-Item $strikeFile -ErrorAction SilentlyContinue
  $notice = "stop-gate: consecutive-block limit (3) reached for the same pending list -- releasing this stop, BUT the pending list is NOT cleared ($count files still owed review: $inline). Dispatch the code-reviewer as soon as possible."
  try { . (Join-Path $PSScriptRoot 'lib-gate-log.ps1'); Write-GateLog 'stop-gate' $notice } catch { }
  Write-Output ([pscustomobject]@{ systemMessage = $notice } | ConvertTo-Json -Compress)
  exit 0
}
Set-Content -Path $strikeFile -Value @("sig=$sig", ("count=" + ($strikes + 1)))
$reason = "Code was modified but not code-reviewed ($count files pending: $inline). Dispatch the code-reviewer sub-agent for the two-stage review; after it passes, run 'echo clean > .claude/.needs-review' to release."
try { . (Join-Path $PSScriptRoot 'lib-gate-log.ps1'); Write-GateLog 'stop-gate' $reason } catch { }
$json = [pscustomobject]@{ decision = 'block'; reason = $reason } | ConvertTo-Json -Compress
Write-Output $json
exit 0
