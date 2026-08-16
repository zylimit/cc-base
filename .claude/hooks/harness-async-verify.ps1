#!/usr/bin/env pwsh
# Hook: PostToolUse(Edit|Write) (PowerShell equivalent of harness-async-verify.sh)
# Background early warning for the large-repo targeted gate -- asyncRewake form (registered
# with async+asyncRewake in settings; this script only runs and sets the exit code).
# Relation to pre-commit-check: the commit gate stays a synchronous hard door; this hook
# runs the same harness verify (four-state gate + attribute evidence gate) in the
# background during edit time between commits. On FAIL/BLOCKED it exits 2 to wake the main
# Agent with a stderr summary -- failures surface early (fail-visible) without adding
# interactive latency.
# Enablement and degradation: runs only with catalog + node both present (lib-harness
# guards); fast-mode passes through (quality gate); 180s debounce (.async-verify-last
# stores the last run epoch; write-before-run to avoid async storms).
# Summary budget: gate + first 5 FAIL/BLOCKED checks + attribute-gap count, never the
# full JSON.
$ErrorActionPreference = 'Stop'

# Fast-mode master switch via shared lib: unexpired expires_epoch -> pass through silently (lib missing => fail-closed, never passes)
try { . (Join-Path $PSScriptRoot 'lib-fast-mode.ps1'); if (Test-FastModeActive) { exit 0 } } catch {}

trap { exit 0 }

[Console]::InputEncoding = [System.Text.UTF8Encoding]::new()
$null = [Console]::In.ReadToEnd()

. (Join-Path $PSScriptRoot 'lib-harness.ps1')
if (-not (Test-HarnessEnabled)) { exit 0 }
if (-not (Get-HarnessNode)) { exit 0 }

$root = $env:CLAUDE_PROJECT_DIR
if (-not $root) { $root = (Get-Location).Path }
$mark = Join-Path $root '.claude/.async-verify-last'
$now = [int][double]::Parse((Get-Date -UFormat %s))
if (Test-Path $mark) {
  $last = (Get-Content $mark -ErrorAction SilentlyContinue | Select-Object -First 1)
  if ($last -match '^\d+$' -and ($now - [int]$last) -lt 180) { exit 0 }
}
Set-Content -Path $mark -Value "$now" -ErrorAction SilentlyContinue

$res = Invoke-Harness -HarnessArgs @('verify')
if (-not $res) { exit 0 }
if ($res.Code -ne 2) { exit 0 }

$summary = ''
try {
  $d = $res.Out | ConvertFrom-Json
  $gate = if ($d.gate) { $d.gate } elseif ($d.state) { $d.state } else { 'FAIL' }
  $lines = @("gate=$gate")
  if ($d.emptyPlan) { $lines += 'empty verification plan: affected modules declare no checks (config gap, not green)' }
  $bad = @($d.checks | Where-Object { $_.state -in @('FAIL', 'BLOCKED') })
  foreach ($c in ($bad | Select-Object -First 5)) {
    $why = if ($c.reason) { $c.reason } else { "exit=$($c.exit)" }
    $lines += "- $($c.module) [$($c.state)] $($c.id) $why"
  }
  if ($bad.Count -gt 5) { $lines += "- ... and $($bad.Count - 5) more" }
  if ($d.attributeGaps -and $d.attributeGaps.Count -gt 0) {
    $lines += "attribute evidence gaps: $($d.attributeGaps.Count) (critical/high attributes lack a claiming PASS)"
  }
  $summary = $lines -join "`n"
} catch {
  $summary = 'verify rc=2 (FAIL/BLOCKED or attribute evidence gap) -- run node .claude/harness/harness.mjs verify for the full report'
}

[Console]::Error.WriteLine('[harness-async-verify] background quality gate failed during edit time:')
[Console]::Error.WriteLine($summary)
[Console]::Error.WriteLine('pre-commit-check will hard-block the commit; fix now or dispatch bug-fixer.')
try { . (Join-Path $PSScriptRoot 'lib-gate-log.ps1'); Write-GateLog 'harness-async-verify' 'background verify failed (early warning, not a hard block)' } catch { }
exit 2
