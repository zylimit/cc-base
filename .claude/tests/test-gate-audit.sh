#!/usr/bin/env bash
# risk: low
# test-gate-audit.sh — gate-audit 误报回归测试（无依赖 claude CLI）。
# 契约：「(b) 零记录死闸」段只该列**真闸**（import gatelog.mjs、经 gateLog 写账本的 block 钩子）
#   里从没拦过的那些；信息类 hook 不是闸，列进去就是误报死闸，把噪声当治理负债。真闸/信息类的
#   判据 = 钩子源码里有没有 gatelog（独立于 gate-audit 自身实现，按 Spec 取真值）。
# 另带一条防空转：注册闸集合若算成空集，(b) 段恒空——「没有死闸」与「压根没算」输出一模一样，
#   只有把 (c) 的注册数与本文件自己数出的真闸数对拍才分得开。扫真实 cc-base .claude/，锁
#   「(b) 段不含某名」与「注册数对得上」，不锁易变的拦截计数。
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

# 真闸 / 信息类都从 hooks/*.mjs 现算（lib/ 是子目录，不被 * 匹配到，不用额外排除）：
#   注册 = settings.json 的 args[0] 里出现 hooks/<name>.mjs（exec form 之后路径只在 args 里，
#          不再有 command 字符串可 grep；static-check 不注册，天然落选）
#   真闸 = 源码里出现 gatelog（import hooks/lib/gatelog.mjs 的那批）
info_only=()
real_gates=()
for h in "$CLAUDE_DIR"/hooks/*.mjs; do
  [ -f "$h" ] || continue
  base=$(basename "$h" .mjs)
  grep -q "/hooks/${base}\.mjs\"" "$CLAUDE_DIR/settings.json" 2>/dev/null || continue
  if grep -q 'gatelog' "$h" 2>/dev/null; then
    real_gates+=("$base")
  else
    info_only+=("$base")
  fi
done

[ "${#info_only[@]}" -gt 0 ] || { echo "test-gate-audit: 没探到任何信息类 hook，断言前提不成立" >&2; exit 1; }
[ "${#real_gates[@]}" -gt 0 ] || { echo "test-gate-audit: 没探到任何真闸，断言前提不成立（settings 的 args 里一个 hooks/*.mjs 都没有？）" >&2; exit 1; }

# 防空转断言：(c) 汇总里的「注册钩子」数必须等于本文件自己数出来的真闸数。
# gate-audit 若还按 hooks/*.sh 现算注册清单，迁移后它会数出 0 个，(b) 段随之恒空——
# 下面那组「信息类不在 (b) 里」会全绿，而闸其实早就不看了。
REG_N=$(printf '%s\n' "$OUT" | sed -n 's/.*注册钩子[^0-9]*\([0-9][0-9]*\).*/\1/p' | head -1)
if [ "${REG_N:-x}" = "${#real_gates[@]}" ]; then
  pass "(c) 注册钩子数 = 源码里的真闸数（$REG_N 个）"
else
  fail "(c) 注册钩子数 $REG_N != 源码里的真闸数 ${#real_gates[@]}（真闸：${real_gates[*]}）——gate-audit 的注册清单算错了或压根没算"
fi

# 核心断言：(b) 死闸段**不该**出现任何信息类 hook。
for h in "${info_only[@]}"; do
  if printf '%s\n' "$SECTION_B" | grep -qE "•[[:space:]]+${h}\$"; then
    fail "信息类 hook 被误列进 (b) 死闸段：$h（它不调 gateLog，不是闸）"
  else
    pass "信息类 hook 未出现在 (b) 死闸段：$h"
  fi
done

echo ""
echo "==== test-gate-audit：PASS=$PASS FAIL=$FAIL ===="
if [ "$FAIL" -gt 0 ]; then
  echo "test-gate-audit: failed（注册闸清单算错，或信息类 hook 被误报为死闸；(b) 段实际内容如下）" >&2
  printf '%s\n' "$SECTION_B" | sed 's/^/    /' >&2
  exit 1
fi
echo "test-gate-audit: passed（注册闸数对得上，(b) 死闸段不含任何信息类 hook）"
