#!/usr/bin/env bash
# PreToolUse(Bash)：拦截 pkill -f 宽泛匹配，防止误杀主 Agent 进程
set -euo pipefail

HOOK_INPUT=$(cat)
CMD=$(echo "$HOOK_INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('command',''))" 2>/dev/null || true)

[ -z "$CMD" ] && exit 0

# 锚定命令起始/分隔符，只拦真实执行的 pkill -f，放过 echo/grep "pkill -f" 字符串
if echo "$CMD" | grep -qE '(^|;|&&|\|\||`|\$\()\s*pkill\s+-f'; then
  echo "⛔ [dangerous-pkill-guard] 检测到 pkill -f 宽泛匹配，已拦截。" >&2
  echo "宽泛 pkill -f 会误杀主 Agent 自身进程（shell wrapper 含相同关键词）。" >&2
  echo "正确做法：先用 ps/pgrep 拿精确 PID，再 kill <PID>。" >&2
  # shellcheck source=/dev/null
  . "$(dirname "$0")/lib-gate-log.sh" 2>/dev/null || true
  gate_log "dangerous-pkill-guard" "拦截 pkill -f 宽泛匹配"
  exit 2
fi

exit 0
