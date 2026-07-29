#!/usr/bin/env pwsh
# Hook: SessionStart (PowerShell equivalent of session-rules-banner.sh)
# Print the CC framework core-rules banner (silent when source=compact/resume).
$ErrorActionPreference = 'Stop'

# Fast-mode master switch, announce edition: the other hooks go silent, this banner must
# instead warn loudly so a forgotten switch cannot hide. Expired flag (expires_epoch in the
# past, or a missing/invalid line) -> note the auto-expiry and fall through to the normal
# banner (strict mode is back on).
if ($env:CLAUDE_PROJECT_DIR) {
  $fastFlag = Join-Path $env:CLAUDE_PROJECT_DIR '.claude/.fast-mode'
  if (Test-Path $fastFlag) {
    # Shared lib does the check; a missing lib counts as not-active (no warning, normal banner).
    $fastOn = $false
    try { . (Join-Path $PSScriptRoot 'lib-fast-mode.ps1'); $fastOn = Test-FastModeActive } catch {}
    if ($fastOn) {
      Write-Output '!! FAST-MODE ON: all hook gates are muted (.claude/.fast-mode). Run pwsh .claude/scripts/fast-mode.ps1 off to restore strict mode. !!'
      exit 0
    }
    Write-Output 'fast-mode expired (TTL passed or flag file invalid) and strict mode is back on; re-run pwsh .claude/scripts/fast-mode.ps1 on if you still need it, or off to clean up the flag.'
  }
}

[Console]::InputEncoding = [System.Text.UTF8Encoding]::new()
$raw = [Console]::In.ReadToEnd()
try { $source = ($raw | ConvertFrom-Json).source } catch { $source = '' }
if ($source -eq 'compact' -or $source -eq 'resume') { exit 0 }

$banner = @'
========================================================
 CC Framework Core Rules
========================================================
 1. Main agent never codes/reviews/tests/deploys directly
    - always delegate to a Sub-Agent
      (implementer / code-reviewer / tester / deployer)
 2. Cross review: implementer writes -> code-reviewer reviews
    (use a fresh instance, never same-session self-review)
 3. Accept on objective evidence: run commands to verify,
    do not trust the Sub-Agent's self-report alone
 4. Preserve existing assets: removing/disabling/rewriting
    any existing hook/skill needs user approval
 5. Verify before concluding: a conclusion needs evidence
    (WebSearch / command output / official docs)
 6. Three-file sync: write decisions/constraints/done to
    progress.md now; spec changes -> Product-Spec + CHANGELOG
========================================================
'@
Write-Output $banner
exit 0
