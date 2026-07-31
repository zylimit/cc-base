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

# ⑤ verify 退出码契约（pre-commit-check 消费：rc=2 阻断 commit、rc=3 静默降级、rc=0 放行）
#   selftest 已覆盖 runCheck/aggregateStates 纯函数；本段补 CLI dispatch -> 退出码映射集成层。
#   每条独立临时仓，跑完即删；catalog JSON 用 node -e 写避免引号嵌套。
verify_setup() {
  local check_cmd="$1" tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/.claude/harness"
  if [ "${2:-}" != "no-catalog" ]; then
    node -e '
      const fs = require("fs");
      fs.writeFileSync(process.argv[1], JSON.stringify({
        version: 1,
        modules: [{ id: "core", paths: ["core/**"], riskTier: "medium" }],
        riskChecks: { medium: ["chk"] },
        checks: { chk: { command: process.argv[2], class: "static" } }
      }));
    ' "$tmp/.claude/harness/module-catalog.json" "$check_cmd"
  fi
  ( cd "$tmp" && git init -q && git config core.autocrlf false \
    && git config user.email t@t.t && git config user.name t \
    && mkdir -p core && echo "x" > core/a.ts && git add -A && git commit -qm init \
    && echo "changed" >> core/a.ts ) >/dev/null 2>&1
  printf '%s' "$tmp"
}

# ⑤a verify 全 PASS -> rc 0
TMPV="$(verify_setup 'node -e "process.exit(0)"')"
RC=0
OUT=$(cd "$TMPV" && CLAUDE_PROJECT_DIR="$TMPV" node "$HARNESS" verify) || RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"state":"PASS"'; then
  pass "verify 全 PASS -> rc 0"
else
  fail "verify 全 PASS 应 rc 0（exit $RC，输出：$OUT）"
fi
rm -rf "$TMPV"

# ⑤b verify 任一 FAIL -> rc 2（commit 闸阻断）
TMPV="$(verify_setup 'node -e "process.exit(1)"')"
RC=0
OUT=$(cd "$TMPV" && CLAUDE_PROJECT_DIR="$TMPV" node "$HARNESS" verify) || RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q '"state":"FAIL"'; then
  pass "verify FAIL -> rc 2"
else
  fail "verify FAIL 应 rc 2（exit $RC，输出：$OUT）"
fi
rm -rf "$TMPV"

# ⑤c verify 缺命令 -> BLOCKED -> rc 2（不假绿：二进制找不到不能默默放行）
TMPV="$(verify_setup 'definitely-not-real-binary-xyz-12345')"
RC=0
OUT=$(cd "$TMPV" && CLAUDE_PROJECT_DIR="$TMPV" node "$HARNESS" verify) || RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q '"state":"BLOCKED"'; then
  pass "verify 缺命令 -> BLOCKED -> rc 2（不假绿）"
else
  fail "verify 缺命令应 BLOCKED rc 2（exit $RC，输出：$OUT）"
fi
rm -rf "$TMPV"

# ⑤d verify 无 catalog -> rc 3（降级：不阻断也不假绿）
TMPV="$(verify_setup 'node -e "process.exit(0)"' no-catalog)"
RC=0
OUT=$(cd "$TMPV" && CLAUDE_PROJECT_DIR="$TMPV" node "$HARNESS" verify) || RC=$?
if [ "$RC" -eq 3 ]; then
  pass "verify 无 catalog -> rc 3"
else
  fail "verify 无 catalog 应 rc 3（exit $RC，输出：$OUT）"
fi
rm -rf "$TMPV"

# ⑤e verify 非 git -> rc 3
TMPNG="$(mktemp -d)"; mkdir -p "$TMPNG/.claude/harness"
node -e '
  const fs = require("fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({
    version: 1, modules: [{ id: "core", paths: ["core/**"], riskTier: "medium" }],
    riskChecks: { medium: ["chk"] },
    checks: { chk: { command: "node -e \"process.exit(0)\"", class: "static" } }
  }));
' "$TMPNG/.claude/harness/module-catalog.json"
RC=0
OUT=$(cd "$TMPNG" && CLAUDE_PROJECT_DIR="$TMPNG" node "$HARNESS" verify) || RC=$?
if [ "$RC" -eq 3 ]; then
  pass "verify 非 git -> rc 3"
else
  fail "verify 非 git 应 rc 3（exit $RC，输出：$OUT）"
fi
rm -rf "$TMPNG"

# ⑤f verify 全 SKIPPED（Fast Mode 端到端）-> rc 0：写 .fast-mode flag + allowFastSkip 真 SKIP 路径
TMPV="$(mktemp -d)"; mkdir -p "$TMPV/.claude/harness"
node -e 'const fs=require("fs"); fs.writeFileSync(process.argv[1], "expires_epoch=" + Math.floor(new Date("2099-01-01").getTime()/1000) + "\n");' "$TMPV/.claude/.fast-mode"
node -e '
  const fs = require("fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({
    version: 1, modules: [{ id: "core", paths: ["core/**"], riskTier: "medium" }],
    riskChecks: { medium: ["chk"] },
    checks: { chk: { command: "node -e \"process.exit(1)\"", class: "static", allowFastSkip: true } }
  }));
' "$TMPV/.claude/harness/module-catalog.json"
( cd "$TMPV" && git init -q && git config core.autocrlf false \
  && git config user.email t@t.t && git config user.name t \
  && mkdir -p core && echo "x" > core/a.ts && git add -A && git commit -qm init \
  && echo "changed" >> core/a.ts ) >/dev/null 2>&1
RC=0
OUT=$(cd "$TMPV" && CLAUDE_PROJECT_DIR="$TMPV" node "$HARNESS" verify) || RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"fastActive":true'; then
  pass "verify 全 SKIPPED (Fast Mode) -> rc 0"
else
  fail "verify Fast Mode SKIPPED 应 rc 0（exit $RC，输出：$OUT）"
fi
rm -rf "$TMPV"

# ⑥ receipt verify 退出码契约（stop-gate 消费：rc=4 拦停强制重审、rc=3 降级、rc=0 放行）
#   selftest 已覆盖 matchReceipts/contentHash 纯函数；本段补 receipt write 落盘往返 + verify 退出码映射。
# ⑥a receipt write 落盘 -> verify 同 diff rc 0
TMPR="$(mktemp -d)"
( cd "$TMPR" && git init -q && git config core.autocrlf false \
  && git config user.email t@t.t && git config user.name t \
  && mkdir -p core && echo "x" > core/a.ts && git add -A && git commit -qm init \
  && echo "changed" >> core/a.ts ) >/dev/null 2>&1
RC=0
OUT=$(cd "$TMPR" && CLAUDE_PROJECT_DIR="$TMPR" node "$HARNESS" receipt write <<<'{"taskId":"T1","reviewer":"alice","verdict":"pass","scope":"core"}'
) || RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"taskId":"T1"' \
   && [ -f "$TMPR/.claude/harness/receipts/T1.json" ] \
   && grep -q '"contentHash"' "$TMPR/.claude/harness/receipts/T1.json"; then
  RC2=0
  OUT2=$(cd "$TMPR" && CLAUDE_PROJECT_DIR="$TMPR" node "$HARNESS" receipt verify) || RC2=$?
  if [ "$RC2" -eq 0 ]; then
    pass "receipt write 落盘 -> verify 同 diff rc 0"
  else
    fail "receipt verify 同 diff 应 rc 0（exit $RC2，输出：$OUT2）"
  fi
else
  fail "receipt write 应 rc 0 + 落盘 T1.json + contentHash（exit $RC，输出：$OUT）"
fi

# ⑥b 改一个字节后 verify -> rc 4（STALE：stop-gate 拦停强制重审）
echo "more-change" >> "$TMPR/core/a.ts"
RC=0
OUT=$(cd "$TMPR" && CLAUDE_PROJECT_DIR="$TMPR" node "$HARNESS" receipt verify) || RC=$?
if [ "$RC" -eq 4 ] && printf '%s' "$OUT" | grep -q '"state":"STALE"'; then
  pass "receipt diff 变动 -> verify rc 4（STALE）"
else
  fail "receipt verify 改一字节应 rc 4 STALE（exit $RC，输出：$OUT）"
fi
rm -rf "$TMPR"

# ⑥c receipt verify 非 git -> rc 3
TMPNG="$(mktemp -d)"
RC=0
OUT=$(cd "$TMPNG" && CLAUDE_PROJECT_DIR="$TMPNG" node "$HARNESS" receipt verify) || RC=$?
if [ "$RC" -eq 3 ]; then
  pass "receipt verify 非 git -> rc 3"
else
  fail "receipt verify 非 git 应 rc 3（exit $RC，输出：$OUT）"
fi
rm -rf "$TMPNG"

# ⑦ waiver create 真写（非 dry-run）：dry-run 已在 ④ 测过，这里验真写落盘 + 禁词真写也拒
# ⑦a 合法 waiver 真写 -> rc 0 + 文件落盘 + contentHash 字段
TMPW="$(mktemp -d)"; mkdir -p "$TMPW/.claude/harness"
RC=0
OUT=$(cd "$TMPW" && CLAUDE_PROJECT_DIR="$TMPW" node "$HARNESS" waiver create \
  --owner tester --reason "flake on CI" --scope lint \
  --expiry 2099-01-01T00:00:00.000Z --compensation "rerun on rebuild") || RC=$?
WPATH=""
if [ "$RC" -eq 0 ]; then
  WPATH=$(printf '%s' "$OUT" | grep -oE '"path":"[^"]*"' | head -1 | sed 's/"path":"//; s/"$//')
fi
if [ "$RC" -eq 0 ] && [ -n "$WPATH" ] && [ -f "$WPATH" ] && grep -q '"contentHash"' "$WPATH"; then
  pass "waiver create 真写 -> rc 0 + 落盘 + contentHash"
else
  fail "waiver create 真写未落盘（rc=$RC，path=$WPATH，输出：$OUT）"
fi
rm -rf "$TMPW"

# ⑦b waiver create reason 含 security -> rc 非 0 + 不落盘（独立临时仓，初态 waiver 数=0）
TMPW="$(mktemp -d)"; mkdir -p "$TMPW/.claude/harness"
RC=0
OUT=$(cd "$TMPW" && CLAUDE_PROJECT_DIR="$TMPW" node "$HARNESS" waiver create \
  --owner tester --reason "bypass security gate" --scope lint \
  --expiry 2099-01-01T00:00:00.000Z --compensation "nope" 2>/dev/null) || RC=$?
WAIVER_COUNT=$(find "$TMPW/.claude/harness/waivers" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
if [ "$RC" -ne 0 ] && [ "${WAIVER_COUNT:-0}" -eq 0 ]; then
  pass "waiver create reason 含 security -> rc 非 0 + 未落盘"
else
  fail "waiver create 禁词应拒绝且不落盘（rc=$RC，waiver count=$WAIVER_COUNT，输出：$OUT）"
fi
rm -rf "$TMPW"

# ⑧ diff-hash CLI：契约 = 总是 rc 0（harness-large-repo.md 退出码表「doctor/diff-hash | 总是」，
#    源码 cmdDiffHash 无条件 emit(...,0)）。nonGit 是输出信息字段，非退出码分支。
#    输出 diffHash 必须是合法 SHA256（64 位小写 hex）。
# ⑧a diff-hash 在临时 git 仓 -> rc 0 + diffHash 是 64 位 hex
TMPDH="$(mktemp -d)"
( cd "$TMPDH" && git init -q && git config core.autocrlf false \
  && git config user.email t@t.t && git config user.name t \
  && echo "x" > a.ts && git add -A && git commit -qm init ) >/dev/null 2>&1
RC=0
OUT=$(cd "$TMPDH" && CLAUDE_PROJECT_DIR="$TMPDH" node "$HARNESS" diff-hash) || RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qE '"diffHash":"[0-9a-f]{64}"'; then
  pass "diff-hash git 仓 -> rc 0 + 合法 SHA256"
else
  fail "diff-hash git 仓应 rc 0 + 64 hex（exit $RC，输出：$OUT）"
fi
rm -rf "$TMPDH"

# ⑧b diff-hash 非 git -> 仍 rc 0（契约：总是 rc 0；nonGit:true 是信息字段，非 rc 3 分支）
TMPDH="$(mktemp -d)"
RC=0
OUT=$(cd "$TMPDH" && CLAUDE_PROJECT_DIR="$TMPDH" node "$HARNESS" diff-hash) || RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"nonGit":true' \
   && printf '%s' "$OUT" | grep -qE '"diffHash":"[0-9a-f]{64}"'; then
  pass "diff-hash 非 git -> rc 0 + nonGit:true（契约总是 rc 0）"
else
  fail "diff-hash 非 git 应 rc 0（exit $RC，输出：$OUT）"
fi
rm -rf "$TMPDH"

# ⑨ waiver list CLI：契约 = 总是 rc 0（空/有 waivers 两态各验）
# ⑨a 空 waivers -> rc 0 + waivers:[]
TMPWL="$(mktemp -d)"
RC=0
OUT=$(cd "$TMPWL" && CLAUDE_PROJECT_DIR="$TMPWL" node "$HARNESS" waiver list) || RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"waivers":\[\]'; then
  pass "waiver list 空 -> rc 0 + waivers:[]"
else
  fail "waiver list 空应 rc 0 + []（exit $RC，输出：$OUT）"
fi

# ⑨b 有 waivers -> rc 0 + waivers 数组非空
( cd "$TMPWL" && CLAUDE_PROJECT_DIR="$TMPWL" node "$HARNESS" waiver create \
  --owner t --reason "flake" --scope lint \
  --expiry 2099-01-01T00:00:00.000Z --compensation "fix" ) >/dev/null 2>&1
RC=0
OUT=$(cd "$TMPWL" && CLAUDE_PROJECT_DIR="$TMPWL" node "$HARNESS" waiver list) || RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qE '"waivers":\[\{'; then
  pass "waiver list 有 waiver -> rc 0 + 数组非空"
else
  fail "waiver list 有 waiver 应 rc 0 + 非空数组（exit $RC，输出：$OUT）"
fi
rm -rf "$TMPWL"

# ⑩ waiver check CLI：契约 = valid rc 0 / invalid rc 1（过期/禁词/缺字段各验一支）
TMPWC="$(mktemp -d)"
# ⑩a valid waiver -> rc 0
cat > "$TMPWC/valid.json" <<'EOF'
{"version":1,"owner":"t","reason":"flake on ci","scope":"lint","expiry":"2099-01-01T00:00:00.000Z","compensation":"rerun","created_at":"2026-07-31T00:00:00.000Z"}
EOF
RC=0
OUT=$(CLAUDE_PROJECT_DIR="$TMPWC" node "$HARNESS" waiver check --file "$TMPWC/valid.json") || RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"valid":true'; then
  pass "waiver check valid -> rc 0"
else
  fail "waiver check valid 应 rc 0（exit $RC，输出：$OUT）"
fi

# ⑩b 过期 waiver -> rc 1
cat > "$TMPWC/expired.json" <<'EOF'
{"version":1,"owner":"t","reason":"x","scope":"lint","expiry":"2020-01-01T00:00:00.000Z","compensation":"x","created_at":"2019-01-01T00:00:00.000Z"}
EOF
RC=0
OUT=$(CLAUDE_PROJECT_DIR="$TMPWC" node "$HARNESS" waiver check --file "$TMPWC/expired.json") || RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'expiry must be in the future'; then
  pass "waiver check 过期 -> rc 1"
else
  fail "waiver check 过期应 rc 1（exit $RC，输出：$OUT）"
fi

# ⑩c 禁词（reason 含 security）-> rc 1
cat > "$TMPWC/forbidden.json" <<'EOF'
{"version":1,"owner":"t","reason":"bypass security","scope":"lint","expiry":"2099-01-01T00:00:00.000Z","compensation":"x","created_at":"2026-07-31T00:00:00.000Z"}
EOF
RC=0
OUT=$(CLAUDE_PROJECT_DIR="$TMPWC" node "$HARNESS" waiver check --file "$TMPWC/forbidden.json") || RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'forbidden keyword'; then
  pass "waiver check 禁词 -> rc 1"
else
  fail "waiver check 禁词应 rc 1（exit $RC，输出：$OUT）"
fi

# ⑩d 缺字段（无 scope）-> rc 1
cat > "$TMPWC/missing.json" <<'EOF'
{"version":1,"owner":"t","reason":"x","expiry":"2099-01-01T00:00:00.000Z","compensation":"x","created_at":"2026-07-31T00:00:00.000Z"}
EOF
RC=0
OUT=$(CLAUDE_PROJECT_DIR="$TMPWC" node "$HARNESS" waiver check --file "$TMPWC/missing.json") || RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'scope required'; then
  pass "waiver check 缺字段 -> rc 1"
else
  fail "waiver check 缺字段应 rc 1（exit $RC，输出：$OUT）"
fi
rm -rf "$TMPWC"

# ⑪ catalog-lint CLI：契约 = 无错 rc 0 / 有错 rc 1（四错误码各验）/ 无 catalog rc 3
FX="$ROOT/.claude/tests/fixtures/harness"
# ⑪a good fixture + 全映射 tracked -> rc 0
RC=0
OUT=$(node "$HARNESS" catalog-lint --catalog "$FX/catalog-good.json" \
  --tracked core/index.ts,db/schema.ts,auth/login.ts,api/routes.ts,package.json,README.md,docs/guide.md) || RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"ok":true'; then
  pass "catalog-lint good -> rc 0"
else
  fail "catalog-lint good 应 rc 0（exit $RC，输出：$OUT）"
fi

# ⑪b UNMAPPED（tracked 驱动）-> rc 1
RC=0
OUT=$(node "$HARNESS" catalog-lint --catalog "$FX/catalog-bad-unmapped.json" \
  --tracked src/unmapped.ts) || RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q '"UNMAPPED"'; then
  pass "catalog-lint UNMAPPED -> rc 1"
else
  fail "catalog-lint UNMAPPED 应 rc 1（exit $RC，输出：$OUT）"
fi

# ⑪c CATCH_ALL（结构错，module paths 含 **）-> rc 1
RC=0
OUT=$(node "$HARNESS" catalog-lint --catalog "$FX/catalog-bad-catchall.json" \
  --tracked core/a.ts) || RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q '"CATCH_ALL"'; then
  pass "catalog-lint CATCH_ALL -> rc 1"
else
  fail "catalog-lint CATCH_ALL 应 rc 1（exit $RC，输出：$OUT）"
fi

# ⑪d DANGLING_DEP（结构错，dependsOn 指向不存在 id）-> rc 1
RC=0
OUT=$(node "$HARNESS" catalog-lint --catalog "$FX/catalog-bad-dangling.json" \
  --tracked core/a.ts) || RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q '"DANGLING_DEP"'; then
  pass "catalog-lint DANGLING_DEP -> rc 1"
else
  fail "catalog-lint DANGLING_DEP 应 rc 1（exit $RC，输出：$OUT）"
fi

# ⑪e OVERLAP（tracked 驱动，同路径多 module 声明）-> rc 1
RC=0
OUT=$(node "$HARNESS" catalog-lint --catalog "$FX/catalog-bad-overlap.json" \
  --tracked core/shared/x.ts) || RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q '"OVERLAP"'; then
  pass "catalog-lint OVERLAP -> rc 1"
else
  fail "catalog-lint OVERLAP 应 rc 1（exit $RC，输出：$OUT）"
fi

# ⑪f 无 catalog -> rc 3
TMPCL="$(mktemp -d)"
RC=0
OUT=$(cd "$TMPCL" && CLAUDE_PROJECT_DIR="$TMPCL" node "$HARNESS" catalog-lint) || RC=$?
if [ "$RC" -eq 3 ] && printf '%s' "$OUT" | grep -q '"catalog-missing"'; then
  pass "catalog-lint 无 catalog -> rc 3"
else
  fail "catalog-lint 无 catalog 应 rc 3（exit $RC，输出：$OUT）"
fi
rm -rf "$TMPCL"

# ⑫ impact CLI：契约 = 正常 rc 0 / 无 catalog rc 3 / 非 git rc 3
# ⑫a 正常（core 变更，api dependsOn core -> affected=[core,api] 反向闭包）-> rc 0
TMPI="$(mktemp -d)"; mkdir -p "$TMPI/.claude/harness"
node -e '
  const fs = require("fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({
    version: 1,
    modules: [
      { id: "core", paths: ["core/**"], riskTier: "medium" },
      { id: "api", paths: ["api/**"], dependsOn: ["core"], riskTier: "medium" }
    ], global: [], ignored: []
  }));
' "$TMPI/.claude/harness/module-catalog.json"
RC=0
OUT=$(CLAUDE_PROJECT_DIR="$TMPI" node "$HARNESS" impact \
  --catalog "$TMPI/.claude/harness/module-catalog.json" --changed core/a.ts) || RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"affected":\["core","api"\]'; then
  pass "impact 正常 -> rc 0 + 反向闭包"
else
  fail "impact 正常应 rc 0（exit $RC，输出：$OUT）"
fi

# ⑫b 无 catalog -> rc 3
RC=0
OUT=$(CLAUDE_PROJECT_DIR="$TMPI" node "$HARNESS" impact \
  --catalog "$TMPI/nope.json" --changed core/a.ts) || RC=$?
if [ "$RC" -eq 3 ] && printf '%s' "$OUT" | grep -q '"catalog-missing"'; then
  pass "impact 无 catalog -> rc 3"
else
  fail "impact 无 catalog 应 rc 3（exit $RC，输出：$OUT）"
fi

# ⑫c 非 git（catalog 在，不传 --changed 走 changedPaths 自动检测）-> rc 3
TMPI2="$(mktemp -d)"; mkdir -p "$TMPI2/.claude/harness"
node -e '
  const fs = require("fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({
    version: 1, modules: [{ id: "core", paths: ["core/**"], riskTier: "medium" }], global: [], ignored: []
  }));
' "$TMPI2/.claude/harness/module-catalog.json"
RC=0
OUT=$(cd "$TMPI2" && CLAUDE_PROJECT_DIR="$TMPI2" node "$HARNESS" impact \
  --catalog "$TMPI2/.claude/harness/module-catalog.json") || RC=$?
if [ "$RC" -eq 3 ] && printf '%s' "$OUT" | grep -q '"non-git"'; then
  pass "impact 非 git -> rc 3"
else
  fail "impact 非 git 应 rc 3（exit $RC，输出：$OUT）"
fi
rm -rf "$TMPI" "$TMPI2"

# ⑬ context-pack CLI：契约 = 正常 rc 0 / 非 git rc 3
# ⑬a 正常（临时 git 仓 + catalog + 工作树变更）-> rc 0
TMPC="$(mktemp -d)"; mkdir -p "$TMPC/.claude/harness"
node -e '
  const fs = require("fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({
    version: 1, modules: [{ id: "core", paths: ["core/**"], riskTier: "medium" }], global: [], ignored: []
  }));
' "$TMPC/.claude/harness/module-catalog.json"
( cd "$TMPC" && git init -q && git config core.autocrlf false \
  && git config user.email t@t.t && git config user.name t \
  && mkdir -p core && echo "x" > core/a.ts && git add -A && git commit -qm init \
  && echo "changed" >> core/a.ts ) >/dev/null 2>&1
RC=0
OUT=$(cd "$TMPC" && CLAUDE_PROJECT_DIR="$TMPC" node "$HARNESS" context-pack) || RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"diffHash"'; then
  pass "context-pack 正常 -> rc 0"
else
  fail "context-pack 正常应 rc 0（exit $RC，输出：$OUT）"
fi
rm -rf "$TMPC"

# ⑬b 非 git -> rc 3
TMPC="$(mktemp -d)"
RC=0
OUT=$(cd "$TMPC" && CLAUDE_PROJECT_DIR="$TMPC" node "$HARNESS" context-pack) || RC=$?
if [ "$RC" -eq 3 ]; then
  pass "context-pack 非 git -> rc 3"
else
  fail "context-pack 非 git 应 rc 3（exit $RC，输出：$OUT）"
fi
rm -rf "$TMPC"

# ⑭ CLI dispatch：契约 = unknown/missing 总是 rc 3（+ usage 诊断到 stderr）
# ⑭a unknown 命令 -> rc 3 + usage
RC=0
ERR=$(node "$HARNESS" bogus-cmd-xyz 2>&1 1>/dev/null) || RC=$?
if [ "$RC" -eq 3 ] && printf '%s' "$ERR" | grep -q 'unknown subcommand: bogus-cmd-xyz' \
   && printf '%s' "$ERR" | grep -q 'usage: node harness.mjs'; then
  pass "unknown 命令 -> rc 3 + usage"
else
  fail "unknown 命令应 rc 3 + usage（exit $RC，stderr：$ERR）"
fi

# ⑭b missing 子命令（无参）-> rc 3 + usage
RC=0
ERR=$(node "$HARNESS" 2>&1 1>/dev/null) || RC=$?
if [ "$RC" -eq 3 ] && printf '%s' "$ERR" | grep -q 'missing subcommand' \
   && printf '%s' "$ERR" | grep -q 'usage: node harness.mjs'; then
  pass "missing 子命令 -> rc 3 + usage"
else
  fail "missing 子命令应 rc 3 + usage（exit $RC，stderr：$ERR）"
fi

echo ""
echo "结果：PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
