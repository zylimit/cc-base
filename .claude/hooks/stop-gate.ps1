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

# Fast-mode master switch via shared lib: unexpired expires_epoch -> pass through silently (lib missing => fail-closed, never passes)
try { . (Join-Path $PSScriptRoot 'lib-fast-mode.ps1'); if (Test-FastModeActive) { exit 0 } } catch {}

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
  Remove-Item $strikeFile -Force -ErrorAction SilentlyContinue
  exit 0
}

$files = @(Get-Content $stateFile | Where-Object { $_.Trim() -ne '' -and $_ -ne 'clean' })
if ($files.Count -eq 0) {
  # Monorepo receipt gate (enabled only when the catalog exists; skipped silently when node is
  # missing -> original logic, zero behaviour change): once the list is cleared (verbal release),
  # verify the current worktree diff is bound to a passed receipt -- if the code moved past every
  # reviewed receipt (STALE, rc=4) force re-review, keeping .needs-review so the next stop still blocks.
  # An out-of-contract exit code (receipt verify contract is only 0/3/4) means the engine itself
  # crashed and the gate never ran -- releasing there would be a fake pass, so it blocks too, names
  # the actual code, keeps .needs-review, and runs through the same .stop-gate-strikes breaker so a
  # permanently broken engine cannot brick the session.
  . (Join-Path $PSScriptRoot 'lib-harness.ps1')
  if ((Test-HarnessEnabled) -and (Get-HarnessNode)) {
    $rv = Invoke-Harness @('receipt', 'verify')
    if ($rv -and $rv.Code -eq 4) {
      $r = 'Code changed after the last review; no matching passed receipt (diff moved past every reviewed receipt). Re-dispatch code-reviewer for the current diff and write a receipt before stopping.'
      try { . (Join-Path $PSScriptRoot 'lib-gate-log.ps1'); Write-GateLog 'stop-gate' $r } catch { }
      Write-Output ([pscustomobject]@{ decision = 'block'; reason = $r } | ConvertTo-Json -Compress)
      exit 0
    }
    if ($rv -and -not (Test-HarnessRcInContract -Code $rv.Code -Contract @(0, 3))) {
      # Strike accounting reuses the same state file; the fingerprint is the exit code (a different
      # code starts over at 1), so it never mixes with the pending-list fingerprints.
      $hsig = "harness-receipt-verify-rc$($rv.Code)"
      $hstrikes = 0
      if (Test-Path $strikeFile) {
        $hprev = @(Get-Content $strikeFile -ErrorAction SilentlyContinue)
        $hprevSig = @($hprev | Where-Object { $_ -like 'sig=*' })[0] -replace '^sig=', ''
        $hprevCount = @($hprev | Where-Object { $_ -like 'count=*' })[0] -replace '^count=', ''
        if ($hprevSig -eq $hsig) { [void][int]::TryParse($hprevCount, [ref]$hstrikes) }
      }
      $rvHead = Get-HarnessErrHead -Text $rv.Err
      if ($hstrikes -ge 3) {
        Remove-Item $strikeFile -Force -ErrorAction SilentlyContinue
        $notice = "stop-gate: harness receipt verify exited with out-of-contract code $($rv.Code) three times in a row (engine failure, NOT a stale receipt) -- consecutive-block limit reached, releasing this stop. The receipt binding was never verified, the debt stands: fix the engine with 'node .claude/harness/harness.mjs receipt verify'. Engine error: $rvHead"
        try { . (Join-Path $PSScriptRoot 'lib-gate-log.ps1'); Write-GateLog 'stop-gate' $notice } catch { }
        Write-Output ([pscustomobject]@{ systemMessage = $notice } | ConvertTo-Json -Compress)
        exit 0
      }
      Set-Content -Path $strikeFile -Value @("sig=$hsig", ("count=" + ($hstrikes + 1)))
      $r = "stop-gate: harness receipt verify exited with out-of-contract code $($rv.Code) (the contract is only 0/3/4), so the receipt gate never ran -- this is an engine failure (missing .claude/harness/lib/, broken node), NOT a stale receipt. Run 'node .claude/harness/harness.mjs receipt verify' for the real error and fix the engine before stopping. Engine error: $rvHead"
      try { . (Join-Path $PSScriptRoot 'lib-gate-log.ps1'); Write-GateLog 'stop-gate' $r } catch { }
      Write-Output ([pscustomobject]@{ decision = 'block'; reason = $r } | ConvertTo-Json -Compress)
      exit 0
    }
  }
  Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
  Remove-Item "$stateFile.lock" -Force -ErrorAction SilentlyContinue
  Remove-Item $strikeFile -Force -ErrorAction SilentlyContinue
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
  Remove-Item $strikeFile -Force -ErrorAction SilentlyContinue
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
