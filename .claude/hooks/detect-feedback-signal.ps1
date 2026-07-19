#!/usr/bin/env pwsh
# Hook: UserPromptSubmit (PowerShell equivalent of detect-feedback-signal.sh)
# Detect correction/feedback signals in the user prompt; if found, inject additionalContext
# reminding to dispatch feedback-observer.
$ErrorActionPreference = 'Stop'

# Fast-mode master switch: flag file carries an unexpired expires_epoch -> pass through silently (missing/invalid line never passes)
try { if ($env:CLAUDE_PROJECT_DIR) { $fmLine = Select-String -LiteralPath (Join-Path $env:CLAUDE_PROJECT_DIR '.claude/.fast-mode') -Pattern '^expires_epoch=(\d+)$' -ErrorAction Stop | Select-Object -First 1; if ($fmLine -and [int64]$fmLine.Matches[0].Groups[1].Value -gt [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) { exit 0 } } } catch {}

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
