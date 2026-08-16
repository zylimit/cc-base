#!/usr/bin/env pwsh
# Hook: PreToolUse(Bash) (PowerShell equivalent of secret-exfil-guard.sh)
# Secret read/copy/exfiltration gate -- makes "secrets/privacy are a safety rail" a
# machine-enforced block. Blocks three high-confidence actions (anchored to command
# start/separators so echo/grep string mentions pass):
#   R1 reading secret files: cat/less/head/tail/strings/xxd/od on the .env family /
#      id_rsa / *.pem / credentials (reading .env.example/.sample/.template/.dist is
#      legitimate and is stripped before matching)
#   R2 copying/moving secret files: cp/scp/rsync/mv hitting the same secret-file set
#   R3 bulk env exfiltration: env/printenv/set piped into curl/wget/nc
# Wrapper stripping: peel sudo/nohup/nice/timeout/env prefixes and bash -c quote shells
# before judging -- wrapping is a known gate-escape path (borrowed from codex-base v3);
# both the original and the stripped form are checked.
# This is a safety rail: fast-mode does NOT bypass it. If JSON parsing fails, degrade
# open (same trade-off as dangerous-pkill-guard -- never misfire on normal commands).
$ErrorActionPreference = 'Stop'

[Console]::InputEncoding = [System.Text.UTF8Encoding]::new()
$raw = [Console]::In.ReadToEnd()
try { $cmd = ($raw | ConvertFrom-Json).tool_input.command } catch { exit 0 }
if (-not $cmd) { exit 0 }

# Remove legitimate example filenames before matching (.env.example is not a secret)
function Strip-Examples([string]$c) {
  return ($c -replace '\.env\.(example|sample|template|dist)[A-Za-z0-9_.-]*', '')
}

# Iteratively peel sudo/nohup/nice/timeout/env prefixes and shell -c quote shells (max 5 layers)
function Strip-Wrappers([string]$c) {
  $prev = ''
  $i = 0
  while (($c -ne $prev) -and ($i -lt 5)) {
    $prev = $c
    $i++
    $c = $c.TrimStart()
    $c = $c -replace '^sudo\s+', ''
    $c = $c -replace '^nohup\s+', ''
    $c = $c -replace '^nice(\s+-n\s*\d+)?\s+', ''
    $c = $c -replace '^timeout(\s+--?[A-Za-z-]+(\s+\S+)?)*\s+\d+[smhd]?\s+', ''
    $c = $c -replace '^env(\s+[A-Za-z_][A-Za-z0-9_]*=\S*)*\s+', ''
    $c = $c -replace "^(ba|z|da)?sh\s+-l?c\s+[`"']?", ''
    $c = $c -replace "[`"']$", ''
  }
  return $c
}

# Secret-file core set (.pem/.ppk hit at any path; trailing boundary avoids .env2/.envoy)
$secretCore = '(\.env(\.[A-Za-z0-9_-]+)?|id_rsa[A-Za-z0-9_.-]*|id_ed25519[A-Za-z0-9_.-]*|\S*\.(pem|ppk)|credentials\.json|\.aws/credentials|\.ssh/\S+)([\s"'']|$)'
# Argument prefix: right after the verb (the space itself is the boundary) or after any
# arguments with a space/slash/quote/= boundary -- both count as a hit
$argPfx = '\s+([^|;&]*[\s/"''=@])?'
$anchor = '(^|;|&&|\|\||`|\$\()\s*'

$script:reason = ''
function Check-One([string]$c) {
  $c = Strip-Examples $c
  if ($c -match "${anchor}(cat|less|more|head|tail|strings|xxd|od|bat|grep|rg|awk|sed)${argPfx}${secretCore}") {
    $script:reason = 'detected a direct read of a secret file (cat/head etc. + .env/id_rsa/*.pem/credentials)'
    return $true
  }
  if ($c -match "${anchor}(cp|scp|rsync|mv)${argPfx}${secretCore}") {
    $script:reason = 'detected copying/moving a secret file (cp/scp/rsync/mv + secret filename)'
    return $true
  }
  if ($c -match "${anchor}(env|printenv|set)\b[^|]*\|\s*(curl|wget|nc)\b") {
    $script:reason = 'detected bulk environment exfiltration via pipe (env/printenv | curl/wget/nc)'
    return $true
  }
  if ($c -match "${anchor}(curl|wget|nc)${argPfx}${secretCore}") {
    $script:reason = 'detected a network command carrying a secret file (curl/wget/nc + secret filename)'
    return $true
  }
  return $false
}

$stripped = Strip-Wrappers $cmd
$hit = Check-One $cmd
if (-not $hit -and ($stripped -ne $cmd)) { $hit = Check-One $stripped }

if ($hit) {
  [Console]::Error.WriteLine("[BLOCKED] [secret-exfil-guard] $($script:reason); blocked.")
  [Console]::Error.WriteLine("Secrets/privacy are a safety rail; Fast Mode does not exempt them. Correct approaches:")
  [Console]::Error.WriteLine("- To learn the config structure -> read .env.example / docs, never the real secret file")
  [Console]::Error.WriteLine("- To actually operate on secrets (rotation/migration) -> stop and let the user run it personally")
  [Console]::Error.WriteLine("- To use a single env var -> reference it by name, never dump/export the whole environment")
  try { . (Join-Path $PSScriptRoot 'lib-gate-log.ps1'); Write-GateLog 'secret-exfil-guard' $script:reason } catch { }
  exit 2
}
exit 0
