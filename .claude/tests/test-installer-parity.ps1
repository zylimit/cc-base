#!/usr/bin/env pwsh
# test-installer-parity.ps1 -- run both installers over one source tree and diff what actually landed.
#
# Why this file exists
#   "Which files are framework files" lives in four hand-synced tables: .claude/scripts/gen-manifest.sh
#   (the generator), setup.sh copy_claude_tree and setup.ps1 $skip + regexes (the two installers), and
#   .claude/harness/lib/release.mjs MANIFEST_RULES (the auditor). tests/test-setup.sh section (6)
#   compares their arms as text, which catches a missing arm but not an arm that reads differently:
#   setup.ps1 matched $skip by leaf name while the other three anchor those arms at the top of .claude/.
#   A nested skills/foo/settings.json was therefore copied by setup.sh and recorded by gen-manifest.sh,
#   and silently skipped by setup.ps1 -- a Windows install whose manifest claims a file that is not on
#   disk, with nothing on the box to say so. The copy loop in setup.ps1 had no behaviour test at all:
#   test-ps1-behavior.ps1 covers the hooks, and the ps1 job in gate.yml stopped at Parser::ParseFile.
#
# What it proves and what it does not
#   It stages the source tree, runs both installers into two fresh targets, and diffs the two file
#   lists by name. Green means the two exclusion tables agree on this tree. It says nothing about file
#   contents, permission bits, or the settings.json merge -- tests/test-setup.sh owns those.
#   pwsh is cross-platform, so the diff is real on Linux too; what a Linux run cannot show is anything
#   that depends on the Windows filesystem itself (hidden attributes, case-insensitive names, 8.3).
#
# The planted fixtures
#   Diffing the repository as it stands only proves today's tree, and today's tree has no nested file
#   whose name collides with a root-anchored arm. The probe directory plants both directions:
#     skills/_probe/settings.json, .../FRAMEWORK-MANIFEST.txt, .../.fast-mode
#       root-anchored names sitting one level down -- framework files, both installers must copy them.
#       This is the red lock for the leaf-vs-root defect.
#     skills/_probe/.DS_Store, .../signals.jsonl, .../Thumbs.db
#       the three names the other three tables also carry a "*/<name>" arm for -- junk at every depth,
#       neither installer may copy them. This is the lock against over-correcting those three into
#       root-only arms while fixing the rest.
#     .claude/settings.local.json, .claude/.static-gate at the top of the staged tree
#       the root-anchored arms must still bite where they are supposed to.
#
# ASCII only (pinned iron law)
#   PS 5.1 reads a BOM-less UTF-8 file as GBK, so one non-ASCII byte breaks parsing on exactly the
#   machines this file protects. tests/test-ps1-behavior.ps1 group 0 asserts the rule for every .ps1.
#
# Run it
#   pwsh -NoProfile -File .claude/tests/test-installer-parity.ps1
#   Needs bash for the setup.sh side (Git Bash on Windows, the system bash elsewhere).
#
# Exit codes: 0 = all assertions passed; 1 = an assertion failed; 3 = the comparison could not run
# (no bash, or no PowerShell host to drive setup.ps1), which is not a pass -- CI treats 3 as failure.
#
# Discipline: the source tree is staged into a temp sandbox and the fixtures are planted there; this
# repository is only ever read. Every assertion prints EXPECT and GOT, and every difference is named
# file by file -- a count alone tells nobody what to fix.

$ErrorActionPreference = 'Continue'

# Nested two-argument Join-Path on purpose: the three-argument form needs -AdditionalChildPath,
# which only exists from PowerShell 6 on and fails to bind on 5.1.
$RepoRoot = (Resolve-Path (Join-Path (Join-Path $PSScriptRoot '..') '..')).Path
$SrcClaude = Join-Path $RepoRoot '.claude'
$SrcSetupSh = Join-Path $RepoRoot 'setup.sh'
$SrcSetupPs1 = Join-Path $RepoRoot 'setup.ps1'

$TmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ccbase-parity-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
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
    param([string]$Title, [string]$Why)
    $script:Skip++
    Write-Output "  [SKIP] $Title"
    Write-Output "         WHY    $Why"
}

# The PowerShell that is running this file drives setup.ps1, so the installer is exercised by the
# same host the operator is on (5.1 vs 7 differs in ways that matter to the copy loop's encoding).
$HostExe = $null
try { $HostExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { $HostExe = $null }
if (-not $HostExe) { $HostExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source }
if (-not $HostExe) { $HostExe = (Get-Command powershell -ErrorAction SilentlyContinue).Source }

# Git Bash first by absolute path: on a Windows box with WSL enabled, `bash` on PATH can be
# System32\bash.exe, which does not see the Windows temp tree the same way and would fail in a
# confusing place. Everywhere else Get-Command finds the system bash.
$BashExe = $null
foreach ($cand in @('C:\Program Files\Git\bin\bash.exe', 'C:\Program Files\Git\usr\bin\bash.exe')) {
    if (Test-Path $cand) { $BashExe = $cand; break }
}
if (-not $BashExe) {
    $found = (Get-Command bash -ErrorAction SilentlyContinue)
    if ($found) { $BashExe = $found.Source }
}

# Copy the source tree file by file with -Force, so dot-prefixed names come along on Unix (where
# PowerShell calls them hidden). A provider-level recursive copy is faster but its hidden-file
# behaviour differs by platform, and this file exists precisely to not paper over that kind of gap.
function Copy-Tree {
    param([string]$From, [string]$To)
    $fromFull = (Resolve-Path $From).Path
    $prefix = $fromFull.Length
    foreach ($f in (Get-ChildItem -Path $fromFull -Recurse -File -Force)) {
        $rel = $f.FullName.Substring($prefix).TrimStart('/', '\')
        $dest = Join-Path $To $rel
        $destDir = Split-Path $dest -Parent
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        Copy-Item $f.FullName $dest -Force
    }
}

# Every regular file under a target's .claude, relative and POSIX-separated, sorted. -Force again:
# without it the listing itself would hide the dot-prefixed files on Unix and the diff would lie.
function Get-InstalledList {
    param([string]$TargetClaude)
    if (-not (Test-Path $TargetClaude)) { return @() }
    $prefix = (Resolve-Path $TargetClaude).Path.Length
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($f in (Get-ChildItem -Path $TargetClaude -Recurse -File -Force)) {
        $out.Add(($f.FullName.Substring($prefix).TrimStart('/', '\') -replace '\\', '/'))
    }
    return @($out | Sort-Object)
}

function Write-Probe {
    param([string]$Path, [string]$Text)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text)
}

# Git Bash takes forward slashes for both the script and its arguments; a Windows path with
# backslashes would be eaten as escapes before setup.sh ever sees it.
function ToPosix {
    param([string]$P)
    return ($P -replace '\\', '/')
}

Write-Output '=== test-installer-parity: setup.ps1 vs setup.sh, same tree, diff what landed ==='
Write-Output "repo:  $RepoRoot"
Write-Output "host:  $HostExe"
Write-Output "bash:  $BashExe"
Write-Output "sandbox: $TmpRoot"

$rc = 0
try {
    if (-not $BashExe -or -not $HostExe) {
        Skipped 'installer parity' 'no bash and/or no PowerShell host -- the comparison needs both installers to run'
        $rc = 3
    } else {
        $stage = Join-Path $TmpRoot 'stage'
        $stageClaude = Join-Path $stage '.claude'
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        Copy-Tree $SrcClaude $stageClaude
        Copy-Item $SrcSetupSh (Join-Path $stage 'setup.sh') -Force
        Copy-Item $SrcSetupPs1 (Join-Path $stage 'setup.ps1') -Force

        # Fixtures. MustInstall = a root-anchored name planted one level down, so it is a framework
        # file; MustSkip = a name the other three tables also match at any depth.
        $probeDir = Join-Path $stageClaude 'skills/_probe'
        $mustInstall = @('skills/_probe/settings.json', 'skills/_probe/FRAMEWORK-MANIFEST.txt', 'skills/_probe/.fast-mode')
        $mustSkip = @('skills/_probe/.DS_Store', 'skills/_probe/signals.jsonl', 'skills/_probe/Thumbs.db',
            'settings.local.json', '.static-gate')
        foreach ($rel in ($mustInstall + $mustSkip)) {
            Write-Probe (Join-Path $stageClaude $rel) "probe $rel`n"
        }

        $staged = Get-InstalledList $stageClaude
        $missingFixtures = @(($mustInstall + $mustSkip) | Where-Object { $staged -notcontains $_ })
        Chk ($missingFixtures.Count -eq 0 -and ($staged -contains '.gitignore')) `
            'staged source tree carries the probes and the dot-files' `
            'all 8 probe files plus .claude/.gitignore present in the staged tree' `
            ("staged=" + $staged.Count + " missing=[" + ($missingFixtures -join ', ') + "] gitignore=" + ($staged -contains '.gitignore'))

        $targetSh = Join-Path $TmpRoot 'target-sh'
        $targetPs = Join-Path $TmpRoot 'target-ps'
        New-Item -ItemType Directory -Path $targetSh -Force | Out-Null
        New-Item -ItemType Directory -Path $targetPs -Force | Out-Null

        # -ubt is load-bearing: without it setup.sh detects MINGW on Windows and execs setup.ps1,
        # and the whole comparison would be setup.ps1 against itself -- green and worthless.
        $shOut = (& $BashExe (ToPosix (Join-Path $stage 'setup.sh')) '-ubt' (ToPosix $targetSh) 2>&1 | Out-String)
        $shRc = $LASTEXITCODE
        $psOut = (& $HostExe -NoProfile -File (Join-Path $stage 'setup.ps1') -Target $targetPs 2>&1 | Out-String)
        $psRc = $LASTEXITCODE

        Chk (($shRc -eq 0) -and ($shOut -match 'installed: hooks=')) `
            'setup.sh installed through its own .sh path' `
            'rc 0 and the .sh summary line "installed: hooks=" (not "ps1_hooks=", which would mean it re-execed setup.ps1)' `
            ("rc=$shRc summary=[" + (($shOut -split "`n" | Where-Object { $_ -match 'installed: ' }) -join ' ') + "]")
        Chk (($psRc -eq 0) -and ($psOut -match 'installed: ps1_hooks=')) `
            'setup.ps1 installed' `
            'rc 0 and the .ps1 summary line "installed: ps1_hooks="' `
            ("rc=$psRc summary=[" + (($psOut -split "`n" | Where-Object { $_ -match 'installed: ' }) -join ' ') + "]")

        $shList = Get-InstalledList (Join-Path $targetSh '.claude')
        $psList = Get-InstalledList (Join-Path $targetPs '.claude')

        # Non-vacuity: an empty or near-empty pair of lists would compare equal and prove nothing.
        Chk (($shList.Count -ge 100) -and ($psList.Count -ge 100)) `
            'both installs produced a real tree' `
            'at least 100 files on each side' `
            ("setup.sh=" + $shList.Count + " setup.ps1=" + $psList.Count)

        $onlySh = @($shList | Where-Object { $psList -notcontains $_ })
        $onlyPs = @($psList | Where-Object { $shList -notcontains $_ })
        foreach ($f in $onlySh) { Write-Output "         MISSING on the setup.ps1 side: $f" }
        foreach ($f in $onlyPs) { Write-Output "         EXTRA   on the setup.ps1 side: $f" }
        Chk ($onlySh.Count -eq 0) `
            'setup.ps1 installed everything setup.sh installed' `
            'no file installed by setup.sh is absent on the setup.ps1 side' `
            ("missing=" + $onlySh.Count + " [" + ($onlySh -join ', ') + "]")
        Chk ($onlyPs.Count -eq 0) `
            'setup.ps1 installed nothing extra' `
            'no file installed by setup.ps1 was skipped by setup.sh' `
            ("extra=" + $onlyPs.Count + " [" + ($onlyPs -join ', ') + "]")

        # The named fixtures, asserted per file so the report says which one broke, not just "the
        # lists differ". These stay red even if some future difference makes the diff above noisy.
        $shMissesInstall = @($mustInstall | Where-Object { $shList -notcontains $_ })
        $psMissesInstall = @($mustInstall | Where-Object { $psList -notcontains $_ })
        Chk (($shMissesInstall.Count -eq 0) -and ($psMissesInstall.Count -eq 0)) `
            'nested copies of root-anchored names are installed by both' `
            ('both sides carry ' + ($mustInstall -join ', ')) `
            ("setup.sh missing=[" + ($shMissesInstall -join ', ') + "] setup.ps1 missing=[" + ($psMissesInstall -join ', ') + "]")

        $shKeptJunk = @($mustSkip | Where-Object { $shList -contains $_ })
        $psKeptJunk = @($mustSkip | Where-Object { $psList -contains $_ })
        Chk (($shKeptJunk.Count -eq 0) -and ($psKeptJunk.Count -eq 0)) `
            'any-depth junk and root-anchored runtime markers are installed by neither' `
            ('neither side carries ' + ($mustSkip -join ', ')) `
            ("setup.sh kept=[" + ($shKeptJunk -join ', ') + "] setup.ps1 kept=[" + ($psKeptJunk -join ', ') + "]")
    }
} finally {
    Remove-Item -Path $TmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
Write-Output ("test-installer-parity: PASS=$script:Pass FAIL=$script:Fail SKIP=$script:Skip")
if ($script:Fail -gt 0) { exit 1 }
if ($rc -ne 0) { exit $rc }
exit 0
