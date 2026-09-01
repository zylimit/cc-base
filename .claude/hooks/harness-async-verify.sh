#!/bin/bash
# PostToolUse(Edit|Write)：大仓定向门的后台早警——asyncRewake 形态（settings 里
# async+asyncRewake 注册，本脚本只管跑与退出码）。
# 与 pre-commit-check 的关系：commit 闸仍是同步硬门；本 hook 在两次 commit 之间的编辑期
# 后台跑同一套 harness verify（四态门+五性证据门），FAIL/BLOCKED 时 exit 2 唤醒主 Agent
# 读 stderr 摘要——失败早暴露（fail-visible），不挤占交互时延。
# 启用条件与降级：catalog + node 双满足才跑（lib-harness 守卫）；fast-mode 放行（质量闸）；
# 180 秒防抖（.async-verify-last 记上次运行 epoch，异步并发场景先写后跑防风暴）。
# 摘要预算：只回 gate + 失败/受阻 check 前 5 条 + 属性缺口计数，不贴全量 JSON。

# fast-mode 总闸：共享库判定（.claude/.fast-mode 内 expires_epoch 未过期才静默放行；库缺失 fail-closed 不放行）
_FM_LIB="$(dirname "$0")/lib-fast-mode.sh"
if [ -f "$_FM_LIB" ]; then . "$_FM_LIB"; if fast_mode_active; then exit 0; fi; fi

# 消费 stdin（file_path 不用——verify 自己从 git 工作树算 changed 集）
cat >/dev/null 2>&1 || true

_HARNESS_LIB="$(dirname "$0")/lib-harness.sh"
[ -f "$_HARNESS_LIB" ] || exit 0
# shellcheck source=/dev/null
. "$_HARNESS_LIB"
harness_enabled || exit 0
harness_node_ok || exit 0

ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
MARK="$ROOT/.claude/.async-verify-last"
NOW=$(date +%s 2>/dev/null || echo 0)
if [ -f "$MARK" ]; then
  LAST=$(sed -n 's/^\([0-9]\{1,\}\)$/\1/p' "$MARK" 2>/dev/null | head -1)
  case "$LAST" in
    ''|*[!0-9]*) ;;
    *) if [ $((NOW - LAST)) -lt 180 ]; then exit 0; fi ;;
  esac
fi
printf '%s\n' "$NOW" > "$MARK" 2>/dev/null || true

ERRF=$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/cc-async-verify.$$")
OUT=$(harness_run verify 2>"$ERRF")
RC=$?
ERR_HEAD=$(harness_err_head "$(cat "$ERRF" 2>/dev/null)")
rm -f "$ERRF"

# 契约外退出码（verify 契约只有 0/2/3）= 引擎自己崩了、门没跑成。早警不硬拦（commit 硬门仍是
# pre-commit-check），但闸跑不起来这件事同样得说话——照唤醒形态发一条可见诊断，不静默 exit 0 吞掉。
if ! harness_rc_in_contract "$RC" 0 2 3; then
  echo "[harness-async-verify] 编辑期后台质量门跑不起来：harness verify 以契约外退出码 $RC 退出（契约只有 0/2/3）。" >&2
  printf '%s\n' "${ERR_HEAD:-（引擎无 stderr 输出）}" >&2
  echo "这是引擎异常（如 .claude/harness/lib/ 缺失、node 出岔），不是门未过；commit 时 pre-commit-check 会硬拦，建议现在就修引擎。" >&2
  # shellcheck source=/dev/null
  . "$(dirname "$0")/lib-gate-log.sh" 2>/dev/null || true
  gate_log "harness-async-verify" "后台 verify 以契约外退出码 $RC 退出（引擎异常，早警）"
  exit 2
fi
[ "$RC" -eq 2 ] || exit 0

SUMMARY=$(printf '%s' "$OUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
gate = d.get('gate', d.get('state', 'FAIL'))
bad = [c for c in d.get('checks', []) if c.get('state') in ('FAIL', 'BLOCKED')]
lines = ['gate=' + str(gate)]
if d.get('emptyPlan'):
    lines.append('空验证计划：受影响模块没有任何 check（配置缺口，不算绿）')
for c in bad[:5]:
    lines.append('- %s [%s] %s %s' % (c.get('module', '?'), c.get('state'), c.get('id'), c.get('reason') or ('exit=' + str(c.get('exit')))))
if len(bad) > 5:
    lines.append('- …另有 %d 条' % (len(bad) - 5))
gaps = d.get('attributeGaps') or []
if gaps:
    lines.append('五性证据缺口 %d 处（critical/high 属性缺认领 PASS）' % len(gaps))
print('\n'.join(lines))
" 2>/dev/null) || SUMMARY="verify rc=2（FAIL/BLOCKED 或五性证据缺口）——跑 node .claude/harness/harness.mjs verify 看全量"

echo "[harness-async-verify] 编辑期后台质量门未过：" >&2
printf '%s\n' "$SUMMARY" >&2
echo "commit 前会被 pre-commit-check 硬拦，建议现在就修或派 bug-fixer。" >&2
# shellcheck source=/dev/null
. "$(dirname "$0")/lib-gate-log.sh" 2>/dev/null || true
gate_log "harness-async-verify" "后台 verify 未过（早警，非硬拦）"
exit 2
