#!/usr/bin/env pwsh
# Hook: SubagentStop (matcher: implementer|code-reviewer|tester|deployer)
# When an execution subagent returns, remind the main Agent to verify by
# objective evidence, not the subagent's self-report.
$ErrorActionPreference = 'Stop'

$raw = [Console]::In.ReadToEnd()
$agent = ''
try { $agent = (ConvertFrom-Json $raw).agent_type } catch { }
if (-not $agent) { $agent = 'subagent' }

$msg = "$agent returned. Per the acceptance rule: do not trust its self-report (done/passed/empty). Verify objective evidence -- code/fix: recheck compile output + Spec line-by-line; test: recheck the real test-runner output; deploy: independently verify the three-piece check."
$out = @{ hookSpecificOutput = @{ hookEventName = 'SubagentStop'; additionalContext = $msg } } | ConvertTo-Json -Compress
Write-Output $out
exit 0
