#!/usr/bin/env pwsh
# Hook: PostToolUse(Bash) if git commit* (PowerShell equivalent of auto-push.sh)
# After a commit, auto-push when local is ahead of upstream.
# Self-gates the trigger command: non "git commit" input exits immediately (replaces the if field).
$ErrorActionPreference = 'Stop'

$raw = [Console]::In.ReadToEnd()
try { $cmd = ($raw | ConvertFrom-Json).tool_input.command } catch { exit 0 }
if (-not $cmd) { exit 0 }
if ($cmd -notmatch 'git\s+commit') { exit 0 }

# Null guard: missing CLAUDE_PROJECT_DIR exits (avoid pushing an unrelated repo under cwd)
if (-not $env:CLAUDE_PROJECT_DIR) { exit 0 }
try { Set-Location $env:CLAUDE_PROJECT_DIR } catch { exit 0 }

# No upstream branch (no remote / no tracking set) -> skip
git rev-parse --abbrev-ref '@{u}' *> $null
if ($LASTEXITCODE -ne 0) { exit 0 }

# Push only when the local-ahead-of-upstream commit count > 0
$ahead = git rev-list '@{u}..HEAD' --count 2>$null
if (-not $ahead) { $ahead = '0' }
if ([int]$ahead -gt 0) {
  git push *> $null
}
exit 0
