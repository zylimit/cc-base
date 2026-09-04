#!/usr/bin/env pwsh
# Hook: PostToolUse(Edit|Write|NotebookEdit) (PowerShell equivalent of record-authorship.sh)
# Feeds the authorship ledger: who wrote which file goes to `harness authorship record`, so the
# "the reviewer is never the author" rule that review verdict wants to apply has data to apply
# it to. The engine capability existed with nothing calling it, which left the ledger empty and
# every verdict reporting authorshipEnforced:false -- a rule that lived only in prose.
# Who counts as the author: agent_type first (the role name is the same key the review side
# passes to `review lens --agent <id>`), falling back to agent_id, and `main` when neither is
# present (the main Agent wrote it). agentType carries the raw agent_type (an empty string is
# normalized to null by the engine); agentId is the matching key.
# Enablement and degradation: runs only with catalog + node both present (lib-harness guards) --
# large-repo governance is off by default, so with no catalog this exits 0 immediately, writing
# nothing and calling nothing.
# This is bookkeeping, not a gate: every internal failure exits 0 (a non-zero PostToolUse exit
# code would feed back into the tool result) and writes one stderr line. The per-hook timeout
# registered in settings.json caps a hung engine call.
$ErrorActionPreference = 'Stop'

# Fast-mode master switch via shared lib: unexpired expires_epoch -> pass through silently (lib missing => fail-closed, never passes)
try { . (Join-Path $PSScriptRoot 'lib-fast-mode.ps1'); if (Test-FastModeActive) { exit 0 } } catch {}

trap { exit 0 }

[Console]::InputEncoding = [System.Text.UTF8Encoding]::new()
$raw = [Console]::In.ReadToEnd()

. (Join-Path $PSScriptRoot 'lib-harness.ps1')
if (-not (Test-HarnessEnabled)) { exit 0 }
$node = Get-HarnessNode
if (-not $node) { exit 0 }

# Test-HarnessEnabled already guarantees CLAUDE_PROJECT_DIR is set
$root = $env:CLAUDE_PROJECT_DIR
$script = Join-Path $root '.claude/harness/harness.mjs'

try { $evt = $raw | ConvertFrom-Json } catch { exit 0 }
if (-not $evt) { exit 0 }

# NotebookEdit spells the path notebook_path, not file_path -- reading only one silently loses
# every notebook edit from the ledger
$filePath = $evt.tool_input.file_path
if (-not $filePath) { $filePath = $evt.tool_input.notebook_path }
if (-not $filePath) { exit 0 }

$agentType = $evt.agent_type
if (-not $agentType) { $agentType = '' }
$author = $agentType
if (-not $author) { $author = $evt.agent_id }
if (-not $author) { $author = 'main' }

# Paths outside the project root (e.g. one-off scripts under %TEMP%) never appear in any diff,
# so recording them could only ever produce entries nothing can match. Relative input resolves
# against the project root; both sides go through the same GetFullPath so 8.3 short names and
# separator style cannot invent a mismatch between two spellings of the same directory.
if (-not [System.IO.Path]::IsPathRooted($filePath)) { $filePath = Join-Path $root $filePath }
try {
  $filePath = [System.IO.Path]::GetFullPath($filePath)
  $root = [System.IO.Path]::GetFullPath($root)
} catch { exit 0 }
$normRoot = ($root -replace '\\', '/').TrimEnd('/')
$normFile = $filePath -replace '\\', '/'
if (-not $normFile.StartsWith("$normRoot/", [System.StringComparison]::OrdinalIgnoreCase)) { exit 0 }
# Forward-slashed, project-root-relative: what the engine compares against (core.mjs toPosixPath
# / changedSet). Normalize where the path is produced, not in the consumer.
$rel = $normFile.Substring($normRoot.Length).TrimStart('/')
if (-not $rel) { exit 0 }

# Build the payload field by field through ConvertTo-Json so quotes, backslashes and non-ASCII
# in a filename are escaped by the serializer. Hand-assembled JSON eventually assembles badly,
# and a single-element array through a hashtable is exactly where ConvertTo-Json has historically
# collapsed the array into a scalar.
$payload = '{"agentId":' + (ConvertTo-Json -InputObject $author -Compress) `
  + ',"agentType":' + (ConvertTo-Json -InputObject $agentType -Compress) `
  + ',"files":[' + (ConvertTo-Json -InputObject $rel -Compress) + ']}'

# PS 5.1 with EAP=Stop turns a native program's stderr into a terminating error, which would
# skip the $LASTEXITCODE check; relax it for this one call and drop the engine's stderr.
$prev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$code = 0
try {
  Push-Location -LiteralPath $root
  try {
    # cd into the project root: record computes baseCommit from git in the cwd, and the wrong
    # cwd records an unrelated repository's HEAD
    $payload | & $node $script authorship record 2>$null | Out-Null
    $code = $LASTEXITCODE
  } finally {
    Pop-Location
  }
} finally {
  $ErrorActionPreference = $prev
}

if ($code -ne 0) {
  [Console]::Error.WriteLine("[record-authorship] authorship not recorded ($rel <- $author): harness authorship record exited $code")
}
exit 0
