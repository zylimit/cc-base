#!/bin/bash
# Stop hook: 有项目代码待 review 时阻止停止
# 状态文件 .needs-review（按文件登记，每行一个相对路径）
# 优先级反转（防 clean 与待审路径混存被误放行）：
#   - 去掉空行与 "clean" 行后，仍有文件 = 阻止并列出
#   - 否则（只剩 clean / 全空 / 不存在）= 放行并清理
# 放行契约（向后兼容）：审查通过后 `echo clean > .claude/.needs-review` 即可。

STATE_FILE="$CLAUDE_PROJECT_DIR/.claude/.needs-review"
[ ! -f "$STATE_FILE" ] && exit 0

FILES=$(grep -vE '^[[:space:]]*$' "$STATE_FILE" 2>/dev/null | grep -vx "clean")
if [ -z "$FILES" ]; then
  rm -f "$STATE_FILE" "${STATE_FILE}.lock"
  exit 0
fi

COUNT=$(printf '%s\n' "$FILES" | wc -l | tr -d ' ')
INLINE=$(printf '%s' "$FILES" | tr '\n' ',' | sed 's/,$//; s/,/、/g')
REASON="代码已修改但未 code review（${COUNT} 个待审文件：${INLINE}）。请派发 code-reviewer sub-agent 两阶段审查；通过后执行 echo clean > .claude/.needs-review 放行。"

# shellcheck source=/dev/null
. "$(dirname "$0")/lib-gate-log.sh" 2>/dev/null || true
gate_log "stop-gate" "$REASON"

if command -v jq >/dev/null 2>&1; then
  jq -nc --arg r "$REASON" '{decision:"block",reason:$r}'
else
  echo '{"decision":"block","reason":"代码已修改但未进行 code review。请派发 code-reviewer sub-agent 进行两阶段审查，通过后 echo clean > .claude/.needs-review。"}'
fi
exit 0
