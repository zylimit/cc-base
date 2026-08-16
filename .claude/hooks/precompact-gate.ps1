#!/usr/bin/env pwsh
# Hook: PreCompact (PowerShell equivalent of precompact-gate.sh)
# Guard before compaction -- makes "decisions lost to in-session compaction" interceptable.
# Compaction replaces the conversation body with a summary; unrecorded decisions and the
# pending-review state are what evaporate first. Before compacting, check:
#   C1: .needs-review has pending files (the review loop is unfinished; its context is
#       lost after compaction)
#   C2: the working tree has uncommitted code/framework changes but progress.md is not in
#       the change set (this round's decisions are not yet in project memory)
# Either hit -> block compaction once (decision:block) and ask for /record first.
# Anti-brick design (opposite bias to the Stop gates -- this gate prefers to release):
#   - after one block, do not block again for 10 minutes (.precompact-block-epoch stores
#     the last block time) -- an auto compaction may be recovering from a context-limit
#     error, and blocking it twice only makes requests fail repeatedly;
#   - internal script errors fail OPEN (a missed reminder is cheaper than a bricked session).
# Clean state / not a git repo / no progress.md -> pass through and clear the marker.
$ErrorActionPreference = 'Stop'

# Fast-mode master switch via shared lib: unexpired expires_epoch -> pass through silently (lib missing => fail-closed, never passes)
try { . (Join-Path $PSScriptRoot 'lib-fast-mode.ps1'); if (Test-FastModeActive) { exit 0 } } catch {}

# Fail-open: any internal error releases the gate (see header note).
trap { exit 0 }

[Console]::InputEncoding = [System.Text.UTF8Encoding]::new()
$null = [Console]::In.ReadToEnd()

$root = $env:CLAUDE_PROJECT_DIR
if (-not $root) {
  try { $root = git rev-parse --show-toplevel 2>$null } catch { $root = $null }
  if (-not $root) { $root = (Get-Location).Path }
}
$mark = Join-Path $root '.claude/.precompact-block-epoch'

# 10-minute cool-down window: once blocked, pass through to leave a record-then-retry path
$now = [int][double]::Parse((Get-Date -UFormat %s))
if (Test-Path $mark) {
  $last = (Get-Content $mark -ErrorAction SilentlyContinue | Select-Object -First 1)
  if ($last -match '^\d+$' -and ($now - [int]$last) -lt 600) { exit 0 }
}

$dirtyReason = ''

# C1: pending review list not cleared (same list semantics as stop-gate)
$stateFile = Join-Path $root '.claude/.needs-review'
if (Test-Path $stateFile) {
  $pending = @(Get-Content $stateFile -ErrorAction SilentlyContinue | Where-Object { $_.Trim() -ne '' -and $_ -ne 'clean' })
  if ($pending.Count -gt 0) {
    $dirtyReason = "pending review list is not cleared ($($pending.Count) file(s) awaiting code review)"
  }
}

# C2: code/framework dirty while progress.md is not in the change set (simplified three-file-sync C1)
if (-not $dirtyReason) {
  $prog = Join-Path $root 'progress.md'
  $inTree = $false
  if (Test-Path $prog) {
    try { git -C $root rev-parse --is-inside-work-tree 2>$null | Out-Null; $inTree = ($LASTEXITCODE -eq 0) } catch { $inTree = $false }
  }
  if ($inTree) {
    $prefix = ''
    try { $p = git -C $root rev-parse --show-prefix 2>$null; if ($p) { $prefix = "$p" } } catch { }
    $codeDirty = $false
    $progDirty = $false
    function Classify-Path([string]$path) {
      if ($path -eq 'progress.md') { $script:progDirty = $true }
      if ($path -match '(^|/)(\.claude/evidence|node_modules|out|dist)/') { return }
      if ($path -match '\.(sh|ps1|ts|tsx|js|jsx|py|css|go|rs)$') { $script:codeDirty = $true }
      elseif ($path -match '(^|/)\.claude/') { $script:codeDirty = $true }
    }
    function Classify-RelPath([string]$path) {
      if ($script:prefix) {
        if (-not $path.StartsWith($script:prefix)) { return }
        $path = $path.Substring($script:prefix.Length)
      }
      Classify-Path $path
    }
    $raw = @(git -C $root status --porcelain -z -- . 2>$null) -join ''
    $records = @($raw -split "`0" | Where-Object { $_ -ne '' })
    $i = 0
    while ($i -lt $records.Count) {
      $rec = $records[$i]
      if ($rec.Length -lt 3) { $i++; continue }
      $status = $rec.Substring(0, 2)
      Classify-RelPath $rec.Substring(3)
      if ($status -match '^[RC]' -or $status -match '[RC]$') {
        $i++
        if ($i -lt $records.Count) { Classify-RelPath $records[$i] }
      }
      $i++
    }
    if ($codeDirty -and (-not $progDirty)) {
      $dirtyReason = 'the working tree has uncommitted code/framework changes but progress.md is not synced (this round''s decisions are not yet in project memory)'
    }
  }
}

if (-not $dirtyReason) {
  Remove-Item $mark -Force -ErrorAction SilentlyContinue
  exit 0
}

Set-Content -Path $mark -Value "$now" -ErrorAction SilentlyContinue
$reason = "Pre-compaction gate: $dirtyReason. Compaction replaces the conversation body with a summary and this state evaporates with it -- dispatch progress-recorder /record to persist decisions/completions first (handle pending reviews or record the debt explicitly), then retry compacting. This gate will not block again for 10 minutes."

try { . (Join-Path $PSScriptRoot 'lib-gate-log.ps1'); Write-GateLog 'precompact-gate' $reason } catch { }

Write-Output ([pscustomobject]@{ decision = 'block'; reason = $reason } | ConvertTo-Json -Compress)
exit 0
