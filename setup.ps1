#!/usr/bin/env pwsh
# setup.ps1 — 把 cc-base 框架资产注入式安装到 target 项目（Windows / 纯 PowerShell）。
# 用法： pwsh -File setup.ps1 [-Target <dir>] [-Force]    不给 -Target 默认当前目录 "."
# 关键：直接写 target/.claude/settings.json（Claude Code 只认这个固定名，不认 settings-windows.json），
#       hook command 改写为 powershell.exe -Command 形式让 powershell 自己展开 $env:CLAUDE_PROJECT_DIR。
[CmdletBinding()]
param(
  [string]$Target = '.',
  [switch]$Force
)
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$srcClaude = Join-Path $root '.claude'
if (-not (Test-Path $srcClaude)) { throw "脚本目录下无 .claude（请在 cc-base 仓库根运行）：$srcClaude" }

# target/.claude
if (-not (Test-Path $Target)) { New-Item -ItemType Directory -Path $Target -Force | Out-Null }
$targetClaude = Join-Path $Target '.claude'

Write-Host '=== cc-base setup (Windows/.ps1) ===' -ForegroundColor Cyan

# 1. 检测 git / claude（提示，不硬阻断）
if (Get-Command git -ErrorAction SilentlyContinue) { Write-Host "[ok] git: $((git --version) 2>$null)" }
else { Write-Host '[缺] 未检测到 git（安装：https://git-scm.com/download/win）' -ForegroundColor Yellow }
if (Get-Command claude -ErrorAction SilentlyContinue) { Write-Host '[ok] Claude Code (claude) 已安装' }
else { Write-Host '[缺] 未检测到 Claude Code（安装：https://docs.claude.com/claude-code）' -ForegroundColor Yellow }

function Test-FilesEqual($a, $b) {
  if (-not (Test-Path $b)) { return $false }
  return (Get-FileHash $a -Algorithm SHA256).Hash -eq (Get-FileHash $b -Algorithm SHA256).Hash
}

function Copy-WithBackup($src, $dest) {
  $destDir = Split-Path $dest -Parent
  if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
  if ((Test-Path $dest) -and -not (Test-FilesEqual $src $dest)) {
    Copy-Item $dest "$dest.bak" -Force
    Write-Host "backup: $dest.bak"
  }
  Copy-Item $src $dest -Force
}

# 2. 复制 .claude 框架文件（跳过运行时产物 / 待删 / 机器特定；settings.json 走专门改写）
$skip = @('settings.json', 'settings-windows.json', 'settings.local.json',
  '.needs-review', '.needs-review.lock', '.tdd-exempt', '.red-verified', '.static-gate', '.degraded-review',
  'signals.jsonl')
$srcRootLen = (Resolve-Path $srcClaude).Path.Length
Get-ChildItem -Path $srcClaude -Recurse -File | ForEach-Object {
  $rel = $_.FullName.Substring($srcRootLen).TrimStart('/', '\')
  if ($skip -contains (Split-Path $rel -Leaf)) { return }
  Copy-WithBackup $_.FullName (Join-Path $targetClaude $rel)
}

# 3. 改写 hook command：.sh → powershell.exe -Command "& '$env:CLAUDE_PROJECT_DIR\.claude\hooks\<name>.ps1'"
function Convert-ToPs1Command([string]$cmd) {
  if ($cmd -match '[/\\]\.claude[/\\]hooks[/\\]([A-Za-z0-9_-]+)\.sh') {
    $name = $Matches[1]
    return "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `"& '`$env:CLAUDE_PROJECT_DIR\.claude\hooks\$name.ps1'`""
  }
  return $cmd
}

$src = Get-Content (Join-Path $srcClaude 'settings.json') -Raw | ConvertFrom-Json
foreach ($event in $src.hooks.PSObject.Properties) {
  foreach ($group in $event.Value) {
    foreach ($h in $group.hooks) { $h.command = Convert-ToPs1Command $h.command }
  }
}

# 递归收集对象里所有 .command 值（merge 去重用）
function Get-AllCommands($obj) {
  $acc = New-Object System.Collections.Generic.List[string]
  function Walk($o) {
    if ($null -eq $o) { return }
    if (($o -is [System.Collections.IEnumerable]) -and ($o -isnot [string])) {
      foreach ($i in $o) { Walk $i }
    } elseif ($o -is [pscustomobject]) {
      foreach ($p in $o.PSObject.Properties) {
        if ($p.Name -eq 'command' -and $p.Value -is [string]) { $acc.Add($p.Value) }
        Walk $p.Value
      }
    }
  }
  Walk $obj
  return $acc
}

$targetSettings = Join-Path $targetClaude 'settings.json'

if ((Test-Path $targetSettings) -and -not $Force) {
  # 4. target 已有 settings.json：只追加尚无的 hook command，不动用户其他配置
  $tgt = Get-Content $targetSettings -Raw | ConvertFrom-Json
  $existing = Get-AllCommands $tgt
  if (-not $tgt.hooks) { $tgt | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) -Force }
  foreach ($event in $src.hooks.PSObject.Properties) {
    foreach ($group in $event.Value) {
      $newHooks = @($group.hooks | Where-Object { $_.command -and ($existing -notcontains $_.command) })
      if ($newHooks.Count -gt 0) {
        $ng = [pscustomobject]@{}
        if ($group.PSObject.Properties['matcher']) { $ng | Add-Member -NotePropertyName matcher -NotePropertyValue $group.matcher }
        $ng | Add-Member -NotePropertyName hooks -NotePropertyValue $newHooks
        if (-not $tgt.hooks.PSObject.Properties[$event.Name]) {
          $tgt.hooks | Add-Member -NotePropertyName $event.Name -NotePropertyValue @() -Force
        }
        $tgt.hooks.($event.Name) = @($tgt.hooks.($event.Name)) + $ng
      }
    }
  }
  Copy-Item $targetSettings "$targetSettings.bak" -Force
  Write-Host "backup: $targetSettings.bak"
  $tgt | ConvertTo-Json -Depth 20 | Set-Content $targetSettings -Encoding UTF8
} else {
  if ((Test-Path $targetSettings) -and $Force) {
    Copy-Item $targetSettings "$targetSettings.bak" -Force
    Write-Host "backup: $targetSettings.bak"
  }
  $targetDir = Split-Path $targetSettings -Parent
  if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
  $src | ConvertTo-Json -Depth 20 | Set-Content $targetSettings -Encoding UTF8
}

$hooksCount = (Get-ChildItem (Join-Path $srcClaude 'hooks') -Filter *.ps1 -ErrorAction SilentlyContinue).Count
Write-Host "installed: ps1_hooks=$hooksCount target=$Target" -ForegroundColor Green
Write-Host "完成。Claude Code 从 $targetClaude\settings.json 加载 .ps1 hooks（powershell 自展开 `$env:CLAUDE_PROJECT_DIR）。"
exit 0
