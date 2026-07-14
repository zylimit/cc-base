#!/bin/bash
# Stop hook: 有项目代码待 review 时阻止停止
# 状态文件 .needs-review（按文件登记，每行一个相对路径）
# 优先级反转（防 clean 与待审路径混存被误放行）：
#   - 去掉空行与 "clean" 行后，仍有文件 = 阻止并列出
#   - 否则（只剩 clean / 全空 / 不存在）= 放行并清理
# 连拦上限（防死锁）：.stop-gate-strikes（sig=/count= 两行自描述，损坏当无状态重建）记
#   同一待审清单被连拦的次数——子代理场景无法自行派 reviewer 满足闸条件，会被无限重验。
#   同一清单连拦 3 次后第 4 次放行并醒目提示欠账仍在；正常放行或清单变化即清零重计。
# 放行契约（向后兼容）：审查通过后 `echo clean > .claude/.needs-review` 即可。

# fast-mode 总闸：开关文件存在且未过 24h TTL 则本 hook 静默放行
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -f "${CLAUDE_PROJECT_DIR:-}/.claude/.fast-mode" ] && [ -n "$(find "${CLAUDE_PROJECT_DIR:-}/.claude/.fast-mode" -mmin -1440 2>/dev/null)" ]; then exit 0; fi

# fail-closed：脚本自身出错绝不静默放行，一律拦停（与 .ps1 侧 trap 对齐）。
_fail_closed() {
  local m="stop-gate 自检失败，fail-closed 拦停——请修复闸/状态文件后重试停止。"
  if command -v jq >/dev/null 2>&1; then jq -nc --arg r "$m" '{decision:"block",reason:$r}'; else echo '{"decision":"block","reason":"stop-gate 自检失败，fail-closed 拦停。"}'; fi
  exit 0
}
set -E
trap _fail_closed ERR

STATE_FILE="$CLAUDE_PROJECT_DIR/.claude/.needs-review"
STRIKE_FILE="$CLAUDE_PROJECT_DIR/.claude/.stop-gate-strikes"
if [ ! -f "$STATE_FILE" ]; then rm -f "$STRIKE_FILE"; exit 0; fi

# grep 无匹配返回 1 属正常（清单只剩 clean/全空），|| true 防 fail-closed 误触
FILES=$(grep -vE '^[[:space:]]*$' "$STATE_FILE" 2>/dev/null | grep -vx "clean" || true)
if [ -z "$FILES" ]; then
  rm -f "$STATE_FILE" "${STATE_FILE}.lock" "$STRIKE_FILE"
  exit 0
fi

COUNT=$(printf '%s\n' "$FILES" | wc -l | tr -d ' ')
INLINE=$(printf '%s' "$FILES" | tr '\n' ',' | sed 's/,$//; s/,/、/g')

# 连拦计数：只对同一待审清单指纹累加，清单一变即清零重计
SIG=$(printf '%s\n' "$FILES" | sort | cksum | awk '{print $1 "-" $2}')
STRIKES=0
if [ -f "$STRIKE_FILE" ]; then
  OLD_SIG=$(sed -n 's/^sig=//p' "$STRIKE_FILE" 2>/dev/null | head -1)
  OLD_N=$(sed -n 's/^count=//p' "$STRIKE_FILE" 2>/dev/null | head -1)
  if [ "$OLD_SIG" = "$SIG" ]; then
    case "$OLD_N" in ''|*[!0-9]*) ;; *) STRIKES=$OLD_N ;; esac
  fi
fi
if [ "$STRIKES" -ge 3 ]; then
  rm -f "$STRIKE_FILE"
  NOTICE="stop-gate：同一待审清单连续拦截已达 3 次上限，本次放行——但待审清单未清空（${COUNT} 个欠账仍在：${INLINE}），条件允许时务必尽快派 code-reviewer 审查。"
  # shellcheck source=/dev/null
  . "$(dirname "$0")/lib-gate-log.sh" 2>/dev/null || true
  gate_log "stop-gate" "$NOTICE"
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg m "$NOTICE" '{systemMessage:$m}'
  else
    echo '{"systemMessage":"stop-gate：同一待审清单连续拦截已达 3 次上限，本次放行；待审清单未清空，欠账仍在，尽快派 code-reviewer。"}'
  fi
  exit 0
fi
printf 'sig=%s\ncount=%s\n' "$SIG" "$((STRIKES + 1))" > "$STRIKE_FILE"
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
