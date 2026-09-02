#!/usr/bin/env pwsh
# Hook: PostCompact (PowerShell equivalent of postcompact-reinject.sh)
# Re-inject the invariants after a compaction, because compaction does not dilute a
# governance constraint -- it deletes it. The summariser works for task continuity, and an
# iron rule nobody has referenced for twenty turns is exactly what it drops; a summary also
# carries drift over rather than correcting it. So this hook reads no summary: it runs
# `harness invariants`, which re-derives "what cannot be traded away" plus the live state
# from CLAUDE.md / progress.md / the runtime, and returns it through additionalContext.
# The ~1200-char budget is the point -- anything longer is eaten by the next compaction.
# Paired with precompact-gate at the other end of the boundary, not overlapping with it:
# that one blocks once before compaction so state gets recorded, this one restores after.
# Official contract (verified against code.claude.com/docs/en/hooks):
#   input carries compact_trigger / compaction_ratio / messages_before / messages_after;
#   output supports top-level additionalContext and systemMessage, and PostCompact has no
#   decision control -- it cannot block, and should not try to.
# Guards (the compaction already happened, so blocking is pointless -- but silence is not):
#   - node missing / harness missing / engine exit outside the 0|3 contract / unparseable
#     output -> emit a visible degradation notice and exit 0.
$ErrorActionPreference = 'Stop'

# Fixed constant payloads: this path may run with no node to build JSON with, and hand-built
# JSON carrying a variable is one unescaped quote away from being invalid -- and invalid JSON
# is recorded as a hook error, which injects nothing at all.
$MSG_NO_NODE = '{"systemMessage":"PostCompact: node not found on PATH, so the invariants could not be re-derived after this compaction. The non-negotiable rules and the live state were NOT re-injected -- run `node .claude/harness/harness.mjs invariants` yourself, or read .claude/CLAUDE.md and progress.md before acting on anything the summary implies."}'
$MSG_NO_HARNESS = '{"systemMessage":"PostCompact: .claude/harness/harness.mjs is missing, so the invariants could not be re-derived after this compaction. The non-negotiable rules and the live state were NOT re-injected -- read .claude/CLAUDE.md and progress.md before acting on anything the summary implies."}'
$MSG_ENGINE = '{"systemMessage":"PostCompact: the harness failed while re-deriving the invariants after this compaction (see the debug log for its exit code and stderr). The non-negotiable rules and the live state were NOT re-injected -- fix the engine, or read .claude/CLAUDE.md and progress.md before acting on anything the summary implies."}'

# An internal fault must still say so. Never block: PostCompact has no decision control, and
# a hook that dies quietly here leaves the caller believing the invariants came back.
trap { Write-Output $MSG_ENGINE; exit 0 }

# UTF-8 both ways. Reading: the event JSON is UTF-8 and a Chinese Windows console defaults to
# GB2312. Writing: node's stdout carries the memory files verbatim, and the same codepage
# would mangle it on the way in. ConvertTo-Json escapes non-ASCII to \uXXXX, so what this
# script finally prints stays ASCII either way.
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new()
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$raw = [Console]::In.ReadToEnd()
$ev = $null
try { if ($raw -and $raw.Trim()) { $ev = $raw | ConvertFrom-Json } } catch { $ev = $null }

$root = $env:CLAUDE_PROJECT_DIR
if (-not $root) {
  try { $root = git rev-parse --show-toplevel 2>$null } catch { $root = $null }
  if (-not $root) { $root = (Get-Location).Path }
}
$harness = Join-Path $root '.claude/harness/harness.mjs'

$node = $null
try { $node = (Get-Command node -ErrorAction SilentlyContinue) } catch { $node = $null }
if (-not $node) { Write-Output $MSG_NO_NODE; exit 0 }
if (-not (Test-Path $harness)) { Write-Output $MSG_NO_HARNESS; exit 0 }

# Native commands write to stderr as ErrorRecords under $ErrorActionPreference='Stop' on
# Windows PowerShell 5.1, which would turn a diagnostic line into a terminating error. Local
# 'Continue' plus 2>$null keeps the exit code the only signal read here.
$out = $null
$rc = 1
try {
  $ErrorActionPreference = 'Continue'
  $out = (& node $harness invariants 2>$null | Out-String)
  $rc = $LASTEXITCODE
} catch {
  $out = $null
  $rc = 1
} finally {
  $ErrorActionPreference = 'Stop'
}

# Contract: 0 = derived, 3 = the source files were missing but the live state still was.
# Both are worth re-injecting. Any other code means the engine itself broke, which is not
# the same claim as "there are no invariants".
if (($rc -ne 0) -and ($rc -ne 3)) { Write-Output $MSG_ENGINE; exit 0 }
if (-not $out -or -not $out.Trim()) { Write-Output $MSG_ENGINE; exit 0 }

$inv = $null
try { $inv = $out | ConvertFrom-Json } catch { $inv = $null }
if (-not $inv -or -not $inv.text) { Write-Output $MSG_ENGINE; exit 0 }

$bits = @()
if ($ev -and $ev.compact_trigger) { $bits += "trigger=$($ev.compact_trigger)" }
if ($ev -and ($null -ne $ev.compaction_ratio)) { $bits += "compaction_ratio=$($ev.compaction_ratio)" }
if ($ev -and ($null -ne $ev.messages_before) -and ($null -ne $ev.messages_after)) {
  $bits += "messages $($ev.messages_before) -> $($ev.messages_after)"
}
$what = ''
if ($bits.Count -gt 0) { $what = ' (' + ($bits -join ', ') + ')' }
$head = "A context compaction just happened$what. Compaction does not dilute constraints, " +
  "it deletes them, and a summary carries drift over rather than correcting it. What follows " +
  "was re-derived from files just now, not recalled from the summary -- calibrate against it, " +
  "not against the impression the compaction left.`n`n"
$ratio = ''
if ($ev -and ($null -ne $ev.compaction_ratio)) { $ratio = " (compaction_ratio=$($ev.compaction_ratio))" }

Write-Output ([pscustomobject]@{
  systemMessage = "PostCompact: invariants re-derived from files and re-injected$ratio."
  additionalContext = $head + $inv.text
} | ConvertTo-Json -Compress)
exit 0
