#!/usr/bin/env pwsh
# Hook: UserPromptSubmit (PowerShell equivalent of detect-feedback-signal.sh)
# Detect correction/feedback signals in the user prompt; if found, inject additionalContext
# reminding to dispatch feedback-observer.
$ErrorActionPreference = 'Stop'

$raw = [Console]::In.ReadToEnd()
try { $prompt = ($raw | ConvertFrom-Json).prompt } catch { exit 0 }
if (-not $prompt) { exit 0 }

# Correction signals live in a sidecar file (keeps this script pure ASCII while still matching
# the Chinese user input). Anchor to $PSScriptRoot (this hook's own dir) so it does not depend
# on $env:CLAUDE_PROJECT_DIR (fail-open preserved). Read with explicit UTF8 so PS 5.1 does not
# misread it as GBK.
$signalsFile = Join-Path $PSScriptRoot 'feedback-signals.txt'
if (-not (Test-Path $signalsFile)) { exit 0 }
$signals = (Get-Content -LiteralPath $signalsFile -Encoding UTF8 -Raw).Trim()
if (-not $signals) { exit 0 }

if ($prompt -match $signals) {
  Write-Output '{"additionalContext": "Detected a user correction signal. After handling the user request, dispatch the feedback-observer sub-agent to record this feedback using the feedback-writer skill. Write the feedback into the .claude/feedback/ directory, not the memory directory."}'
}
exit 0
