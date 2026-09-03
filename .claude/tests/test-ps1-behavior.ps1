#!/usr/bin/env pwsh
# test-ps1-behavior.ps1 -- behaviour regression for the .ps1 hooks, run by a real PowerShell.
#
# Why this file exists
#   The .ps1 files under .claude/ are the Windows half of every gate, and the only machine check
#   they ever got was a parse: check-syntax.mjs and the ps1 job in .github/workflows/gate.yml
#   both stop at Parser::ParseFile. Syntax says the file loads; it says nothing about whether
#   stop-gate.ps1 actually blocks. The fail-closed fix for out-of-contract engine exit codes has
#   a red lock on the .sh side (tests/test-hook-failopen.sh) and had nothing at all on the .ps1
#   side. This file feeds real input to the real hooks and asserts real stdout, exit codes and
#   side effects.
#
# What it proves and what it does not
#   CI runs this under pwsh 7 (the Windows runner ships it). Real users run the hooks under
#   powershell.exe 5.1, which differs in ways a 7 host cannot cover:
#     - Console.InputEncoding defaults to the ANSI code page (GBK on zh-CN) on 5.1 and to UTF-8
#       on 7, so a green group D here does not prove the 5.1 stdin decode path.
#     - Native stderr becomes a terminating error under $ErrorActionPreference='Stop' on 5.1
#       where 7 is laxer; the hooks work around that, and the workaround is only partly
#       exercised from here.
#   Green on pwsh 7 means "the logic is right", not "5.1 is safe". Re-run this file with
#   powershell.exe on a real 5.1 box to close the other half.
#
# ASCII only (pinned iron law)
#   PS 5.1 reads a BOM-less UTF-8 file as GBK, so one non-ASCII byte breaks parsing on exactly
#   the machines this file protects. Chinese is matched through \uXXXX escapes inside the JSON
#   payloads (ConvertFrom-Json decodes them). Group 0 asserts the rule for every .ps1 in the
#   repository -- the first machine check that rule has ever had.
#
# Overlap with tests/test-hook-parity.sh
#   That file drives tdd-gate.ps1 and mark-review-needed.ps1 from Git Bash and explicitly defers
#   the .needs-review content assertion, because Git Bash /tmp and the .NET GetFullPath used by
#   pwsh resolve to different places. Running natively removes that mismatch, so group E asserts
#   what the other file had to leave open. Group D keeps the trigger assertion only as the
#   precondition that makes the exemption assertion non-vacuous.
#
# Run it
#   pwsh       -NoProfile -File .claude/tests/test-ps1-behavior.ps1
#   powershell -NoProfile -File .claude\tests\test-ps1-behavior.ps1   (5.1, the real target)
#
# Exit codes: 0 = all assertions passed; 1 = an assertion failed; 3 = a group could not run
# (node or git missing), which is not a pass -- CI treats 3 as a failure of the runner.
#
# Discipline: every mutable fixture lives in a mktemp-style sandbox that is removed on exit;
# this repository is only ever read. Every assertion prints EXPECT and GOT so a third party can
# re-judge it without trusting the wording, and every failure names the file and the behaviour.

$ErrorActionPreference = 'Continue'

# Nested two-argument Join-Path on purpose: the three-argument form needs -AdditionalChildPath,
# which only exists from PowerShell 6 on. On 5.1 -- the host this file most needs to run on --
# it fails to bind and the script dies on line one.
$RepoRoot = (Resolve-Path (Join-Path (Join-Path $PSScriptRoot '..') '..')).Path
$Hooks = Join-Path $RepoRoot '.claude/hooks'
$Scripts = Join-Path $RepoRoot '.claude/scripts'

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

# The host that is running this file, so the hooks are exercised by the same PowerShell the
# operator is on (5.1 vs 7 is the whole question here, so it must not be hard-coded).
$HostExe = $null
try { $HostExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { $HostExe = $null }
if (-not $HostExe) { $HostExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source }
if (-not $HostExe) { $HostExe = (Get-Command powershell -ErrorAction SilentlyContinue).Source }

$NodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
$GitExe = (Get-Command git -ErrorAction SilentlyContinue).Source

# Invoke-Script -- run a .ps1 in its own process with stdin/stdout/stderr on files.
# A child process is mandatory: the hooks read [Console]::In, which is the process stdin and is
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
    # UTF-8 without BOM: the hooks set Console.InputEncoding to UTF-8 and parse stdin as JSON; a
    # BOM would land inside the first token and break ConvertFrom-Json on 5.1.
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

# New-Sandbox -- a throwaway project root. Engine: '' none, 'missing' catalog but no harness.mjs
# (the real shape of a half-installed engine), 'exit:N' a one-line engine with a chosen code.
function New-Sandbox {
    param([string]$Name, [switch]$WithCatalog, [string]$Engine = '', [switch]$GitInit)
    $d = Join-Path $TmpRoot $Name
    New-Item -ItemType Directory -Path (Join-Path $d '.claude') -Force | Out-Null
    if ($WithCatalog -or $Engine) {
        New-Item -ItemType Directory -Path (Join-Path $d '.claude/harness') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $d '.claude/harness/module-catalog.json') -Encoding ascii `
            -Value '{"version":1,"modules":[{"id":"core","paths":["core/**"],"riskTier":"medium"}]}'
    }
    if ($Engine -like 'exit:*') {
        Set-Content -LiteralPath (Join-Path $d '.claude/harness/harness.mjs') -Encoding ascii `
            -Value ('process.exit(' + $Engine.Substring(5) + ');')
    }
    if ($GitInit -and $GitExe) {
        Push-Location $d
        try {
            & $GitExe init -q . 2>&1 | Out-Null
            & $GitExe config core.autocrlf false 2>&1 | Out-Null
            & $GitExe config user.email t@example.com 2>&1 | Out-Null
            & $GitExe config user.name t 2>&1 | Out-Null
        } finally { Pop-Location }
    }
    return $d
}

# The exit code the sandbox engine really produces -- asserted before it is used, so a group
# cannot pass vacuously because the fixture stopped producing the condition it tests.
function Get-EngineCode {
    param([string]$Dir, [string[]]$HarnessArgs)
    if (-not $NodeExe) { return -1 }
    $tag = [guid]::NewGuid().ToString('N').Substring(0, 10)
    $o = Join-Path $TmpRoot "eng-$tag.out"
    $e = Join-Path $TmpRoot "eng-$tag.err"
    $line = '"' + (Join-Path $Dir '.claude/harness/harness.mjs') + '"'
    foreach ($a in $HarnessArgs) { $line += ' "' + $a + '"' }
    $p = Start-Process -FilePath $NodeExe -ArgumentList $line `
        -WorkingDirectory $Dir -RedirectStandardOutput $o -RedirectStandardError $e `
        -NoNewWindow -Wait -PassThru
    if ($null -eq $p.ExitCode) { return -1 }
    return $p.ExitCode
}

function Test-Blocked { param([string]$Text) return ($Text -like '*"decision":"block"*') }
function Test-Number { param([string]$Text, [int]$N) return ($Text -match ('(^|[^0-9])' + $N + '([^0-9]|$)')) }
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
    Write-Output '--- 0 fixture self-check + the ASCII-only rule for every .ps1 ---'

    Chk ([bool]$HostExe) 'a PowerShell host path was resolved (the hooks run under it)' `
        'non-empty host path' "host=$HostExe"

    $ps1Files = @(Get-ChildItem -LiteralPath $RepoRoot -Recurse -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/](node_modules|\.git)[\\/]' })
    Chk ($ps1Files.Count -gt 0) 'found .ps1 files to check (zero would mean this group checks nothing)' `
        'at least one .ps1' "count=$($ps1Files.Count)"

    $nonAscii = @()
    foreach ($f in $ps1Files) {
        $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
        $bad = 0
        foreach ($b in $bytes) { if ($b -gt 127) { $bad++ } }
        if ($bad -gt 0) { $nonAscii += ($f.FullName + " ($bad byte(s))") }
    }
    Chk ($nonAscii.Count -eq 0) `
        'every .ps1 is pure ASCII (PS 5.1 reads a BOM-less UTF-8 file as GBK and fails to parse)' `
        'zero files with a byte > 127' `
        $(if ($nonAscii.Count -eq 0) { "clean, $($ps1Files.Count) file(s) scanned" } else { ($nonAscii -join '; ') })

    # -----------------------------------------------------------------------
    Write-Output ''
    Write-Output '--- A stop-gate.ps1: a pending review list blocks the stop, a cleared list releases it ---'

    $sbA = New-Sandbox 'a-pending'
    Set-Content -LiteralPath (Join-Path $sbA '.claude/.needs-review') -Encoding ascii -Value @('src/app.ts', 'src/lib.ts')
    $rA = Invoke-Script -Script (Join-Path $Hooks 'stop-gate.ps1') -ProjectDir $sbA -WorkingDir $sbA

    Chk (Test-Blocked $rA.Out) 'A1 stop-gate.ps1 blocks while 2 files are queued for review' `
        'stdout contains "decision":"block"' "rc=$($rA.Code) stdout=$(Show $rA.Out)"

    Chk ($rA.Out -like '*src/app.ts*') 'A2 stop-gate.ps1 names the pending files (a block with no list is unactionable)' `
        'stdout contains src/app.ts' "stdout=$(Show $rA.Out)"

    $logA = Join-Path $sbA '.claude/evidence/gate-block.log'
    $logTextA = if (Test-Path $logA) { (Get-Content -LiteralPath $logA -Raw) } else { '' }
    Chk ($logTextA -like '*stop-gate*') 'A3 stop-gate.ps1 records the block in .claude/evidence/gate-block.log (gate-audit reads this)' `
        'gate-block.log exists and names stop-gate' "log=$(Show $logTextA)"

    $sbAc = New-Sandbox 'a-clean'
    Set-Content -LiteralPath (Join-Path $sbAc '.claude/.needs-review') -Encoding ascii -Value 'clean'
    $rAc = Invoke-Script -Script (Join-Path $Hooks 'stop-gate.ps1') -ProjectDir $sbAc -WorkingDir $sbAc

    Chk (-not (Test-Blocked $rAc.Out)) 'A4 stop-gate.ps1 releases the stop once the list reads clean' `
        'stdout has no decision:block' "rc=$($rAc.Code) stdout=$(Show $rAc.Out)"

    Chk (-not (Test-Path (Join-Path $sbAc '.claude/.needs-review'))) `
        'A5 stop-gate.ps1 deletes .needs-review after releasing (state is cleaned, not left to rot)' `
        '.needs-review gone' `
        $(if (Test-Path (Join-Path $sbAc '.claude/.needs-review')) { 'still present' } else { 'deleted' })

    # -----------------------------------------------------------------------
    Write-Output ''
    Write-Output '--- B stop-gate.ps1: an unusable engine must not be read as a pass (the .sh side of this is test-hook-failopen.sh) ---'

    if (-not $NodeExe) {
        Skipped 'B group -- no node on PATH, so the harness branch of stop-gate.ps1 never runs here (not executed is not a pass)'
    } else {
        # B0: the engine is genuinely outside the receipt-verify contract {0,3,4}. Without this the
        # rest of the group could pass for the wrong reason.
        $sbB0 = New-Sandbox 'b-missing' -WithCatalog
        $codeMissing = Get-EngineCode -Dir $sbB0 -HarnessArgs @('receipt', 'verify')
        Chk (@(0, 3, 4) -notcontains $codeMissing) `
            'B0 fixture self-check: catalog present but harness.mjs absent gives an out-of-contract code' `
            'exit code outside {0,3,4}' "rc=$codeMissing"

        Set-Content -LiteralPath (Join-Path $sbB0 '.claude/.needs-review') -Encoding ascii -Value 'clean'
        $rB0 = Invoke-Script -Script (Join-Path $Hooks 'stop-gate.ps1') -ProjectDir $sbB0 -WorkingDir $sbB0

        Chk (Test-Blocked $rB0.Out) `
            'B1 stop-gate.ps1 blocks when the engine cannot run at all (silently releasing would be a fake pass)' `
            'stdout contains "decision":"block"' "rc=$($rB0.Code) stdout=$(Show $rB0.Out)"

        Chk (Test-Path (Join-Path $sbB0 '.claude/.needs-review')) `
            'B2 stop-gate.ps1 keeps .needs-review while blocking (deleting it would make the block one-shot)' `
            '.needs-review still present' `
            $(if (Test-Path (Join-Path $sbB0 '.claude/.needs-review')) { 'present' } else { 'deleted' })

        $sb7 = New-Sandbox 'b-exit7' -Engine 'exit:7'
        Set-Content -LiteralPath (Join-Path $sb7 '.claude/.needs-review') -Encoding ascii -Value 'clean'
        $r7 = Invoke-Script -Script (Join-Path $Hooks 'stop-gate.ps1') -ProjectDir $sb7 -WorkingDir $sb7

        Chk ((Test-Blocked $r7.Out) -and (Test-Number $r7.Out 7)) `
            'B3 stop-gate.ps1 blocks on exit 7 and names 7 (an engine crash must be told apart from a stale receipt)' `
            'stdout has decision:block and the number 7' "stdout=$(Show $r7.Out)"

        $sb9 = New-Sandbox 'b-exit9' -Engine 'exit:9'
        Set-Content -LiteralPath (Join-Path $sb9 '.claude/.needs-review') -Encoding ascii -Value 'clean'
        $r9 = Invoke-Script -Script (Join-Path $Hooks 'stop-gate.ps1') -ProjectDir $sb9 -WorkingDir $sb9

        Chk ((Test-Number $r9.Out 9) -and ($r9.Out -ne $r7.Out)) `
            'B4 the diagnostic follows the real exit code (exit 9 reads differently from exit 7, not one canned line)' `
            'exit-9 output contains 9 and differs from the exit-7 output' `
            "contains9=$(Test-Number $r9.Out 9) identical=$($r9.Out -eq $r7.Out)"

        $sb0 = New-Sandbox 'b-exit0' -Engine 'exit:0'
        Set-Content -LiteralPath (Join-Path $sb0 '.claude/.needs-review') -Encoding ascii -Value 'clean'
        $r0 = Invoke-Script -Script (Join-Path $Hooks 'stop-gate.ps1') -ProjectDir $sb0 -WorkingDir $sb0
        $left0 = Test-Path (Join-Path $sb0 '.claude/.needs-review')

        Chk ((-not (Test-Blocked $r0.Out)) -and (-not $left0)) `
            'B5 an in-contract exit 0 still releases and cleans up (B1-B4 must not turn into blocking everything)' `
            'no decision:block and .needs-review deleted' `
            "blocked=$(Test-Blocked $r0.Out) leftover=$left0 stdout=$(Show $r0.Out)"
    }

    # -----------------------------------------------------------------------
    Write-Output ''
    Write-Output '--- C pre-commit-check.ps1: silent pass with no catalog, exit 2 when the gate could not run ---'

    if (-not $GitExe) {
        Skipped 'C group -- no git on PATH, so there is no staged set to judge (not executed is not a pass)'
    } else {
        $sbC = New-Sandbox 'c-plain' -GitInit
        Set-Content -LiteralPath (Join-Path $sbC 'notes.md') -Encoding ascii -Value 'x'
        Push-Location $sbC; try { & $GitExe add -A 2>&1 | Out-Null } finally { Pop-Location }
        $rC = Invoke-Script -Script (Join-Path $Hooks 'pre-commit-check.ps1') `
            -StdinText '{"tool_input":{"command":"git commit -m t"}}' -ProjectDir $sbC -WorkingDir $sbC

        Chk (($rC.Code -eq 0) -and ($rC.Err.Trim() -eq '')) `
            'C1 pre-commit-check.ps1 passes a plain repo silently (a commit is never blocked by a missing tool)' `
            'exit 0 with empty stderr' "rc=$($rC.Code) stderr=$(Show $rC.Err)"

        if (-not $NodeExe) {
            Skipped 'C2/C3 -- no node on PATH, so the harness branch of pre-commit-check.ps1 never runs here (not executed is not a pass)'
        } else {
            $sbC7 = New-Sandbox 'c-exit7' -Engine 'exit:7' -GitInit
            Set-Content -LiteralPath (Join-Path $sbC7 'notes.md') -Encoding ascii -Value 'x'
            Push-Location $sbC7; try { & $GitExe add -A 2>&1 | Out-Null } finally { Pop-Location }
            $codeVerify = Get-EngineCode -Dir $sbC7 -HarnessArgs @('verify')
            Chk ($codeVerify -eq 7) 'C0 fixture self-check: the sandbox engine really exits 7 (verify contract is {0,2,3})' `
                'exit code 7' "rc=$codeVerify"

            $rC7 = Invoke-Script -Script (Join-Path $Hooks 'pre-commit-check.ps1') `
                -StdinText '{"tool_input":{"command":"git commit -m t"}}' -ProjectDir $sbC7 -WorkingDir $sbC7

            Chk ($rC7.Code -eq 2) `
                'C2 pre-commit-check.ps1 blocks the commit when the quality gate could not run (only exit 2 stops a PreToolUse command)' `
                'exit 2' "rc=$($rC7.Code) stderr=$(Show $rC7.Err)"

            Chk (Test-Number $rC7.Err 7) `
                'C3 the block names the real exit code, so an engine failure is not mistaken for a failed gate' `
                'stderr contains the number 7' "stderr=$(Show $rC7.Err)"
        }
    }

    # -----------------------------------------------------------------------
    Write-Output ''
    Write-Output '--- D tdd-gate.ps1: the Chinese trigger word survives JSON \uXXXX, and .tdd-exempt silences it ---'

    # \u7f16\u7801\u5b9e\u73b0 is the Chinese trigger word ("write the implementation") that
    # tdd-gate.ps1 matches. JSON escapes carry it through, which is how this file stays ASCII
    # while still feeding the hook real Chinese -- and it exercises the decode path too.
    $tddJson = '{"tool_input":{"command":"\u7f16\u7801\u5b9e\u73b0 the parser"}}'

    $sbD = New-Sandbox 'd-tdd'
    $rD = Invoke-Script -Script (Join-Path $Hooks 'tdd-gate.ps1') -StdinText $tddJson -ProjectDir $sbD -WorkingDir $sbD
    Chk (($rD.Err + $rD.Out).Trim() -ne '') `
        'D1 tdd-gate.ps1 fires on the Chinese trigger with no red mark present' `
        'non-empty advisory output' "rc=$($rD.Code) out=$(Show ($rD.Err + $rD.Out))"

    Set-Content -LiteralPath (Join-Path $sbD '.claude/.tdd-exempt') -Encoding ascii -Value ''
    $rDe = Invoke-Script -Script (Join-Path $Hooks 'tdd-gate.ps1') -StdinText $tddJson -ProjectDir $sbD -WorkingDir $sbD
    Chk ((($rDe.Err + $rDe.Out).Trim() -eq '') -and ($rDe.Code -eq 0)) `
        'D2 tdd-gate.ps1 goes quiet once .claude/.tdd-exempt declares the exemption' `
        'empty output and exit 0' "rc=$($rDe.Code) out=$(Show ($rDe.Err + $rDe.Out))"

    # -----------------------------------------------------------------------
    Write-Output ''
    Write-Output '--- E mark-review-needed.ps1: source registers into .needs-review, docs and framework files do not ---'

    $sbE = New-Sandbox 'e-mark'
    $stateE = Join-Path $sbE '.claude/.needs-review'

    $rE1 = Invoke-Script -Script (Join-Path $Hooks 'mark-review-needed.ps1') `
        -StdinText '{"tool_input":{"file_path":"src/app.ts"}}' -ProjectDir $sbE -WorkingDir $sbE
    $listE1 = @(if (Test-Path $stateE) { Get-Content -LiteralPath $stateE } else { @() })
    Chk (($rE1.Code -eq 0) -and ($listE1 -contains 'src/app.ts')) `
        'E1 mark-review-needed.ps1 registers edited source into .needs-review (what test-hook-parity.sh had to defer)' `
        'exit 0 and .needs-review contains src/app.ts' `
        "rc=$($rE1.Code) list=[$($listE1 -join ', ')]"

    $rE2 = Invoke-Script -Script (Join-Path $Hooks 'mark-review-needed.ps1') `
        -StdinText '{"tool_input":{"file_path":"docs/readme.md"}}' -ProjectDir $sbE -WorkingDir $sbE
    $listE2 = @(if (Test-Path $stateE) { Get-Content -LiteralPath $stateE } else { @() })
    Chk (($rE2.Code -eq 0) -and ($listE2 -notcontains 'docs/readme.md')) `
        'E2 a .md edit is exempt (documentation does not queue a code review)' `
        '.needs-review has no docs/readme.md' "rc=$($rE2.Code) list=[$($listE2 -join ', ')]"

    $rE3 = Invoke-Script -Script (Join-Path $Hooks 'mark-review-needed.ps1') `
        -StdinText '{"tool_input":{"file_path":".claude/hooks/x.ps1"}}' -ProjectDir $sbE -WorkingDir $sbE
    $listE3 = @(if (Test-Path $stateE) { Get-Content -LiteralPath $stateE } else { @() })
    Chk (($rE3.Code -eq 0) -and ($listE3 -notcontains '.claude/hooks/x.ps1')) `
        'E3 the framework tree itself is exempt (top-level anchored, not a substring match)' `
        '.needs-review has no .claude/hooks/x.ps1' "rc=$($rE3.Code) list=[$($listE3 -join ', ')]"

    # -----------------------------------------------------------------------
    Write-Output ''
    Write-Output '--- F fast-mode.ps1 + session-rules-banner.ps1: the switch, the shared lib and the announcement, end to end ---'

    # fast-mode.ps1 resolves the project from $PSScriptRoot/../.., so it is copied into the
    # sandbox; running the repository copy would flip the real repository into fast mode.
    $sbF = New-Sandbox 'f-fastmode'
    New-Item -ItemType Directory -Path (Join-Path $sbF '.claude/scripts') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $Scripts 'fast-mode.ps1') -Destination (Join-Path $sbF '.claude/scripts/fast-mode.ps1')
    $fmScript = Join-Path $sbF '.claude/scripts/fast-mode.ps1'
    $banner = Join-Path $Hooks 'session-rules-banner.ps1'

    $rOn = Invoke-Script -Script $fmScript -ScriptArgs @('on', '3') -WorkingDir $sbF
    $rStatus = Invoke-Script -Script $fmScript -ScriptArgs @('status') -WorkingDir $sbF
    $mins = -1
    if ($rStatus.Out -match 'about\s+(\d+)\s+minutes remaining') { $mins = [int]$Matches[1] }
    Chk (($rOn.Code -eq 0) -and ($mins -ge 175) -and ($mins -le 180)) `
        'F1 fast-mode.ps1 on 3 then status reports the remaining minutes (the unix-epoch arithmetic is right on a real host)' `
        'status reports 175..180 minutes remaining' "on rc=$($rOn.Code) minutes=$mins status=$(Show $rStatus.Out)"

    $rBanOn = Invoke-Script -Script $banner -StdinText '{"source":"startup"}' -ProjectDir $sbF -WorkingDir $sbF
    Chk ($rBanOn.Out -like '*FAST-MODE ON*') `
        'F2 session-rules-banner.ps1 shouts while fast mode is open (every other hook is muted, so a forgotten switch must not hide)' `
        'stdout contains FAST-MODE ON' "rc=$($rBanOn.Code) stdout=$(Show $rBanOn.Out)"

    $rOff = Invoke-Script -Script $fmScript -ScriptArgs @('off') -WorkingDir $sbF
    $rStatus2 = Invoke-Script -Script $fmScript -ScriptArgs @('status') -WorkingDir $sbF
    Chk (($rOff.Code -eq 0) -and ($rStatus2.Out -like '*fast-mode: off*') -and (-not (Test-Path (Join-Path $sbF '.claude/.fast-mode')))) `
        'F3 fast-mode.ps1 off removes the flag and status agrees (strict mode really comes back)' `
        'status says off and .fast-mode is gone' `
        "off rc=$($rOff.Code) status=$(Show $rStatus2.Out) flag=$(Test-Path (Join-Path $sbF '.claude/.fast-mode'))"

    $rBanOff = Invoke-Script -Script $banner -StdinText '{"source":"startup"}' -ProjectDir $sbF -WorkingDir $sbF
    Chk ($rBanOff.Out -like '*CC Framework Core Rules*') `
        'F4 session-rules-banner.ps1 prints the normal banner once fast mode is off' `
        'stdout contains CC Framework Core Rules' "stdout=$(Show $rBanOff.Out)"

    $rBanCompact = Invoke-Script -Script $banner -StdinText '{"source":"compact"}' -ProjectDir $sbF -WorkingDir $sbF
    Chk ($rBanCompact.Out.Trim() -eq '') `
        'F5 session-rules-banner.ps1 stays silent on a compact/resume start (the banner is for fresh sessions only)' `
        'empty stdout' "stdout=$(Show $rBanCompact.Out)"

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
    Write-Output 'test-ps1-behavior: FAILED -- a .ps1 hook did not behave as its contract says.'
    exit 1
}
if ($script:Skip -gt 0) {
    Write-Output 'test-ps1-behavior: INCOMPLETE -- a group could not run (see [SKIP] above). Not executed is not a pass.'
    exit 3
}
Write-Output 'test-ps1-behavior: passed'
exit 0
