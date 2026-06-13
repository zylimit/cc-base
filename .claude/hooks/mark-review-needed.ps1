#!/usr/bin/env pwsh
# Hook: PostToolUse(Edit|Write)（PowerShell 等价 mark-review-needed.sh）
# 项目业务代码被编辑/创建后，把文件登记进待审清单（.needs-review 每行一个相对项目根路径）。
#   - 豁免基于「相对项目根路径」并顶层锚定：仅根级 tools/ 与 .claude/ 框架自身豁免
#   - 扩展名豁免用白名单末段
#   - 上一轮已 clean（或文件不存在）→ 开新清单；否则去重追加
$ErrorActionPreference = 'Stop'

if (-not $env:CLAUDE_PROJECT_DIR) { exit 0 }
$raw = [Console]::In.ReadToEnd()
try { $filePath = ($raw | ConvertFrom-Json).tool_input.file_path } catch { exit 0 }
if (-not $filePath) { exit 0 }

$root = $env:CLAUDE_PROJECT_DIR
$stateFile = Join-Path $root '.claude/.needs-review'

# 相对项目根路径，统一正斜杠（Windows 反斜杠归一，豁免正则与 .sh 一致）
$rel = $filePath
if ($filePath.StartsWith($root)) { $rel = $filePath.Substring($root.Length) }
$rel = ($rel -replace '\\', '/').TrimStart('/')

# 豁免 1：基础设施/框架自身（顶层锚定）
if ($rel -match '^(tools|\.claude)/') { exit 0 }
# 豁免 2：文档/配置类（按最终扩展名白名单）
if ($rel -match '\.(md|txt|json|yaml|yml|toml|lock|log|gitignore|prettierrc|eslintrc)$') { exit 0 }
if ($rel -match '\.(env|env\.local|env\.development|env\.production|env\.test)$') { exit 0 }

# 上一轮已 clean（或文件不存在）→ 开新清单
$lines = @()
if (Test-Path $stateFile) {
  $existing = @(Get-Content $stateFile -ErrorAction SilentlyContinue)
  if ($existing -notcontains 'clean') { $lines = $existing }
}
# 去重登记
if ($lines -notcontains $rel) { $lines += $rel }
Set-Content -Path $stateFile -Value $lines
exit 0
