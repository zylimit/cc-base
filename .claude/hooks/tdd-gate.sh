#!/usr/bin/env bash
# PreToolUse(Bash)：TDD 闸门建议提示（非硬拦截，仅提醒）
# 检测是否在没有 .red-verified / .tdd-exempt 的情况下派 implementer 写代码
set -euo pipefail

HOOK_INPUT=$(cat)
CMD=$(echo "$HOOK_INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('command',''))" 2>/dev/null || true)

[ -z "$CMD" ] && exit 0

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# 只对看起来是在启动 implementer 的命令触发
if echo "$CMD" | grep -qiE '(implementer|dev-builder|GREEN|编码实现)'; then
  if [ ! -f "$PROJECT_ROOT/.claude/.red-verified" ] && [ ! -f "$PROJECT_ROOT/.claude/.tdd-exempt" ]; then
    echo "TDD 闸门：派 implementer 做 GREEN 实现前须先完成 RED。" >&2
    echo "高价值逻辑（契约/解析器/状态机/去重/schema 校验/驱动适配层等）：先派 tester 出失败测试 → 验红 → touch .claude/.red-verified，再派 implementer 写最简实现到绿。" >&2
    echo "若本 Task 是 UI/样式/非 TDD 逻辑：touch .claude/.tdd-exempt 显式声明豁免。" >&2
    # 建议性提示，不硬拦截（与文件头注释一致）
    exit 0
  fi
fi

exit 0
