#!/usr/bin/env bash
# test-harness.sh — 大仓治理 harness 自测脚手架（SKIP-非假绿）。
# 契约：无 node → 打印 SKIPPED 并 exit 0（未执行 != 通过，对齐 run-all.sh SKIPPED 语义）；
#   有 node → 真跑 node harness.mjs selftest 断言 {"ok":true} + exit 0，再跑 doctor 断言出 JSON。
# Phase 1（T1.5）在此追加 catalog/impact/context-pack/receipt fixtures 断言 + 规模 smoke。
set -eu

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
HARNESS="$ROOT/.claude/harness/harness.mjs"

echo "===== test-harness ====="

# node 缺失 → 可见跳过，非假绿
if ! command -v node >/dev/null 2>&1; then
  echo "SKIPPED: 无 node（command -v node 未找到）——harness 自测跳过，未执行 != 通过。"
  exit 0
fi
[ -f "$HARNESS" ] || { echo "  [FAIL] 缺 harness.mjs：$HARNESS" >&2; exit 1; }

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  [PASS] $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }

# ① selftest：stdout JSON 含 "ok":true 且 exit 0
RC=0
OUT=$(node "$HARNESS" selftest) || RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"ok":true'; then
  pass "selftest 返回 {\"ok\":true} 且 exit 0"
else
  fail "selftest 未通过（exit $RC，输出：$OUT）"
fi

# ② doctor：exit 0 且 stdout 是 JSON 对象（含 node 字段）
RC=0
OUT=$(node "$HARNESS" doctor) || RC=$?
case "$OUT" in
  '{'*'"node"'*) DJSON=1 ;;
  *) DJSON=0 ;;
esac
if [ "$RC" -eq 0 ] && [ "$DJSON" -eq 1 ]; then
  pass "doctor 出 JSON 且 exit 0"
else
  fail "doctor 未出预期 JSON（exit $RC，输出：$OUT）"
fi

# ③ 规模性能 smoke：mktemp 造 24 模块合成 catalog + 微型 git 仓，计时 context-pack < 5000ms。
#    合成物只在临时目录，跑完即删，不入版本库。
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.claude/harness"
# 24 模块 dependsOn 链 catalog（node 本段已确保存在，用它合成 JSON）。
node -e '
  const fs = require("fs");
  const mods = [];
  for (let i = 0; i < 24; i++) {
    const m = { id: "m" + i, paths: ["m" + i + "/**", "src/m" + i + "/**/*.ts"], riskTier: "medium" };
    if (i > 0) m.dependsOn = ["m" + (i - 1)];
    mods.push(m);
  }
  fs.writeFileSync(process.argv[1], JSON.stringify({ version: 1, modules: mods, global: ["package.json"], ignored: ["**/*.md"] }));
' "$TMP/.claude/harness/module-catalog.json"

(
  cd "$TMP"
  git init -q
  git config core.autocrlf false
  git config user.email t@t.t
  git config user.name t
  mkdir -p m0 m5 m23
  echo "x" > m0/a.ts
  echo "y" > m5/b.ts
  echo "z" > m23/c.ts
  git add -A
  git commit -qm init
  echo "changed" >> m0/a.ts        # 制造一处工作树变更
) >/dev/null 2>&1

START=$(date +%s%N)
RC=0
OUT=$(cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" node "$HARNESS" context-pack --catalog "$TMP/.claude/harness/module-catalog.json") || RC=$?
END=$(date +%s%N)
ELAPSED_MS=$(( (END - START) / 1000000 ))

if [ "$RC" -eq 0 ] && [ "$ELAPSED_MS" -lt 5000 ]; then
  pass "24 模块 context-pack 计时 ${ELAPSED_MS}ms < 5000ms"
else
  fail "24 模块 context-pack 超时或失败（exit $RC，计时 ${ELAPSED_MS}ms，输出：$OUT）"
fi

rm -rf "$TMP"
trap - EXIT

# ④ waiver CLI smoke：create --dry-run 合法应 ok；reason 含 security 应非 0
RC=0
OUT=$(node "$HARNESS" waiver create --owner t --reason "flake" --scope lint \
  --expiry 2099-01-01T00:00:00.000Z --compensation "fix in CI" --dry-run) || RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"ok":true'; then
  pass "waiver create --dry-run 合法 -> ok"
else
  fail "waiver create --dry-run 合法未通过（exit $RC，输出：$OUT）"
fi
RC=0
OUT=$(node "$HARNESS" waiver create --owner t --reason "bypass security gate" --scope lint \
  --expiry 2099-01-01T00:00:00.000Z --compensation "nope" --dry-run 2>/dev/null) || RC=$?
if [ "$RC" -ne 0 ]; then
  pass "waiver create reason 含 security -> 非 0"
else
  fail "waiver create reason 含 security 应拒绝，却 exit 0（输出：$OUT）"
fi

echo ""
echo "结果：PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
