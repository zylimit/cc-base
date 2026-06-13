#!/usr/bin/env pwsh
# cc-base Windows 安装脚本：检测环境 + 生成 Windows 版 settings（hook 走 .ps1）。
# 用法： pwsh -File setup.ps1 [-Force]
#   -Force  覆盖已存在的 .claude/settings-windows.json
[CmdletBinding()]
param(
  [switch]$Force
)
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$claudeDir = Join-Path $root '.claude'
$srcSettings = Join-Path $claudeDir 'settings.json'
$winSettings = Join-Path $claudeDir 'settings-windows.json'

Write-Host '=== cc-base Windows setup ===' -ForegroundColor Cyan

# 1. 检测 Git / Claude Code
if (Get-Command git -ErrorAction SilentlyContinue) {
  Write-Host "[ok] git: $((git --version) 2>$null)"
} else {
  Write-Host '[缺] 未检测到 git，请先安装：https://git-scm.com/download/win' -ForegroundColor Yellow
}
if (Get-Command claude -ErrorAction SilentlyContinue) {
  Write-Host '[ok] Claude Code (claude) 已安装'
} else {
  Write-Host '[缺] 未检测到 Claude Code (claude)，请先安装：https://docs.claude.com/claude-code' -ForegroundColor Yellow
}

# 2. 生成 Windows 版 settings（从 settings.json 派生，把 .sh hook 改为 powershell.exe -File *.ps1）
if (-not (Test-Path $srcSettings)) {
  Write-Host "[错] 找不到 $srcSettings，无法生成 Windows 版。" -ForegroundColor Red
  exit 1
}
if ((Test-Path $winSettings) -and -not $Force) {
  Write-Host "[跳过] $winSettings 已存在（加 -Force 覆盖）。" -ForegroundColor Yellow
} else {
  $settings = Get-Content $srcSettings -Raw | ConvertFrom-Json
  foreach ($event in $settings.hooks.PSObject.Properties) {
    foreach ($group in $event.Value) {
      foreach ($h in $group.hooks) {
        if ($h.command -match '/.claude/hooks/([A-Za-z0-9_-]+)\.sh') {
          $name = $Matches[1]
          $h.command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"`$env:CLAUDE_PROJECT_DIR\.claude\hooks\$name.ps1`""
        }
      }
    }
  }
  $settings | ConvertTo-Json -Depth 10 | Set-Content -Path $winSettings -Encoding UTF8
  Write-Host "[ok] 已生成 $winSettings" -ForegroundColor Green
}

# 3. 使用提示
Write-Host ''
Write-Host '--- 启用方式（二选一）---'
Write-Host '① 已装 Git Bash 且设置了 CLAUDE_CODE_GIT_BASH_PATH：可直接用现有 .claude/settings.json（.sh hooks 经 Git Bash 运行），无需 Windows 版。'
Write-Host '② 纯 PowerShell 环境：把 .claude/settings-windows.json 的内容合并/覆盖到 .claude/settings.json（或按 Claude Code 文档指向该文件）。'
Write-Host ''
Write-Host 'setup 完成。' -ForegroundColor Cyan
exit 0
