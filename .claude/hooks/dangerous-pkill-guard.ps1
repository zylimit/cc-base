#!/usr/bin/env pwsh
# Hook: PreToolUse(Bash)（PowerShell 等价 dangerous-pkill-guard.sh）
# 拦截 pkill -f 宽泛匹配，防止误杀主 Agent 进程。
$ErrorActionPreference = 'Stop'

$raw = [Console]::In.ReadToEnd()
try { $cmd = ($raw | ConvertFrom-Json).tool_input.command } catch { exit 0 }
if (-not $cmd) { exit 0 }

# 锚定命令起始/分隔符，只拦真实执行的 pkill -f，放过 echo/grep "pkill -f" 字符串
if ($cmd -match '(^|;|&&|\|\||`|\$\()\s*pkill\s+-f') {
  [Console]::Error.WriteLine("⛔ [dangerous-pkill-guard] 检测到 pkill -f 宽泛匹配，已拦截。")
  [Console]::Error.WriteLine("宽泛 pkill -f 会误杀主 Agent 自身进程（shell wrapper 含相同关键词）。")
  [Console]::Error.WriteLine("正确做法：先用 ps/pgrep 拿精确 PID，再 kill <PID>。")
  exit 2
}
exit 0
