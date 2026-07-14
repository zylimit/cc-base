#!/usr/bin/env pwsh
# Hook: Stop (PowerShell equivalent of three-file-sync-gate.sh)
# Three-file-sync gate (recovery-side enforcement) -- trusts only actual uncommitted
# changes in the git working tree.
#   C1: uncommitted changes include code/framework files but progress.md is not in the
#       change set -> block and remind to sync.
#   C2: change set contains Product-Spec.md but not CHANGELOG (or vice versa) -> a
#       requirement change may be missing its record.
#       Only validates files that exist -- if either Spec/CHANGELOG is absent, do not
#       fabricate, do not block.
# Clean tree / changes already include progress or the pair is updated together /
# not a git repo / no progress.md -> pass through gracefully.
# Subtree case: when the project dir is only a subdirectory of a parent repo
# (show-prefix non-empty), status is limited to the project subtree via `-- .` and
# each record path has the show-prefix stripped before classification (paths not
# carrying the prefix are skipped). When the project itself is the repo root the
# prefix is empty and behavior is unchanged.
# Fail-closed: an internal script error blocks with a self-check message; it never
# silently releases the gate.
$ErrorActionPreference = 'Stop'

# Fast-mode master switch: flag file present (and younger than the 24h TTL) -> pass through silently
if ($env:CLAUDE_PROJECT_DIR -and (Test-Path (Join-Path $env:CLAUDE_PROJECT_DIR '.claude/.fast-mode')) -and ((Get-Date) - (Get-Item (Join-Path $env:CLAUDE_PROJECT_DIR '.claude/.fast-mode')).LastWriteTime).TotalHours -lt 24) { exit 0 }

# Fail-closed: never let an internal error silently release the gate.
trap {
  $r = "three-file-sync-gate self-check failed: $($_.Exception.Message). Failing closed -- fix the gate/state, then retry stopping."
  Write-Output ([pscustomobject]@{ decision = 'block'; reason = $r } | ConvertTo-Json -Compress)
  exit 0
}

$root = $env:CLAUDE_PROJECT_DIR
if (-not $root) {
  try { $root = git rev-parse --show-toplevel 2>$null } catch { $root = $null }
  if (-not $root) { $root = (Get-Location).Path }
}
$prog = Join-Path $root 'progress.md'
if (-not (Test-Path $prog)) { exit 0 }

# Not a git repo -> no working tree to inspect, pass through gracefully.
try { git -C $root rev-parse --is-inside-work-tree 2>$null | Out-Null } catch { exit 0 }
if ($LASTEXITCODE -ne 0) { exit 0 }

# Porcelain paths are always relative to the repo root: when the project dir is a
# subdirectory of a parent repo they carry a prefix (e.g. proj/progress.md), so grab
# show-prefix now for stripping.
$prefix = ''
try { $p = git -C $root rev-parse --show-prefix 2>$null; if ($p) { $prefix = "$p" } } catch { }

$codeDirty = $false
$progDirty = $false
$specDirty = $false
$changelogDirty = $false
$firstCode = ''

# Classify a single changed path into the three-doc hit flags / code-change flag.
function Classify-Path([string]$path) {
  switch ($path) {
    'progress.md' { $script:progDirty = $true }
    'Product-Spec.md' { $script:specDirty = $true }
    'Product-Spec-CHANGELOG.md' { $script:changelogDirty = $true }
  }
  if ($path -match '(^|/)(\.claude/evidence|node_modules|out|dist)/') { return }
  if ($path -match '\.(sh|ps1|ts|tsx|js|jsx|py|css|go|rs)$') {
    $script:codeDirty = $true
    if (-not $script:firstCode) { $script:firstCode = $path }
  } elseif ($path -match '(^|/)\.claude/') {
    # Framework assets under .claude/ (CLAUDE.md / agents / skills / settings.json etc.)
    # also count as "changed, must record in progress", so they join the code set; the
    # evidence ledger was already excluded by the early-return branch above.
    $script:codeDirty = $true
    if (-not $script:firstCode) { $script:firstCode = $path }
  }
}

# Strip the repo-root-to-project prefix, then feed Classify-Path; paths not carrying
# the prefix (should not appear after the `-- .` pathspec limit) are skipped without
# classification. When the project is the repo root the prefix is empty, pass-through.
function Classify-RelPath([string]$path) {
  if ($script:prefix) {
    if (-not $path.StartsWith($script:prefix)) { return }
    $path = $path.Substring($script:prefix.Length)
  }
  Classify-Path $path
}

# --porcelain -z: NUL-separated, paths unquoted (avoids regex misses when filenames with
# spaces get quote-wrapped). git -z output has no newlines; PowerShell receives it as one
# string, split into records on NUL. `-- .` limits status to the project subtree (cwd is
# already the project dir via -C), so unrelated changes outside it never enter the set.
# rename/copy spans two segments: `XY <new>` NUL
# `<old>` NUL (old path is bare, no prefix), so when X/Y matches R/C, read the next bare
# old-path segment too and count both old and new.
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

$block = $false
$reason = ''

if ($codeDirty -and (-not $progDirty)) {
  $reason = "Three-file-sync rule: uncommitted code/framework changes detected (e.g. $firstCode) but progress.md is not synced. Write this round's decisions/completions/progress/new tasks into progress.md now (doc-type edits are done by the main Agent directly), so the project can always be fully recovered via Clear->recap, then retry stopping."
  $block = $true
}

# Pair validation runs only when both files exist; if either is missing, do not fabricate, do not block.
if ((Test-Path (Join-Path $root 'Product-Spec.md')) -and (Test-Path (Join-Path $root 'Product-Spec-CHANGELOG.md'))) {
  if ($specDirty -and (-not $changelogDirty)) {
    $reason = ("$reason Product-Spec.md has uncommitted changes but Product-Spec-CHANGELOG.md is not synced; the requirement change may be missing from the CHANGELOG. Add this change's record to Product-Spec-CHANGELOG.md, then retry stopping.").Trim()
    $block = $true
  }
  if ($changelogDirty -and (-not $specDirty)) {
    $reason = ("$reason Product-Spec-CHANGELOG.md has uncommitted changes but Product-Spec.md is not synced; requirement changes must update both files as a pair. Sync Product-Spec.md, then retry stopping.").Trim()
    $block = $true
  }
}

if (-not $block) { exit 0 }

try { . (Join-Path $PSScriptRoot 'lib-gate-log.ps1'); Write-GateLog 'three-file-sync-gate' $reason } catch { }

$json = [pscustomobject]@{ decision = 'block'; reason = $reason } | ConvertTo-Json -Compress
Write-Output $json
exit 0
