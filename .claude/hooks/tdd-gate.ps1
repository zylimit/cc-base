#!/usr/bin/env pwsh
# Hook: PreToolUse(Bash) (PowerShell equivalent of tdd-gate.sh)
# TDD gate advisory (not a hard block, reminder only): detect dispatching implementer to write
# code while .red-verified / .tdd-exempt is absent.
$ErrorActionPreference = 'Stop'

$raw = [Console]::In.ReadToEnd()
try { $cmd = ($raw | ConvertFrom-Json).tool_input.command } catch { exit 0 }
if (-not $cmd) { exit 0 }

# try/catch: under Windows PowerShell 5.1 a git fatal (not-a-repo) on stderr becomes an
# ErrorRecord that $ErrorActionPreference='Stop' promotes to terminating, bypassing the
# fallback below. Catch -> fall back to the current location.
try { $root = git rev-parse --show-toplevel 2>$null } catch { $root = $null }
if (-not $root) { $root = (Get-Location).Path }

# Only fire for commands that look like launching implementer
if ($cmd -match '(?i)(implementer|dev-builder|GREEN)') {
  $redVerified = Join-Path $root '.claude/.red-verified'
  $tddExempt = Join-Path $root '.claude/.tdd-exempt'
  if ((-not (Test-Path $redVerified)) -and (-not (Test-Path $tddExempt))) {
    [Console]::Error.WriteLine("TDD gate: complete RED before dispatching implementer for the GREEN implementation.")
    [Console]::Error.WriteLine("High-value logic (contract/parser/state-machine/dedup/schema validation/driver-adapter layer): first dispatch tester to produce a failing test -> verify red -> touch .claude/.red-verified, then dispatch implementer to write the minimal implementation to green.")
    [Console]::Error.WriteLine("If this Task is UI/styling/non-TDD logic: touch .claude/.tdd-exempt to declare an explicit exemption.")
    # Advisory only, not a hard block (consistent with the file header comment)
    exit 0
  }
}
exit 0
