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

# fast-mode 总闸：共享库判定（.claude/.fast-mode 内 expires_epoch 未过期才静默放行；库缺失 fail-closed 不放行）
_FM_LIB="$(dirname "$0")/lib-fast-mode.sh"
if [ -f "$_FM_LIB" ]; then . "$_FM_LIB"; if fast_mode_active; then exit 0; fi; fi

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
  # 大仓回执网关（catalog 存在才启用；node 缺失或 lib 不在时静默跳过、走原逻辑零行为变化）：清单已清空
  # （口头释放）后，再校验当前工作树 diff 是否有已通过回执绑定——代码越过所有已审回执（STALE, rc=4）则
  # 强制重审，此时不清状态文件、保留 .needs-review 让下轮仍拦；rc=0/3 照原样清理放行。
  # 契约外退出码（receipt verify 契约只有 0/3/4）= 引擎自己崩了、闸压根没跑成，放行就是假绿：同样拦停、
  # 点名实际退出码、保留 .needs-review，并走同一套 .stop-gate-strikes 三振熔断（引擎长期崩不至于拦死人）。
  _HARNESS_LIB="$(dirname "$0")/lib-harness.sh"
  if [ -f "$_HARNESS_LIB" ]; then
    # shellcheck source=/dev/null
    . "$_HARNESS_LIB"
    if harness_enabled && harness_node_ok; then
      # 用 if 捕获退出码：set -E/ERR trap 下裸赋值遇非零会误触 fail-closed，if 条件内命令失败不触发（rc 4/3 均属正常返回）
      # stderr 收进变量、stdout 照旧丢弃：引擎崩掉时那几行是唯一有用的线索，要带进诊断
      if RV_ERR=$(harness_run receipt verify 2>&1 >/dev/null); then RV_RC=0; else RV_RC=$?; fi
      if [ "$RV_RC" -eq 4 ]; then
        R="代码在上次审查后又有改动，无匹配的已通过回执（diff 已越过所有已审回执）。请重新派 code-reviewer 审查当前改动并写回执后再停止。"
        # shellcheck source=/dev/null
        . "$(dirname "$0")/lib-gate-log.sh" 2>/dev/null || true
        gate_log "stop-gate" "$R"
        if command -v jq >/dev/null 2>&1; then jq -nc --arg r "$R" '{decision:"block",reason:$r}'; else echo '{"decision":"block","reason":"代码在审查后又有改动，无匹配已通过回执，请重新审查。"}'; fi
        exit 0
      fi
      if ! harness_rc_in_contract "$RV_RC" 0 3; then
        # 连拦计数复用同一状态文件，sig 按退出码记（码一变即清零重计），与待审清单那套互不串味
        HSIG="harness-receipt-verify-rc$RV_RC"
        HSTRIKES=0
        if [ -f "$STRIKE_FILE" ]; then
          H_OLD_SIG=$(sed -n 's/^sig=//p' "$STRIKE_FILE" 2>/dev/null | head -1)
          H_OLD_N=$(sed -n 's/^count=//p' "$STRIKE_FILE" 2>/dev/null | head -1)
          if [ "$H_OLD_SIG" = "$HSIG" ]; then
            case "$H_OLD_N" in ''|*[!0-9]*) ;; *) HSTRIKES=$H_OLD_N ;; esac
          fi
        fi
        RV_HEAD=$(harness_err_head "$RV_ERR")
        # shellcheck source=/dev/null
        . "$(dirname "$0")/lib-gate-log.sh" 2>/dev/null || true
        if [ "$HSTRIKES" -ge 3 ]; then
          rm -f "$STRIKE_FILE"
          NOTICE="stop-gate：harness receipt verify 连续 3 次以契约外退出码 ${RV_RC} 退出（引擎异常，不是回执过期），达连拦上限本次放行——但回执绑定始终没被验过，欠账仍在，请尽快修引擎：node .claude/harness/harness.mjs receipt verify。引擎报错：${RV_HEAD}"
          gate_log "stop-gate" "$NOTICE"
          if command -v jq >/dev/null 2>&1; then
            jq -nc --arg m "$NOTICE" '{systemMessage:$m}'
          else
            printf '{"systemMessage":"stop-gate：harness receipt verify 以契约外退出码 %s 连拦达上限，本次放行；引擎仍是坏的，回执绑定未被验过，尽快修引擎。"}\n' "$RV_RC"
          fi
          exit 0
        fi
        printf 'sig=%s\ncount=%s\n' "$HSIG" "$((HSTRIKES + 1))" > "$STRIKE_FILE"
        R="stop-gate：harness receipt verify 以契约外退出码 ${RV_RC} 退出（契约只有 0/3/4），回执闸没跑成——这是引擎异常（如 .claude/harness/lib/ 缺失、node 出岔），不是回执过期。跑 node .claude/harness/harness.mjs receipt verify 看真实报错，修好引擎再停止。引擎报错：${RV_HEAD}"
        gate_log "stop-gate" "$R"
        if command -v jq >/dev/null 2>&1; then
          jq -nc --arg r "$R" '{decision:"block",reason:$r}'
        else
          printf '{"decision":"block","reason":"stop-gate：harness receipt verify 以契约外退出码 %s 退出，回执闸没跑成（引擎异常，不是回执过期）。修好引擎再停止。"}\n' "$RV_RC"
        fi
        exit 0
      fi
    fi
  fi
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
