#!/usr/bin/env pwsh
# Hook: PreToolUse(Bash)（PowerShell 等价 kill-dev-ports.sh）
# 启动 dev server 前清掉常用端口占用进程，避免端口被旧进程占住起不来。
# Windows 用 netstat + taskkill 替代 lsof + kill。
# 脚本内自判：命令非 pnpm dev 直接放行（exit 0）。
$ErrorActionPreference = 'Stop'

$raw = [Console]::In.ReadToEnd()
try { $cmd = ($raw | ConvertFrom-Json).tool_input.command } catch { $cmd = $raw }
if (-not $cmd) { exit 0 }
if ($cmd -notmatch 'pnpm\s+dev') { exit 0 }

foreach ($port in 3000, 3001, 4173, 5173, 8080) {
  $listening = netstat -ano 2>$null | Select-String ":$port\s+.*LISTENING"
  foreach ($line in $listening) {
    $procId = ($line.ToString().Trim() -split '\s+')[-1]
    if ($procId -match '^\d+$') {
      taskkill /PID $procId /F *> $null
    }
  }
}
Start-Sleep -Seconds 1
exit 0
