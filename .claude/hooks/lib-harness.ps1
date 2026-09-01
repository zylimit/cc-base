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
    $errText = ''
    try {
        $out = & $node $script @HarnessArgs 2> $err
        $code = $LASTEXITCODE
        # Keep stderr: when the engine itself crashes those lines are the only useful clue,
        # and the caller puts them into the gate diagnostic.
        $errText = (Get-Content $err -Raw -ErrorAction SilentlyContinue)
    } finally {
        Remove-Item $err -Force -ErrorAction SilentlyContinue
        $ErrorActionPreference = $prev
    }
    [pscustomobject]@{ Out = ($out | Out-String); Code = $code; Err = $errText }
}

# Is the exit code inside the contract? $true = in contract, $false = out of contract.
# Out of contract = the engine itself crashed (missing lib/, broken node, internal error), not a
# verdict from the gate -- callers keep "the engine cannot run" and "stale receipt / gate really
# failed" apart, because the two need completely different actions.
# Contract table: .claude/rules/harness-large-repo.md, exit-code contract section.
function Test-HarnessRcInContract {
    param([int]$Code, [int[]]$Contract)
    return ($Contract -contains $Code)
}

# First few stderr lines from the engine (blank lines dropped, first 3 joined into one line,
# truncated to 400 chars) for the gate diagnostic; empty string when there is nothing.
function Get-HarnessErrHead {
    param([string]$Text, [int]$Lines = 3)
    if (-not $Text) { return '' }
    $head = @($Text -split "`r?`n" | Where-Object { $_.Trim() -ne '' } | Select-Object -First $Lines)
    $joined = ($head -join ' ')
    if ($joined.Length -gt 400) { $joined = $joined.Substring(0, 400) }
    return $joined
}
