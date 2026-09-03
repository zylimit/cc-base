#!/usr/bin/env bash
# test-release-manifest.sh — release 的 manifest 项对「运行态文件」的排除规则回归（只需 node + git + sha256sum）。
# 锁的是 release.mjs MANIFEST_RULES：运行态文件在场时 manifest 项仍须 PASS、unlisted 恒为 0。
#   这批规则此前没有任何测试守着——删掉它们，selftest 与 golden 都照样全绿，本机和 CI 都不会红。
# 造真文件不做字符串匹配：规则还在但 caseGlobToRegExp / manifestIncludes 被改坏，字符串匹配看不出来。
# 逐类单独跑一遍 release（每类 ~1.4s），所以删掉哪一条规则就红哪一条，报错直接点名到 pattern。
# 另有两条非退化对照，防「PASS 是因为什么都没检查」：
#   ① 未登记的**非**运行态文件必须让 manifest 判 FAIL 并点名（检查确实还在工作）
#   ② 带全部运行态文件跑 gen-manifest.sh，产物须与不带时逐字节一致（生成器与审计者两张表口径一致）
# 沙箱隔离：release 读的是 projectRoot()（CLAUDE_PROJECT_DIR 或 cwd），所以在 mktemp 的 git 仓里
#   cd 进去跑、并 env -u CLAUDE_PROJECT_DIR，对本仓纯只读，不会把运行态垃圾造进 .claude/。
# 用法：bash test-release-manifest.sh [harness.mjs 路径]
#   带参数是给突变验证用的——把引擎整目录拷到 /tmp、在副本上删规则，跑同一份断言看它红不红。
set -eu

SRC=$(cd "$(dirname "$0")/.." && pwd)
ENTRY=${1:-"$SRC/harness/harness.mjs"}
GEN="$SRC/scripts/gen-manifest.sh"

echo "===== test-release-manifest ====="
command -v node >/dev/null 2>&1 || { echo "SKIPPED: 无 node——未执行 != 通过。"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIPPED: 无 git——未执行 != 通过。"; exit 0; }
command -v sha256sum >/dev/null 2>&1 || { echo "SKIPPED: 无 sha256sum（gen-manifest 依赖）——未执行 != 通过。"; exit 0; }
[ -f "$ENTRY" ] || { echo "test-release-manifest: 找不到引擎入口 $ENTRY" >&2; exit 1; }
[ -f "$GEN" ] || { echo "test-release-manifest: 找不到 $GEN" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  [PASS] $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }

# ---- 沙箱：一个最小 git 仓 + 最小 .claude 框架层 ----
ROOT="$TMP/proj"
mkdir -p "$ROOT/.claude/scripts" "$ROOT/.claude/rules" "$ROOT/.claude/hooks" "$ROOT/.claude/skills/demo"
cp "$GEN" "$ROOT/.claude/scripts/gen-manifest.sh"
printf '# 沙箱主控\n' > "$ROOT/.claude/CLAUDE.md"
printf '# 沙箱规则\n'   > "$ROOT/.claude/rules/demo.md"
printf 'echo hi\n'      > "$ROOT/.claude/hooks/demo.sh"
printf '# demo skill\n' > "$ROOT/.claude/skills/demo/SKILL.md"
( cd "$ROOT" && git init -q . && git add -A \
  && git -c user.email=t@example.com -c user.name=t commit -qm init ) >/dev/null

# 清单由**真正的** gen-manifest.sh 生成，不手搓——手搓的清单只能证明 release 自洽，
#   证明不了它和生成器口径一致，而这两张表分叉正是 MANIFEST_RULES 要防的事。
bash "$ROOT/.claude/scripts/gen-manifest.sh" >/dev/null
BASE_MANIFEST="$TMP/manifest.base"
cp "$ROOT/.claude/FRAMEWORK-MANIFEST.txt" "$BASE_MANIFEST"

# OUT/M_STATUS/M_UNLISTED/M_SUMMARY/M_NAMES 由 release_manifest 回填
OUT=""; M_STATUS=""; M_UNLISTED=""; M_SUMMARY=""; M_NAMES=""; R_RC=0
release_manifest() {
  R_RC=0
  OUT=$( cd "$ROOT" && env -u CLAUDE_PROJECT_DIR node "$ENTRY" release 2>/dev/null ) || R_RC=$?
  local parsed
  parsed=$(printf '%s' "$OUT" | node -e '
let s = "";
process.stdin.on("data", d => s += d).on("end", () => {
  let j;
  try { j = JSON.parse(s); } catch (e) { console.log(["PARSE-ERR", "-1", "stdout 不是 JSON: " + e.message, ""].join("\t")); return; }
  const m = (j.checks || []).find(c => c.id === "manifest");
  if (!m) { console.log(["ABSENT", "-1", "checks 里没有 manifest 项", ""].join("\t")); return; }
  // unlisted 从 summary 的计数取，不从 evidence 数组长度取——那个列表被 capped() 截断过。
  const hit = /(\d+) unlisted/.exec(String(m.summary || ""));
  const unlisted = m.status === "PASS" ? 0 : (hit ? Number(hit[1]) : -1);
  const ev = m.evidence || {};
  const names = [].concat(ev.missingFromManifest || [], (ev.staleInManifest || []).map(x => "stale:" + x),
    (ev.digestChanged || []).map(x => "changed:" + x)).join(",");
  console.log([m.status, String(unlisted), String(m.summary || ""), names].join("\t"));
});') || parsed="PARSE-ERR	-1	node 解析器自身失败	"
  M_STATUS=$(printf '%s' "$parsed" | cut -f1)
  M_UNLISTED=$(printf '%s' "$parsed" | cut -f2)
  M_SUMMARY=$(printf '%s' "$parsed" | cut -f3)
  M_NAMES=$(printf '%s' "$parsed" | cut -f4)
}

# ---- 脚手架自证：沙箱真的搭起来了，红了不许赖在行为断言头上 ----
release_manifest
if [ "$M_STATUS" = "PASS" ] && [ "$M_UNLISTED" = "0" ]; then
  pass "脚手架：干净沙箱下 manifest=PASS unlisted=0（EXPECT PASS/0，GOT $M_STATUS/$M_UNLISTED · $M_SUMMARY）"
else
  fail "脚手架：干净沙箱本该 PASS/0，GOT $M_STATUS/$M_UNLISTED · $M_SUMMARY · $M_NAMES（release rc=$R_RC）"
fi
if grep -q '^CLAUDE.md	' "$BASE_MANIFEST" && [ "$(grep -vc '^#' "$BASE_MANIFEST")" -ge 4 ]; then
  pass "脚手架：gen-manifest 写出了 $(grep -vc '^#' "$BASE_MANIFEST") 条框架文件（非空清单）"
else
  fail "脚手架：清单为空或缺 CLAUDE.md，后续 PASS 会是空转（内容：$(cat "$BASE_MANIFEST")）"
fi

# ---- 逐类运行态文件：造真文件 → release 的 manifest 项必须仍 PASS 且 unlisted=0 ----
# 左边是相对 .claude/ 的路径，右边是对应的 MANIFEST_RULES pattern（红了直接报出是哪条规则没了）。
RUNTIME_CASES="
.stop-gate-strikes|.stop-gate-strikes
.precompact-block-epoch|.precompact-block-epoch
.async-verify-last|.async-verify-last
harness/state/ledger-head.json|harness/state/*
harness/state/nested/task.json|harness/state/*
harness/waivers/w-001.json|harness/waivers/*
harness/trend/2026-09-03.json|harness/trend/*
harness/evidence/static-check.stdout|harness/evidence/*
harness/receipts/task-1.json|harness/receipts/*
.runtime/supervisor.json|.runtime/*
.runtime/logs/app.log|.runtime/*
evidence/run-1.log|evidence/*
signals.jsonl|signals.jsonl
skills/demo/signals.jsonl|*/signals.jsonl
"

# 用 for + IFS 换行遍历而不是 while read：管道里的 while 是子 shell，PASS/FAIL 计数加不回来。
ALL_RUNTIME=""
OLDIFS=$IFS
IFS='
'
for line in $RUNTIME_CASES; do
  [ -n "$line" ] || continue
  rel=${line%%|*}
  pattern=${line#*|}
  f="$ROOT/.claude/$rel"
  mkdir -p "$(dirname "$f")"
  printf 'runtime-state-%s\n' "$rel" > "$f"
  release_manifest
  if [ "$M_STATUS" = "PASS" ] && [ "$M_UNLISTED" = "0" ]; then
    pass "运行态 .claude/$rel 在场（规则 $pattern）：manifest=PASS unlisted=0"
  else
    fail "运行态 .claude/$rel 在场（规则 $pattern 缺失或匹配逻辑坏了）：EXPECT PASS/0，GOT $M_STATUS/$M_UNLISTED · $M_SUMMARY · 点名 [$M_NAMES]"
  fi
  rm -f "$f"
  ALL_RUNTIME="$ALL_RUNTIME$rel
"
done
IFS=$OLDIFS

# ---- 全部运行态文件同时在场（真实现场就是这样：一次 18 个）----
COUNT=0
OLDIFS=$IFS
IFS='
'
for rel in $ALL_RUNTIME; do
  [ -n "$rel" ] || continue
  f="$ROOT/.claude/$rel"
  mkdir -p "$(dirname "$f")"
  printf 'runtime-state-%s\n' "$rel" > "$f"
  COUNT=$((COUNT + 1))
done
IFS=$OLDIFS
release_manifest
if [ "$M_STATUS" = "PASS" ] && [ "$M_UNLISTED" = "0" ]; then
  pass "$COUNT 个运行态文件同时在场：manifest=PASS unlisted=0"
else
  fail "$COUNT 个运行态文件同时在场：EXPECT PASS/0，GOT $M_STATUS/$M_UNLISTED · $M_SUMMARY · 点名 [$M_NAMES]"
fi

# ---- 对照 ①：带着全部运行态文件重跑 gen-manifest.sh，产物须与干净时逐字节一致 ----
# 生成器和 release 是故意分开抄的两张表，这条锁的是它们不许分叉——任一侧漏一条都会让这里 diff。
bash "$ROOT/.claude/scripts/gen-manifest.sh" >/dev/null
if cmp -s "$BASE_MANIFEST" "$ROOT/.claude/FRAMEWORK-MANIFEST.txt"; then
  pass "对照：运行态文件在场时 gen-manifest 产物不变（生成器与 MANIFEST_RULES 口径一致）"
else
  fail "对照：运行态文件让 gen-manifest 产物变了，两张排除表已分叉：$(diff "$BASE_MANIFEST" "$ROOT/.claude/FRAMEWORK-MANIFEST.txt" | head -5 | tr '\n' ' ')"
fi

# ---- 对照 ②：未登记的**非**运行态文件必须让 manifest 判 FAIL 并点名 ----
# 没有这条，「manifestIncludes 一律返回 false」这种把检查废掉的改法会让上面全部照样绿。
# 先把运行态文件全清掉再造 orphan：排除规则真坏了时那批也会挤进 unlisted，点名列表被 capped()
#   截断后 orphan.sh 就看不见了——这条对照的红绿必须只由 orphan.sh 决定。
OLDIFS=$IFS
IFS='
'
for rel in $ALL_RUNTIME; do
  [ -n "$rel" ] || continue
  rm -f "$ROOT/.claude/$rel"
done
IFS=$OLDIFS
printf 'echo orphan\n' > "$ROOT/.claude/hooks/orphan.sh"
release_manifest
case "$M_STATUS/$M_NAMES" in
  FAIL/*hooks/orphan.sh*) pass "对照：未登记的 hooks/orphan.sh 让 manifest 判 FAIL 且点名（unlisted=$M_UNLISTED）" ;;
  *) fail "对照：未登记的 hooks/orphan.sh 本该 FAIL 并点名，GOT $M_STATUS/$M_UNLISTED · $M_SUMMARY · 点名 [$M_NAMES]" ;;
esac
rm -f "$ROOT/.claude/hooks/orphan.sh"

echo ""
echo "==== test-release-manifest：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ]
