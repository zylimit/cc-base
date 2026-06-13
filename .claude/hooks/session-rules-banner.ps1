#!/usr/bin/env pwsh
# Hook: SessionStart (PowerShell equivalent of session-rules-banner.sh)
# Print the CC framework core-rules banner (silent when source=compact/resume).
$ErrorActionPreference = 'Stop'

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
