#!/usr/bin/env pwsh
# static-check.ps1 -- identify the stack and run static checks (shellcheck / ruff|py_compile / tsc /
# node --check). PowerShell equivalent of static-check.sh: same argument, same exclusions, same exit
# codes. All green -> exit 0; any red -> exit 1 with the offending files named; a tool that is not
# installed skips its stack (a missing tool must never block).
# Usage: pwsh static-check.ps1 [project_dir]
#
# Role: Stage 0 of code-review, the static gate. A single-model review shares its own blind spots,
# so a model-independent mechanical pass runs first; semantic review (Stage 1/2) only starts on green.
# A pure-PowerShell install used to have no Stage 0 at all -- this hook existed only as .sh.
#
# ASCII only: Windows PowerShell 5.1 reads a BOM-less UTF-8 script as GBK, so one non-ASCII byte
# breaks the whole file. Diagnostics are English for that reason, not for style.
param([string]$Dir = '.')

$ErrorActionPreference = 'Stop'
# PowerShell 7.3+ can promote a native command's non-zero exit into a terminating error. Every
# checker below reports failure exactly that way, so the promotion is off where the setting exists.
if (Test-Path 'Variable:\PSNativeCommandUseErrorActionPreference') { $PSNativeCommandUseErrorActionPreference = $false }

if ($Dir -like '*..*') { [Console]::Error.WriteLine("static-check: unsafe dir $Dir"); exit 1 }
try { Set-Location -LiteralPath $Dir } catch { [Console]::Error.WriteLine("static-check: bad dir $Dir"); exit 1 }

$RootPath = (Get-Location).Path
$script:fail = 0
$script:ran = @()

function Test-Have([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

# Repository-relative, forward slashes -- the same shape find(1) prints, so the exclusion and
# tsc-subtree comparisons below read the same on both platforms.
function Get-RelPath([string]$Full) {
    $rel = $Full.Substring($RootPath.Length).TrimStart([char]'\', [char]'/')
    return ($rel -replace '\\', '/')
}

# Walk the tree pruning at the directory level, the way find's -not -path '*/node_modules/*' does:
# descending into node_modules first and filtering afterwards is the difference between a second and
# a minute on a real project. Reparse points are skipped because find does not follow symlinks.
function Get-Files {
    param([string[]]$SkipDirNames, [string[]]$SkipRelDirs)
    $found = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack
    $stack.Push($RootPath)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        $entries = @()
        try { $entries = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue) } catch { $entries = @() }
        foreach ($e in $entries) {
            if ($e.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            if ($e.PSIsContainer) {
                if ($SkipDirNames -contains $e.Name) { continue }
                if ($SkipRelDirs -contains (Get-RelPath $e.FullName)) { continue }
                $stack.Push($e.FullName)
            } else {
                [void]$found.Add($e)
            }
        }
    }
    return $found
}

function Select-ByExt($Files, [string[]]$Exts) {
    $out = New-Object System.Collections.ArrayList
    foreach ($f in $Files) { if ($Exts -contains $f.Extension.ToLowerInvariant()) { [void]$out.Add($f) } }
    return $out
}

function Invoke-Tool {
    param([string]$Exe, [string[]]$ToolArgs, [string]$WorkDir = '')
    # Function-scoped on purpose: with EAP=Stop, Windows PowerShell 5.1 turns native stderr captured
    # by 2>&1 into a terminating NativeCommandError, so a linter that merely warns would kill the run.
    $ErrorActionPreference = 'Continue'
    $text = ''
    $code = 0
    if ($WorkDir) { Push-Location -LiteralPath $WorkDir }
    try {
        $text = (& $Exe @ToolArgs 2>&1 | Out-String)
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = 0 }
    } catch {
        $text = $text + $_.Exception.Message
        $code = 1
    } finally {
        if ($WorkDir) { Pop-Location }
    }
    return [pscustomobject]@{ Code = $code; Text = $text }
}

function Write-CheckFailure([string]$Name, [string]$Text) {
    Write-Output ('[' + $Name + ' FAILED]')
    $lines = @($Text -split "`r?`n")
    if ($lines.Count -gt 40) { $lines = $lines[0..39] }
    foreach ($l in $lines) { Write-Output $l }
    $script:fail = 1
}

# Dependencies / runtime state / build output / VCS + the framework itself (.opencode and .claude are
# installed infrastructure, not the user code under review).
$PRUNE = @('node_modules', '.git', '.ccb', 'dist', 'build', '.venv', 'out', '.opencode', '.claude')
$pruned = @(Get-Files -SkipDirNames $PRUNE -SkipRelDirs @())

# ---- shell ----
$SH = @(Select-ByExt $pruned @('.sh'))
if ($SH.Count -gt 0 -and (Test-Have 'shellcheck')) {
    $script:ran += 'shellcheck'
    $r = Invoke-Tool 'shellcheck' @($SH | ForEach-Object { Get-RelPath $_.FullName })
    if ($r.Code -ne 0) { Write-CheckFailure 'shellcheck' $r.Text }
}

# ---- python ----
# python3 first, then python: the .sh side only needs python3, but a Windows box that has Python at
# all usually spells it `python`, and falling back is the difference between checking and skipping.
$PY = @(Select-ByExt $pruned @('.py'))
if ($PY.Count -gt 0) {
    if (Test-Have 'ruff') {
        $script:ran += 'ruff'
        $r = Invoke-Tool 'ruff' @('check', '.')
        if ($r.Code -ne 0) { Write-CheckFailure 'ruff' $r.Text }
    } else {
        $python = ''
        foreach ($cand in @('python3', 'python')) { if (-not $python -and (Test-Have $cand)) { $python = $cand } }
        if ($python) {
            $script:ran += 'py_compile'
            $r = Invoke-Tool $python (@('-m', 'py_compile') + @($PY | ForEach-Object { Get-RelPath $_.FullName }))
            if ($r.Code -ne 0) { Write-CheckFailure 'py_compile' $r.Text }
        }
    }
}

# ---- TypeScript ----
# tsconfig is not always at the top level (a front end often sits in a subdirectory), so probe every
# tsconfig.json down to depth 3; only enter a directory that has its dependencies installed
# (node_modules present), otherwise skip it -- missing dependencies must not turn into a red.
$TSDIRS = @()
if (Test-Have 'npx') {
    foreach ($cfg in $pruned) {
        if ($cfg.Name -ne 'tsconfig.json') { continue }
        $cfgRel = Get-RelPath $cfg.FullName
        if (@($cfgRel -split '/').Count -gt 3) { continue }
        $tsdir = $cfg.Directory.FullName
        if (-not (Test-Path -LiteralPath (Join-Path $tsdir 'node_modules'))) { continue }
        $tsRel = Get-RelPath $tsdir
        if (-not $tsRel) { $tsRel = '.' }
        $TSDIRS += $tsRel
        $script:ran += ('tsc(' + $tsRel + ')')
        $r = Invoke-Tool 'npx' @('--no-install', 'tsc', '--noEmit') $tsdir
        if ($r.Code -ne 0) { Write-CheckFailure ('tsc ' + $tsRel) $r.Text }
    }
}

# ---- JavaScript ----
# A different exclusion list on purpose, not a reuse of PRUNE: .claude holds the framework's own JS
# (engine, audit scripts, workflow orchestration), and pruning it wholesale would mean the framework's
# .mjs has never been syntax-checked by anyone. .claude/worktrees still has to go -- it holds full
# working-tree copies per agent, so scanning it checks the same repository N times and charges another
# branch's code to this review.
$JS_PRUNE = @('node_modules', '.git', '.ccb', 'dist', 'build', '.venv', 'out', 'coverage', '.opencode')
$JS = @(Select-ByExt (Get-Files -SkipDirNames $JS_PRUNE -SkipRelDirs @('.claude/worktrees')) @('.mjs', '.cjs', '.js'))
if ($JS.Count -gt 0 -and (Test-Have 'node')) {
    $jsout = ''
    $jsn = 0
    foreach ($f in $JS) {
        $rel = Get-RelPath $f.FullName
        # Anything under a subtree tsc already covered is not checked twice: tsc sees further than
        # syntax, and the same file reported by both is only noise.
        $skip = $false
        foreach ($d in $TSDIRS) { if ($d -eq '.' -or $rel.StartsWith($d + '/')) { $skip = $true; break } }
        if ($skip) { continue }
        $jsn++
        # node --check already prints <file>:<line>; pass it through as it comes and only drop the
        # pure-noise stack frames.
        $r = Invoke-Tool 'node' @('--check', $rel)
        if ($r.Code -ne 0) {
            foreach ($line in @($r.Text -split "`r?`n")) {
                if ($line -match '^    at ') { continue }
                if ($line -match '^Node\.js v') { continue }
                $jsout = $jsout + $line + [Environment]::NewLine
            }
        }
    }
    if ($jsn -gt 0) {
        $script:ran += ('node --check(' + $jsn + ')')
        if ($jsout) { Write-CheckFailure 'node --check' $jsout }
    }
}

if ($script:ran.Count -eq 0) {
    Write-Output 'static-check: no runnable static check found (no matching stack, or the tools are not installed); skipped.'
    exit 0
}
if ($script:fail -ne 0) {
    Write-Output 'static-check: static checks reported errors (see above); fix them before semantic review.'
    exit 1
}
Write-Output ('static-check: all green (' + ($script:ran -join ' ') + ').')
exit 0
