#!/usr/bin/env pwsh
# Hook: PreToolUse(Edit|Write)（PowerShell 等价 no-direct-code-guard.sh）
# 检测主 Agent 是否直接写业务源码，是则警告（exit 2）；框架文件放行。
$ErrorActionPreference = 'Stop'

$raw = [Console]::In.ReadToEnd()
try { $obj = $raw | ConvertFrom-Json } catch { exit 0 }
$filePath = $obj.tool_input.file_path
if (-not $filePath) { $filePath = $obj.tool_input.path }
if (-not $filePath) { exit 0 }

# Windows 反斜杠归一后再套与 .sh 一致的正则
$fp = $filePath -replace '\\', '/'

# 框架文件放行（.claude/ / CLAUDE.md / Product-Spec / DEV-PLAN / progress / CHANGELOG / feedback / agents / skills / hooks / *.md/json/toml/sh/ps1）
if ($fp -match '(\.claude/|CLAUDE\.md|Product-Spec|DEV-PLAN|progress\.md|CHANGELOG|/feedback/|/agents/|/skills/|/hooks/|\.md$|\.json$|\.toml$|\.sh$|\.ps1$)') {
  exit 0
}

# 业务源码路径（src/ / app/ / lib/ / components/ 等），相对/绝对两种形态都拦
if ($fp -match '(^|/)(src|app|lib|components|pages|api|server|client|utils|models|services)/') {
  [Console]::Error.WriteLine("⚠️  [no-direct-code-guard] 主 Agent 不应直接写业务源码：$filePath")
  [Console]::Error.WriteLine("请派 implementer Sub-Agent 来编写，保持职责边界。")
  exit 2
}
exit 0
