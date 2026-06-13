#!/usr/bin/env pwsh
# Hook: Stop（PowerShell 等价 stop-gate.sh）
# 有项目代码待 review 时阻止停止。状态文件 .needs-review（按文件登记，每行一个相对路径）。
#   - 去掉空行与 "clean" 行后仍有文件 = 阻止并列出
#   - 否则（只剩 clean / 全空 / 不存在）= 放行并清理
# 放行契约：审查通过后 `echo clean > .claude/.needs-review` 即可。
$ErrorActionPreference = 'Stop'

if (-not $env:CLAUDE_PROJECT_DIR) { exit 0 }
$stateFile = Join-Path $env:CLAUDE_PROJECT_DIR '.claude/.needs-review'
if (-not (Test-Path $stateFile)) { exit 0 }

$files = @(Get-Content $stateFile | Where-Object { $_.Trim() -ne '' -and $_ -ne 'clean' })
if ($files.Count -eq 0) {
  Remove-Item $stateFile -ErrorAction SilentlyContinue
  Remove-Item "$stateFile.lock" -ErrorAction SilentlyContinue
  exit 0
}

$count = $files.Count
$inline = $files -join '、'
$reason = "代码已修改但未 code review（$count 个待审文件：$inline）。请派发 code-reviewer sub-agent 两阶段审查；通过后执行 echo clean > .claude/.needs-review 放行。"
$json = [pscustomobject]@{ decision = 'block'; reason = $reason } | ConvertTo-Json -Compress
Write-Output $json
exit 0
