# lib-harness.ps1 - shared monorepo governance harness gate check (hooks dot-source this
# then call Test-HarnessEnabled / Get-HarnessNode / Invoke-Harness).
# Default-off: the only switch is the catalog file $env:CLAUDE_PROJECT_DIR/.claude/harness/module-catalog.json.
# Present -> enabled (Test-HarnessEnabled returns $true); absent -> caller skips the harness branch,
# runs the original logic, zero behaviour change. node is located via Get-Command; when node is
# missing Invoke-Harness returns $null (a decidable degrade signal, not a crash, not a fake pass),
# so the caller can visibly skip the harness check and never block a small project.
# No jq dependency - Bash and PowerShell read the same catalog switch.

function Get-HarnessCatalogPath {
    if (-not $env:CLAUDE_PROJECT_DIR) { return $null }
    Join-Path $env:CLAUDE_PROJECT_DIR '.claude/harness/module-catalog.json'
}

function Test-HarnessEnabled {
    $catalog = Get-HarnessCatalogPath
    if (-not $catalog) { return $false }
    return (Test-Path -LiteralPath $catalog -PathType Leaf)
}

function Get-HarnessNode {
    (Get-Command node -ErrorAction SilentlyContinue).Source
}

function Invoke-Harness {
    param([string[]]$HarnessArgs)
    $node = Get-HarnessNode
    if (-not $node) { return $null }
    $script = Join-Path $env:CLAUDE_PROJECT_DIR '.claude/harness/harness.mjs'
    # PS 5.1 + EAP=Stop turns a native program's stderr into a terminating error, which would
    # swallow the JSON on stdout and skip the $LASTEXITCODE gate. Relax to Continue for this
    # native call and redirect stderr to a temp file (same approach as pre-commit-check.ps1).
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $err = [System.IO.Path]::GetTempFileName()
    try {
        $out = & $node $script @HarnessArgs 2> $err
        $code = $LASTEXITCODE
    } finally {
        Remove-Item $err -Force -ErrorAction SilentlyContinue
        $ErrorActionPreference = $prev
    }
    [pscustomobject]@{ Out = ($out | Out-String); Code = $code }
}
