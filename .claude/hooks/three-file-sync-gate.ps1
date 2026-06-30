#!/usr/bin/env pwsh
# Hook: Stop (PowerShell equivalent of three-file-sync-gate.sh)
# 三文件同步铁律恢复侧强制闸——只认 git 工作树实际未提交改动。
#   C1: 未提交改动里有代码/家底文件且 progress.md 不在改动集 -> 拦停提醒同步。
#   C2: 改动集含 Product-Spec.md 但不含 CHANGELOG（或反之）-> 需求变更漏记。
#       只校验存在的文件——Spec/CHANGELOG 任一不存在则不强造、不拦停。
# 干净树 / 改动已含 progress 或两份成对 / 非 git 仓 / 无 progress.md -> 优雅放行。
$ErrorActionPreference = 'Stop'

$root = $env:CLAUDE_PROJECT_DIR
if (-not $root) {
  try { $root = git rev-parse --show-toplevel 2>$null } catch { $root = $null }
  if (-not $root) { $root = (Get-Location).Path }
}
$prog = Join-Path $root 'progress.md'
if (-not (Test-Path $prog)) { exit 0 }

# 非 git 仓 -> 无工作树可判，优雅放行。
try { git -C $root rev-parse --is-inside-work-tree 2>$null | Out-Null } catch { exit 0 }
if ($LASTEXITCODE -ne 0) { exit 0 }

$codeDirty = $false
$progDirty = $false
$specDirty = $false
$changelogDirty = $false
$firstCode = ''

# 把单条改动路径归类到三文档命中 / 代码改动标志。
function Classify-Path([string]$path) {
  switch ($path) {
    'progress.md' { $script:progDirty = $true }
    'Product-Spec.md' { $script:specDirty = $true }
    'Product-Spec-CHANGELOG.md' { $script:changelogDirty = $true }
  }
  if ($path -match '(^|/)(\.claude/evidence|node_modules|out|dist)/') { return }
  if ($path -match '\.(sh|ps1|ts|tsx|js|jsx|py|css|go|rs)$') {
    $script:codeDirty = $true
    if (-not $script:firstCode) { $script:firstCode = $path }
  } elseif ($path -match '(^|/)\.claude/') {
    # .claude/ 下家底（CLAUDE.md / agents / skills / settings.json 等）改了也属「改了要记
    # progress」，计入家底代码集；evidence 账本已由上面排除分支提前 return，到不了这里。
    $script:codeDirty = $true
    if (-not $script:firstCode) { $script:firstCode = $path }
  }
}

# --porcelain -z：NUL 分隔、路径不加引号（消除带空格文件名被引号包裹致正则漏判）。git -z
# 输出无换行，PowerShell 收成单串，按 NUL 切成记录。rename/copy 是两段：`XY <new>` NUL
# `<old>` NUL（旧路径裸路径无前缀），故 X/Y 命中 R/C 时要再读下一段裸 old-path，新旧都计入。
$raw = @(git -C $root status --porcelain -z 2>$null) -join ''
$records = @($raw -split "`0" | Where-Object { $_ -ne '' })
$i = 0
while ($i -lt $records.Count) {
  $rec = $records[$i]
  if ($rec.Length -lt 3) { $i++; continue }
  $status = $rec.Substring(0, 2)
  Classify-Path $rec.Substring(3)
  if ($status -match '^[RC]' -or $status -match '[RC]$') {
    $i++
    if ($i -lt $records.Count) { Classify-Path $records[$i] }
  }
  $i++
}

$block = $false
$reason = ''

if ($codeDirty -and (-not $progDirty)) {
  $reason = "三文件同步铁律：检测到未提交的代码/家底改动（如 $firstCode）但 progress.md 未同步。请把本轮的决策/完成事项/进度/新任务即时写入 progress.md（doc 类主 Agent 直接写），保证随时可 Clear->recap 完整恢复，然后重试停止。"
  $block = $true
}

# 成对校验只在两份都存在时进行，缺一不强造、不拦停。
if ((Test-Path (Join-Path $root 'Product-Spec.md')) -and (Test-Path (Join-Path $root 'Product-Spec-CHANGELOG.md'))) {
  if ($specDirty -and (-not $changelogDirty)) {
    $reason = ("$reason Product-Spec.md 有未提交改动但 Product-Spec-CHANGELOG.md 未同步，需求变更可能漏记 CHANGELOG。请在 Product-Spec-CHANGELOG.md 补本次需求变更记录后重试停止。").Trim()
    $block = $true
  }
  if ($changelogDirty -and (-not $specDirty)) {
    $reason = ("$reason Product-Spec-CHANGELOG.md 有未提交改动但 Product-Spec.md 未同步，需求变更须成对更新两份文件。请同步 Product-Spec.md 后重试停止。").Trim()
    $block = $true
  }
}

if (-not $block) { exit 0 }

try { . (Join-Path $PSScriptRoot 'lib-gate-log.ps1'); Write-GateLog 'three-file-sync-gate' $reason } catch { }

$json = [pscustomobject]@{ decision = 'block'; reason = $reason } | ConvertTo-Json -Compress
Write-Output $json
exit 0
