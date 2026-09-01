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

# ⑮ 合成大仓实战（35 模块 5 层依赖图）——impact 反向闭包正确性 + global fanout
#   目的：现有 fixture 只覆盖 4 模块浅依赖；本段造 35 模块 5 层真实依赖图，
#   验 reverseClosure 的多跳传递正确性（不止直接依赖）+ degraded fanout 语义。
#   合成 catalog 仅落临时目录，跑完即删，不入版本库。
TMPBIG="$(mktemp -d)"
mkdir -p "$TMPBIG/.claude/harness"
BIGCAT="$TMPBIG/.claude/harness/module-catalog.json"
node -e '
  const fs = require("fs");
  const m = [];
  // L1 utils (3) — 底层，带 verification 路径字符串
  for (let i=1;i<=3;i++) m.push({id:"u"+i, paths:["utils/u"+i+"/**"], riskTier:"low", verification:["utils/u"+i+"/test.sh"]});
  // L2 shared (4) depends on all utils
  for (let i=1;i<=4;i++) m.push({id:"s"+i, paths:["shared/s"+i+"/**"], dependsOn:["u1","u2","u3"], riskTier:"medium"});
  // L3 auth (2) depends on shared s1
  for (let i=1;i<=2;i++) m.push({id:"a"+i, paths:["auth/a"+i+"/**"], dependsOn:["s1"], riskTier:"high"});
  // L3 services (8) depends on shared s1,s2
  for (let i=1;i<=8;i++) m.push({id:"svc"+i, paths:["services/svc"+i+"/**"], dependsOn:["s1","s2"], riskTier:"medium"});
  // L4 api (6) depends on services svc1,svc2 + auth a1
  for (let i=1;i<=6;i++) m.push({id:"api"+i, paths:["api/api"+i+"/**"], dependsOn:["svc1","svc2","a1"], riskTier:"high"});
  // L5 webapp (10) depends on api api1,api2 + auth a1
  for (let i=1;i<=10;i++) m.push({id:"w"+i, paths:["webapp/w"+i+"/**"], dependsOn:["api1","api2","a1"], riskTier:"high"});
  // 孤立 (2) 无依赖也无人依赖
  for (let i=1;i<=2;i++) m.push({id:"iso"+i, paths:["iso/iso"+i+"/**"], riskTier:"low"});
  fs.writeFileSync(process.argv[1], JSON.stringify({version:1, modules:m, global:["package.json","tsconfig.base.json"], ignored:["**/*.md"]}));
' "$BIGCAT"

# ⑮a catalog 落盘成功（35 模块）
NM=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).modules.length)' "$BIGCAT")
if [ "$NM" -eq "35" ]; then
  pass "合成大仓 catalog 落盘 35 模块"
else
  fail "合成大仓 catalog 模块数不对（期望 35，实际 $NM）"
fi

# ⑮b 改 utils/u1 —— 反向闭包必须包含全部上层（shared/auth/services/api/webapp 共 30 + u1 = 31）
#     不止直接依赖：u2,u3,iso1,iso2 不在 affected（u2/u3 无人改，iso 孤立）
RC=0
OUT=$(CLAUDE_PROJECT_DIR="$TMPBIG" node "$HARNESS" impact --catalog "$BIGCAT" --changed utils/u1/a.ts) || RC=$?
AFFECTED_OK=$(printf '%s' "$OUT" | python3 -c '
import sys,json
d=json.load(sys.stdin)
a=set(d["affected"])
need={"u1","s1","s2","s3","s4","a1","a2","svc1","svc2","svc3","svc4","svc5","svc6","svc7","svc8","api1","api2","api3","api4","api5","api6","w1","w2","w3","w4","w5","w6","w7","w8","w9","w10"}
exclude={"u2","u3","iso1","iso2"}
print("OK" if (need<=a and exclude.isdisjoint(a) and len(a)==31) else "BAD")
')
if [ "$RC" -eq 0 ] && [ "$AFFECTED_OK" = "OK" ]; then
  pass "改 utils/u1 -> 反向闭包含全部 31 上层（shared/auth/services/api/webapp），不含 u2/u3/iso"
else
  fail "改 utils/u1 反向闭包错（rc=$RC，affected_ok=$AFFECTED_OK，输出：$OUT）"
fi

# ⑮c 改 webapp/w1 —— 反向闭包到底（无人 dependsOn webapp），affected 只含 w1
RC=0
OUT=$(CLAUDE_PROJECT_DIR="$TMPBIG" node "$HARNESS" impact --catalog "$BIGCAT" --changed webapp/w1/a.ts) || RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"affected":\["w1"\]'; then
  pass "改 webapp/w1 -> 反向闭包到底，affected 只含 w1（无反向）"
else
  fail "改 webapp/w1 反向闭包应只 w1（rc=$RC，输出：$OUT）"
fi

# ⑮d 改 shared/s1 —— 反向闭包含 auth/services/api/webapp（27 个），不含 utils 其他/shared 其他/iso
RC=0
OUT=$(CLAUDE_PROJECT_DIR="$TMPBIG" node "$HARNESS" impact --catalog "$BIGCAT" --changed shared/s1/a.ts) || RC=$?
AFFECTED_OK=$(printf '%s' "$OUT" | python3 -c '
import sys,json
d=json.load(sys.stdin)
a=set(d["affected"])
need={"s1","a1","a2","svc1","svc2","svc3","svc4","svc5","svc6","svc7","svc8","api1","api2","api3","api4","api5","api6","w1","w2","w3","w4","w5","w6","w7","w8","w9","w10"}
exclude={"u1","u2","u3","s2","s3","s4","iso1","iso2"}
print("OK" if (need<=a and exclude.isdisjoint(a) and len(a)==27) else "BAD")
')
if [ "$RC" -eq 0 ] && [ "$AFFECTED_OK" = "OK" ]; then
  pass "改 shared/s1 -> 反向闭包含 auth/services/api/webapp 共 27，不含 utils/shared 其他"
else
  fail "改 shared/s1 反向闭包错（rc=$RC，affected_ok=$AFFECTED_OK，输出：$OUT）"
fi

# ⑮e 改 package.json (global) —— 全 fanout：affected 含全部 35 模块 + degraded:true
RC=0
OUT=$(CLAUDE_PROJECT_DIR="$TMPBIG" node "$HARNESS" impact --catalog "$BIGCAT" --changed package.json) || RC=$?
GOK=$(printf '%s' "$OUT" | python3 -c '
import sys,json
d=json.load(sys.stdin)
print("OK" if (len(d["affected"])==35 and d["degraded"]==True and any(r.startswith("global") for r in d["expansionReasons"])) else "BAD")
')
if [ "$RC" -eq 0 ] && [ "$GOK" = "OK" ]; then
  pass "改 package.json (global) -> 全 35 模块 fanout + degraded:true"
else
  fail "改 package.json global fanout 错（rc=$RC，gok=$GOK，输出：$OUT）"
fi

# ⑯ 性能计时 + context-pack 预算（packHash 稳定 + verification 路径进包 + DENY 不入包）
# ⑯a 35 模块 impact + context-pack 全流程 <5s（性能断言，贴实测毫秒）
TMPG="$(mktemp -d)"
mkdir -p "$TMPG/.claude/harness"
cp "$HARNESS" "$TMPG/.claude/harness/harness.mjs"   # 端到端需要 harness.mjs 在 $CLAUDE_PROJECT_DIR
cp "$BIGCAT" "$TMPG/.claude/harness/module-catalog.json"
( cd "$TMPG" && git init -q && git config core.autocrlf false \
  && git config user.email t@t.t && git config user.name t \
  && mkdir -p utils/u1 && echo "x" > utils/u1/a.ts && git add -A && git commit -qm init ) >/dev/null 2>&1
echo "changed" >> "$TMPG/utils/u1/a.ts"

START=$(date +%s%N)
RC=0
OUT=$(cd "$TMPG" && CLAUDE_PROJECT_DIR="$TMPG" node "$HARNESS" impact --catalog "$TMPG/.claude/harness/module-catalog.json" --changed utils/u1/a.ts) || RC=$?
RC2=0
OUT2=$(cd "$TMPG" && CLAUDE_PROJECT_DIR="$TMPG" node "$HARNESS" context-pack) || RC2=$?
END=$(date +%s%N)
ELAPSED_MS=$(( (END - START) / 1000000 ))
if [ "$RC" -eq 0 ] && [ "$RC2" -eq 0 ] && [ "$ELAPSED_MS" -lt 5000 ]; then
  pass "35 模块 impact + context-pack 全流程 ${ELAPSED_MS}ms < 5000ms"
else
  fail "35 模块性能超时或失败（impact rc=$RC, pack rc=$RC2, ${ELAPSED_MS}ms）"
fi

# ⑯b context-pack packHash 稳定（同工作树两次跑 hash 完全相同）
OUT3=$(cd "$TMPG" && CLAUDE_PROJECT_DIR="$TMPG" node "$HARNESS" context-pack)
H1=$(printf '%s' "$OUT2" | python3 -c 'import sys,json; print(json.load(sys.stdin)["packHash"])')
H2=$(printf '%s' "$OUT3" | python3 -c 'import sys,json; print(json.load(sys.stdin)["packHash"])')
if [ -n "$H1" ] && [ "$H1" = "$H2" ]; then
  pass "context-pack packHash 稳定（同输入两次相同：${H1:0:16}...）"
else
  fail "context-pack packHash 不稳定（H1=$H1, H2=$H2）"
fi

# ⑯c context-pack DENY 路径（.env/node_modules）入 denied 不入 included
echo "secret" > "$TMPG/.env"
mkdir -p "$TMPG/node_modules" && echo "dep" > "$TMPG/node_modules/x.js"
RC=0
OUTD=$(cd "$TMPG" && CLAUDE_PROJECT_DIR="$TMPG" node "$HARNESS" context-pack) || RC=$?
DENY_OK=$(printf '%s' "$OUTD" | python3 -c '
import sys,json
d=json.load(sys.stdin)
inc=[f["path"] for f in d["included"]]
den=set(d["denied"])
# .env 和 node_modules/x.js 必须在 denied，且不在 included
ok = (".env" in den) and ("node_modules/x.js" in den) and (".env" not in inc) and ("node_modules/x.js" not in inc)
print("OK" if ok else "BAD")
')
if [ "$RC" -eq 0 ] && [ "$DENY_OK" = "OK" ]; then
  pass "context-pack DENY 路径（.env/node_modules）入 denied 不入 included"
else
  fail "context-pack DENY 失效（rc=$RC, deny_ok=$DENY_OK）"
fi

# ⑯d context-pack 受影响模块 verification 路径入 included（改 utils/u1 -> utils/u1/test.sh 进包）
VOK=$(printf '%s' "$OUTD" | python3 -c '
import sys,json
d=json.load(sys.stdin)
inc=[f["path"] for f in d["included"]]
print("OK" if any("utils/u1/test.sh" in p for p in inc) else "BAD")
')
if [ "$RC" -eq 0 ] && [ "$VOK" = "OK" ]; then
  pass "context-pack 受影响模块 verification 路径（utils/u1/test.sh）入 included"
else
  fail "context-pack verification 路径未入包（vok=$VOK）"
fi
rm -rf "$TMPG" "$TMPBIG"

# ⑰ stop-gate 端到端（hook→lib-harness→harness.mjs receipt verify 链）
#   验重点：stop-gate.sh 真调了 harness receipt verify 并据 rc=4 拦停、rc=0 放行（不只 CLI 单测）。
#   关键：临时仓必须自带 harness.mjs（hook 经 $CLAUDE_PROJECT_DIR/.claude/harness/harness.mjs 找它）。
STOP_GATE="$ROOT/.claude/hooks/stop-gate.sh"

# ⑰a 有 stale receipt + diff 变动 + .needs-review=clean -> stop-gate decision:block（rc=4 路径）
TMPS="$(mktemp -d)"
mkdir -p "$TMPS/.claude/harness"
cp "$HARNESS" "$TMPS/.claude/harness/harness.mjs"
node -e 'const fs=require("fs"); fs.writeFileSync(process.argv[1], JSON.stringify({version:1, modules:[{id:"core",paths:["core/**"],riskTier:"medium"}]}));' "$TMPS/.claude/harness/module-catalog.json"
( cd "$TMPS" && git init -q && git config core.autocrlf false \
  && git config user.email t@t.t && git config user.name t \
  && mkdir -p core && echo "x" > core/a.ts && git add -A && git commit -qm init ) >/dev/null 2>&1
echo "changed" >> "$TMPS/core/a.ts"
# 写 receipt 绑定当前 diff，再改代码制造 stale（rc=4 触发条件：receipts 存在但都不匹配当前 diff）
( cd "$TMPS" && CLAUDE_PROJECT_DIR="$TMPS" node "$HARNESS" receipt write <<<'{"taskId":"T1","reviewer":"bob","verdict":"pass","scope":"core"}'
) >/dev/null 2>&1
echo "more-change-after-receipt" >> "$TMPS/core/a.ts"
echo "clean" > "$TMPS/.claude/.needs-review"
RC=0
OUT=$(cd "$TMPS" && CLAUDE_PROJECT_DIR="$TMPS" bash "$STOP_GATE" 2>&1) || RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"decision":"block"'; then
  pass "stop-gate 端到端 rc=4 拦停链（stale receipt -> decision:block）"
else
  fail "stop-gate 未按 rc=4 拦停（rc=$RC，输出：$OUT）"
fi

# ⑰b 写匹配 receipt -> stop-gate 放行 + 清理 .needs-review
( cd "$TMPS" && CLAUDE_PROJECT_DIR="$TMPS" node "$HARNESS" receipt write <<<'{"taskId":"T2","reviewer":"bob","verdict":"pass","scope":"core"}'
) >/dev/null 2>&1
RC=0
OUT=$(cd "$TMPS" && CLAUDE_PROJECT_DIR="$TMPS" bash "$STOP_GATE" 2>&1) || RC=$?
if [ "$RC" -eq 0 ] && [ ! -f "$TMPS/.claude/.needs-review" ] \
   && ! printf '%s' "$OUT" | grep -q '"decision":"block"'; then
  pass "stop-gate 端到端放行链（匹配 receipt -> 放行 + 清 .needs-review）"
else
  fail "stop-gate 匹配 receipt 未放行（rc=$RC, needs-review 残留=$([ -f "$TMPS/.claude/.needs-review" ] && echo YES || echo NO), 输出：$OUT）"
fi
rm -rf "$TMPS"

# ⑱ pre-commit-check 端到端（hook→lib-harness→harness.mjs verify 链）
#   验重点：pre-commit-check.sh 真调了 harness verify 并据 rc=2 阻断 commit（exit 2）、rc=0 放行。
#   stdin 喂 git commit JSON 模拟 PreToolUse hook；catalog verification 故意 FAIL。
PRECOMMIT="$ROOT/.claude/hooks/pre-commit-check.sh"

# ⑱a catalog verification FAIL -> pre-commit exit 2（阻断 commit）
TMPP="$(mktemp -d)"
mkdir -p "$TMPP/.claude/harness"
cp "$HARNESS" "$TMPP/.claude/harness/harness.mjs"
node -e '
  const fs = require("fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({
    version:1, modules:[{id:"core",paths:["core/**"],riskTier:"medium",verification:["chk"]}],
    riskChecks:{medium:["chk"]}, checks:{chk:{command:process.argv[2],class:"static"}}
  }));
' "$TMPP/.claude/harness/module-catalog.json" 'node -e "process.exit(1)"'
( cd "$TMPP" && git init -q && git config core.autocrlf false \
  && git config user.email t@t.t && git config user.name t \
  && mkdir -p core && echo "x" > core/a.ts && git add -A && git commit -qm init ) >/dev/null 2>&1
echo "stage-me" >> "$TMPP/core/a.ts" && ( cd "$TMPP" && git add -A ) >/dev/null 2>&1
RC=0
OUT=$(echo '{"tool_input":{"command":"git commit -m test"}}' | (cd "$TMPP" && CLAUDE_PROJECT_DIR="$TMPP" bash "$PRECOMMIT") 2>&1) || RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q '大仓四态质量门未通过'; then
  pass "pre-commit 端到端 rc=2 阻断链（verification FAIL -> exit 2）"
else
  fail "pre-commit 未按 rc=2 阻断（rc=$RC，输出：$OUT）"
fi

# ⑱b 改 verification PASS -> pre-commit exit 0（放行）
node -e '
  const fs = require("fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({
    version:1, modules:[{id:"core",paths:["core/**"],riskTier:"medium",verification:["chk"]}],
    riskChecks:{medium:["chk"]}, checks:{chk:{command:process.argv[2],class:"static"}}
  }));
' "$TMPP/.claude/harness/module-catalog.json" 'node -e "process.exit(0)"'
RC=0
OUT=$(echo '{"tool_input":{"command":"git commit -m test"}}' | (cd "$TMPP" && CLAUDE_PROJECT_DIR="$TMPP" bash "$PRECOMMIT") 2>&1) || RC=$?
if [ "$RC" -eq 0 ]; then
  pass "pre-commit 端到端放行链（verification PASS -> exit 0）"
else
  fail "pre-commit verification PASS 应放行 exit 0（rc=$RC，输出：$OUT）"
fi

# ⑱c 非 git commit 命令 -> pre-commit 直接放行（不触发 harness）
RC=0
OUT=$(echo '{"tool_input":{"command":"git status"}}' | (cd "$TMPP" && CLAUDE_PROJECT_DIR="$TMPP" bash "$PRECOMMIT") 2>&1) || RC=$?
if [ "$RC" -eq 0 ]; then
  pass "pre-commit 非 git commit 命令 -> 放行（不触发 harness）"
else
  fail "pre-commit 非 git commit 应放行（rc=$RC，输出：$OUT）"
fi
rm -rf "$TMPP"

# ⑲ arch-check CLI：契约 = 图干净 rc 0 / 越禁边或未声明边 rc 1 / 无 catalog rc 3
#   造迷你双模块仓：analytics import pii-store（forbiddenDependencies 命中）+ 未声明边。
TMPA="$(mktemp -d)"; mkdir -p "$TMPA/.claude/harness"
node -e '
  const fs = require("fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({
    version: 1,
    modules: [
      { id: "pii-store", paths: ["pii/**"], riskTier: "high" },
      { id: "analytics", paths: ["analytics/**"], riskTier: "medium", forbiddenDependencies: ["pii-store"] },
      { id: "web", paths: ["web/**"], riskTier: "low" }
    ], global: [], ignored: ["**/*.md"]
  }));
' "$TMPA/.claude/harness/module-catalog.json"
( cd "$TMPA" && git init -q && git config core.autocrlf false \
  && git config user.email t@t.t && git config user.name t \
  && mkdir -p pii analytics web \
  && echo "export const store = 1;" > pii/store.ts \
  && printf 'import { store } from "../pii/store";\nexport const track = () => store;\n' > analytics/track.ts \
  && printf 'import { track } from "../analytics/track";\ntrack();\n' > web/page.ts \
  && git add -A && git commit -qm init ) >/dev/null 2>&1

# ⑲a 越禁边（analytics->pii-store）+ 未声明边（web->analytics）-> rc 1，两类分开报
RC=0
OUT=$(cd "$TMPA" && CLAUDE_PROJECT_DIR="$TMPA" node "$HARNESS" arch-check) || RC=$?
AOK=$(printf '%s' "$OUT" | python3 -c '
import sys,json
d=json.load(sys.stdin)
fb=[(v["from"],v["to"]) for v in d["forbiddenDependencies"]]
ud=[(v["from"],v["to"]) for v in d["undeclaredDependencies"]]
print("OK" if (("analytics","pii-store") in fb and ("web","analytics") in ud and d["ok"]==False) else "BAD")
')
if [ "$RC" -eq 1 ] && [ "$AOK" = "OK" ]; then
  pass "arch-check 越禁边 + 未声明边 -> rc 1（两类分开报：禁令 vs 漂移）"
else
  fail "arch-check 违规应 rc 1（rc=$RC，aok=$AOK，输出：$OUT）"
fi

# ⑲b 修 catalog（web 声明依赖 analytics）+ 删越禁 import -> rc 0 干净
node -e '
  const fs = require("fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({
    version: 1,
    modules: [
      { id: "pii-store", paths: ["pii/**"], riskTier: "high" },
      { id: "analytics", paths: ["analytics/**"], riskTier: "medium", forbiddenDependencies: ["pii-store"] },
      { id: "web", paths: ["web/**"], riskTier: "low", dependsOn: ["analytics"] }
    ], global: [], ignored: ["**/*.md"]
  }));
' "$TMPA/.claude/harness/module-catalog.json"
printf 'export const track = () => 1;\n' > "$TMPA/analytics/track.ts"
RC=0
OUT=$(cd "$TMPA" && CLAUDE_PROJECT_DIR="$TMPA" node "$HARNESS" arch-check) || RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"ok":true'; then
  pass "arch-check 修复后 -> rc 0 图干净"
else
  fail "arch-check 修复后应 rc 0（rc=$RC，输出：$OUT）"
fi
rm -rf "$TMPA"

# ⑲c 无 catalog -> rc 3
TMPA="$(mktemp -d)"
( cd "$TMPA" && git init -q ) >/dev/null 2>&1
RC=0
OUT=$(cd "$TMPA" && CLAUDE_PROJECT_DIR="$TMPA" node "$HARNESS" arch-check) || RC=$?
if [ "$RC" -eq 3 ]; then
  pass "arch-check 无 catalog -> rc 3"
else
  fail "arch-check 无 catalog 应 rc 3（rc=$RC，输出：$OUT）"
fi
rm -rf "$TMPA"

# ⑳ fitness CLI：契约 = error 命中 rc 1 / 压制后 rc 0（--paths 显式指定，无需 catalog）
TMPF="$(mktemp -d)"
printf 'const apiKey = "AKIAABCDEFGHIJKLMNOP";\n' > "$TMPF/leak.ts"  # scan-secrets:ignore 假密钥，测的就是 fitness 规则本身
RC=0
OUT=$(cd "$TMPF" && CLAUDE_PROJECT_DIR="$TMPF" node "$HARNESS" fitness --paths leak.ts) || RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q '"no-secret-literal"'; then
  pass "fitness 密钥字面量 -> rc 1 + no-secret-literal 命中"
else
  fail "fitness 密钥应 rc 1（rc=$RC，输出：$OUT）"
fi
printf '// harness-fitness:ignore\nconst apiKey = "AKIAABCDEFGHIJKLMNOP";\n' > "$TMPF/leak.ts"  # scan-secrets:ignore 同上
RC=0
OUT=$(cd "$TMPF" && CLAUDE_PROJECT_DIR="$TMPF" node "$HARNESS" fitness --paths leak.ts) || RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"ok":true'; then
  pass "fitness 行内压制 -> rc 0"
else
  fail "fitness 压制后应 rc 0（rc=$RC，输出：$OUT）"
fi
rm -rf "$TMPF"

# ㉑ attributes CLI：契约 = blocking 属性未接线 rc 1 / 接线后 rc 0 / 无 catalog rc 3
TMPQ="$(mktemp -d)"; mkdir -p "$TMPQ/.claude/harness"
node -e '
  const fs = require("fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({
    version: 1,
    modules: [{ id: "pay", paths: ["pay/**"], riskTier: "high", verification: ["lint"], attributes: { security: "critical" } }],
    checks: { lint: { command: "node --version", class: "static" } }
  }));
' "$TMPQ/.claude/harness/module-catalog.json"
RC=0
OUT=$(CLAUDE_PROJECT_DIR="$TMPQ" node "$HARNESS" attributes --catalog "$TMPQ/.claude/harness/module-catalog.json") || RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q '"unwiredBlocking":1'; then
  pass "attributes critical 声明未接线 -> rc 1 可见缺口"
else
  fail "attributes 未接线应 rc 1（rc=$RC，输出：$OUT）"
fi
node -e '
  const fs = require("fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({
    version: 1,
    modules: [{ id: "pay", paths: ["pay/**"], riskTier: "high", verification: ["sec"], attributes: { security: "critical" } }],
    checks: { sec: { command: "node --version", class: "security", attributes: ["security"] } }
  }));
' "$TMPQ/.claude/harness/module-catalog.json"
RC=0
OUT=$(CLAUDE_PROJECT_DIR="$TMPQ" node "$HARNESS" attributes --catalog "$TMPQ/.claude/harness/module-catalog.json") || RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"ok":true'; then
  pass "attributes 接线后 -> rc 0"
else
  fail "attributes 接线后应 rc 0（rc=$RC，输出：$OUT）"
fi
rm -rf "$TMPQ"

# ㉒ verify 五性门端到端：check 全 PASS 但 critical 属性无认领 -> rc 2 BLOCKED_BY_ATTRIBUTES；
#    认领 check PASS 后 -> rc 0。「check 全绿但没人证明过 security」不再能读作完成。
verify_attr_setup() {
  local catalog_js="$1" tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/.claude/harness"
  node -e "$catalog_js" "$tmp/.claude/harness/module-catalog.json"
  ( cd "$tmp" && git init -q && git config core.autocrlf false \
    && git config user.email t@t.t && git config user.name t \
    && mkdir -p pay && echo "x" > pay/a.ts && git add -A && git commit -qm init \
    && echo "changed" >> pay/a.ts ) >/dev/null 2>&1
  printf '%s' "$tmp"
}
TMPV="$(verify_attr_setup '
  const fs = require("fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({
    version: 1,
    modules: [{ id: "pay", paths: ["pay/**"], riskTier: "high", verification: ["lint"], attributes: { security: "critical" } }],
    checks: { lint: { command: "node -e \"process.exit(0)\"", class: "static" } }
  }));
')"
RC=0
OUT=$(cd "$TMPV" && CLAUDE_PROJECT_DIR="$TMPV" node "$HARNESS" verify) || RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q '"gate":"BLOCKED_BY_ATTRIBUTES"' \
   && printf '%s' "$OUT" | grep -q '"state":"PASS"'; then
  pass "verify check 全 PASS 但 critical 属性缺证据 -> rc 2 BLOCKED_BY_ATTRIBUTES"
else
  fail "verify 属性门应 rc 2（rc=$RC，输出：$OUT）"
fi
rm -rf "$TMPV"

TMPV="$(verify_attr_setup '
  const fs = require("fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({
    version: 1,
    modules: [{ id: "pay", paths: ["pay/**"], riskTier: "high", verification: ["sec"], attributes: { security: "critical" } }],
    checks: { sec: { command: "node -e \"process.exit(0)\"", class: "security", attributes: ["security"] } }
  }));
')"
RC=0
OUT=$(cd "$TMPV" && CLAUDE_PROJECT_DIR="$TMPV" node "$HARNESS" verify) || RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"gate":"PASS"'; then
  pass "verify 认领 check PASS 覆盖 critical 属性 -> rc 0 gate:PASS"
else
  fail "verify 属性覆盖后应 rc 0（rc=$RC，输出：$OUT）"
fi
rm -rf "$TMPV"

# ㉓ adapters CLI：list rc 0 含内置工具；add --dry-run rc 0；add 未知 id rc 1
TMPD="$(mktemp -d)"; mkdir -p "$TMPD/.claude/harness"
cp "$ROOT/.claude/harness/adapters.json" "$TMPD/.claude/harness/adapters.json"
node -e '
  const fs = require("fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({ version: 1, modules: [{ id: "core", paths: ["core/**"] }] }));
' "$TMPD/.claude/harness/module-catalog.json"
RC=0
OUT=$(cd "$TMPD" && CLAUDE_PROJECT_DIR="$TMPD" node "$HARNESS" adapters list) || RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"sast-semgrep"'; then
  pass "adapters list -> rc 0 含 sast-semgrep"
else
  fail "adapters list 应 rc 0（rc=$RC，输出：$OUT）"
fi
RC=0
OUT=$(cd "$TMPD" && CLAUDE_PROJECT_DIR="$TMPD" node "$HARNESS" adapters add secrets-gitleaks --dry-run) || RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"changed":true' \
   && ! grep -q 'secrets-gitleaks' "$TMPD/.claude/harness/module-catalog.json"; then
  pass "adapters add --dry-run -> rc 0 且不落盘"
else
  fail "adapters add --dry-run 应 rc 0 不落盘（rc=$RC，输出：$OUT）"
fi
RC=0
OUT=$(cd "$TMPD" && CLAUDE_PROJECT_DIR="$TMPD" node "$HARNESS" adapters add secrets-gitleaks) || RC=$?
if [ "$RC" -eq 0 ] && grep -q '"secrets-gitleaks"' "$TMPD/.claude/harness/module-catalog.json"; then
  pass "adapters add 真写 -> check 落进 catalog.checks"
else
  fail "adapters add 真写应落盘（rc=$RC，输出：$OUT）"
fi
RC=0
OUT=$(cd "$TMPD" && CLAUDE_PROJECT_DIR="$TMPD" node "$HARNESS" adapters add no-such-tool-xyz 2>/dev/null) || RC=$?
if [ "$RC" -eq 1 ]; then
  pass "adapters add 未知 id -> rc 1"
else
  fail "adapters add 未知 id 应 rc 1（rc=$RC，输出：$OUT）"
fi
rm -rf "$TMPD"

# ㉔ adr-check CLI：契约 = 无 ADR rc 0 / 缺执法或幽灵引用 rc 1 / manual-only 与 retired 放行
TMPADR="$(mktemp -d)"
# ㉔a 无任何 ADR 文档 -> rc 0 + records:0
RC=0
OUT=$(cd "$TMPADR" && CLAUDE_PROJECT_DIR="$TMPADR" node "$HARNESS" adr-check) || RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"records":0'; then
  pass "adr-check 无 ADR 文档 -> rc 0 nothing to enforce"
else
  fail "adr-check 无文档应 rc 0（rc=$RC，输出：$OUT）"
fi

# ㉔b 四条 ADR：机器执法 ok / manual-only ok / 缺执法 fail / 幽灵引用 fail / retired 豁免
cat > "$TMPADR/Architecture-Design.md" <<'EOF'
# Architecture Design

## 6. 架构决策记录（ADR）

### ADR-001：分层依赖
- **状态**：accepted
- **执法方式**：arch-check 禁边 / layers

### ADR-002：选 PostgreSQL
- **状态**：accepted
- **执法方式**：无法机器执法，靠评审

### ADR-003：缺执法的决策
- **状态**：accepted

### ADR-004：幽灵引用
- **状态**：accepted
- **执法方式**：ghost-gate-xyz

### ADR-005：已废弃的旧决策
- **状态**：superseded
EOF
RC=0
OUT=$(cd "$TMPADR" && CLAUDE_PROJECT_DIR="$TMPADR" node "$HARNESS" adr-check) || RC=$?
AOK=$(printf '%s' "$OUT" | python3 -c '
import sys,json
d=json.load(sys.stdin)
failing={f["id"] for f in d["failing"]}
ok = (d["ok"]==False and failing=={"ADR-003","ADR-004"}
  and "ADR-002" in d["manualOnly"] and "ADR-005" in d["retired"] and d["records"]==5)
print("OK" if ok else "BAD")
')
if [ "$RC" -eq 1 ] && [ "$AOK" = "OK" ]; then
  pass "adr-check 五态齐验 -> rc 1（缺执法+幽灵 fail；manual-only/retired/机器执法放行）"
else
  fail "adr-check 判定错（rc=$RC，aok=$AOK，输出：$OUT）"
fi

# ㉔c 修复缺口后 -> rc 0
python3 - "$TMPADR/Architecture-Design.md" <<'PY'
import sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
t = t.replace("### ADR-003：缺执法的决策\n- **状态**：accepted\n",
  "### ADR-003：缺执法的决策\n- **状态**：accepted\n- **执法方式**：fitness 规则 no-silent-failure\n")
t = t.replace("- **执法方式**：ghost-gate-xyz", "- **执法方式**：人工评审（ghost-gate-xyz 已改名）")
open(p, "w", encoding="utf-8").write(t)
PY
RC=0
OUT=$(cd "$TMPADR" && CLAUDE_PROJECT_DIR="$TMPADR" node "$HARNESS" adr-check) || RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"ok":true'; then
  pass "adr-check 修复执法引用后 -> rc 0"
else
  fail "adr-check 修复后应 rc 0（rc=$RC，输出：$OUT）"
fi
rm -rf "$TMPADR"

# ㉕ arch-trend 漂移棘轮端到端：record 基线（带债）-> 改善 record -> gate rc 0；回退 -> gate rc 1
TMPT="$(mktemp -d)"; mkdir -p "$TMPT/.claude/harness"
node -e '
  const fs = require("fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({
    version: 1,
    modules: [
      { id: "core", paths: ["core/**"], riskTier: "low" },
      { id: "web", paths: ["web/**"], riskTier: "low" }
    ], global: [], ignored: ["**/*.md"]
  }));
' "$TMPT/.claude/harness/module-catalog.json"
( cd "$TMPT" && git init -q && git config core.autocrlf false \
  && git config user.email t@t.t && git config user.name t \
  && mkdir -p core web \
  && echo "export const c = 1;" > core/c.ts \
  && printf 'import { c } from "../core/c";\nexport const w = c;\n' > web/w.ts \
  && git add -A && git commit -qm init ) >/dev/null 2>&1

# ㉕a 无趋势数据 -> arch-trend rc 0 + 提示先 record
RC=0
OUT=$(cd "$TMPT" && CLAUDE_PROJECT_DIR="$TMPT" node "$HARNESS" arch-trend) || RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"records":0'; then
  pass "arch-trend 无数据 -> rc 0 提示先 record"
else
  fail "arch-trend 无数据应 rc 0（rc=$RC，输出：$OUT）"
fi

# ㉕b 带债基线 record（web->core 未声明，undeclared=1，arch-check rc 1 但照记）
RC=0
OUT=$(cd "$TMPT" && CLAUDE_PROJECT_DIR="$TMPT" node "$HARNESS" arch-check --record) || RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q '"recordedTo":".claude/harness/trend/arch-trend.jsonl"'; then
  pass "arch-check --record 带债基线照记（rc 1 不挡记录）"
else
  fail "arch-check --record 应记录（rc=$RC，输出：$OUT）"
fi

# ㉕c 修 catalog 声明该边 -> record 改善 -> gate rc 0 + improved 含 undeclared
node -e '
  const fs = require("fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({
    version: 1,
    modules: [
      { id: "core", paths: ["core/**"], riskTier: "low" },
      { id: "web", paths: ["web/**"], riskTier: "low", dependsOn: ["core"] }
    ], global: [], ignored: ["**/*.md"]
  }));
' "$TMPT/.claude/harness/module-catalog.json"
( cd "$TMPT" && CLAUDE_PROJECT_DIR="$TMPT" node "$HARNESS" arch-check --record ) >/dev/null 2>&1 || true
RC=0
OUT=$(cd "$TMPT" && CLAUDE_PROJECT_DIR="$TMPT" node "$HARNESS" arch-trend --gate) || RC=$?
TOK=$(printf '%s' "$OUT" | python3 -c '
import sys,json
d=json.load(sys.stdin)
print("OK" if (d["ok"]==True and d["summary"]["undeclared"]["latest"]==0
  and any(i["metric"]=="undeclared" for i in d["improved"])) else "BAD")
')
if [ "$RC" -eq 0 ] && [ "$TOK" = "OK" ]; then
  pass "arch-trend --gate 改善 -> rc 0 + improved 记 undeclared 1->0"
else
  fail "arch-trend 改善应 rc 0（rc=$RC，tok=$TOK，输出：$OUT）"
fi

# ㉕d 回退（撤销声明，漂移重现）-> record -> gate rc 1 + regressed
node -e '
  const fs = require("fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({
    version: 1,
    modules: [
      { id: "core", paths: ["core/**"], riskTier: "low" },
      { id: "web", paths: ["web/**"], riskTier: "low" }
    ], global: [], ignored: ["**/*.md"]
  }));
' "$TMPT/.claude/harness/module-catalog.json"
( cd "$TMPT" && CLAUDE_PROJECT_DIR="$TMPT" node "$HARNESS" arch-check --record ) >/dev/null 2>&1 || true
RC=0
OUT=$(cd "$TMPT" && CLAUDE_PROJECT_DIR="$TMPT" node "$HARNESS" arch-trend --gate) || RC=$?
TOK=$(printf '%s' "$OUT" | python3 -c '
import sys,json
d=json.load(sys.stdin)
print("OK" if (d["ok"]==False and any(r["metric"]=="undeclared" and r["latest"]==1 and r["bestBefore"]==0 for r in d["regressed"])) else "BAD")
')
if [ "$RC" -eq 1 ] && [ "$TOK" = "OK" ]; then
  pass "arch-trend --gate 棘轮回退 -> rc 1 + regressed（undeclared 0->1 超历史最优）"
else
  fail "arch-trend 回退应 rc 1（rc=$RC，tok=$TOK，输出：$OUT）"
fi

# ㉕e 不带 --gate 纯报告 -> 永远 rc 0
RC=0
OUT=$(cd "$TMPT" && CLAUDE_PROJECT_DIR="$TMPT" node "$HARNESS" arch-trend) || RC=$?
if [ "$RC" -eq 0 ]; then
  pass "arch-trend 纯报告（无 --gate）-> rc 0 信息态"
else
  fail "arch-trend 纯报告应 rc 0（rc=$RC，输出：$OUT）"
fi
rm -rf "$TMPT"

echo ""
echo "结果：PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
