#!/usr/bin/env pwsh
# Hook: SubagentStop (matcher: implementer|code-reviewer|tester|deployer)
# When an execution subagent returns, remind the main Agent to verify by
# objective evidence, not the subagent's self-report.
# Dedup: the same completion can re-fire this hook (e.g. a stop gate blocks the subagent's
# stop and it stops again); repeated reminders drown the subagent's final report, so each
# completion is reminded once -- keyed by agent_id when the payload carries one, else a
# hash of the stable fields. Seen keys live in .claude/.subagent-reminded (last 50 kept;
# corrupt/missing state just means remind again, the reminder stays fail-open).
$ErrorActionPreference = 'Stop'

# Fast-mode master switch via shared lib: unexpired expires_epoch -> pass through silently (lib missing => fail-closed, never passes)
try { . (Join-Path $PSScriptRoot 'lib-fast-mode.ps1'); if (Test-FastModeActive) { exit 0 } } catch {}

$raw = [Console]::In.ReadToEnd()
$agent = ''
$obj = $null
try { $obj = ConvertFrom-Json $raw } catch { }
if ($obj -and $obj.agent_type) { $agent = $obj.agent_type }
if (-not $agent) { $agent = 'subagent' }

try {
  if ($env:CLAUDE_PROJECT_DIR) {
    $key = ''
    if ($obj -and $obj.agent_id) { $key = "$($obj.agent_id)" }
    if (-not $key) {
      $stable = "$($obj.session_id)|$agent|$($obj.transcript_path)"
      $sha = [System.Security.Cryptography.SHA256]::Create()
      $key = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($stable)) | ForEach-Object { $_.ToString('x2') })
    }
    $seenFile = Join-Path $env:CLAUDE_PROJECT_DIR '.claude/.subagent-reminded'
    $seen = @()
    if (Test-Path $seenFile) { $seen = @(Get-Content $seenFile -ErrorAction SilentlyContinue) }
    if ($seen -contains $key) { exit 0 }
    $seen += $key
    if ($seen.Count -gt 50) { $seen = $seen[($seen.Count - 50)..($seen.Count - 1)] }
    Set-Content -Path $seenFile -Value $seen
  }
} catch { }

$msg = "$agent returned. Per the acceptance rule: do not trust its self-report (done/passed/empty). Verify objective evidence -- code/fix: recheck compile output + Spec line-by-line; test: recheck the real test-runner output; deploy: independently verify the three-piece check."
$out = @{ hookSpecificOutput = @{ hookEventName = 'SubagentStop'; additionalContext = $msg } } | ConvertTo-Json -Compress
Write-Output $out
exit 0
