#!/usr/bin/env pwsh
# Hook: PreToolUse(Bash)（PowerShell 等价 tdd-gate.sh）
# TDD 闸门建议提示（非硬拦截，仅提醒）：检测在没有 .red-verified / .tdd-exempt 时派 implementer 写代码。
$ErrorActionPreference = 'Stop'

$raw = [Console]::In.ReadToEnd()
try { $cmd = ($raw | ConvertFrom-Json).tool_input.command } catch { exit 0 }
if (-not $cmd) { exit 0 }

$root = git rev-parse --show-toplevel 2>$null
if (-not $root) { $root = (Get-Location).Path }

# 只对看起来是在启动 implementer 的命令触发
if ($cmd -match '(?i)(implementer|dev-builder|GREEN|编码实现)') {
  $redVerified = Join-Path $root '.claude/.red-verified'
  $tddExempt = Join-Path $root '.claude/.tdd-exempt'
  if ((-not (Test-Path $redVerified)) -and (-not (Test-Path $tddExempt))) {
    [Console]::Error.WriteLine("TDD 闸门：派 implementer 做 GREEN 实现前须先完成 RED。")
    [Console]::Error.WriteLine("高价值逻辑（契约/解析器/状态机/去重/schema 校验/驱动适配层等）：先派 tester 出失败测试 → 验红 → touch .claude/.red-verified，再派 implementer 写最简实现到绿。")
    [Console]::Error.WriteLine("若本 Task 是 UI/样式/非 TDD 逻辑：touch .claude/.tdd-exempt 显式声明豁免。")
    # 建议性提示，不硬拦截（与文件头注释一致）
    exit 0
  }
}
exit 0
