#!/usr/bin/env pwsh
# Hook: PostToolUse(Bash) if git commit*（PowerShell 等价 auto-push.sh）
# commit 后若本地领先上游则自动 push。
# 脚本内自判触发命令：非 git commit 输入直接退出（替代 if 字段）。
$ErrorActionPreference = 'Stop'

$raw = [Console]::In.ReadToEnd()
try { $cmd = ($raw | ConvertFrom-Json).tool_input.command } catch { exit 0 }
if (-not $cmd) { exit 0 }
if ($cmd -notmatch 'git\s+commit') { exit 0 }

# 空值兜底：CLAUDE_PROJECT_DIR 缺失直接退出（避免误推 cwd 所在的无关 repo）
if (-not $env:CLAUDE_PROJECT_DIR) { exit 0 }
try { Set-Location $env:CLAUDE_PROJECT_DIR } catch { exit 0 }

# 无上游分支（没配远程/未设 tracking）→ 跳过
git rev-parse --abbrev-ref '@{u}' *> $null
if ($LASTEXITCODE -ne 0) { exit 0 }

# 本地领先上游的 commit 数 > 0 才推
$ahead = git rev-list '@{u}..HEAD' --count 2>$null
if (-not $ahead) { $ahead = '0' }
if ([int]$ahead -gt 0) {
  git push *> $null
}
exit 0
