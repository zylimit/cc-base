#!/bin/bash
# Fail-safe gate block ledger. Source from block hooks and call gate_log <hook> <reason>.

gate_log() {
  local hook_name=${1:-unknown}
  local reason=${2:-}
  local project_dir=${CLAUDE_PROJECT_DIR:-}
  local first_line ts dir

  [ -n "$project_dir" ] || return 0
  first_line=$(printf '%s' "$reason" | sed -n '1p')
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || return 0
  dir="$project_dir/.claude/evidence"
  mkdir -p "$dir" 2>/dev/null || return 0
  printf '%s\t%s\t%s\n' "$ts" "$hook_name" "$first_line" >>"$dir/gate-block.log" 2>/dev/null || true
  return 0
}
