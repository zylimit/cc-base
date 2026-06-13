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
    $tsOutput = npx --no-install tsc --noEmit 2>&1
    $tsExit = $LASTEXITCODE
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
  } else {
    # Degrade: syntax-level compile check (python3 usually available; if missing, skip the stack and do not block commit)
    if (Get-Command python3 -ErrorAction SilentlyContinue) {
      $pyOutput = python3 -m py_compile $pyFiles 2>&1
      $pyExit = $LASTEXITCODE
      $tool = 'python3 -m py_compile (ruff not installed, degraded to syntax check)'
    } else {
      $pyExit = 0
      $tool = '(ruff/python3 not installed, Python check skipped)'
    }
  }
  if ($pyExit -ne 0) {
    [Console]::Error.WriteLine("[x] Python check failed ($tool), commit blocked:")
    [Console]::Error.WriteLine(($pyOutput | Out-String))
    $fail = 1
  }
}

if ($fail -ne 0) { exit 2 }
exit 0
