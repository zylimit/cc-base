#!/usr/bin/env pwsh
# Hook: PostToolUse(Edit|Write) (PowerShell equivalent of mark-review-needed.sh)
# After business source is edited/created, register the file into the review list
# (.needs-review, one project-root-relative path per line).
#   - Exemptions are based on the project-root-relative path, anchored at the top level:
#     only root-level tools/ and the .claude/ framework itself are exempt
#   - Extension exemptions use a whitelist on the final segment
#   - If the previous round was clean (or the file does not exist) -> start a new list;
#     otherwise dedupe and append
$ErrorActionPreference = 'Stop'

# Fast-mode master switch via shared lib: unexpired expires_epoch -> pass through silently (lib missing => fail-closed, never passes)
try { . (Join-Path $PSScriptRoot 'lib-fast-mode.ps1'); if (Test-FastModeActive) { exit 0 } } catch {}

if (-not $env:CLAUDE_PROJECT_DIR) { exit 0 }
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new()
$raw = [Console]::In.ReadToEnd()
try { $filePath = ($raw | ConvertFrom-Json).tool_input.file_path } catch { exit 0 }
if (-not $filePath) { exit 0 }

$root = $env:CLAUDE_PROJECT_DIR
$stateFile = Join-Path $root '.claude/.needs-review'

# Project-root-relative path, normalized to forward slashes (Windows backslashes normalized,
# so the exemption regex matches the .sh version). Relative input resolves against the
# project root, then GetFullPath collapses ./.. segments; the prefix compare is
# case-insensitive because Windows paths vary in casing and separator style. Paths outside
# the project root (e.g. one-off scripts under %TEMP%) are not project code: ignore, never
# register -- while a project file must never be misjudged as outside (that would skip review).
if (-not [System.IO.Path]::IsPathRooted($filePath)) { $filePath = Join-Path $root $filePath }
# Keep the pre-collapse forms: a path that started under the root but escaped through ../
# earns one stderr line (parity with the .sh); a path that was outside all along stays silent.
$preJoin = $filePath -replace '\\', '/'
$rawRoot = ($root -replace '\\', '/').TrimEnd('/')
# Both sides through the same GetFullPath: it also expands 8.3 short names (TEMP is often
# C:\Users\ABC123~1\...), so comparing a canonicalized file against a raw root would misjudge
# project files as outside. Symmetric canonicalization keeps the compare honest.
try {
  $filePath = [System.IO.Path]::GetFullPath($filePath)
  $root = [System.IO.Path]::GetFullPath($root)
} catch { exit 0 }
$normRoot = ($root -replace '\\', '/').TrimEnd('/')
$normFile = $filePath -replace '\\', '/'
if (-not $normFile.StartsWith("$normRoot/", [System.StringComparison]::OrdinalIgnoreCase)) {
  if ($preJoin.StartsWith("$rawRoot/", [System.StringComparison]::OrdinalIgnoreCase)) {
    [Console]::Error.WriteLine("[mark-review-needed] not registered: $preJoin lands outside the project root once ./.. is collapsed; such an entry could never be cleared")
  }
  exit 0
}
$rel = $normFile.Substring($normRoot.Length).TrimStart('/')

# Exemption 1: infrastructure / framework itself (top-level anchored)
if ($rel -match '^(tools|\.claude)/') { exit 0 }
# Exemption 2: docs/config (by final-extension whitelist)
if ($rel -match '\.(md|txt|json|yaml|yml|toml|lock|log|gitignore|prettierrc|eslintrc)$') { exit 0 }
if ($rel -match '\.(env|env\.local|env\.development|env\.production|env\.test)$') { exit 0 }

# Serialize concurrent PostToolUse writers (Mutex ~ Windows flock in .sh): without it,
# concurrent invocations truncate each other's Set-Content. Mutex new failed or WaitOne
# timeout -> fall back to a bare run (parity with .sh's flock-not-available bare run).
$mut = $null
$locked = $false
try {
  $mut = New-Object System.Threading.Mutex($false, 'Global\cc-base-mark-review')
  $locked = $mut.WaitOne(2000)
} catch {
  # Mutex new failed (e.g. OOM) -> bare run, $locked stays $false
}
try {
  # If the previous round was clean (or the file does not exist) -> start a new list
  $lines = @()
  if (Test-Path $stateFile) {
    $existing = @(Get-Content $stateFile -ErrorAction SilentlyContinue)
    if ($existing -notcontains 'clean') { $lines = $existing }
  }
  # Dedupe before registering
  if ($lines -notcontains $rel) { $lines += $rel }
  Set-Content -Path $stateFile -Value $lines
} finally {
  if ($locked -and $mut) { $null = $mut.ReleaseMutex() }
}
exit 0
