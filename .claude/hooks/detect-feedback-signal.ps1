#!/usr/bin/env pwsh
# Hook: UserPromptSubmit（PowerShell 等价 detect-feedback-signal.sh）
# 检测用户 prompt 中是否包含修正/反馈信号，有则注入 additionalContext 提醒派发 feedback-observer。
$ErrorActionPreference = 'Stop'

$raw = [Console]::In.ReadToEnd()
try { $prompt = ($raw | ConvertFrom-Json).prompt } catch { exit 0 }
if (-not $prompt) { exit 0 }

# 修正信号：用户指出 AI 做错了、漏了、忘了 / 不满 / 改进
$signals = '不是这样|别这样做|你搞错|搞错了|你错了|不对|不应该|你漏了|你忘了|改一下|不合理|你理解错|我说的不是|你确定|到底在|为什么没|没有执行|没有生效|你又忘|强调了|说过了|提醒过|怎么还|一直在|每次都|我不是让你|你先.*看|再说一遍|你到底|什么意思|能不能|不要再|别再|停下|不用管|先不要'
if ($prompt -match $signals) {
  Write-Output '{"additionalContext": "检测到用户修正信号。请在处理完用户请求后，派发 feedback-observer sub-agent 使用 feedback-writer skill 记录这条反馈。feedback 记录到 .claude/feedback/ 目录，不是 memory 目录。"}'
}
exit 0
