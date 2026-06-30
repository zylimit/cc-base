#!/usr/bin/env pwsh
# Hook: PreToolUse(Bash) (PowerShell equivalent of dangerous-pkill-guard.sh)
# Block broad "pkill -f" matches to prevent killing the main agent process.
$ErrorActionPreference = 'Stop'

$raw = [Console]::In.ReadToEnd()
try { $cmd = ($raw | ConvertFrom-Json).tool_input.command } catch { exit 0 }
if (-not $cmd) { exit 0 }

# Anchor to command start/separators: only block a real pkill -f, let echo/grep "pkill -f" strings pass
if ($cmd -match '(^|;|&&|\|\||`|\$\()\s*pkill\s+-f') {
  [Console]::Error.WriteLine("[BLOCKED] [dangerous-pkill-guard] detected a broad 'pkill -f' match; blocked.")
  [Console]::Error.WriteLine("A broad 'pkill -f' can kill the main agent's own process (the shell wrapper contains the same keyword).")
  [Console]::Error.WriteLine("Correct approach: first get the exact PID via ps/pgrep, then 'kill <PID>'.")
  try { . (Join-Path $PSScriptRoot 'lib-gate-log.ps1'); Write-GateLog 'dangerous-pkill-guard' 'blocked a broad pkill -f match' } catch { }
  exit 2
}
exit 0
