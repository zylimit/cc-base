#!/usr/bin/env bash
# test-release-manifest.sh — release 的 manifest 项对「被排除文件」的排除规则回归（只需 node + git + sha256sum）。
# 锁的是 release.mjs MANIFEST_RULES：运行态产物、系统垃圾（.DS_Store / Thumbs.db / *.swp）与
#   Claude Code sub-agent 的 worktree 副本（.claude/worktrees/，⑦）在场时，manifest 项仍须 PASS、
#   unlisted 恒为 0。
#   这批规则此前没有任何测试守着——删掉它们，selftest 与 golden 都照样全绿，本机和 CI 都不会红。
# 造真文件不做字符串匹配：规则还在但 caseGlobToRegExp / manifestIncludes 被改坏，字符串匹配看不出来。
# 逐类单独跑一遍 release（每类 ~1.4s），所以删掉哪一条规则就红哪一条，报错直接点名到 pattern。
# 另有两条非退化对照，防「PASS 是因为什么都没检查」：
#   ① 未登记的**非**排除类文件必须让 manifest 判 FAIL 并点名（检查确实还在工作）
#   ② 带全部被排除文件跑 gen-manifest.sh，产物须与不带时逐字节一致（生成器与审计者两张表口径一致）
# 四份排除表的字面口径由 test-setup.sh ⑥ 比对；这里只管其中两份的行为。
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
mkdir -p "$ROOT/.claude/scripts" "$ROOT/.claude/rules" "$ROOT/.claude/hooks" "$ROOT/.claude/skills/demo" \
         "$ROOT/.claude/feedback/templates"
cp "$GEN" "$ROOT/.claude/scripts/gen-manifest.sh"
printf '# 沙箱主控\n' > "$ROOT/.claude/CLAUDE.md"
printf '# 沙箱规则\n'   > "$ROOT/.claude/rules/demo.md"
printf 'echo hi\n'      > "$ROOT/.claude/hooks/demo.sh"
printf '# demo skill\n' > "$ROOT/.claude/skills/demo/SKILL.md"
# 模板目录是 keep 臂，垃圾臂必须排在它前面才挡得住 feedback/templates/.DS_Store——
# 有这份文件在，臂序被挪动时下面那条用例就会红。
printf '# 模板\n'       > "$ROOT/.claude/feedback/templates/demo-template.md"
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

# ---- 逐类被排除的文件：造真文件 → release 的 manifest 项必须仍 PASS 且 unlisted=0 ----
# 两类都在这张表里：运行态产物，和 .claude/.gitignore 排除的系统垃圾（.DS_Store / Thumbs.db /
#   *.swp）——后者不挡就会被当成框架文件登记进清单、跟着安装器装进别人项目。
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
.DS_Store|.DS_Store
skills/demo/.DS_Store|*/.DS_Store
feedback/templates/.DS_Store|*/.DS_Store
Thumbs.db|Thumbs.db
hooks/Thumbs.db|*/Thumbs.db
hooks/demo.sh.swp|*.swp
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
    pass "排除项 .claude/$rel 在场（规则 $pattern）：manifest=PASS unlisted=0"
  else
    fail "排除项 .claude/$rel 在场（规则 $pattern 缺失或匹配逻辑坏了）：EXPECT PASS/0，GOT $M_STATUS/$M_UNLISTED · $M_SUMMARY · 点名 [$M_NAMES]"
  fi
  rm -f "$f"
  ALL_RUNTIME="$ALL_RUNTIME$rel
"
done
IFS=$OLDIFS

# ---- 全部被排除文件同时在场（真实现场就是这样：运行态和垃圾一起来）----
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
  pass "$COUNT 个被排除文件同时在场：manifest=PASS unlisted=0"
else
  fail "$COUNT 个被排除文件同时在场：EXPECT PASS/0，GOT $M_STATUS/$M_UNLISTED · $M_SUMMARY · 点名 [$M_NAMES]"
fi

# ---- 对照 ①：带着全部被排除文件重跑 gen-manifest.sh，产物须与干净时逐字节一致 ----
# 生成器和 release 是故意分开抄的两张表，这条锁的是它们不许分叉——任一侧漏一条都会让这里 diff。
bash "$ROOT/.claude/scripts/gen-manifest.sh" >/dev/null
if cmp -s "$BASE_MANIFEST" "$ROOT/.claude/FRAMEWORK-MANIFEST.txt"; then
  pass "对照：被排除文件在场时 gen-manifest 产物不变（生成器与 MANIFEST_RULES 口径一致）"
else
  fail "对照：被排除文件让 gen-manifest 产物变了，两张排除表已分叉：$(diff "$BASE_MANIFEST" "$ROOT/.claude/FRAMEWORK-MANIFEST.txt" | head -5 | tr '\n' ' ')"
fi

# ---- 对照 ②：未登记的**非**排除类文件必须让 manifest 判 FAIL 并点名 ----
# 没有这条，「manifestIncludes 一律返回 false」这种把检查废掉的改法会让上面全部照样绿。
# 先把被排除文件全清掉再造 orphan：排除规则真坏了时那批也会挤进 unlisted，点名列表被 capped()
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

# ---- 对照 ③：core.mjs STATE_EXCLUDE 挡住 .claude/.runtime/（diff 指纹不被 supervisor 运行态扰动）----
# 那张排除表是同一件事的第五、六份拷贝（gitignore / 生成器 / 两个安装器 / release / core），
#   .runtime/ 上一批只补了前四份。沙箱里没有 .claude/.gitignore，所以这里的 .runtime 正是
#   「没被 gitignore 兜住」的形态——真仓里一个曾被跟踪或被 force-add 的 .runtime 文件同形，
#   STATE_EXCLUDE 就是那一层，不能靠 gitignore 代劳。
diff_hash() {
  ( cd "$ROOT" && env -u CLAUDE_PROJECT_DIR node "$ENTRY" diff-hash 2>/dev/null ) \
    | sed -n 's/.*"diffHash":"\([0-9a-f]*\)".*/\1/p'
}
H_BASE=$(diff_hash)
mkdir -p "$ROOT/.claude/.runtime/supervisor/web"
printf 'pid 4242\n' > "$ROOT/.claude/.runtime/supervisor/web/state.json"
printf 'boot\n'     > "$ROOT/.claude/.runtime/supervisor/web/service.log"
H_RUNTIME=$(diff_hash)
if [ -n "$H_BASE" ] && [ "$H_BASE" = "$H_RUNTIME" ]; then
  pass "对照：.claude/.runtime/ 落文件不改 diff 指纹（core.mjs STATE_EXCLUDE 覆盖 .runtime/）"
else
  fail "对照：.claude/.runtime/ 扰动了 diff 指纹（STATE_EXCLUDE 漏 .runtime/）：base=$H_BASE after=$H_RUNTIME"
fi
# 非退化：真代码改动必须让指纹变，否则上面的「相等」可能只是 diff-hash 整体坏了
printf 'echo probe\n' > "$ROOT/.claude/hooks/probe.sh"
H_REAL=$(diff_hash)
if [ -n "$H_REAL" ] && [ "$H_REAL" != "$H_BASE" ]; then
  pass "对照：新增 hooks/probe.sh 改变 diff 指纹（排除表没宽到把真改动也吞掉）"
else
  fail "对照：新增 hooks/probe.sh 没改变 diff 指纹，上面那条相等是空转：base=$H_BASE after=$H_REAL"
fi
rm -rf "$ROOT/.claude/.runtime" "$ROOT/.claude/hooks/probe.sh"

# ---- 对照 ④：isStateExcluded 那两张表（untracked 分支，逐条）----
# ③ 只造了 `.claude/.runtime/` 一条 untracked 文件，那是 STATE_EXCLUDE_PREFIXES 七条里的**一条**，
#   STATE_EXCLUDE_PATHS 那三条一条没碰。删表实测：把 '.claude/evidence/'、'.claude/harness/state/'、
#   '.claude/.fast-mode' 里任意一条从表里删掉，③ + ⑤ + selftest(268) + golden(20127) 全部照样全绿——
#   十条里只有 `.runtime/` 那条真被守着，其余九条一直在裸奔。本段把它们逐条补齐。
# 与 ⑤ 的分工：这里造 untracked 文件走 hashUntracked() → isStateExcluded()；⑤ 把文件送进索引/HEAD
#   去走 canonicalDiff() 的 pathspec。同一批目录，两条互不相交的代码路径，删哪张表就红哪一段。
# 左列 = 相对 .claude/ 的路径；中列 = 它对应的表成员（红了直接点名）；右列 = 它属于哪张表。
UNTRACKED_CASES="
.needs-review|.claude/.needs-review|STATE_EXCLUDE_PATHS
.needs-review.lock|.claude/.needs-review.lock|STATE_EXCLUDE_PATHS
.fast-mode|.claude/.fast-mode|STATE_EXCLUDE_PATHS
.runtime/supervisor/web/state.json|.claude/.runtime/|STATE_EXCLUDE_PREFIXES
evidence/run-1.log|.claude/evidence/|STATE_EXCLUDE_PREFIXES
harness/receipts/task-1.json|.claude/harness/receipts/|STATE_EXCLUDE_PREFIXES
harness/waivers/w-001.json|.claude/harness/waivers/|STATE_EXCLUDE_PREFIXES
harness/trend/arch-trend.jsonl|.claude/harness/trend/|STATE_EXCLUDE_PREFIXES
harness/state/nested/task.json|.claude/harness/state/|STATE_EXCLUDE_PREFIXES
harness/evidence/static-check.stdout|.claude/harness/evidence/|STATE_EXCLUDE_PREFIXES
worktrees/agent-x/foo.txt|.claude/worktrees/|STATE_EXCLUDE_PREFIXES
"

# ④a 逐条造 untracked 文件，指纹都不许动
U_BASE=$(diff_hash)
OLDIFS=$IFS
IFS='
'
for line in $UNTRACKED_CASES; do
  [ -n "$line" ] || continue
  rel=$(printf '%s' "$line" | cut -d'|' -f1)
  member=$(printf '%s' "$line" | cut -d'|' -f2)
  table=$(printf '%s' "$line" | cut -d'|' -f3)
  f="$ROOT/.claude/$rel"
  mkdir -p "$(dirname "$f")"
  printf 'runtime-state-%s\n' "$rel" > "$f"
  H=$(diff_hash)
  if [ -n "$U_BASE" ] && [ "$H" = "$U_BASE" ]; then
    pass "④a 未跟踪的 .claude/$rel 不改 diff 指纹（$table 的 '$member' 在）"
  else
    fail "④a 未跟踪的 .claude/$rel 扰动了 diff 指纹——$table 缺 '$member'（untracked 分支走 isStateExcluded，不是 pathspec）：base=$U_BASE after=$H"
  fi
  rm -f "$f"
done
IFS=$OLDIFS

# ④b 非退化：未跟踪的**非**排除类文件必须让指纹变，否则上面 10 条相等只是 hashUntracked 整体失明
printf 'echo untracked-probe\n' > "$ROOT/.claude/hooks/untracked-probe.sh"
U_CTRL=$(diff_hash)
if [ -n "$U_CTRL" ] && [ "$U_CTRL" != "$U_BASE" ]; then
  pass "④b 对照：未跟踪的 hooks/untracked-probe.sh 改变 diff 指纹（hashUntracked 确实在看未跟踪文件，④a 那 10 条不是空转）"
else
  fail "④b 对照：未跟踪的 hooks/untracked-probe.sh 没改变 diff 指纹，hashUntracked 整体失明，④a 那 10 条全是空转：base=$U_BASE after=$U_CTRL"
fi
rm -f "$ROOT/.claude/hooks/untracked-probe.sh"

# ---- 对照 ⑤：STATE_EXCLUDE 那张 pathspec 表（tracked 分支，逐条）----
# ③ 和 ④ 造的都是 untracked 文件，走 hashUntracked() 里的 isStateExcluded()（= STATE_EXCLUDE_PATHS
#   + STATE_EXCLUDE_PREFIXES 那两张表）；canonicalDiff() 里 `git diff HEAD -- ...STATE_EXCLUDE` 那
#   **第三张**表只对已进索引/已被提交的路径起作用，③/④ 一次都碰不到。
#   实测：删掉 STATE_EXCLUDE 里任意一条 pathspec，③/④ 与 selftest（268）、golden（20127 断言）全绿。
# core.mjs 给这张表写的存在理由是「a path that was once tracked, or force-added」——两种形态各跑一遍
#   全部 10 条，逐条隔离，红了直接点名是哪条 pathspec 没了。各配一条非退化对照，防「相等」其实是
#   tracked 分支整体失明。
# 左边是相对 .claude/ 的路径，右边是它对应的 pathspec（`**` 的那几条特意放到嵌套层，顺带验 glob）。
TRACKED_CASES="
.needs-review|:(exclude).claude/.needs-review
.needs-review.lock|:(exclude).claude/.needs-review.lock
.fast-mode|:(exclude).claude/.fast-mode
.runtime/supervisor/web/state.json|:(exclude).claude/.runtime/**
evidence/run-1.log|:(exclude).claude/evidence/**
harness/receipts/task-1.json|:(exclude).claude/harness/receipts/**
harness/waivers/w-001.json|:(exclude).claude/harness/waivers/**
harness/trend/arch-trend.jsonl|:(exclude).claude/harness/trend/**
harness/state/nested/task.json|:(exclude).claude/harness/state/**
harness/evidence/static-check.stdout|:(exclude).claude/harness/evidence/**
"

# ⑤a force-add 形态：逐条进索引，指纹都不许动
H4_BASE=$(diff_hash)
ALL_TRACKED=""
OLDIFS=$IFS
IFS='
'
for line in $TRACKED_CASES; do
  [ -n "$line" ] || continue
  rel=${line%%|*}
  pattern=${line#*|}
  f="$ROOT/.claude/$rel"
  mkdir -p "$(dirname "$f")"
  printf 'runtime-state-%s\n' "$rel" > "$f"
  ( cd "$ROOT" && git add -f -- ".claude/$rel" )
  H=$(diff_hash)
  if [ -n "$H4_BASE" ] && [ "$H" = "$H4_BASE" ]; then
    pass "⑤a force-add .claude/$rel 进索引不改 diff 指纹（pathspec $pattern 在）"
  else
    fail "⑤a force-add .claude/$rel 扰动了 diff 指纹——STATE_EXCLUDE 缺 '$pattern'（tracked 分支，非 STATE_EXCLUDE_PREFIXES）：base=$H4_BASE after=$H"
  fi
  ( cd "$ROOT" && git reset -q -- ".claude/$rel" )
  rm -f "$f"
  ALL_TRACKED="$ALL_TRACKED$rel
"
done
IFS=$OLDIFS

# ⑤b 非退化：同样进索引的**非**排除类文件必须让指纹变，否则上面 10 条相等可能只是 tracked 分支不看索引
printf 'echo staged-probe\n' > "$ROOT/.claude/hooks/staged-probe.sh"
( cd "$ROOT" && git add -- .claude/hooks/staged-probe.sh )
H4_CTRL=$(diff_hash)
if [ -n "$H4_CTRL" ] && [ "$H4_CTRL" != "$H4_BASE" ]; then
  pass "⑤b 对照：进索引的 hooks/staged-probe.sh 改变 diff 指纹（tracked 分支确实在看索引，⑤a 那 10 条不是空转）"
else
  fail "⑤b 对照：进索引的 hooks/staged-probe.sh 没改变 diff 指纹，tracked 分支整体失明，⑤a 那 10 条全是空转：base=$H4_BASE after=$H4_CTRL"
fi
( cd "$ROOT" && git reset -q -- .claude/hooks/staged-probe.sh )
rm -f "$ROOT/.claude/hooks/staged-probe.sh"

# ⑤c once-tracked 形态：全部提交进 HEAD，再逐条改内容——改动落在 tracked diff 上，同一张表的另一种形态
OLDIFS=$IFS
IFS='
'
for rel in $ALL_TRACKED; do
  [ -n "$rel" ] || continue
  f="$ROOT/.claude/$rel"
  mkdir -p "$(dirname "$f")"
  printf 'runtime-state-%s\n' "$rel" > "$f"
  ( cd "$ROOT" && git add -f -- ".claude/$rel" )
done
IFS=$OLDIFS
( cd "$ROOT" && git -c user.email=t@example.com -c user.name=t commit -qm runtime-tracked ) >/dev/null
H4_BASE2=$(diff_hash)
OLDIFS=$IFS
IFS='
'
for line in $TRACKED_CASES; do
  [ -n "$line" ] || continue
  rel=${line%%|*}
  pattern=${line#*|}
  f="$ROOT/.claude/$rel"
  printf 'runtime-state-%s-CHANGED\n' "$rel" > "$f"
  H=$(diff_hash)
  if [ -n "$H4_BASE2" ] && [ "$H" = "$H4_BASE2" ]; then
    pass "⑤c 已跟踪的 .claude/$rel 改内容不改 diff 指纹（pathspec $pattern 的 once-tracked 形态）"
  else
    fail "⑤c 已跟踪的 .claude/$rel 改内容就扰动了 diff 指纹——STATE_EXCLUDE 缺 '$pattern'：base=$H4_BASE2 after=$H"
  fi
  printf 'runtime-state-%s\n' "$rel" > "$f"
done
IFS=$OLDIFS

# ⑤d 非退化：改普通已跟踪文件必须让指纹变
printf 'echo appended\n' >> "$ROOT/.claude/hooks/demo.sh"
H4_CTRL2=$(diff_hash)
if [ -n "$H4_CTRL2" ] && [ "$H4_CTRL2" != "$H4_BASE2" ]; then
  pass "⑤d 对照：改已跟踪的 hooks/demo.sh 改变 diff 指纹（排除表没宽到把真改动也吞掉）"
else
  fail "⑤d 对照：改已跟踪的 hooks/demo.sh 没改变 diff 指纹，⑤c 那 10 条全是空转：base=$H4_BASE2 after=$H4_CTRL2"
fi


# ---- 对照 ⑥：本文件的用例表与 core.mjs 三张排除表对拍（加了第 11 条时测试自己会红）----
# ④/⑤ 是「每条表成员都有断言守着」，但表长出新成员时它们一声不吭——新成员天生免检，正是
#   ④ 头注释里那九条裸奔了很久的成因。这里把两边的成员集合直接比一次：core.mjs 加一条、
#   改一条、删一条，都会在这里红并打印出差在哪，逼着上面两段的用例表跟着长。
# 抽取自检写死条数（不写 >=）：抽取正则半坏时只抽到一部分，逐条比对会在空转而闸不响。
CORE_FILE="$(cd "$(dirname "$ENTRY")" && pwd)/lib/core.mjs"
EXP_EXCLUDE=10
EXP_PATHS=3
EXP_PREFIXES=8

# 从被测那份 core.mjs 里把数组字面量的字符串成员抠出来（单引号用 charCode 拼，避开 shell 引号地狱）
dump_table() {
  node -e '
const fs = require("fs");
const Q = String.fromCharCode(39);
const src = fs.readFileSync(process.argv[1], "utf8");
const m = new RegExp("const\\s+" + process.argv[2] + "\\s*=\\s*\\[([^\\]]*)\\]").exec(src);
if (!m) { console.log("<TABLE-NOT-FOUND>"); process.exit(0); }
const re = new RegExp(Q + "([^" + Q + "]*)" + Q, "g");
const out = [];
let x;
while ((x = re.exec(m[1])) !== null) out.push(x[1]);
for (const v of out) console.log(v);
' "$CORE_FILE" "$1" 2>/dev/null
}

# ⑥ 逐表比对
cmp_table() { # $1=core 表名  $2=写死条数  $3=本文件的成员清单（已排序）  $4=来源说明
  local tname="$1" want="$2" mine="$3" src="$4"
  local got n_got n_mine
  got=$(dump_table "$tname" | sort)
  n_got=$(printf '%s\n' "$got" | sed '/^$/d' | wc -l | tr -d ' ')
  n_mine=$(printf '%s\n' "$mine" | sed '/^$/d' | wc -l | tr -d ' ')
  if [ "$got" = "<TABLE-NOT-FOUND>" ] || [ "$n_got" -eq 0 ]; then
    fail "⑥ 抽取坏了：在 $CORE_FILE 里没抠出 $tname 的成员（不是表变了，是本段的抽取正则失效了）"
    return
  fi
  if [ "$n_got" -ne "$want" ] || [ "$n_mine" -ne "$want" ]; then
    fail "⑥ $tname 条数对不上：core.mjs=$n_got 本文件$src=$n_mine 写死期望=$want。core 独有：[$(comm -23 <(printf '%s\n' "$got") <(printf '%s\n' "$mine") | tr '\n' ' ')] 本文件独有：[$(comm -13 <(printf '%s\n' "$got") <(printf '%s\n' "$mine") | tr '\n' ' ')]"
    return
  fi
  if [ "$got" = "$mine" ]; then
    pass "⑥ $tname 的 $want 条成员与本文件$src 逐条一致（表长新成员时这里会红）"
  else
    fail "⑥ $tname 与本文件$src 成员不一致。core 独有：[$(comm -23 <(printf '%s\n' "$got") <(printf '%s\n' "$mine") | tr '\n' ' ')] 本文件独有：[$(comm -13 <(printf '%s\n' "$got") <(printf '%s\n' "$mine") | tr '\n' ' ')]"
  fi
}

MINE_EXCLUDE=$(printf '%s\n' "$TRACKED_CASES" | sed '/^$/d' | cut -d'|' -f2 | sort)
MINE_PATHS=$(printf '%s\n' "$UNTRACKED_CASES" | sed '/^$/d' | awk -F'|' '$3=="STATE_EXCLUDE_PATHS"{print $2}' | sort)
MINE_PREFIXES=$(printf '%s\n' "$UNTRACKED_CASES" | sed '/^$/d' | awk -F'|' '$3=="STATE_EXCLUDE_PREFIXES"{print $2}' | sort)

cmp_table STATE_EXCLUDE          "$EXP_EXCLUDE"  "$MINE_EXCLUDE"  "TRACKED_CASES"
cmp_table STATE_EXCLUDE_PATHS    "$EXP_PATHS"    "$MINE_PATHS"    "UNTRACKED_CASES(PATHS)"
cmp_table STATE_EXCLUDE_PREFIXES "$EXP_PREFIXES" "$MINE_PREFIXES" "UNTRACKED_CASES(PREFIXES)"

# ---- ⑦ Claude Code 的 .claude/worktrees/ 不是框架文件 ----
# sub-agent 的 worktree 隔离会在 .claude/worktrees/<agent>/ 下建一整棵仓副本——里面有它自己的
#   .claude/harness/harness.mjs、自己的 README.md，文件名与框架文件一模一样。六份排除表里
#   **一份都没有** worktrees/，所以四个 worktree 在场时它们整棵被当成框架文件：进清单、被
#   release 判 unlisted、扰动 diff 指纹。上面 ①~⑥ 全绿也照样漏，因为那几张表压根没这一条。
# 契约：`.claude/worktrees/` 整目录按**根锚定**排除（任意层级下的 worktrees/ 只认 .claude/ 那份），
#   本段管其中三面：生成器不收、release 不判 unlisted、untracked 指纹不计入。
#   ④a 已按 STATE_EXCLUDE_PREFIXES 的表成员单独锁了平铺形态（worktrees/agent-x/foo.txt），
#   这里补的是真实形态——副本里**还有一层 .claude/**，naive 的 `*/.claude/**` 类规则会在这里翻车。
# 前置还原：⑤d 往 hooks/demo.sh 追加过内容，不还原的话 manifest 项会因 digestChanged 而 FAIL，
#   ⑦b 的红就会记到错的账上。
printf 'echo hi\n' > "$ROOT/.claude/hooks/demo.sh"
cp "$BASE_MANIFEST" "$ROOT/.claude/FRAMEWORK-MANIFEST.txt"
release_manifest
if [ "$M_STATUS" = "PASS" ] && [ "$M_UNLISTED" = "0" ]; then
  pass "⑦ 脚手架：造 worktrees 之前 manifest=PASS unlisted=0（⑦b 的红只能由 worktrees 造成）"
else
  fail "⑦ 脚手架：造 worktrees 之前就不干净，EXPECT PASS/0，GOT $M_STATUS/$M_UNLISTED · $M_SUMMARY · 点名 [$M_NAMES]"
fi

WT_DEEP="worktrees/agent-x/.claude/harness/harness.mjs"
WT_TOP="worktrees/agent-x/README.md"
mkdir -p "$ROOT/.claude/worktrees/agent-x/.claude/harness"
printf 'export const wt = 1;\n' > "$ROOT/.claude/worktrees/agent-x/.claude/harness/harness.mjs"
printf '# worktree 副本的 README\n'  > "$ROOT/.claude/worktrees/agent-x/README.md"

# ⑦a 生成器：清单里不许出现 worktrees/ 开头的条目
bash "$ROOT/.claude/scripts/gen-manifest.sh" >/dev/null
WT_IN_MANIFEST=$(grep -c '^worktrees/' "$ROOT/.claude/FRAMEWORK-MANIFEST.txt" || true)
if [ "$WT_IN_MANIFEST" = "0" ]; then
  pass "⑦a gen-manifest.sh 不把 .claude/worktrees/ 下的文件收进清单"
else
  fail "⑦a gen-manifest.sh 把 worktree 副本当框架文件登记进清单（缺 worktrees/* 臂）：$(grep '^worktrees/' "$ROOT/.claude/FRAMEWORK-MANIFEST.txt" | cut -f1 | tr '\n' ' ')"
fi
# ⑦a2 与干净清单逐字节一致——比「不含 worktrees/」更严：条目内容、条数、排序都不许被搅动
if cmp -s "$BASE_MANIFEST" "$ROOT/.claude/FRAMEWORK-MANIFEST.txt"; then
  pass "⑦a2 worktree 副本在场时 gen-manifest 产物与干净时逐字节一致"
else
  fail "⑦a2 worktree 副本改变了 gen-manifest 产物：$(diff "$BASE_MANIFEST" "$ROOT/.claude/FRAMEWORK-MANIFEST.txt" | head -5 | tr '\n' ' ')"
fi

# ⑦b release 的 manifest 项：worktree 副本不许被判成 unlisted
# 必须先把清单还原成干净版——生成器现在正把这两个文件收进清单，不还原就是拿被审者的漂移
#   给审计者开后门，⑦b 会假绿。
cp "$BASE_MANIFEST" "$ROOT/.claude/FRAMEWORK-MANIFEST.txt"
release_manifest
if [ "$M_STATUS" = "PASS" ] && [ "$M_UNLISTED" = "0" ]; then
  pass "⑦b worktree 副本在场：release 的 manifest 项 PASS unlisted=0（MANIFEST_RULES 有 worktrees/* 且 keep:false）"
else
  fail "⑦b worktree 副本被 release 判成 unlisted——MANIFEST_RULES 缺 worktrees/*：EXPECT PASS/0，GOT $M_STATUS/$M_UNLISTED · $M_SUMMARY · 点名 [$M_NAMES]"
fi
rm -rf "$ROOT/.claude/worktrees"

# ⑦c diff 指纹：untracked 的 worktree 副本不许扰动 gitFingerprint
# 走的是 hashUntracked() → isStateExcluded()，即 STATE_EXCLUDE_PREFIXES 那张表（④ 那条同表）。
# 沙箱仓已在 ⑤c 提交过，这里新建的两份都是 untracked。
cp "$BASE_MANIFEST" "$ROOT/.claude/FRAMEWORK-MANIFEST.txt"
W_BASE=$(diff_hash)
mkdir -p "$ROOT/.claude/worktrees/agent-x/.claude/hooks"
printf 'echo wt\n'  > "$ROOT/.claude/worktrees/agent-x/.claude/hooks/notify.sh"
printf '# 副本\n'    > "$ROOT/.claude/worktrees/agent-x/README.md"
W_AFTER=$(diff_hash)
if [ -n "$W_BASE" ] && [ "$W_BASE" = "$W_AFTER" ]; then
  pass "⑦c 未跟踪的 .claude/worktrees/agent-x/**（含内层 .claude/）不改 diff 指纹"
else
  fail "⑦c worktree 副本扰动了 diff 指纹——STATE_EXCLUDE_PREFIXES 缺 '.claude/worktrees/'：base=$W_BASE after=$W_AFTER"
fi
rm -rf "$ROOT/.claude/worktrees"

# ⑦d 非退化对照：普通未跟踪文件必须让指纹变，否则 ⑦c 的相等只是 hashUntracked 整体失明
printf 'echo wt-probe\n' > "$ROOT/.claude/hooks/wt-probe.sh"
W_CTRL=$(diff_hash)
if [ -n "$W_CTRL" ] && [ "$W_CTRL" != "$W_BASE" ]; then
  pass "⑦d 对照：未跟踪的 hooks/wt-probe.sh 改变 diff 指纹（⑦c 不是空转）"
else
  fail "⑦d 对照：未跟踪的 hooks/wt-probe.sh 没改变 diff 指纹，⑦c 是空转：base=$W_BASE after=$W_CTRL"
fi
rm -f "$ROOT/.claude/hooks/wt-probe.sh"

echo ""
echo "==== test-release-manifest：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ]
