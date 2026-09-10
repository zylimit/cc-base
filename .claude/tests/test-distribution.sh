#!/usr/bin/env bash
# risk: high
# test-distribution.sh — 分发边界红锁：哪些东西该进安装产物 / 清单 / 发布包，哪些绝不该。
# 契约：tests/ 默认不装（要装得显式 --with-tests）、research/ 与 agent-memory/ 是本机私产永不分发；
# 清单侧同口径；release zip 里不含 progress*.md / docs/ / research/ / agent-memory/，但**含** tests/
# （zip 是 --with-tests 的料源，抽掉了 --with-tests 就成了空承诺）。
# 沙箱造法照抄 test-setup.sh：mktemp -d + git init + bash setup.sh <tmp>；
# 断言用 chk 逐条计数、不撞见第一条就 exit——六段互相独立，一次要看全各红在哪。
# 功能未实现期间整份为红，红因是「setup.sh 没有 --with-tests / 排除表没有这三项」，不是夹具坏。
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
[ -f "$ROOT/setup.sh" ]        || { echo "test-distribution: 仓库根缺 setup.sh：$ROOT" >&2; exit 1; }
[ -f "$ROOT/make-release.sh" ] || { echo "test-distribution: 仓库根缺 make-release.sh：$ROOT" >&2; exit 1; }
GEN_SH="$ROOT/.claude/scripts/gen-manifest.sh"
[ -f "$GEN_SH" ]               || { echo "test-distribution: 缺 gen-manifest.sh" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "test-distribution: $*" >&2; exit 1; }

PASS=0
FAIL=0
chk() {  # chk <0=通过/非0=失败> <标题> <EXPECT> <GOT>
  if [ "$1" = "0" ]; then
    PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$2"
  else
    FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$2"
  fi
  printf '         EXPECT %s\n' "$3"
  printf '         GOT    %s\n' "$4"
}
# 日志首行塞进 GOT，主 Agent 不用重跑就能分辨「没实现」和「夹具没搭起来」。
d_head() { head -1 "$1" 2>/dev/null | tr -d '\000-\011\013-\037\177' | cut -c1-140; }

mk_sandbox() {  # mk_sandbox <路径>——mktemp 里建目标目录并 git init（与 test-setup 沙箱同形）
  mkdir -p "$1"
  if command -v git >/dev/null 2>&1; then ( cd "$1" && git init -q . ) >/dev/null 2>&1 || true; fi
}

# ---- D-1 默认安装：tests/ research/ agent-memory/ 三个都不该出现 ----
T1="$TMP/d1"
mk_sandbox "$T1"
RC1=0
bash "$ROOT/setup.sh" "$T1" >"$TMP/d1.out" 2>"$TMP/d1.err" || RC1=$?
CL1="$T1/.claude"

ok=0; [ "$RC1" = "0" ] || ok=1
chk "$ok" "D-1a 默认安装（无 --with-tests）rc=0" \
  "rc=0" \
  "rc=$RC1 stderr=[$(d_head "$TMP/d1.err")] stdout=[$(d_head "$TMP/d1.out")]"

[ "$RC1" = "0" ] || fail "D-1 脚手架：默认安装就失败，后面五段的判别力全没了（见 $TMP/d1.err）"

for d in tests research agent-memory; do
  ok=0; [ ! -e "$CL1/$d" ] || ok=1
  chk "$ok" "D-1 默认安装不含 .claude/$d/" \
    "目标里不存在 .claude/$d（本机私产 / 框架自测，装进别人项目是脏数据）" \
    "存在=$([ -e "$CL1/$d" ] && echo yes || echo no) 文件数=$(find "$CL1/$d" -type f 2>/dev/null | wc -l | tr -d ' ')"
done

# ---- D-2 反向：排除表不许过宽（证明上面三条不是「整个装失败」蒙来的绿）----
hook_count=$(find "$CL1/hooks" -maxdepth 1 -type f -name '*.mjs' 2>/dev/null | wc -l | tr -d ' ')
ok=0; [ "$hook_count" = "22" ] || ok=1
chk "$ok" "D-2a hooks/*.mjs 装齐 22 个" \
  "22（21 个注册 hook + 未注册的 static-check；数量写死，多一个少一个都要人看一眼）" \
  "实得 $hook_count 个"

skill_count=$(find "$CL1/skills" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
ok=0; [ "$skill_count" -gt 0 ] 2>/dev/null || ok=1
chk "$ok" "D-2b skills/ 非空" \
  ">0 个 skill 目录" \
  "实得 $skill_count 个"

# ---- D-3 --with-tests：tests/ 装进来，另两个仍不许出现 ----
T2="$TMP/d2"
mk_sandbox "$T2"
RC2=0
bash "$ROOT/setup.sh" --with-tests "$T2" >"$TMP/d2.out" 2>"$TMP/d2.err" || RC2=$?
CL2="$T2/.claude"

ok=0; [ "$RC2" = "0" ] || ok=1
chk "$ok" "D-3a --with-tests 是被识别的开关、正常退出" \
  "rc=0（现在必红：setup.sh 的参数循环里 -* 一律 usage_die，--with-tests 会被当未知选项）" \
  "rc=$RC2 stderr=[$(d_head "$TMP/d2.err")]"

ok=0; [ -f "$CL2/tests/cases/run-all.sh" ] || ok=1
chk "$ok" "D-3b --with-tests 装出 tests/cases/run-all.sh" \
  "目标里存在 .claude/tests/cases/run-all.sh（装了测试就要能一把跑）" \
  "存在=$([ -f "$CL2/tests/cases/run-all.sh" ] && echo yes || echo no) tests 下文件数=$(find "$CL2/tests" -type f 2>/dev/null | wc -l | tr -d ' ')"

for d in research agent-memory; do
  ok=0; [ ! -e "$CL2/$d" ] || ok=1
  chk "$ok" "D-3c --with-tests 仍不含 .claude/$d/" \
    "开关只放行 tests/，不许顺带把私产一起带出去" \
    "存在=$([ -e "$CL2/$d" ] && echo yes || echo no) 文件数=$(find "$CL2/$d" -type f 2>/dev/null | wc -l | tr -d ' ')"
done

# ---- D-4 清单侧同口径：三项一条都不许登记进 FRAMEWORK-MANIFEST ----
# gen-manifest.sh 写的是本仓那份，跑前跑后钉 sha 并从备份还原——用 git checkout 还原的话，
# 工作树里本就有的未提交改动会被一起抹掉。
MANIFEST="$ROOT/.claude/FRAMEWORK-MANIFEST.txt"
[ -f "$MANIFEST" ] || fail "D-4 脚手架：本仓缺 $MANIFEST"
cp -p "$MANIFEST" "$TMP/manifest.backup"
MAN_SHA_BEFORE=$(sha256sum "$MANIFEST" | awk '{print $1}')
GRC=0
bash "$GEN_SH" >"$TMP/d4.out" 2>"$TMP/d4.err" || GRC=$?
listed=$(grep -cE '^(tests|research|agent-memory)/' "$MANIFEST" || true)
listed_names=$(grep -E '^(tests|research|agent-memory)/' "$MANIFEST" | cut -f1 | head -5 | tr '\n' ' ' || true)
cp -p "$TMP/manifest.backup" "$MANIFEST"
MAN_SHA_AFTER=$(sha256sum "$MANIFEST" | awk '{print $1}')

ok=0; [ "$GRC" = "0" ] || ok=1
chk "$ok" "D-4a gen-manifest.sh 跑通" \
  "rc=0" \
  "rc=$GRC stderr=[$(d_head "$TMP/d4.err")]"

ok=0; [ "$listed" = "0" ] || ok=1
chk "$ok" "D-4b MANIFEST 里 tests/ research/ agent-memory/ 条目数为 0" \
  "0 条（登记成框架文件的话，release 的 manifest 检查随手一跑就转 FAIL）" \
  "实得 $listed 条，头几条=[${listed_names}]"

ok=0; [ "$MAN_SHA_BEFORE" = "$MAN_SHA_AFTER" ] || ok=1
chk "$ok" "D-4c 跑完把 MANIFEST 还原（本测试不留痕）" \
  "还原后 sha256 与跑前一致 $MAN_SHA_BEFORE" \
  "跑后 $MAN_SHA_AFTER"

# ---- D-5 发布包边界：私产不进 zip，tests/ 必须在 zip 里 ----
ZRC=0
bash "$ROOT/make-release.sh" vTEST >"$TMP/d5.out" 2>"$TMP/d5.err" || ZRC=$?
ZIP=$(tail -1 "$TMP/d5.out" | tr -d '\r' | grep -oE '[^[:space:]]+\.zip' | tail -1 || true)
[ -n "$ZIP" ] || ZIP=$(grep -oE '[^[:space:]]+\.zip' "$TMP/d5.out" 2>/dev/null | tail -1 || true)
case "$ZIP" in /*) : ;; "") : ;; *) ZIP="$ROOT/$ZIP" ;; esac

ok=0
[ "$ZRC" = "0" ] || ok=1
[ -n "$ZIP" ] && [ -f "$ZIP" ] || ok=1
chk "$ok" "D-5a make-release.sh vTEST 产出 zip 并在末行给出路径" \
  "rc=0 且末行路径指向一个真实存在的 .zip" \
  "rc=$ZRC zip=[$ZIP] 存在=$([ -n "$ZIP" ] && [ -f "$ZIP" ] && echo yes || echo no) stderr=[$(d_head "$TMP/d5.err")]"

if [ -n "$ZIP" ] && [ -f "$ZIP" ]; then
  # 本机无 unzip，用 python3 的 zipfile 列条目（列全路径，不做任何裁剪）
  python3 - "$ZIP" >"$TMP/zip-entries.txt" <<'PY' || true
import sys, zipfile
print("\n".join(zipfile.ZipFile(sys.argv[1]).namelist()))
PY
  entries=$(grep -c . "$TMP/zip-entries.txt" || true)
  [ "$entries" -gt 0 ] || fail "D-5 脚手架：zip 条目列表为空（列包失败？$ZIP），后面的「不含」断言会恒绿"

  # 「不含」四组：按路径分量匹配，别用裸子串——progress.md 是 progress.archive.md 的子串，
  # 子串匹配红是红了，点名的却是另一份文件。
  for pair in \
    'progress.md|(^|/)progress\.md$' \
    'progress.archive.md|(^|/)progress\.archive\.md$' \
    'docs/|(^|/)docs/' \
    '.claude/research/|(^|/)\.claude/research/' \
    '.claude/agent-memory/|(^|/)\.claude/agent-memory/'
  do
    name=${pair%%|*}; pat=${pair#*|}
    hits=$(grep -cE "$pat" "$TMP/zip-entries.txt" || true)
    sample=$(grep -E "$pat" "$TMP/zip-entries.txt" | head -3 | tr '\n' ' ' || true)
    ok=0; [ "$hits" = "0" ] || ok=1
    chk "$ok" "D-5 zip 不含 $name" \
      "0 条（项目记忆 / 内部文档 / 本机私产不随包发出去）" \
      "实得 $hits 条，头几条=[$sample]"
  done

  wt_hits=$(grep -cE '(^|/)\.claude/tests/cases/run-all\.sh$' "$TMP/zip-entries.txt" || true)
  ok=0; [ "$wt_hits" -ge 1 ] 2>/dev/null || ok=1
  chk "$ok" "D-5 zip **含** .claude/tests/cases/run-all.sh" \
    "≥1 条（zip 是 --with-tests 的唯一料源，抽掉 tests/ 那个开关就成了空承诺）" \
    "实得 $wt_hits 条，包内 tests 条目数=$(grep -cE '(^|/)\.claude/tests/' "$TMP/zip-entries.txt" || true)"

  rm -f "$ZIP"
fi

# ---- D-6 未知选项仍拒（防 --with-tests 的解析把别的横杠参数一起放进来）----
T3="$TMP/d3"
mk_sandbox "$T3"
RC3=0
bash "$ROOT/setup.sh" --bogus "$T3" >"$TMP/d6.out" 2>"$TMP/d6.err" || RC3=$?
ok=0; [ "$RC3" = "2" ] || ok=1
chk "$ok" "D-6 未知选项 --bogus 仍以 rc=2 拒绝" \
  "rc=2（usage_die 的既有口径；加 --with-tests 时若把 -* 分支改成放行，这里当场红）" \
  "rc=$RC3 stderr=[$(d_head "$TMP/d6.err")] 目标被写=$([ -e "$T3/.claude" ] && echo yes || echo no)"

printf '==== test-distribution：PASS=%s FAIL=%s ====\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ] || exit 1
