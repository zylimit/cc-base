#!/usr/bin/env pwsh
# test-ps1-behavior.ps1 -- behaviour regression for what is left of PowerShell in this repository.
#
# Scope after the single-runtime migration (docs/v3-work-packs.md D.1)
#   The hooks are no longer .sh/.ps1 pairs; settings.json runs `node <hook>.mjs` on both
#   platforms and every hook .ps1 is gone. Groups A-E of this file drove stop-gate.ps1,
#   pre-commit-check.ps1, tdd-gate.ps1 and mark-review-needed.ps1 -- those files do not exist
#   any more and their assertions now live in .claude/tests/test-hooks-node.sh, which the
#   Windows runner executes through Git Bash. What is left here is the part node testing
#   cannot cover:
#     group 0  the pinned ASCII-only rule, for the named list of .ps1 files that survive,
#              plus a check that the list is still the whole truth
#     group F  fast-mode.ps1 driven by a real PowerShell host (the unix-epoch arithmetic and
#              the flag file are the parts that used to differ between hosts)
#
# What it proves and what it does not
#   CI runs this under pwsh 7 (the Windows runner ships it). Real users run these scripts under
#   powershell.exe 5.1, which differs in ways a 7 host cannot cover -- Console encoding defaults
#   and native stderr handling above all. Green on pwsh 7 means "the logic is right", not
#   "5.1 is safe". Re-run this file with powershell.exe on a real 5.1 box to close the other half.
#
# ASCII only (pinned iron law)
#   PS 5.1 reads a BOM-less UTF-8 file as GBK, so one non-ASCII byte breaks parsing on exactly
#   the machines this file protects. Group 0 is the only machine check that rule has.
#
# Run it
#   pwsh       -NoProfile -File .claude/tests/test-ps1-behavior.ps1
#   powershell -NoProfile -File .claude\tests\test-ps1-behavior.ps1   (5.1, the real target)
#
# Exit codes: 0 = all assertions passed; 1 = an assertion failed; 3 = a group could not run,
# which is not a pass -- CI treats 3 as a failure of the runner.
#
# Discipline: every mutable fixture lives in a temp sandbox that is removed on exit; this
# repository is only ever read. Every assertion prints EXPECT and GOT so a third party can
# re-judge it without trusting the wording.

$ErrorActionPreference = 'Continue'

# Nested two-argument Join-Path on purpose: the three-argument form needs -AdditionalChildPath,
# which only exists from PowerShell 6 on. On 5.1 -- the host this file most needs to run on --
# it fails to bind and the script dies on line one.
$RepoRoot = (Resolve-Path (Join-Path (Join-Path $PSScriptRoot '..') '..')).Path
$Scripts = Join-Path $RepoRoot '.claude/scripts'
$Tests = Join-Path $RepoRoot '.claude/tests'

$TmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ccbase-ps1-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
New-Item -ItemType Directory -Path $TmpRoot -Force | Out-Null

$script:Pass = 0
$script:Fail = 0
$script:Skip = 0

function Chk {
    param([bool]$Ok, [string]$Title, [string]$Expect, [string]$Got)
    if ($Ok) { $script:Pass++; Write-Output "  [PASS] $Title" }
    else { $script:Fail++; Write-Output "  [FAIL] $Title" }
    Write-Output "         EXPECT $Expect"
    Write-Output "         GOT    $Got"
}

function Skipped {
    param([string]$Title)
    $script:Skip++
    Write-Output "  [SKIP] $Title"
}

# The host that is running this file, so the scripts are exercised by the same PowerShell the
# operator is on (5.1 vs 7 is the whole question here, so it must not be hard-coded).
$HostExe = $null
try { $HostExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { $HostExe = $null }
if (-not $HostExe) { $HostExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source }
if (-not $HostExe) { $HostExe = (Get-Command powershell -ErrorAction SilentlyContinue).Source }

# Invoke-Script -- run a .ps1 in its own process with stdin/stdout/stderr on files.
# A child process is mandatory: the scripts read [Console]::In, which is the process stdin and is
# not fed by the PowerShell pipeline, so calling them in-process would read the terminal.
function Invoke-Script {
    param(
        [string]$Script,
        [string]$StdinText = '',
        [string]$ProjectDir = '',
        [string]$WorkingDir = '',
        [string[]]$ScriptArgs = @()
    )
    $tag = [guid]::NewGuid().ToString('N').Substring(0, 10)
    $inFile = Join-Path $TmpRoot "in-$tag.txt"
    $outFile = Join-Path $TmpRoot "out-$tag.txt"
    $errFile = Join-Path $TmpRoot "err-$tag.txt"
    # UTF-8 without BOM: a BOM would land inside the first token and break ConvertFrom-Json on 5.1.
    [System.IO.File]::WriteAllText($inFile, $StdinText, (New-Object System.Text.UTF8Encoding($false)))

    $had = Test-Path Env:CLAUDE_PROJECT_DIR
    $prev = $null
    if ($had) { $prev = $env:CLAUDE_PROJECT_DIR }
    if ($ProjectDir) { $env:CLAUDE_PROJECT_DIR = $ProjectDir }
    else { Remove-Item Env:CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue }
    # One verbatim command-line string, not an array: PS 5.1 joins an -ArgumentList array with
    # spaces and adds no quoting, so a checkout under "C:\Program Files\..." would silently run
    # the wrong thing. A single pre-quoted string behaves the same on 5.1 and 7.
    $argLine = '-NoProfile -NonInteractive -File "' + $Script + '"'
    foreach ($a in $ScriptArgs) { $argLine += ' "' + $a + '"' }
    try {
        $spArgs = @{
            FilePath               = $HostExe
            ArgumentList           = $argLine
            RedirectStandardInput  = $inFile
            RedirectStandardOutput = $outFile
            RedirectStandardError  = $errFile
            NoNewWindow            = $true
            Wait                   = $true
            PassThru               = $true
        }
        if ($WorkingDir) { $spArgs['WorkingDirectory'] = $WorkingDir }
        $proc = Start-Process @spArgs
        $code = $proc.ExitCode
    } finally {
        if ($had) { $env:CLAUDE_PROJECT_DIR = $prev }
        else { Remove-Item Env:CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue }
    }
    if ($null -eq $code) { $code = -1 }
    # Get-Content -Raw gives $null for an empty file; normalise to '' so every caller can use
    # -like and .Trim() without a null guard.
    $out = (Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue)
    $err = (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)
    if ($null -eq $out) { $out = '' }
    if ($null -eq $err) { $err = '' }
    return [pscustomobject]@{ Code = $code; Out = $out; Err = $err }
}

function Show { param([string]$Text, [int]$Max = 220)
    if (-not $Text) { return '<empty>' }
    $one = ($Text -replace '\r?\n', ' ').Trim()
    if ($one.Length -gt $Max) { return $one.Substring(0, $Max) + '...' }
    return $one
}

Write-Output '===== test-ps1-behavior ====='
Write-Output "host: $HostExe  (PSVersion $($PSVersionTable.PSVersion))"
Write-Output "sandbox root: $TmpRoot"

try {

    # -----------------------------------------------------------------------
    Write-Output ''
    Write-Output '--- 0 the ASCII-only rule, over the named list of .ps1 files that survive ---'

    Chk ([bool]$HostExe) 'a PowerShell host path was resolved (the scripts run under it)' `
        'non-empty host path' "host=$HostExe"

    # The list is named, not globbed: after the migration the repository is supposed to hold
    # exactly these six .ps1 files, so a glob that quietly finds zero (or finds a hook .ps1 that
    # should have been deleted) has to be a failure, not a smaller/larger silent pass.
    $expected = @(
        (Join-Path $RepoRoot 'setup.ps1'),
        (Join-Path $Scripts 'fix-platform.ps1'),
        (Join-Path $Scripts 'fast-mode.ps1'),
        (Join-Path $Scripts 'install-githooks.ps1'),
        (Join-Path $Tests 'test-ps1-behavior.ps1'),
        (Join-Path $Tests 'test-installer-parity.ps1')
    )

    $missing = @($expected | Where-Object { -not (Test-Path -LiteralPath $_) })
    Chk ($missing.Count -eq 0) `
        '0a every .ps1 the migration is supposed to keep is on disk' `
        'all six named files exist' `
        $(if ($missing.Count -eq 0) { 'all present' } else { ($missing -join '; ') })

    # Set equality against a real recursive scan. This is the anti-drift half: a hook .ps1 that
    # D-3b forgot to delete, or a new .ps1 nobody added to the list, both show up here -- and an
    # unlisted .ps1 is one nobody is holding to the ASCII rule.
    # -Force is load-bearing: .claude is a dot-directory, which Get-ChildItem treats as hidden on
    # Unix and skips without it -- the scan would then see setup.ps1 alone and "no strays" would
    # be vacuously true. The count guard below makes that failure mode loud instead of green.
    $found = @(Get-ChildItem -LiteralPath $RepoRoot -Recurse -Filter '*.ps1' -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/](node_modules|\.git|worktrees)[\\/]' } |
        ForEach-Object { $_.FullName })
    $expectedNorm = @($expected | ForEach-Object { (Resolve-Path -LiteralPath $_ -ErrorAction SilentlyContinue).Path } | Where-Object { $_ })
    Chk ($found.Count -ge $expectedNorm.Count) `
        '0b the recursive scan really walks the tree (fewer hits than the list means it is blind, and the drift check below would be vacuous)' `
        "at least $($expectedNorm.Count) .ps1 found by the scan" `
        ("scanned=" + $found.Count + " listed=" + $expectedNorm.Count)
    $extra = @($found | Where-Object { $expectedNorm -notcontains $_ })
    Chk ($extra.Count -eq 0) `
        '0c the repository holds no .ps1 outside that list (a stray one is one nobody checks)' `
        'zero unlisted .ps1 files' `
        ("unlisted=" + $extra.Count + " [" + (($extra | ForEach-Object { $_.Replace($RepoRoot, '') }) -join ', ') + "]")

    $scan = @($expected | Where-Object { Test-Path -LiteralPath $_ })
    Chk ($scan.Count -gt 0) '0d there are files to scan (zero would mean this group checks nothing)' `
        'at least one .ps1' "count=$($scan.Count)"

    $nonAscii = @()
    foreach ($f in $scan) {
        $bytes = [System.IO.File]::ReadAllBytes($f)
        $bad = 0
        foreach ($b in $bytes) { if ($b -gt 127) { $bad++ } }
        if ($bad -gt 0) { $nonAscii += ($f + " ($bad byte(s))") }
    }
    Chk ($nonAscii.Count -eq 0) `
        '0e every surviving .ps1 is pure ASCII (PS 5.1 reads a BOM-less UTF-8 file as GBK and fails to parse)' `
        'zero files with a byte > 127' `
        $(if ($nonAscii.Count -eq 0) { "clean, $($scan.Count) file(s) scanned" } else { ($nonAscii -join '; ') })

    # -----------------------------------------------------------------------
    Write-Output ''
    Write-Output '--- F fast-mode.ps1: the switch on a real PowerShell host, end to end ---'

    # fast-mode.ps1 resolves the project from $PSScriptRoot/../.., so it is copied into the
    # sandbox; running the repository copy would flip the real repository into fast mode.
    $fmSrc = Join-Path $Scripts 'fast-mode.ps1'
    if (-not (Test-Path -LiteralPath $fmSrc)) {
        Skipped 'F fast-mode.ps1 is missing, the group cannot run (not executed is not a pass)'
    } else {
        $sbF = Join-Path $TmpRoot 'f-fastmode'
        New-Item -ItemType Directory -Path (Join-Path $sbF '.claude/scripts') -Force | Out-Null
        Copy-Item -LiteralPath $fmSrc -Destination (Join-Path $sbF '.claude/scripts/fast-mode.ps1')
        $fmScript = Join-Path $sbF '.claude/scripts/fast-mode.ps1'
        $flag = Join-Path $sbF '.claude/.fast-mode'

        $rOn = Invoke-Script -Script $fmScript -ScriptArgs @('on', '3') -WorkingDir $sbF
        $rStatus = Invoke-Script -Script $fmScript -ScriptArgs @('status') -WorkingDir $sbF
        $mins = -1
        if ($rStatus.Out -match 'about\s+(\d+)\s+minutes remaining') { $mins = [int]$Matches[1] }
        Chk (($rOn.Code -eq 0) -and ($mins -ge 175) -and ($mins -le 180)) `
            'F1 fast-mode.ps1 on 3 then status reports the remaining minutes (the unix-epoch arithmetic is right on a real host)' `
            'status reports 175..180 minutes remaining' "on rc=$($rOn.Code) minutes=$mins status=$(Show $rStatus.Out)"

        # The flag file is what every gate reads, so assert the file and not only the message.
        # LF only: the engine and the hooks both strip \r, but a CRLF flag written here would
        # hide a regression in the writer that bit this repository once already (#38).
        $flagText = ''
        if (Test-Path -LiteralPath $flag) { $flagText = [System.IO.File]::ReadAllText($flag) }
        Chk (($flagText -match '(?m)^expires_epoch=\d+$') -and (-not ($flagText -match "`r"))) `
            'F2 on writes a LF-only flag file carrying expires_epoch (the line every gate parses)' `
            'flag has an expires_epoch=<digits> line and no CR' `
            ("flag=[" + (Show $flagText) + "] hasCR=" + [bool]($flagText -match "`r"))

        $rOff = Invoke-Script -Script $fmScript -ScriptArgs @('off') -WorkingDir $sbF
        $rStatus2 = Invoke-Script -Script $fmScript -ScriptArgs @('status') -WorkingDir $sbF
        Chk (($rOff.Code -eq 0) -and ($rStatus2.Out -like '*fast-mode: off*') -and (-not (Test-Path -LiteralPath $flag))) `
            'F3 fast-mode.ps1 off removes the flag and status agrees (strict mode really comes back)' `
            'status says off and .fast-mode is gone' `
            "off rc=$($rOff.Code) status=$(Show $rStatus2.Out) flag=$(Test-Path -LiteralPath $flag)"

        $rBad = Invoke-Script -Script $fmScript -ScriptArgs @('on', 'abc') -WorkingDir $sbF
        Chk (($rBad.Code -eq 2) -and (-not (Test-Path -LiteralPath $flag))) `
            'F4 a bad hours argument exits 2 and writes no flag (a rejected switch must not half-open the gate)' `
            'rc 2 and no .fast-mode on disk' `
            "rc=$($rBad.Code) flag=$(Test-Path -LiteralPath $flag) out=$(Show $rBad.Out)$(Show $rBad.Err)"
    }

} catch {
    # A crash halfway through must not read as "nothing failed": without this the remaining
    # assertions would simply never run and the summary would never print.
    $script:Fail++
    Write-Output "  [FAIL] the suite crashed before finishing: $($_.Exception.Message)"
    Write-Output '         EXPECT every group to run to the end'
    Write-Output "         GOT    $($_.ScriptStackTrace -replace '\r?\n', ' | ')"
} finally {
    Remove-Item -LiteralPath $TmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
Write-Output "==== test-ps1-behavior: PASS=$script:Pass FAIL=$script:Fail SKIP=$script:Skip ===="
if ($script:Fail -gt 0) {
    Write-Output 'test-ps1-behavior: FAILED -- a surviving .ps1 did not behave as its contract says.'
    exit 1
}
if ($script:Skip -gt 0) {
    Write-Output 'test-ps1-behavior: INCOMPLETE -- a group could not run (see [SKIP] above). Not executed is not a pass.'
    exit 3
}
Write-Output 'test-ps1-behavior: passed'
exit 0
