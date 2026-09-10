#!/usr/bin/env bash
# risk: high
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
UNTRACKED_CASES="
.needs-review|.claude/.needs-review|STATE_EXCLUDE_PATHS
.needs-review.lock|.claude/.needs-review.lock|STATE_EXCLUDE_PATHS
.fast-mode|.claude/.fast-mode|STATE_EXCLUDE_PATHS
.tdd-exempt|.claude/.tdd-exempt|STATE_EXCLUDE_PATHS
.red-verified|.claude/.red-verified|STATE_EXCLUDE_PATHS
.runtime/supervisor/web/state.json|.claude/.runtime/|STATE_EXCLUDE_PREFIXES
evidence/run-1.log|.claude/evidence/|STATE_EXCLUDE_PREFIXES
harness/receipts/task-1.json|.claude/harness/receipts/|STATE_EXCLUDE_PREFIXES
harness/waivers/w-001.json|.claude/harness/waivers/|STATE_EXCLUDE_PREFIXES
harness/trend/arch-trend.jsonl|.claude/harness/trend/|STATE_EXCLUDE_PREFIXES
harness/state/nested/task.json|.claude/harness/state/|STATE_EXCLUDE_PREFIXES
harness/evidence/static-check.stdout|.claude/harness/evidence/|STATE_EXCLUDE_PREFIXES
worktrees/agent-x/foo.txt|.claude/worktrees/|STATE_EXCLUDE_PREFIXES
"

TRACKED_CASES="
.needs-review|:(exclude).claude/.needs-review
.needs-review.lock|:(exclude).claude/.needs-review.lock
.fast-mode|:(exclude).claude/.fast-mode
.tdd-exempt|:(exclude).claude/.tdd-exempt
.red-verified|:(exclude).claude/.red-verified
.runtime/supervisor/web/state.json|:(exclude).claude/.runtime/**
evidence/run-1.log|:(exclude).claude/evidence/**
harness/receipts/task-1.json|:(exclude).claude/harness/receipts/**
harness/waivers/w-001.json|:(exclude).claude/harness/waivers/**
harness/trend/arch-trend.jsonl|:(exclude).claude/harness/trend/**
harness/state/nested/task.json|:(exclude).claude/harness/state/**
harness/evidence/static-check.stdout|:(exclude).claude/harness/evidence/**
worktrees/agent-x/foo.txt|:(exclude).claude/worktrees/**
"

# ④/⑤ 是「每条表成员都有断言守着」，但表长出新成员时它们一声不吭——新成员天生免检，正是
#   ④ 头注释里那九条裸奔了很久的成因。这里把两边的成员集合直接比一次：core.mjs 加一条、
#   改一条、删一条，都会在这里红并打印出差在哪，逼着上面两段的用例表跟着长。
# 抽取自检写死条数（不写 >=）：抽取正则半坏时只抽到一部分，逐条比对会在空转而闸不响。
CORE_FILE="$(cd "$(dirname "$ENTRY")" && pwd)/lib/core.mjs"
EXP_EXCLUDE=13
EXP_PATHS=5
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

echo ""
echo "==== test-release-manifest：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ]
