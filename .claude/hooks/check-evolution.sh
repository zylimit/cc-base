#!/bin/bash
# Hook: SessionStart (startup)
# 检查 FEEDBACK-INDEX.md 是否有需要处理的 feedback
# 有条目 → 输出提醒派发 evolution-runner

# fast-mode 总闸：共享库判定（.claude/.fast-mode 内 expires_epoch 未过期才静默放行；库缺失 fail-closed 不放行）
_FM_LIB="$(dirname "$0")/lib-fast-mode.sh"
if [ -f "$_FM_LIB" ]; then . "$_FM_LIB"; if fast_mode_active; then exit 0; fi; fi

FEEDBACK_INDEX="$CLAUDE_PROJECT_DIR/.claude/feedback/FEEDBACK-INDEX.md"

if [ ! -f "$FEEDBACK_INDEX" ]; then
  exit 0
fi

# 待处理 = 索引中未带「✅[已毕业]」前缀的条目（行首 "- ["）
# 总数   = 含已毕业前缀一并计数
PENDING=$(grep -c "^- \[" "$FEEDBACK_INDEX" 2>/dev/null)
PENDING=$(echo "${PENDING:-0}" | tr -d '[:space:]')
TOTAL=$(grep -cE "^- (✅\[已毕业\] )?\[" "$FEEDBACK_INDEX" 2>/dev/null)
TOTAL=$(echo "${TOTAL:-0}" | tr -d '[:space:]')

if [ "$PENDING" -gt 0 ] 2>/dev/null; then
  echo "📋 项目有 ${PENDING} 条待处理 feedback（共 ${TOTAL} 条）。建议派发 evolution-runner 检查是否有进化建议。"
fi

exit 0
