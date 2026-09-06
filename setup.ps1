#!/usr/bin/env pwsh
# setup.ps1 - install the cc-base framework assets into a target project (Windows / pure PowerShell).
# Usage: pwsh -File setup.ps1 [-Target <dir>] [-Force] [-DryRun]    without -Target, defaults to the current directory ".".
#      -DryRun writes nothing and prints the plan (create / update / conflict / skip) instead.
# Key: write target/.claude/settings.json directly (Claude Code only reads that fixed name, not settings-windows.json).
#      Hook commands are no longer rewritten: settings.json ships the exec form ("command":"node" plus
#      "args":["${CLAUDE_PROJECT_DIR}/.claude/hooks/<name>.mjs"]), which spawns node.exe directly with no shell in
#      between, so the very same file works verbatim on Windows / Mac / Linux.
#      The one thing still rewritten here is statusLine: it has no exec form, only a shell command string, and on a
#      pure PowerShell box that string is run by PowerShell - where the Git Bash spelling "$CLAUDE_PROJECT_DIR"
#      expands to nothing. Hence the $env: spelling.
#      Also cleaned up: hook files and hook commands an older .sh/.ps1 install of this framework left behind.
[CmdletBinding()]
param(
  [string]$Target = '.',
  [switch]$Force,
  [switch]$DryRun,
  [switch]$WithTests
)
$ErrorActionPreference = 'Stop'

# Install transaction state (mirrors setup.sh): an exclusive lock so two installs cannot write the
# same target at once, a maintenance marker that says "this tree was left half installed", and the
# dry-run plan counters. Both files live under .claude/.runtime/ (already excluded from the copy),
# and a normal finish takes the whole directory with it.
$script:startedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$script:lockPath = ''
$script:markerPath = ''
$script:installDone = $false
$script:writeCount = 0
$script:written = @()
$script:plan = @{ create = 0; update = 0; conflict = 0; skip = 0 }

function Write-InstallMarker([string]$status) {
  if (-not $script:markerPath) { return }
  $items = @()
  foreach ($f in $script:written) { $items += ('"' + ($f -replace '\\', '/' -replace '"', '\"') + '"') }
  $json = '{"status": "' + $status + '", "pid": ' + $PID + ', "startedAt": "' + $script:startedAt +
    '", "written": [' + ($items -join ',') + ']}'
  try { [System.IO.File]::WriteAllText($script:markerPath, $json) } catch { }
}

# Anything that throws lands here: the marker flips to interrupted and stays put (doctor.sh and the
# SessionStart banner both read it), the lock goes because the process holding it is leaving.
trap {
  if (-not $script:installDone) { Write-InstallMarker 'interrupted' }
  if ($script:lockPath) { Remove-Item $script:lockPath -Force -ErrorAction SilentlyContinue }
  Write-Host ('setup: ' + $_.Exception.Message) -ForegroundColor Red
  exit 1
}

# Count each written file (the interrupted marker carries the list) and honour the fault-injection
# hook: CC_SETUP_FAIL_AFTER=N fails right after the Nth write. Unset, none of this does anything.
function Register-Write([string]$rel) {
  $script:writeCount++
  $script:written += ($rel -replace '\\', '/')
  if ($env:CC_SETUP_FAIL_AFTER -match '^\d+$' -and $script:writeCount -ge [int]$env:CC_SETUP_FAIL_AFTER) {
    throw ("CC_SETUP_FAIL_AFTER=$($env:CC_SETUP_FAIL_AFTER) fault injection: aborting after writing " +
      "$($script:writeCount) file(s)")
  }
}

function Add-Plan([string]$kind, [string]$rel) {
  $script:plan[$kind] = $script:plan[$kind] + 1
  if ($DryRun) { Write-Output ('  {0,-8} .claude/{1}' -f $kind, $rel) }
}

# Per-segment target validation, same table as setup.sh validate_target. It runs before the first
# New-Item on purpose - "rejected, but half the directories are already there" is not a rejection.
$WinBadChars = '<>:"|?*'
$WinReserved = @('con', 'prn', 'aux', 'nul',
  'com1', 'com2', 'com3', 'com4', 'com5', 'com6', 'com7', 'com8', 'com9',
  'lpt1', 'lpt2', 'lpt3', 'lpt4', 'lpt5', 'lpt6', 'lpt7', 'lpt8', 'lpt9')
function Test-TargetPath([string]$path) {
  if (-not $path) { throw 'target directory must not be empty' }
  if ($path -eq '.') { return }
  $rest = $path
  # A leading ./ (or .\) is the documented relative form; rejecting every "." segment literally
  # would brick the two most common ways of calling this script.
  if ($rest.StartsWith('./') -or $rest.StartsWith('.\')) { $rest = $rest.Substring(2) }
  $segs = @($rest -split '[\\/]+' | Where-Object { $_ -ne '' })
  if ($segs.Count -gt 64) {
    throw "target path has too many segments: $($segs.Count), the cap is 64 (that much nesting is usually a typo): $path"
  }
  $first = $true
  foreach ($seg in $segs) {
    if ($first) {
      $first = $false
      # A drive letter (the "C:" segment) is only legal at the front; everything after it is a normal segment.
      if ($seg -match '^[A-Za-z]:$') { continue }
    }
    if ($seg -eq '..') { throw "unsafe target path: a '..' segment writes outside the target ($path)" }
    if ($seg -eq '.') { throw "invalid target path: a '.' segment in the middle ($path); only a leading ./ is allowed" }
    if ($seg -match '[\x00-\x1f\x7f]') { throw "target path segment holds a control char: [$seg] ($path)" }
    foreach ($ch in $WinBadChars.ToCharArray()) {
      if ($seg.IndexOf($ch) -ge 0) {
        throw "target path segment holds the illegal char [$ch] (Windows file names cannot carry $WinBadChars): [$seg] ($path)"
      }
    }
    if ($WinReserved -contains $seg.ToLower()) {
      throw "target path segment is a Windows reserved device name [$seg] (con/prn/aux/nul/com1-9/lpt1-9, case-insensitive): $path"
    }
    if ($seg.EndsWith('.')) { throw "target path segment ends with a dot (Windows silently eats it): [$seg] ($path)" }
    if ($seg.EndsWith(' ')) { throw "target path segment ends with a space (same as above): [$seg] ($path)" }
    if ([System.Text.Encoding]::UTF8.GetByteCount($seg) -gt 255) {
      throw "target path segment is too long: over 255 bytes: [$seg] ($path)"
    }
  }
}

$root = $PSScriptRoot
$srcClaude = Join-Path $root '.claude'
if (-not (Test-Path $srcClaude)) { throw "No .claude under the script directory (run from the cc-base repo root): $srcClaude" }

# target/.claude
Test-TargetPath $Target
if (-not $DryRun -and -not (Test-Path $Target)) { New-Item -ItemType Directory -Path $Target -Force | Out-Null }
$targetClaude = Join-Path $Target '.claude'
$runtimeDir = Join-Path $targetClaude '.runtime'

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

# Take the lock and drop the marker before the first byte is written. A lock whose pid is still
# alive means someone else is writing this target: refuse. A dead pid is the leftover of a crash
# (stale lock): say so on the way past and take it over, so a crash cannot lock the target forever.
# Creating the lock has to be atomic (mirrors setup.sh, which uses `set -o noclobber`): the old
# "Test-Path then WriteAllText" was two steps, so two setups racing could both pass the existence
# test, both write a lock and both believe they hold it. CreateNew is the O_EXCL of .NET - it
# throws when the file is already there, which folds check and write into one call. The lock stays
# one regular file at the same path, so the stale-pid reader and the cleanup that removes it are
# unchanged.
if ($DryRun) {
  Write-Host "dry-run: planning only, not a byte is written to $Target"
} else {
  if (-not (Test-Path $runtimeDir)) { New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null }
  $lockFile = Join-Path $runtimeDir 'install.lock'
  $lockTry = 0
  while ($true) {
    $lockTry++
    $lockStream = $null
    try { $lockStream = [System.IO.File]::Open($lockFile, 'CreateNew', 'Write') } catch { $lockStream = $null }
    if ($lockStream) {
      try {
        $lockBytes = [System.Text.Encoding]::UTF8.GetBytes('{"pid": ' + $PID + ', "startedAt": "' + $script:startedAt + '"}')
        $lockStream.Write($lockBytes, 0, $lockBytes.Length)
      } finally { $lockStream.Dispose() }
      break
    }
    # Losing the race has two causes: the lock is already there (normal contention), or the file
    # cannot be created at all (permissions / disk). The latter leaves no lock behind - do not
    # report it as "somebody else holds it".
    if (-not (Test-Path $lockFile)) { throw "cannot create the install lock $lockFile" }
    $holder = 0
    try {
      $lockText = Get-Content $lockFile -Raw
      if ($lockText -match '"pid"\s*:\s*(\d+)') { $holder = [int]$Matches[1] }
    } catch { $holder = 0 }
    if ($holder -gt 0 -and (Get-Process -Id $holder -ErrorAction SilentlyContinue)) {
      throw "another setup is writing this target: install.lock $lockFile is held by live pid=$holder; wait for it to finish, or delete the lock once you are sure that process is gone"
    }
    Write-Host "setup: stale install.lock $lockFile (holder pid=$holder is gone), taking over; the last install probably died halfway" -ForegroundColor Yellow
    # Taking over a stale lock deletes and re-races instead of overwriting: overwriting would be
    # two steps again. If somebody grabs it in between, the next pass re-reads the pid and checks
    # whether it is alive, so nobody ends up holding a lock they did not create.
    Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
    # Bounded retry: cleared a stale lock and still lost it a few times in a row means someone is
    # taking it over and over - fail loudly rather than spin here forever.
    if ($lockTry -ge 3) { throw "cannot win the install lock ${lockFile}: cleared a stale lock $lockTry times and it was taken again each time; make sure no other setup is running, then retry" }
  }
  $script:lockPath = $lockFile
  $script:markerPath = Join-Path $runtimeDir 'install.marker'
  Write-InstallMarker 'active'
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
  # Claude Code sub-agent worktree isolation: a whole copy of the repo under .claude/worktrees/<agent>/,
  # with its own .claude/ inside - someone else's repo, not framework files
  if ($relSlash -match '^worktrees/') { return }
  # framework self-tests / design research / this repo's agent memory: not distributed (same arms as the other three tables)
  if ($relSlash -match '^(tests|research|agent-memory)/') { return }
  # installer leftovers + editor swap files (same arms as the other three tables / .claude/.gitignore)
  if ($relSlash -match '\.(bak|framework-new|swp)$') { return }
  $dest = Join-Path $targetClaude $rel
  # Manifest layering: only when the target exists with different content do we decide
  # "safe upgrade" vs "user-modified, do not overwrite".
  if ((Test-Path $dest) -and -not (Test-FilesEqual $_.FullName $dest)) {
    $oldSha = $oldManifest[$relSlash]
    if (-not ($oldSha -and (Get-NormalizedSha $dest) -eq $oldSha)) {
      # user-modified (SHA differs from old manifest) or no old manifest (legacy install)
      Add-Plan 'conflict' $relSlash
      if (-not $DryRun) {
        Copy-Item $_.FullName "$dest.framework-new" -Force
        $script:frameworkNewList += $relSlash
        Register-Write ($relSlash + '.framework-new')
      }
      return
    }
    # else: target == old framework version, fall through to safe overwrite (with .bak)
    Add-Plan 'update' $relSlash
  } elseif (Test-Path $dest) {
    Add-Plan 'skip' $relSlash
  } else {
    Add-Plan 'create' $relSlash
  }
  if ($DryRun) { return }
  Copy-WithBackup $_.FullName $dest
  Register-Write $relSlash
}

# -WithTests: copy the framework self-tests wholesale (no manifest layering - they are the framework's
# tests, not user files, so an upgrade just replaces them). Same arm as setup.sh --with-tests.
if ($WithTests -and (Test-Path (Join-Path $srcClaude 'tests'))) {
  Get-ChildItem -Path (Join-Path $srcClaude 'tests') -Recurse -File -Force | ForEach-Object {
    $rel = $_.FullName.Substring($srcRootLen).TrimStart('/', '\')
    $relSlash = $rel -replace '\\', '/'
    Add-Plan 'create' $relSlash
    if ($DryRun) { return }
    $dest = Join-Path $targetClaude $rel
    New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
    Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
    Register-Write $relSlash
  }
}

# -DryRun stops here. The three files the copy loop does not own get planned too: settings.json is
# rewritten hook by hook so an existing one always counts as an update, the other two are plain copies.
if ($DryRun) {
  foreach ($rel in @('settings.json', 'FRAMEWORK-MANIFEST.txt', 'feedback/FEEDBACK-INDEX.md')) {
    if (Test-Path (Join-Path $targetClaude $rel)) { Add-Plan 'update' $rel } else { Add-Plan 'create' $rel }
  }
  Write-Output ('dry-run: create={0} update={1} conflict={2} skip={3} (conflict would land <file>.framework-new)' -f `
      $script:plan['create'], $script:plan['update'], $script:plan['conflict'], $script:plan['skip'])
  exit 0
}

# 3. Hook commands are taken as they ship - exec form, node runs the .mjs directly (see the header note).
#    Two things still happen here.
#    a) statusLine has no exec form; on a pure PowerShell box the string is run by PowerShell, so the project-dir
#       variable has to be spelled $env:CLAUDE_PROJECT_DIR (forward slashes, double quotes - PowerShell expands
#       $env: inside those).
$src = Get-Content (Join-Path $srcClaude 'settings.json') -Raw | ConvertFrom-Json
if ($src.PSObject.Properties['statusLine'] -and $src.statusLine.command) {
  $src.statusLine.command = 'node "$env:CLAUDE_PROJECT_DIR/.claude/scripts/statusline.mjs"'
}

#    b) drop hook files an older install of this framework left in the target: .claude/hooks/<name>.sh|.ps1 plus
#       the lib-*.sh / lib-*.ps1 helpers next to them. The framework no longer ships any of them, so copying
#       alone would leave them lying around forever and doctor.sh / gate-audit.sh would keep counting them.
$targetHooks = Join-Path $targetClaude 'hooks'
if (Test-Path $targetHooks) {
  $stale = @(Get-ChildItem $targetHooks -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq '.sh' -or $_.Extension -eq '.ps1' })
  foreach ($f in $stale) { Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue }
  if ($stale.Count -gt 0) { Write-Host "[ok] removed $($stale.Count) legacy .sh/.ps1 hook file(s) from the target" }
}

# Identity of one hook entry = command plus its args. Exec form puts the literal "node" in .command for all 21
# hooks, so keying dedup on .command alone would judge every incoming hook "already present" and merge nothing.
function Get-HookId($h) {
  $id = [string]$h.command
  if ($h.PSObject.Properties['args'] -and $h.args) {
    $id += ' ' + ((@($h.args) | ForEach-Object { [string]$_ }) -join ' ')
  }
  return $id
}

# Recursively collect the identity of every command-bearing object (for merge dedup)
function Get-AllCommands($obj) {
  $acc = New-Object System.Collections.Generic.List[string]
  function Walk($o) {
    if ($null -eq $o) { return }
    if (($o -is [System.Collections.IEnumerable]) -and ($o -isnot [string])) {
      foreach ($i in $o) { Walk $i }
    } elseif ($o -is [pscustomobject]) {
      if ($o.PSObject.Properties['command'] -and ($o.command -is [string])) { $acc.Add((Get-HookId $o)) }
      foreach ($p in $o.PSObject.Properties) { Walk $p.Value }
    }
  }
  Walk $obj
  return $acc
}

$targetSettings = Join-Path $targetClaude 'settings.json'

# Detect hook entries an older install of this framework left in the target settings - either the Git Bash ".sh"
# form or the pwsh '-Command "& ...<name>.ps1"' form - so the merge can drop them before appending the exec-form
# entries. Conservative: the command or one of its args must point at a .claude/hooks/<name>.sh|.ps1 path, which
# only the framework's own entries do; user commands stay untouched.
function Test-IsLegacyHook($h) {
  if ($null -eq $h) { return $false }
  $parts = @()
  if ($h.PSObject.Properties['command'] -and $h.command) { $parts += [string]$h.command }
  if ($h.PSObject.Properties['args'] -and $h.args) { foreach ($a in @($h.args)) { $parts += [string]$a } }
  foreach ($p in $parts) {
    if ($p -match '\.claude[/\\]hooks[/\\][A-Za-z0-9_-]+\.(sh|ps1)') { return $true }
  }
  return $false
}

# Strip legacy hook entries from every group of every event in $obj's hooks (in place).
function Remove-LegacyHooks($obj) {
  if (-not $obj.hooks) { return }
  foreach ($ev in $obj.hooks.PSObject.Properties) {
    foreach ($group in $ev.Value) {
      if ($group.hooks) {
        $group.hooks = @($group.hooks | Where-Object { -not (Test-IsLegacyHook $_) })
      }
    }
  }
}

if ((Test-Path $targetSettings) -and -not $Force) {
  # 4. target already has settings.json: strip legacy .sh/.ps1 hook entries, then only append the exec-form hook
  #    commands not present yet, leaving other user config untouched.
  $tgt = Get-Content $targetSettings -Raw | ConvertFrom-Json
  Remove-LegacyHooks $tgt
  $existing = Get-AllCommands $tgt
  if (-not $tgt.hooks) { $tgt | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) -Force }
  foreach ($event in $src.hooks.PSObject.Properties) {
    foreach ($group in $event.Value) {
      $newHooks = @($group.hooks | Where-Object { $_.command -and ($existing -notcontains (Get-HookId $_)) })
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
  Register-Write 'settings.json'
} else {
  if ((Test-Path $targetSettings) -and $Force) {
    Copy-Item $targetSettings "$targetSettings.bak" -Force
    Write-Host "backup: $targetSettings.bak"
  }
  $targetDir = Split-Path $targetSettings -Parent
  if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
  $src | ConvertTo-Json -Depth 20 | Set-Content $targetSettings -Encoding UTF8
  Register-Write 'settings.json'
}

# Reset feedback INDEX to a clean template (same source as make-release.sh; private entries were skipped above)
$fbTpl = Join-Path $srcClaude 'feedback/templates/feedback-index-template.md'
if (Test-Path $fbTpl) {
  Copy-WithBackup $fbTpl (Join-Path $targetClaude 'feedback/FEEDBACK-INDEX.md')
  Register-Write 'feedback/FEEDBACK-INDEX.md'
}

# Install the new manifest into the target (next upgrade uses it to tell
# "old framework version, safe to overwrite" from "user-modified, keep").
$srcManifest = Join-Path $srcClaude 'FRAMEWORK-MANIFEST.txt'
if (Test-Path $srcManifest) {
  Copy-WithBackup $srcManifest (Join-Path $targetClaude 'FRAMEWORK-MANIFEST.txt')
  Register-Write 'FRAMEWORK-MANIFEST.txt'
}

# Summary of user-modified files that were NOT overwritten (new versions at *.framework-new)
if ($script:frameworkNewList.Count -gt 0) {
  Write-Host ("setup: {0} file(s) modified on the target side were NOT overwritten;" -f $script:frameworkNewList.Count) -ForegroundColor Yellow
  Write-Host 'setup: new versions were written next to them as <file>.framework-new for manual merge:' -ForegroundColor Yellow
  foreach ($f in $script:frameworkNewList) { Write-Host "setup:   - .claude/$f" -ForegroundColor Yellow }
}

# Normal finish: marker and lock both go, and the empty .runtime goes with them - an empty shell left
# behind turns "runtime dirs are not installed" red in tests/test-setup.sh (5), which reads unrelated.
$script:installDone = $true
if ($script:markerPath -and (Test-Path $script:markerPath)) { Remove-Item $script:markerPath -Force }
if ($script:lockPath -and (Test-Path $script:lockPath)) { Remove-Item $script:lockPath -Force }
if ((Test-Path $runtimeDir) -and -not (Get-ChildItem $runtimeDir -Force)) { Remove-Item $runtimeDir -Force }

$hooksCount = (Get-ChildItem (Join-Path $srcClaude 'hooks') -Filter *.mjs -File -ErrorAction SilentlyContinue).Count
Write-Host "installed: mjs_hooks=$hooksCount target=$Target" -ForegroundColor Green
Write-Host "Done. Claude Code loads the hooks from $targetClaude\settings.json (exec form: node runs .claude/hooks/<name>.mjs directly, byte-identical on every platform)."
exit 0
