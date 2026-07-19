#!/usr/bin/env bash
# PreToolUse(Edit|Write)：检测主 Agent 是否直接写业务源码，是则警告
set -euo pipefail

# fast-mode 总闸：开关文件内 expires_epoch 未过期则本 hook 静默放行（缺行/非法一律不放行）
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ "$(sed -n 's/^expires_epoch=\([0-9]\{1,\}\)$/\1/p' "${CLAUDE_PROJECT_DIR:-}/.claude/.fast-mode" 2>/dev/null | head -1)" -gt "$(date +%s)" ] 2>/dev/null; then exit 0; fi

HOOK_INPUT=$(cat)
FILE_PATH=$(echo "$HOOK_INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('file_path','') or d.get('tool_input',{}).get('path',''))" 2>/dev/null || true)

[ -z "$FILE_PATH" ] && exit 0

# 框架文件放行（.claude/ / CLAUDE.md / Product-Spec / DEV-PLAN / progress / feedback / agents / skills / hooks / *.md）
if echo "$FILE_PATH" | grep -qE '(\.claude/|CLAUDE\.md|Product-Spec|DEV-PLAN|progress\.md|CHANGELOG|/feedback/|/agents/|/skills/|/hooks/|\.md$|\.json$|\.toml$|\.sh$|\.ps1$)'; then
  exit 0
fi

# 业务源码路径（src/ / app/ / lib/ / components/ 等），相对/绝对两种形态都拦
if echo "$FILE_PATH" | grep -qE '(^|/)(src|app|lib|components|pages|api|server|client|utils|models|services)/'; then
  echo "⚠️  [no-direct-code-guard] 主 Agent 不应直接写业务源码：$FILE_PATH" >&2
  echo "请派 implementer Sub-Agent 来编写，保持职责边界。" >&2
  # shellcheck source=/dev/null
  . "$(dirname "$0")/lib-gate-log.sh" 2>/dev/null || true
  gate_log "no-direct-code-guard" "主 Agent 直接写业务源码被拦：$FILE_PATH"
  exit 2
fi

exit 0
