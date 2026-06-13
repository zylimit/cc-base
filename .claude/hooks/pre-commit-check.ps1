#!/usr/bin/env pwsh
# Hook: PreToolUse(Bash) if git commit*（PowerShell 等价 pre-commit-check.sh）
# commit 前按技术栈分发编译/语法门禁，任一栈不通过则阻止 commit（exit 2）。
#   - 只检查本次 staged 改动涉及的栈，不全量误伤
#   - 工具未安装 → 降级或跳过该栈，绝不因环境缺工具卡死 commit
$ErrorActionPreference = 'Stop'

# 脚本内自判触发命令：非 git commit 输入直接放行
$raw = [Console]::In.ReadToEnd()
try { $cmd = ($raw | ConvertFrom-Json).tool_input.command } catch { exit 0 }
if (-not $cmd) { exit 0 }
if ($cmd -notmatch 'git\s+commit') { exit 0 }

if (-not $env:CLAUDE_PROJECT_DIR) { exit 0 }
Set-Location $env:CLAUDE_PROJECT_DIR

# 本次提交涉及的文件（新增/复制/修改）
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
      [Console]::Error.WriteLine("❌ TypeScript 编译检查未通过，commit 被阻止：")
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
    # 降级：语法级编译检查（python3 一般可用；缺失则跳过该栈不卡 commit）
    if (Get-Command python3 -ErrorAction SilentlyContinue) {
      $pyOutput = python3 -m py_compile $pyFiles 2>&1
      $pyExit = $LASTEXITCODE
      $tool = 'python3 -m py_compile（未装 ruff，降级语法检查）'
    } else {
      $pyExit = 0
      $tool = '（未装 ruff/python3，跳过 Python 检查）'
    }
  }
  if ($pyExit -ne 0) {
    [Console]::Error.WriteLine("❌ Python 检查未通过（$tool），commit 被阻止：")
    [Console]::Error.WriteLine(($pyOutput | Out-String))
    $fail = 1
  }
}

if ($fail -ne 0) { exit 2 }
exit 0
