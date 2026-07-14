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

# Fast-mode master switch: flag file present (and younger than the 24h TTL) -> pass through silently
if ($env:CLAUDE_PROJECT_DIR -and (Test-Path (Join-Path $env:CLAUDE_PROJECT_DIR '.claude/.fast-mode')) -and ((Get-Date) - (Get-Item (Join-Path $env:CLAUDE_PROJECT_DIR '.claude/.fast-mode')).LastWriteTime).TotalHours -lt 24) { exit 0 }

if (-not $env:CLAUDE_PROJECT_DIR) { exit 0 }
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
# Both sides through the same GetFullPath: it also expands 8.3 short names (TEMP is often
# C:\Users\ABC123~1\...), so comparing a canonicalized file against a raw root would misjudge
# project files as outside. Symmetric canonicalization keeps the compare honest.
try {
  $filePath = [System.IO.Path]::GetFullPath($filePath)
  $root = [System.IO.Path]::GetFullPath($root)
} catch { exit 0 }
$normRoot = ($root -replace '\\', '/').TrimEnd('/')
$normFile = $filePath -replace '\\', '/'
if (-not $normFile.StartsWith("$normRoot/", [System.StringComparison]::OrdinalIgnoreCase)) { exit 0 }
$rel = $normFile.Substring($normRoot.Length).TrimStart('/')

# Exemption 1: infrastructure / framework itself (top-level anchored)
if ($rel -match '^(tools|\.claude)/') { exit 0 }
# Exemption 2: docs/config (by final-extension whitelist)
if ($rel -match '\.(md|txt|json|yaml|yml|toml|lock|log|gitignore|prettierrc|eslintrc)$') { exit 0 }
if ($rel -match '\.(env|env\.local|env\.development|env\.production|env\.test)$') { exit 0 }

# If the previous round was clean (or the file does not exist) -> start a new list
$lines = @()
if (Test-Path $stateFile) {
  $existing = @(Get-Content $stateFile -ErrorAction SilentlyContinue)
  if ($existing -notcontains 'clean') { $lines = $existing }
}
# Dedupe before registering
if ($lines -notcontains $rel) { $lines += $rel }
Set-Content -Path $stateFile -Value $lines
exit 0
