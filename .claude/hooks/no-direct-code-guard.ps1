#!/usr/bin/env pwsh
# Hook: PreToolUse(Edit|Write) (PowerShell equivalent of no-direct-code-guard.sh)
# Detect whether the main agent writes business source directly; if so, warn (exit 2). Framework files pass.
$ErrorActionPreference = 'Stop'

# Fast-mode master switch: flag file present (and younger than the 24h TTL) -> pass through silently
if ($env:CLAUDE_PROJECT_DIR -and (Test-Path (Join-Path $env:CLAUDE_PROJECT_DIR '.claude/.fast-mode')) -and ((Get-Date) - (Get-Item (Join-Path $env:CLAUDE_PROJECT_DIR '.claude/.fast-mode')).LastWriteTime).TotalHours -lt 24) { exit 0 }

$raw = [Console]::In.ReadToEnd()
try { $obj = $raw | ConvertFrom-Json } catch { exit 0 }
$filePath = $obj.tool_input.file_path
if (-not $filePath) { $filePath = $obj.tool_input.path }
if (-not $filePath) { exit 0 }

# Normalize Windows backslashes, then apply the same regex as the .sh version
$fp = $filePath -replace '\\', '/'

# Framework files pass (.claude/ / CLAUDE.md / Product-Spec / DEV-PLAN / progress / CHANGELOG / feedback / agents / skills / hooks / *.md/json/toml/sh/ps1)
if ($fp -match '(\.claude/|CLAUDE\.md|Product-Spec|DEV-PLAN|progress\.md|CHANGELOG|/feedback/|/agents/|/skills/|/hooks/|\.md$|\.json$|\.toml$|\.sh$|\.ps1$)') {
  exit 0
}

# Business source paths (src/ / app/ / lib/ / components/ etc.), block both relative and absolute forms
if ($fp -match '(^|/)(src|app|lib|components|pages|api|server|client|utils|models|services)/') {
  [Console]::Error.WriteLine("[!] [no-direct-code-guard] the main agent should not write business source directly: $filePath")
  [Console]::Error.WriteLine("Dispatch the implementer Sub-Agent to write it, keeping the responsibility boundary.")
  try { . (Join-Path $PSScriptRoot 'lib-gate-log.ps1'); Write-GateLog 'no-direct-code-guard' "main agent wrote business source directly: $filePath" } catch { }
  exit 2
}
exit 0
