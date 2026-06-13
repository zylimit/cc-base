#!/usr/bin/env pwsh
# Hook: SessionStart（PowerShell 等价 check-evolution.sh）
# 检查 FEEDBACK-INDEX.md 是否有需要处理的 feedback，有则输出提醒派发 evolution-runner。
$ErrorActionPreference = 'Stop'

if (-not $env:CLAUDE_PROJECT_DIR) { exit 0 }
$feedbackIndex = Join-Path $env:CLAUDE_PROJECT_DIR '.claude/feedback/FEEDBACK-INDEX.md'
if (-not (Test-Path $feedbackIndex)) { exit 0 }

$lines = Get-Content $feedbackIndex
# 待处理 = 索引中未带「✅[已毕业]」前缀的条目（行首 "- ["）
$pending = @($lines | Where-Object { $_ -match '^- \[' }).Count
# 总数 = 含已毕业前缀一并计数
$total = @($lines | Where-Object { $_ -match '^- (✅\[已毕业\] )?\[' }).Count

if ($pending -gt 0) {
  Write-Output "📋 项目有 $pending 条待处理 feedback（共 $total 条）。建议派发 evolution-runner 检查是否有进化建议。"
}
exit 0
