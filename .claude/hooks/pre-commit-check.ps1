#!/usr/bin/env pwsh
# Hook: PreToolUse(Bash) if git commit* (PowerShell equivalent of pre-commit-check.sh)
# Before commit, dispatch a compile/syntax gate by tech stack; if any stack fails, block the commit (exit 2).
#   - Only checks stacks touched by the staged changes, not the whole repo
#   - Tool not installed -> degrade or skip that stack, never block the commit because a tool is missing
$ErrorActionPreference = 'Stop'

# Self-gate the trigger command: non "git commit" input passes
$raw = [Console]::In.ReadToEnd()
try { $cmd = ($raw | ConvertFrom-Json).tool_input.command } catch { exit 0 }
if (-not $cmd) { exit 0 }
if ($cmd -notmatch 'git\s+commit') { exit 0 }

if (-not $env:CLAUDE_PROJECT_DIR) { exit 0 }
Set-Location $env:CLAUDE_PROJECT_DIR

# Files touched by this commit (added/copied/modified)
$staged = @(git diff --cached --name-only --diff-filter=ACM 2>$null)
if ($staged.Count -eq 0) { exit 0 }
$stagedText = $staged -join "`n"
$fail = 0

# ---------- TypeScript ----------
if ($stagedText -match '\.(ts|tsx)$') {
  $tsconfig = Get-ChildItem -Path $env:CLAUDE_PROJECT_DIR -Filter tsconfig.json -Recurse -Depth 2 -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch 'node_modules|\.next' } | Select-Object -First 1
  if ($tsconfig -and (Get-Command npx -ErrorAction SilentlyContinue)) {
    Push-Location $tsconfig.DirectoryName
    # PS 5.1 + EAP=Stop turns tsc's stderr (merged via 2>&1) into a terminating error, which
    # would swallow the compile-error text and skip the $LASTEXITCODE gate. Relax to Continue
    # for this native call (same approach as the Python branch below); gate on the exit code.
    $prevTsEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $tsOutput = npx --no-install tsc --noEmit 2>&1
    $tsExit = $LASTEXITCODE
    $ErrorActionPreference = $prevTsEAP
    Pop-Location
    if ($tsExit -ne 0) {
      [Console]::Error.WriteLine("[x] TypeScript compile check failed, commit blocked:")
      [Console]::Error.WriteLine(($tsOutput | Out-String))
      $fail = 1
    }
  }
}

# ---------- Python ----------
$pyFiles = @($staged | Where-Object { $_ -match '\.py$' })
if ($pyFiles.Count -gt 0) {
  if (Get-Command ruff -ErrorAction SilentlyContinue) {
    $pyOutput = ruff check $pyFiles 2>&1
    $pyExit = $LASTEXITCODE
    $tool = 'ruff check'
    if ($pyExit -ne 0) {
      [Console]::Error.WriteLine("[x] Python check failed ($tool), commit blocked:")
      [Console]::Error.WriteLine(($pyOutput | Out-String))
      $fail = 1
    }
  } else {
    # Degrade: syntax-level compile check via a real interpreter.
    # The bare "python3" on Windows is often a Microsoft Store stub: it prints
    # nothing for --version and cannot compile, so picking it would falsely
    # block commits. Probe candidates in order and keep the first one whose
    # --version reports "Python 3".
    #
    # Note: this hook sets $ErrorActionPreference='Stop'. Merging a native
    # program's stderr with 2>&1 turns that stderr into a terminating error
    # under Stop, which would swallow real SyntaxError text. So every native
    # call below redirects stderr to a temp file (2>) and reads it back, which
    # never raises, and we relax the preference to Continue for the duration.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      $pyCmd = $null
      $errFile = [System.IO.Path]::GetTempFileName()
      foreach ($cand in @('py -3', 'python', 'python3')) {
        $parts = $cand -split ' '
        $exe = $parts[0]
        $pre = @()
        if ($parts.Count -gt 1) { $pre = $parts[1..($parts.Count - 1)] }
        if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { continue }
        $ver = (& $exe @pre '--version' 2> $errFile | Out-String)
        $verExit = $LASTEXITCODE
        $verErr = (Get-Content $errFile -Raw -ErrorAction SilentlyContinue)
        $verAll = "$ver`n$verErr"
        if ($verExit -eq 0 -and $verAll -match 'Python 3') {
          $pyCmd = @{ Exe = $exe; Pre = $pre }
          break
        }
      }
      if ($null -eq $pyCmd) {
        # No real interpreter found -> skip Python check, do not block commit.
        $tool = '(ruff/python not available, Python check skipped)'
      } else {
        # Loop per file instead of passing the whole list at once, so a large
        # staged set cannot blow the command-line length limit (Error 206).
        # Only a true py_compile syntax error blocks the commit; any non-syntax
        # failure (stub, missing file, length, etc.) degrades to a skip.
        $tool = "$($pyCmd.Exe) -m py_compile (ruff not installed, degraded to syntax check)"
        $pyErrors = @()
        foreach ($f in $pyFiles) {
          $out = (& $pyCmd.Exe @($pyCmd.Pre) '-m' 'py_compile' $f 2> $errFile | Out-String)
          $cExit = $LASTEXITCODE
          $cErr = (Get-Content $errFile -Raw -ErrorAction SilentlyContinue)
          $cAll = "$out`n$cErr"
          if ($cExit -ne 0 -and $cAll -match 'SyntaxError') {
            $pyErrors += "$f`n$cAll"
          }
          # Non-syntax non-zero exit -> degrade (skip), do not block.
        }
        if ($pyErrors.Count -gt 0) {
          [Console]::Error.WriteLine("[x] Python check failed ($tool), commit blocked:")
          [Console]::Error.WriteLine(($pyErrors -join "`n"))
          $fail = 1
        }
      }
    } finally {
      Remove-Item $errFile -Force -ErrorAction SilentlyContinue
      $ErrorActionPreference = $prevEAP
    }
  }
}

if ($fail -ne 0) {
  try { . (Join-Path $PSScriptRoot 'lib-gate-log.ps1'); Write-GateLog 'pre-commit-check' 'compile/syntax gate failed, commit blocked' } catch { }
  exit 2
}
exit 0
