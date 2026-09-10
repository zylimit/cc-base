#!/usr/bin/env bash
# risk: low
# test-three-file-sync-gate.sh — 三文件同步闸的改动集回归（无依赖 claude CLI）。
# 契约：一个工作单元若有未提交的代码/**家底**改动而 progress.md 未同步，Stop 闸须出提醒。
#   家底 = .claude/** 下的可控文件（CLAUDE.md / agents / skills / settings.json 等），只有
#   .claude/evidence/（账本，机器写）除外。本闸三档都是 advise：出 systemMessage、不出
#   decision:block——围绕「拦停」写的断言已随 Phase A 作废，这里判「有提醒且没拦」。
# 留一正一反（2026-09-10 预算表）：家底 .md 改动要提醒（扩展名表漏 .md/.json 的老形态）、
#   evidence 账本不提醒（边界）；未跟踪新目录、普通代码对照那批退休。临时仓建 mktemp，trap 清理。
set -eu

SRC=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$SRC/hooks/three-file-sync-gate.mjs"
# .mjs 由 node 拉起，不需要执行位（执行位只对 shebang 生效）——判 -f 就够，判 -x 会变成恒红。
[ -f "$HOOK" ] || { echo "test-three-file-sync-gate: 缺 hook：$HOOK" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "test-three-file-sync-gate: 无 node——hook 是 .mjs，跑不起来；未执行 != 通过。" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  [PASS] $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }
# 干净的临时仓：progress.md + 家底 + evidence 账本 + 档位表，全部已提交。
# 档位表随仓一起装并提交：不装就是在测一条不存在的兼容路径，未跟踪则会把沙箱抬成 strict。
fresh_repo() {
  local t="$1"
  rm -rf "$t"
  mkdir -p "$t/.claude/agents" "$t/.claude/evidence" "$t/.claude/harness" "$t/src"
  cp "$SRC/harness/profile.json" "$t/.claude/harness/profile.json" 2>/dev/null || true
  git -C "$t" init -q
  git -C "$t" config user.email t@t.t; git -C "$t" config user.name t
  printf '# progress\n' > "$t/progress.md"
  printf '# claude\n' > "$t/.claude/CLAUDE.md"; printf '# agent\n' > "$t/.claude/agents/impl.md"
  printf 'echo hi\n' > "$t/src/app.sh"; printf 'log\n' > "$t/.claude/evidence/gate-block.log"
  git -C "$t" add -A >/dev/null 2>&1; git -C "$t" -c commit.gpgsign=false commit -qm init >/dev/null 2>&1
}

run_gate() { CLAUDE_PROJECT_DIR="$1" node "$HOOK" 2>/dev/null; }
advised() {
  case "$1" in *'"systemMessage"'*) ;; *) return 1 ;; esac
  case "$1" in *'"decision":"block"'*|*'"decision": "block"'*) return 1 ;; esac
  return 0
}

echo "===== test-three-file-sync-gate ====="

echo "── 红：只改家底文件，progress 未同步 → 应出提醒 ──"
t="$TMP/repo"; fresh_repo "$t"
printf 'changed\n' >> "$t/.claude/CLAUDE.md"
out=$(run_gate "$t")
if advised "$out"; then
  pass "改家底 .claude/CLAUDE.md（progress 未同步）→ 闸出 systemMessage 提醒且不 block"
else
  fail "改家底 .claude/CLAUDE.md（progress 未同步）→ 漏判或改成了硬拦（期望 systemMessage 且无 decision:block，实得：[${out}]）"
fi

echo "── 边界：只改 .claude/evidence/ 账本，progress 未同步 → 不该出声 ──"
fresh_repo "$t"
printf 'more log\n' >> "$t/.claude/evidence/gate-block.log"
out=$(run_gate "$t")
if [ -z "$out" ]; then
  pass ".claude/evidence/ 改动 → 闸放行（账本机器写，不计入家底）"
else
  fail ".claude/evidence/ 改动被判成家底改动了（期望零输出，实得：[${out}]）"
fi

echo ""
echo "==== test-three-file-sync-gate：PASS=$PASS FAIL=$FAIL ===="
if [ "$FAIL" -gt 0 ]; then
  echo "test-three-file-sync-gate: failed（见上方 FAIL 行：闸的改动集有漏判）" >&2
  exit 1
fi
echo "test-three-file-sync-gate: passed（家底改动出提醒、evidence 放行均符合契约）"
