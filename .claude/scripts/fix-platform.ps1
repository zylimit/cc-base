#!/usr/bin/env pwsh
# fix-platform.ps1 — 把项目 .claude/settings.json 的 hook command 归一为当前平台（.ps1）形态。
# 跨平台搬迁后旧平台（.sh）command 残留会与本地平台 command 并存报错；搬到 Windows 后跑本脚本一次即可。
# 不依赖 cc-base 仓库在场、不依赖 jq——用 pwsh 内置 ConvertFrom-Json/ConvertTo-Json。
# 用法：pwsh -File fix-platform.ps1 [-Target <dir>]    不给 -Target 默认当前目录 "."，或读 CLAUDE_PROJECT_DIR。
[CmdletBinding()]
param(
  [string]$Target = '.'
)
$ErrorActionPreference = 'Stop'

# 定位项目根：优先 CLAUDE_PROJECT_DIR，其次 -Target（默认当前目录）。
$projectRoot = $env:CLAUDE_PROJECT_DIR
if (-not $projectRoot) { $projectRoot = (Resolve-Path $Target).Path }
$settings = Join-Path $projectRoot '.claude\settings.json'
if (-not (Test-Path $settings)) { throw "找不到 settings.json：$settings（请在项目根运行，或设 CLAUDE_PROJECT_DIR）" }

Write-Host '=== fix-platform (Windows/.ps1) ===' -ForegroundColor Cyan

# pwsh 解释器探测（复制自 setup.ps1:113-121）：pwsh 7 绝对路径优先 → Get-Command pwsh → fallback powershell.exe。
# pwsh 7 用绝对路径（带空格需引号）——powershell.exe 5.1 会继承被 Git Bash 污染的 PATH 卡死（setup.ps1 注释已记）。
$pwsh7Path = 'C:\Program Files\PowerShell\7\pwsh.exe'
if (Test-Path $pwsh7Path) {
  $hookInterp = '"' + ($pwsh7Path -replace '\\', '/') + '"'
} else {
  $pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
  if ($pwshCmd) { $hookInterp = '"' + ($pwshCmd.Source -replace '\\', '/') + '"' }
  else { $hookInterp = 'powershell.exe'; Write-Host '[!] pwsh 7 not found, hook commands fall back to powershell.exe 5.1' -ForegroundColor Yellow }
}
Write-Host "[ok] hook interpreter: $hookInterp"

# Convert-ToPs1Command（复制自 setup.ps1:122-128）：把 .sh command 改写为 .ps1 形态。
# 单引号字面量构造，\, ", $ 原样进入生成的 command（ConvertTo-Json 再转义）。
function Convert-ToPs1Command([string]$cmd) {
  if ($cmd -match '[/\\]\.claude[/\\]hooks[/\\]([A-Za-z0-9_-]+)\.sh') {
    $name = $Matches[1]
    return $hookInterp + ' -NoProfile -ExecutionPolicy Bypass -Command "& \"\$env:CLAUDE_PROJECT_DIR\.claude\hooks\' + $name + '.ps1\""'
  }
  return $cmd
}

# .sh 残留判定（复制自 setup.ps1:164-170 Test-IsShResidue）：
# 保守只认框架 .sh 形态——不含 powershell/pwsh、指向 .claude/hooks/<name>.sh、不带 $env/-Command（.ps1 形态标记）。
# 三条件都中才算 .sh 残留；用户自定义 .sh（指向别处）或 .ps1 形态都不动。
function Test-IsShResidue([string]$cmd) {
  if (-not $cmd) { return $false }
  if ($cmd -match 'powershell|pwsh') { return $false }
  if ($cmd -notmatch '\.claude[/\\]hooks[/\\][A-Za-z0-9_-]+\.sh') { return $false }
  if ($cmd -match '\$env' -or $cmd -match '-Command') { return $false }
  return $true
}

# 从 command 提 hook name（.sh 或 .ps1 都支持，用于查重）。
function Get-HookName([string]$cmd, [string]$ext) {
  if ($cmd -match ('\.claude[/\\]hooks[/\\]([A-Za-z0-9_-]+)\.' + $ext)) { return $Matches[1] }
  return $null
}

$data = Get-Content $settings -Raw | ConvertFrom-Json
$deletedSh = 0
$addedPs1 = 0

if ($data.hooks) {
  foreach ($event in $data.hooks.PSObject.Properties) {
    $groups = $event.Value
    if (-not $groups) { continue }
    foreach ($group in $groups) {
      if (-not $group.hooks) { continue }
      # 先收集本 group 已有的 .ps1 hook name（避免补重复）——用 hashtable 当集合，避开
      # pwsh 7.6 对 List[object]/HashSet[string] 做数组强转时的 PSToObjectArrayBinder 绑定 bug。
      $existingPs1 = @{}
      foreach ($h in $group.hooks) {
        $n = Get-HookName $h.command 'ps1'
        if ($n) { $existingPs1[$n] = $true }
      }
      $newList = @()
      $deletedEntries = @()
      foreach ($h in $group.hooks) {
        if (Test-IsShResidue $h.command) {
          $n = Get-HookName $h.command 'sh'
          $deletedEntries += [pscustomobject]@{ Name = $n; Entry = $h }
          $deletedSh++
        } else {
          $newList += $h
        }
      }
      # 对每个被删的 name，若同 group 无对应 .ps1 则补一条（保留原 entry 的 type/timeout 等）
      foreach ($de in $deletedEntries) {
        if ($de.Name -and $existingPs1.ContainsKey($de.Name)) { continue }
        $newEntry = [pscustomobject]@{}
        foreach ($p in $de.Entry.PSObject.Properties) {
          if ($p.Name -eq 'command') {
            $newEntry | Add-Member -NotePropertyName command -NotePropertyValue (Convert-ToPs1Command $de.Entry.command) -Force
          } else {
            $newEntry | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
          }
        }
        if (-not $newEntry.PSObject.Properties['command']) {
          $newEntry | Add-Member -NotePropertyName command -NotePropertyValue (Convert-ToPs1Command $de.Entry.command) -Force
        }
        # 匹 setup.ps1:135：有 timeout 就归 30（pwsh 启动慢于 bash，setup.ps1 装时同样强写 30）
        if ($newEntry.PSObject.Properties['timeout']) { $newEntry.timeout = 30 }
        $newList += $newEntry
        if ($de.Name) { $existingPs1[$de.Name] = $true }
        $addedPs1++
      }
      $group.hooks = $newList
    }
  }
}

# 备份后写回
Copy-Item $settings "$settings.bak" -Force
Write-Host "backup: $settings.bak"
$data | ConvertTo-Json -Depth 20 | Set-Content $settings -Encoding UTF8
Write-Host "fix-platform: deleted .sh residue commands=$deletedSh, added .ps1 commands=$addedPs1" -ForegroundColor Green
Write-Host "完成。settings.json 已归一为 .ps1 形态（Windows）。路径：$settings" -ForegroundColor Green
exit 0
