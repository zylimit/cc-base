#!/usr/bin/env pwsh
# fast-mode.ps1 -- fast-mode master switch manager (PowerShell equivalent of fast-mode.sh).
# Flag file .claude/.fast-mode stores expires_epoch (unix seconds); while unexpired, every hook
# under .claude/hooks/ passes through silently. Expired flag auto-reverts to strict mode.
# Usage: pwsh .claude/scripts/fast-mode.ps1 on [hours] | off | status   (no args = status; hours defaults to 24)
param(
    [string]$Action = 'status',
    [string]$Hours = '24'
)

$ErrorActionPreference = 'Stop'
$projectDir = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$flag = Join-Path $projectDir '.claude/.fast-mode'

function Get-FastModeExpiryEpoch {
    if (-not (Test-Path -LiteralPath $flag -PathType Leaf)) { return $null }
    try {
        $line = Get-Content -LiteralPath $flag -ErrorAction SilentlyContinue |
            Where-Object { $_ -match '^expires_epoch=(\d+)$' } |
            Select-Object -First 1
        if (-not $line) { return $null }
        return [int64]($line -replace '^expires_epoch=', '')
    } catch { return $null }
}

switch ($Action) {
    'on' {
        if ($Hours -notmatch '^\d+$' -or [int64]$Hours -lt 1) {
            Write-Error 'hours must be a positive integer (e.g. fast-mode.ps1 on 3)' -ErrorAction Continue
            exit 2
        }
        $h = [int64]$Hours
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $expires = $now + ($h * 3600)
        @(
            "enabled_epoch=$now"
            "expires_epoch=$expires"
            "hours=$h"
        ) | Set-Content -LiteralPath $flag -Encoding ascii
        Write-Output "fast-mode: on ($flag created/renewed, auto-expires in ${h}h; run off to restore strict mode when done)"
    }
    'off' {
        Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
        Write-Output 'fast-mode: off (flag file removed, hooks back to strict enforcement)'
    }
    'status' {
        $expiry = Get-FastModeExpiryEpoch
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if ($null -ne $expiry -and $expiry -gt $now) {
            $left = [math]::Ceiling(($expiry - $now) / 60)
            Write-Output "fast-mode: on (about $left minutes remaining: $flag)"
        }
        elseif (Test-Path -LiteralPath $flag) {
            Write-Output "fast-mode: expired (flag file still present: $flag; re-run on if still needed, or off to clean up)"
        }
        else {
            Write-Output 'fast-mode: off'
        }
    }
    default {
        Write-Error 'usage: pwsh .claude/scripts/fast-mode.ps1 on [hours]|off|status' -ErrorAction Continue
        exit 2
    }
}
exit 0
