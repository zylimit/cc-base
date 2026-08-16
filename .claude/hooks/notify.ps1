#!/usr/bin/env pwsh
# Hook: Notification(agent_needs_input|agent_completed|permission_prompt)
# (PowerShell equivalent of notify.sh)
# Desktop notification -- with background subagents as the default (v2.1.198+ spawns
# return async_launched), completion/needs-input no longer has a synchronous return
# point and the user can end up staring at a silent terminal. This hook turns those
# notifications into terminal escape sequences (OSC 777 desktop notification + BEL),
# emitted via the hook JSON terminalSequence field so Claude Code writes them on our
# behalf (hooks have no /dev/tty; terminalSequence is the official channel).
# The Notification event ignores exit codes and stderr; terminalSequence still fires.
# Blocks nothing -- pure visibility.
$ErrorActionPreference = 'Stop'
trap {
  Write-Output '{"terminalSequence":"\u001b]777;notify;Claude Code;attention\u0007\u0007"}'
  exit 0
}

[Console]::InputEncoding = [System.Text.UTF8Encoding]::new()
$raw = [Console]::In.ReadToEnd()
$msg = 'Claude Code needs your attention'
try {
  $m = ($raw | ConvertFrom-Json).message
  if ($m) { $msg = ($m -replace "`n", ' ') }
} catch { }
if ($msg.Length -gt 120) { $msg = $msg.Substring(0, 120) }

$esc = [char]27
$bel = [char]7
$seq = "$esc]777;notify;Claude Code;$msg$bel$bel"
Write-Output ([pscustomobject]@{ terminalSequence = $seq } | ConvertTo-Json -Compress)
exit 0
