#!/usr/bin/env bash
# test-gate-audit.sh — gate-audit 误报回归测试（无依赖 claude CLI）。
# 契约：「(b) 零记录死闸」段只该列**真闸**（source 了 lib-gate-log、能经 gate_log 写账本的
#   block 钩子）里从没拦过的那些；信息类 hook（不调 gate_log、永不拦截）不是闸，列进去
#   就是误报死闸，把噪声当治理负债。
# 真闸/信息类的判据 = 钩子脚本里有没有 gate_log（独立于 gate-audit 自身实现，按 Spec 取真值）。
# 红测试：现状把 auto-push / session-rules-banner 等信息类 hook 列进 (b) → 本测试 FAIL；
#   修复（gate-audit 只把真闸纳入注册闸集合）后 → PASS。
# 扫的是真实 cc-base .claude/，断言锁「(b) 段不含某名」而非易变计数。
set -eu

CLAUDE_DIR=$(cd "$(dirname "$0")/.." && pwd)
AUDIT="$CLAUDE_DIR/scripts/gate-audit.sh"
[ -x "$AUDIT" ] || { echo "test-gate-audit: 缺 gate-audit.sh：$AUDIT" >&2; exit 1; }

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  [PASS] $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }

# 跑 gate-audit，从仓库根扫真实账本。
OUT=$(cd "$CLAUDE_DIR/.." && bash "$AUDIT" 2>&1) || { echo "test-gate-audit: gate-audit 执行失败" >&2; echo "$OUT" >&2; exit 1; }

# 抽「(b) 零记录」段：自 (b) 标题行起，至 (c) 汇总标题前止。
SECTION_B=$(printf '%s\n' "$OUT" | awk '/\(b\) 零记录/{f=1;next} /\(c\) 汇总/{f=0} f')

# 信息类 hook = 注册了但脚本里没有 gate_log（永不拦截，不是闸）。按 Spec 取真值。
info_only=()
for h in "$CLAUDE_DIR"/hooks/*.sh; do
  base=$(basename "$h" .sh)
  case "$base" in lib-*) continue ;; esac
  # 只看注册在 settings.json 里的钩子
  grep -qE "hooks/${base}\.sh" "$CLAUDE_DIR/settings.json" 2>/dev/null || continue
  if ! grep -q 'gate_log' "$h" 2>/dev/null; then
    info_only+=("$base")
  fi
done

[ "${#info_only[@]}" -gt 0 ] || { echo "test-gate-audit: 没探到任何信息类 hook，断言前提不成立" >&2; exit 1; }

# 核心断言：(b) 死闸段**不该**出现任何信息类 hook。
for h in "${info_only[@]}"; do
  if printf '%s\n' "$SECTION_B" | grep -qE "•[[:space:]]+${h}\$"; then
    fail "信息类 hook 被误列进 (b) 死闸段：$h（它不调 gate_log，不是闸）"
  else
    pass "信息类 hook 未出现在 (b) 死闸段：$h"
  fi
done

echo ""
echo "==== test-gate-audit：PASS=$PASS FAIL=$FAIL ===="
if [ "$FAIL" -gt 0 ]; then
  echo "test-gate-audit: failed（gate-audit 把信息类 hook 误报为死闸；(b) 段实际内容如下）" >&2
  printf '%s\n' "$SECTION_B" | sed 's/^/    /' >&2
  exit 1
fi
echo "test-gate-audit: passed（(b) 死闸段不含任何信息类 hook）"
