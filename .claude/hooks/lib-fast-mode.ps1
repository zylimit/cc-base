# lib-fast-mode.ps1 - shared fast-mode gate check (hooks dot-source this then call Test-FastModeActive).
# The flag file $env:CLAUDE_PROJECT_DIR/.claude/.fast-mode carries an expires_epoch=<unix seconds>
# line; only a value strictly greater than now counts as active (hook may pass through silently).
# Missing env var / file / line, a non-numeric value, or an expired epoch all return $false
# (fail-closed, strict logic stays on). No jq dependency - Bash and PowerShell read the same file.

function Get-FastModeFlagPath {
    if (-not $env:CLAUDE_PROJECT_DIR) { return $null }
    Join-Path $env:CLAUDE_PROJECT_DIR '.claude/.fast-mode'
}

function Test-FastModeActive {
    try {
        $flag = Get-FastModeFlagPath
        if (-not $flag) { return $false }
        if (-not (Test-Path -LiteralPath $flag -PathType Leaf)) { return $false }
        $fmLine = Select-String -LiteralPath $flag -Pattern '^expires_epoch=(\d+)$' -ErrorAction Stop | Select-Object -First 1
        if ($fmLine -and [int64]$fmLine.Matches[0].Groups[1].Value -gt [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) { return $true }
    } catch {}
    return $false
}
