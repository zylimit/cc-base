#!/usr/bin/env pwsh
# Hook: PreToolUse(Bash)（PowerShell 等价 dangerous-pkill-guard.ps1）
# 拦截宽泛进程匹配（pkill -f / Stop-Process 通配名），防止误杀主 Agent 进程。
$ErrorActionPreference = 'Stop'

$raw = [Console]::In.ReadToEnd()
try { $cmd = ($raw | ConvertFrom-Json).tool_input.command } catch { exit 0 }
if (-not $cmd) { exit 0 }

# 锚定命令起始/分隔符，只拦真实执行的 pkill -f，放过 echo/grep "pkill -f" 字符串
# 跨平台项目脚本里可能写 pkill，保留原检测逻辑。
if ($cmd -match '(^|;|&&|\|\||`|\$\()\s*pkill\s+-f') {
  [Console]::Error.WriteLine("⛔ [dangerous-pkill-guard] 检测到 pkill -f 宽泛匹配，已拦截。")
  [Console]::Error.WriteLine("宽泛 pkill -f 会误杀主 Agent 自身进程（shell wrapper 含相同关键词）。")
  [Console]::Error.WriteLine("正确做法：先用 ps/pgrep 拿精确 PID，再 kill <PID>。")
  exit 2
}

# Windows 原生同构footgun：Stop-Process 按通配名宽泛杀（-Name "*node*"），同样会误伤；精确 -Id/-Name 字面值放行
if ($cmd -match '(^|;|&&|\|\||`|\$\()\s*Stop-Process\b[^;&|]*-Name\s+["'']?[^"''\s]*\*') {
  [Console]::Error.WriteLine("⛔ [dangerous-pkill-guard] 检测到 Stop-Process -Name 通配匹配，已拦截。")
  [Console]::Error.WriteLine("通配名宽泛 Stop-Process 会误杀主 Agent 自身进程。")
  [Console]::Error.WriteLine("正确做法：先用 Get-Process 拿精确 Id，再 Stop-Process -Id <PID>。")
  exit 2
}
exit 0
