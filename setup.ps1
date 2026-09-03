#!/usr/bin/env pwsh
# setup.ps1 - install the cc-base framework assets into a target project (Windows / pure PowerShell).
# Usage: pwsh -File setup.ps1 [-Target <dir>] [-Force]    without -Target, defaults to the current directory ".".
# Key: write target/.claude/settings.json directly (Claude Code only reads that fixed name, not settings-windows.json),
#      and rewrite each hook command to: <pwsh> -Command "& \"\$env:CLAUDE_PROJECT_DIR\.claude\hooks\<name>.ps1\""
#      Interpreter: prefer pwsh 7 (absolute path, quoted - it lives under "Program Files") because powershell.exe 5.1
#      inherits a Git Bash-polluted PATH and stalls on some machines (verified fix on digifiber UserPromptSubmit);
#      fall back to powershell.exe when pwsh is absent so machines without PowerShell 7 still work.
#      Why the \$ escape: on Windows the hook command runs in Git Bash (the outer shell when git is installed - a
#      cc-base prerequisite). A bare $env:CLAUDE_PROJECT_DIR has its $env eaten by bash (unset bash var -> empty,
#      leaving ":CLAUDE_PROJECT_DIR", broken). Escaping as \$env keeps a literal $ through bash, so the full
#      $env:CLAUDE_PROJECT_DIR reaches the inner powershell which expands it. -Command (not -File) is required
#      because only inside -Command does PowerShell expand $env: (a -File path is taken literally). Verified on a
#      real Windows machine (the SessionStart banner prints).
[CmdletBinding()]
param(
  [string]$Target = '.',
  [switch]$Force
)
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$srcClaude = Join-Path $root '.claude'
if (-not (Test-Path $srcClaude)) { throw "No .claude under the script directory (run from the cc-base repo root): $srcClaude" }

# target/.claude
if (-not (Test-Path $Target)) { New-Item -ItemType Directory -Path $Target -Force | Out-Null }
$targetClaude = Join-Path $Target '.claude'

Write-Host '=== cc-base setup (Windows/.ps1) ===' -ForegroundColor Cyan

# 1. Detect git / claude (advisory, not a hard block)
if (Get-Command git -ErrorAction SilentlyContinue) { Write-Host "[ok] git: $((git --version) 2>$null)" }
else { Write-Host '[!] git not detected (install: https://git-scm.com/download/win)' -ForegroundColor Yellow }
if (Get-Command claude -ErrorAction SilentlyContinue) { Write-Host '[ok] Claude Code (claude) installed' }
else { Write-Host '[!] Claude Code not detected (install: https://docs.claude.com/claude-code)' -ForegroundColor Yellow }

function Test-FilesEqual($a, $b) {
  if (-not (Test-Path $b)) { return $false }
  return (Get-FileHash $a -Algorithm SHA256).Hash -eq (Get-FileHash $b -Algorithm SHA256).Hash
}

# LF-normalized SHA256 (strip CR bytes before hashing) - must match gen-manifest.sh's
# "tr -d '\r' | sha256sum" so a CRLF checkout still matches the recorded manifest hash.
function Get-NormalizedSha([string]$path) {
  $bytes = [System.IO.File]::ReadAllBytes($path)
  $filtered = [byte[]]($bytes | Where-Object { $_ -ne 13 })
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { return ([System.BitConverter]::ToString($sha.ComputeHash($filtered)) -replace '-', '').ToLower() }
  finally { $sha.Dispose() }
}

# Framework core layer vs project private layer (FRAMEWORK-MANIFEST.txt):
# the target-side old manifest records the SHA each framework file had at install time.
# Before overwriting: target == old framework version -> safe upgrade; user-modified or
# no old manifest -> do not overwrite, drop <name>.framework-new for manual merge.
# Files on the target side that are not in the manifest = private layer, never touched.
$oldManifest = @{}
$oldManifestPath = Join-Path $targetClaude 'FRAMEWORK-MANIFEST.txt'
if (Test-Path $oldManifestPath) {
  foreach ($line in Get-Content $oldManifestPath) {
    if ($line -match '^#' -or -not $line.Trim()) { continue }
    $parts = $line -split "`t"
    if ($parts.Count -ge 2) { $oldManifest[$parts[0]] = $parts[1] }
  }
}
$script:frameworkNewList = @()

function Copy-WithBackup($src, $dest) {
  $destDir = Split-Path $dest -Parent
  if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
  if ((Test-Path $dest) -and -not (Test-FilesEqual $src $dest)) {
    Copy-Item $dest "$dest.bak" -Force
    Write-Host "backup: $dest.bak"
  }
  Copy-Item $src $dest -Force
}

# 2. Copy the .claude framework files (skip runtime artifacts / scratch / machine-specific; settings.json is rewritten separately)
# Same exclusion set as setup.sh copy_claude_tree, .claude/scripts/gen-manifest.sh and
# .claude/harness/lib/release.mjs MANIFEST_RULES -- change one, change all four. The four are kept
# as hand-synced copies on purpose (installers must run standalone; the release one is the auditor
# and would stop auditing if it shared a source), so the shared wording is verified by tests instead:
# .claude/tests/test-setup.sh section (6) compares the arms of all four literally, and
# .claude/tests/test-installer-parity.ps1 runs both installers side by side and diffs what landed.
# $skip is compared against the whole path relative to .claude/, i.e. root-anchored, which is what the
# bare-name arms of the other three tables mean: only the copy at the top of .claude/ is a runtime artifact.
# $skipAnyDepth is the subset the other three also carry a "*/<name>" arm for - those three grow at every
# depth, so they are matched by leaf name instead. Matching all of $skip by leaf name drops a nested
# skills/foo/settings.json that setup.sh copies and gen-manifest.sh records: installed on Linux, missing on
# Windows, with the manifest claiming it is there.
# Anything that is a directory rather than a file name goes in the regex list below.
$skip = @('settings.json', 'settings-windows.json', 'settings.local.json',
  '.needs-review', '.needs-review.lock', '.tdd-exempt', '.red-verified', '.static-gate', '.degraded-review',
  '.fast-mode', '.subagent-reminded', '.stop-gate-strikes', '.precompact-block-epoch', '.async-verify-last',
  'signals.jsonl', 'FRAMEWORK-MANIFEST.txt', '.DS_Store', 'Thumbs.db')
$skipAnyDepth = @('signals.jsonl', '.DS_Store', 'Thumbs.db')
$srcRootLen = (Resolve-Path $srcClaude).Path.Length
# -Force: PowerShell treats dot-prefixed names as hidden on Unix, so without it a pwsh run there silently
# skips .claude/.gitignore - a manifest-listed framework file. The find(1) in the other two shell tables has
# no such notion, and on Windows a Hidden attribute would hide a file the same way; -Force puts this walk on
# the same footing everywhere.
Get-ChildItem -Path $srcClaude -Recurse -File -Force | ForEach-Object {
  $rel = $_.FullName.Substring($srcRootLen).TrimStart('/', '\')
  $relSlash = $rel -replace '\\', '/'
  if ($skipAnyDepth -contains (Split-Path $rel -Leaf)) { return }
  if ($skip -contains $relSlash) { return }
  # private evolution feedback: skip top-level feedback/*.md, keep feedback/templates/ (INDEX is reset below)
  if ($relSlash -match '^feedback/[^/]+\.md$') { return }
  if ($relSlash -match '^evidence/') { return }
  # large-repo harness runtime state: receipts / evidence chain / waivers / drift ledger / raw check output
  if ($relSlash -match '^harness/(receipts|state|waivers|trend|evidence)/') { return }
  # supervisor process-guard runtime (supervisor.mjs itself is still distributed)
  if ($relSlash -match '^\.runtime/') { return }
  # installer leftovers + editor swap files (same arms as the other three tables / .claude/.gitignore)
  if ($relSlash -match '\.(bak|framework-new|swp)$') { return }
  $dest = Join-Path $targetClaude $rel
  # Manifest layering: only when the target exists with different content do we decide
  # "safe upgrade" vs "user-modified, do not overwrite".
  if ((Test-Path $dest) -and -not (Test-FilesEqual $_.FullName $dest)) {
    $oldSha = $oldManifest[$relSlash]
    if (-not ($oldSha -and (Get-NormalizedSha $dest) -eq $oldSha)) {
      # user-modified (SHA differs from old manifest) or no old manifest (legacy install)
      Copy-Item $_.FullName "$dest.framework-new" -Force
      $script:frameworkNewList += $relSlash
      return
    }
    # else: target == old framework version, fall through to safe overwrite (with .bak)
  }
  Copy-WithBackup $_.FullName $dest
}

# 3. Rewrite each hook command: .sh -> <pwsh> -Command "& \"\$env:CLAUDE_PROJECT_DIR\.claude\hooks\<name>.ps1\""
#    Built with single-quoted PowerShell literals so the \, ", and $ characters pass through verbatim into the
#    generated command (ConvertTo-Json escapes them for the JSON file).
#    Interpreter detection: pwsh 7 preferred (quoted absolute path, forward slashes survive Git Bash fine);
#    powershell.exe 5.1 kept as fallback for machines without PowerShell 7.
$pwsh7Path = 'C:\Program Files\PowerShell\7\pwsh.exe'
if (Test-Path $pwsh7Path) {
  $hookInterp = '"' + ($pwsh7Path -replace '\\', '/') + '"'
} else {
  $pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
  if ($pwshCmd) { $hookInterp = '"' + ($pwshCmd.Source -replace '\\', '/') + '"' }
  else { $hookInterp = 'powershell.exe'; Write-Host '[!] pwsh 7 not found, hook commands fall back to powershell.exe 5.1' -ForegroundColor Yellow }
}
Write-Host "[ok] hook interpreter: $hookInterp"
function Convert-ToPs1Command([string]$cmd) {
  if ($cmd -match '[/\\]\.claude[/\\]hooks[/\\]([A-Za-z0-9_-]+)\.sh') {
    $name = $Matches[1]
    return $hookInterp + ' -NoProfile -ExecutionPolicy Bypass -Command "& \"\$env:CLAUDE_PROJECT_DIR\.claude\hooks\' + $name + '.ps1\""'
  }
  if ($cmd -match '[/\\]\.claude[/\\]scripts[/\\]statusline\.sh') {
    return $hookInterp + ' -NoProfile -ExecutionPolicy Bypass -Command "& \"\$env:CLAUDE_PROJECT_DIR\.claude\scripts\statusline.ps1\""'
  }
  return $cmd
}

$src = Get-Content (Join-Path $srcClaude 'settings.json') -Raw | ConvertFrom-Json
foreach ($event in $src.hooks.PSObject.Properties) {
  foreach ($group in $event.Value) {
    foreach ($h in $group.hooks) {
      $h.command = Convert-ToPs1Command $h.command
      if ($h.PSObject.Properties['timeout']) { $h.timeout = 30 }
    }
  }
}
# statusLine command goes through the same .sh -> .ps1 rewrite (statusline.ps1 lives under .claude/scripts/)
if ($src.PSObject.Properties['statusLine'] -and $src.statusLine.command) {
  $src.statusLine.command = Convert-ToPs1Command $src.statusLine.command
}

# Recursively collect every .command value in the object (for merge dedup)
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

# Detect .sh-platform residue commands in target (left by a prior setup.sh install on Linux/Mac) so the merge
# can drop them before appending .ps1 commands. Conservative: only pure .sh invocations go - a command must
# reference a .claude/hooks/<name>.sh path, NOT mention powershell/pwsh (the .ps1 interpreter marker), and
# NOT carry .ps1-form shape ($env / -Command). All three together = .sh residue; user commands stay untouched.
function Test-IsShResidue([string]$cmd) {
  if (-not $cmd) { return $false }
  if ($cmd -match 'powershell|pwsh') { return $false }
  if ($cmd -notmatch '\.claude[/\\]hooks[/\\][A-Za-z0-9_-]+\.sh') { return $false }
  if ($cmd -match '\$env' -or $cmd -match '-Command') { return $false }
  return $true
}

# Strip .sh-residue hook entries from every group of every event in $obj's hooks (in place).
function Remove-ShResidue($obj) {
  if (-not $obj.hooks) { return }
  foreach ($ev in $obj.hooks.PSObject.Properties) {
    foreach ($group in $ev.Value) {
      if ($group.hooks) {
        $group.hooks = @($group.hooks | Where-Object { -not (Test-IsShResidue $_.command) })
      }
    }
  }
}

if ((Test-Path $targetSettings) -and -not $Force) {
  # 4. target already has settings.json: strip cross-platform .sh residue, then only append .ps1 hook commands
  #    not present yet, leaving other user config untouched.
  $tgt = Get-Content $targetSettings -Raw | ConvertFrom-Json
  Remove-ShResidue $tgt
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
  # Adopt the framework statusLine only when the target has none (never clobber a user statusline)
  if ($src.PSObject.Properties['statusLine'] -and -not $tgt.PSObject.Properties['statusLine']) {
    $tgt | Add-Member -NotePropertyName statusLine -NotePropertyValue $src.statusLine
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

# Reset feedback INDEX to a clean template (same source as make-release.sh; private entries were skipped above)
$fbTpl = Join-Path $srcClaude 'feedback/templates/feedback-index-template.md'
if (Test-Path $fbTpl) {
  Copy-WithBackup $fbTpl (Join-Path $targetClaude 'feedback/FEEDBACK-INDEX.md')
}

# Install the new manifest into the target (next upgrade uses it to tell
# "old framework version, safe to overwrite" from "user-modified, keep").
$srcManifest = Join-Path $srcClaude 'FRAMEWORK-MANIFEST.txt'
if (Test-Path $srcManifest) {
  Copy-WithBackup $srcManifest (Join-Path $targetClaude 'FRAMEWORK-MANIFEST.txt')
}

# Summary of user-modified files that were NOT overwritten (new versions at *.framework-new)
if ($script:frameworkNewList.Count -gt 0) {
  Write-Host ("setup: {0} file(s) modified on the target side were NOT overwritten;" -f $script:frameworkNewList.Count) -ForegroundColor Yellow
  Write-Host 'setup: new versions were written next to them as <file>.framework-new for manual merge:' -ForegroundColor Yellow
  foreach ($f in $script:frameworkNewList) { Write-Host "setup:   - .claude/$f" -ForegroundColor Yellow }
}

$hooksCount = (Get-ChildItem (Join-Path $srcClaude 'hooks') -Filter *.ps1 -ErrorAction SilentlyContinue).Count
Write-Host "installed: ps1_hooks=$hooksCount target=$Target" -ForegroundColor Green
Write-Host "Done. Claude Code loads the .ps1 hooks from $targetClaude\settings.json (hook commands use the escaped-dollar form so the project-dir env var survives the Git Bash outer shell and expands in the inner powershell)."
exit 0
