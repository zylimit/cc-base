#!/usr/bin/env bash
# test-golden-mutate.sh — harness-golden.mjs 的 `--mutate` 突变尺子回归（只需 node + git + sha256sum）。
#
# 锁的是「谁来量这把尺子」：golden 有 20127 条断言，但没人证明过它们**挡得住什么**。
#   --mutate 往 .claude/harness/lib/*.mjs 里按清单注入一处真改动，跑一遍 --check，
#   有差异 = killed（尺子看得见），无差异 = survived（尺子这块是瞎的）。
# 本文件写在实现之前，整体现在必红——红因是 `--mutate` 模式还不存在（裸跑打 usage、rc 2、stdout 空）。
#
# 三件事这里必须一起守，少一件这把尺子就会说谎：
#   ① killed 判定真的存在（一条必然改变 catalog-good 输出的突变，必须报 killed）
#   ② survived 判定也真的存在（一条纯注释突变必须报 survived）——否则「恒 killed」也能全绿
#   ③ 清单坏了不许当 killed（find 在目标文件里一次都找不到 → not-applicable + 计入失败）
# 外加两条防砖：跑完源码必须逐字节还原；目标文件有未提交改动时必须拒跑，且**不许顺手抹掉**那些改动。
#
# 为什么不走 /tmp 副本：golden 的 loadFx() 按引擎位置往上找 tests/fixtures/，副本跑起来是
#   fixture load failed。所以突变只能在仓内做——本文件自己 cp 备份 + trap 还原 + sha256 复核，
#   并以「目标文件干净」为前置条件，脏了直接 SKIPPED，绝不拿别人的在制品当试验田。
# 为什么钉 --scenario catalog-good：全量 --check 实测 2m52s（9 场景 + in-repo），单场景 ~18s，
#   四次运行才跑得完；catalog-good 是 catalog 在场的主场景，改 catalogFilePath 一定看得见。
# 用法：bash test-golden-mutate.sh [harness-golden.mjs 路径]
#   带参数是给候选实现验证用的：把候选实现放成 .claude/tests/harness-golden-<x>.mjs 再指过来，
#   跑同一份断言看它转不转绿。**候选必须仍放在 .claude/tests/ 下**——那个文件所有路径
#   （REPO_ROOT / fixtures / golden 基线）都从 `path.dirname(import.meta.url)` 推，挪去 /tmp 直接找不到基线。
set -eu

SRC=$(cd "$(dirname "$0")/.." && pwd)
REPO=$(cd "$SRC/.." && pwd)
GOLDEN=${1:-"$SRC/tests/harness-golden.mjs"}
MUTANTS="$SRC/tests/golden/MUTANTS.json"
CORE_REL=".claude/harness/lib/core.mjs"
CATALOG_REL=".claude/harness/lib/catalog.mjs"
CORE="$REPO/$CORE_REL"
CATALOG="$REPO/$CATALOG_REL"
SCEN=catalog-good

echo "===== test-golden-mutate ====="
command -v node >/dev/null 2>&1 || { echo "SKIPPED: 无 node——未执行 != 通过。"; exit 0; }
command -v git  >/dev/null 2>&1 || { echo "SKIPPED: 无 git——未执行 != 通过。"; exit 0; }
command -v sha256sum >/dev/null 2>&1 || { echo "SKIPPED: 无 sha256sum（还原复核依赖）——未执行 != 通过。"; exit 0; }
[ -f "$GOLDEN" ] || { echo "test-golden-mutate: 找不到 $GOLDEN" >&2; exit 1; }
[ -f "$CORE" ]   || { echo "test-golden-mutate: 找不到 $CORE" >&2; exit 1; }
[ -f "$CATALOG" ] || { echo "test-golden-mutate: 找不到 $CATALOG" >&2; exit 1; }

# 前置条件：本测试会让被测工具**真的**改这两个源文件，脏树上跑等于拿别人的未提交改动做试验。
DIRTY=$(git -C "$REPO" status --porcelain -- "$CORE_REL" "$CATALOG_REL" 2>/dev/null || true)
if [ -n "$DIRTY" ]; then
  echo "SKIPPED: $CORE_REL / $CATALOG_REL 有未提交改动，本测试要真突变这两个文件、须以干净树为前提。"
  echo "         git status: $DIRTY"
  exit 0
fi

TMP=$(mktemp -d)
cp "$CORE" "$TMP/core.bak"
cp "$CATALOG" "$TMP/catalog.bak"
CORE_SHA0=$(sha256sum < "$CORE" | cut -d' ' -f1)
CATALOG_SHA0=$(sha256sum < "$CATALOG" | cut -d' ' -f1)

# 兜底还原：断言先看到破坏（记 FAIL），trap 再把仓收拾干净。用 cp 不用 git checkout——
#   checkout 还原到的是索引版，会把别人未暂存的活儿悄悄抹掉。
restore_sources() {
  local now
  now=$(sha256sum < "$CORE" | cut -d' ' -f1)
  if [ "$now" != "$CORE_SHA0" ]; then
    echo "  [CLEANUP] $CORE_REL 被留在突变态，从备份还原" >&2
    cp "$TMP/core.bak" "$CORE"
  fi
  now=$(sha256sum < "$CATALOG" | cut -d' ' -f1)
  if [ "$now" != "$CATALOG_SHA0" ]; then
    echo "  [CLEANUP] $CATALOG_REL 被留在突变态，从备份还原" >&2
    cp "$TMP/catalog.bak" "$CATALOG"
  fi
}
trap 'restore_sources; rm -rf "$TMP"' EXIT INT TERM

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  [PASS] $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }

# ---------------------------------------------------------------------------
# 助手
# ---------------------------------------------------------------------------

# 数一个字面串在文件里出现几次（不是几行——find 可以跨行，grep -c 会数错）。
cat > "$TMP/occ.mjs" <<'EOF'
import fs from 'node:fs';
const src = fs.readFileSync(process.argv[2], 'utf8');
const find = fs.readFileSync(process.argv[3], 'utf8');
process.stdout.write(String(src.split(find).length - 1));
EOF
occ() { # $1=文件 $2=装着 find 的文件
  node "$TMP/occ.mjs" "$1" "$2"
}
occ_lit() { # $1=文件 $2=字面串
  printf '%s' "$2" > "$TMP/needle.txt"
  occ "$1" "$TMP/needle.txt"
}

# 把 --mutate 的 stdout 拍成一行 TSV 供 bash 消费。字段缺失一律 '-'。
cat > "$TMP/probe.mjs" <<'EOF'
import fs from 'node:fs';
const raw = fs.readFileSync(0, 'utf8');
const nLines = raw.replace(/\n+$/, '').split('\n').filter(l => l.trim() !== '').length;
let j = null, parseOk = 0;
try { j = JSON.parse(raw); parseOk = 1; } catch (_e) { parseOk = 0; }
const g = (o, k) => (o && typeof o === 'object' && k in o) ? o[k] : undefined;
const s = v => (v === undefined || v === null) ? '-' : (typeof v === 'object' ? JSON.stringify(v) : String(v));
const ms = Array.isArray(g(j, 'mutants')) ? j.mutants : [];
const m0 = ms[0];
const scen = g(m0, 'scenarios');
let scenNonEmpty = '-';
if (m0) {
  if (Array.isArray(scen)) scenNonEmpty = scen.length > 0 ? '1' : '0';
  else if (typeof scen === 'string') scenNonEmpty = scen.trim() !== '' ? '1' : '0';
  else if (typeof scen === 'number') scenNonEmpty = scen > 0 ? '1' : '0';
  else if (scen && typeof scen === 'object') scenNonEmpty = Object.keys(scen).length > 0 ? '1' : '0';
  else scenNonEmpty = 'MISSING';
}
const row = [
  parseOk ? 'OK' : 'ERR',
  String(nLines),
  (j && typeof j === 'object' && 'killRate' in j) ? 'YES' : 'NO',
  s(g(j, 'ok')),
  s(g(j, 'killed')),
  s(g(j, 'survived')),
  s(g(j, 'killRate')),
  String(ms.length),
  s(g(m0, 'name')),
  s(g(m0, 'file')),
  s(g(m0, 'status')),
  scenNonEmpty,
];
process.stdout.write(row.join('\t'));
EOF

RC=0; OUT=""; ERR=""; BOTH=""
P_PARSE=-; P_LINES=-; P_HASKR=-; P_OK=-; P_KILLED=-; P_SURV=-; P_KR=-; P_N=-
P_M0NAME=-; P_M0FILE=-; P_M0STATUS=-; P_M0SCEN=-
run_mutate() { # $1 = 清单绝对路径
  RC=0
  OUT=$(node "$GOLDEN" --mutate --mutants "$1" --scenario "$SCEN" 2>"$TMP/stderr.txt") || RC=$?
  ERR=$(cat "$TMP/stderr.txt")
  BOTH=$(printf '%s\n%s' "$OUT" "$ERR")
  IFS=$'\t' read -r P_PARSE P_LINES P_HASKR P_OK P_KILLED P_SURV P_KR P_N \
                    P_M0NAME P_M0FILE P_M0STATUS P_M0SCEN \
    <<< "$(printf '%s' "$OUT" | node "$TMP/probe.mjs")" || true
}
# 每条断言都把 RC 和 stdout 头 200 字带上，主 Agent 不用重跑就分得清
#   「红是因为模式没实现」还是「红是因为夹具没搭起来」。
got() { printf 'rc=%s stdout[0:200]=%s' "$RC" "$(printf '%s' "$OUT" | head -c 200 | tr '\n' ' ')"; }

sha_of() { sha256sum < "$1" | cut -d' ' -f1; }
assert_sources_intact() { # $1 = 场景说明
  local c t ok=1
  c=$(sha_of "$CORE"); t=$(sha_of "$CATALOG")
  [ "$c" = "$CORE_SHA0" ] || { fail "③c 还原：$1 之后 $CORE_REL 的 sha256 变了（期望 $CORE_SHA0 实得 $c）"; ok=0; }
  [ "$t" = "$CATALOG_SHA0" ] || { fail "③c 还原：$1 之后 $CATALOG_REL 的 sha256 变了（期望 $CATALOG_SHA0 实得 $t）"; ok=0; }
  if [ "$ok" -eq 1 ]; then pass "③c 还原：$1 之后两个被突变文件逐字节回到原样"; fi
  return 0
}

# ---------------------------------------------------------------------------
# 脚手架自证：下面机制段用到的三个 find 现在必须各出现恰好一次。
# 这一段红 = 我的夹具选错了字面串（源码变了），不是 --mutate 有问题——两种红处置完全相反。
# ---------------------------------------------------------------------------
NEEDLE_KILL="'.claude', 'harness', 'module-catalog.json'"
NEEDLE_SURVIVE='// S4 catalog'
NEEDLE_ABSENT='cc-base-golden-mutate-absent-needle-do-not-add-this-string'

n=$(occ_lit "$CORE" "$NEEDLE_KILL")
[ "$n" = "1" ] && pass "自证：kill 用的 find 在 $CORE_REL 里恰好 1 次" \
                || fail "自证：kill 用的 find 在 $CORE_REL 里出现 $n 次（期望 1）——夹具失效，机制段的红不可信"
n=$(occ_lit "$CATALOG" "$NEEDLE_SURVIVE")
[ "$n" = "1" ] && pass "自证：survive 用的 find 在 $CATALOG_REL 里恰好 1 次" \
                || fail "自证：survive 用的 find 在 $CATALOG_REL 里出现 $n 次（期望 1）——夹具失效"
n=$(occ_lit "$CORE" "$NEEDLE_ABSENT")
[ "$n" = "0" ] && pass "自证：not-applicable 用的 find 在 $CORE_REL 里 0 次" \
                || fail "自证：not-applicable 用的 find 居然出现 $n 次（期望 0）——夹具失效"

# ---------------------------------------------------------------------------
# ① --mutate 模式存在，stdout 是单行 JSON 机器契约
#    现在：mode 落进 ['--record','--check','--probe'] 之外 → 打 usage、rc 2、stdout 空。
# ---------------------------------------------------------------------------
cat > "$TMP/mut-kill.json" <<'EOF'
[
  {
    "name": "core-catalog-file-path",
    "file": ".claude/harness/lib/core.mjs",
    "find": "'.claude', 'harness', 'module-catalog.json'",
    "replace": "'.claude', 'harness', 'module-catalog-GOLDEN-MUTANT.json'",
    "why": "catalogFilePath() 指向另一个文件名——catalog-good 场景下 catalog 变成找不到，golden 必须看得见"
  }
]
EOF

run_mutate "$TMP/mut-kill.json"
RUN_A_RC=$RC; RUN_A_OUT=$OUT
A_PARSE=$P_PARSE; A_LINES=$P_LINES; A_HASKR=$P_HASKR; A_OK=$P_OK
A_KILLED=$P_KILLED; A_SURV=$P_SURV; A_KR=$P_KR; A_N=$P_N
A_M0NAME=$P_M0NAME; A_M0FILE=$P_M0FILE; A_M0STATUS=$P_M0STATUS; A_M0SCEN=$P_M0SCEN

[ "$A_PARSE" = "OK" ] && pass "①a --mutate 的 stdout 可 JSON.parse（模式存在）" \
                       || fail "①a --mutate 的 stdout 不是 JSON。EXPECT=可解析 GOT=$(got)"
[ "$A_LINES" = "1" ] && pass "①b stdout 恰好一行（机器通道契约：单行 JSON）" \
                      || fail "①b stdout 不是单行。EXPECT=1 GOT=$A_LINES 行；$(got)"
[ "$A_HASKR" = "YES" ] && pass "①c stdout JSON 含 killRate 字段" \
                        || fail "①c stdout JSON 里没有 killRate。EXPECT=有 GOT=$A_HASKR；$(got)"
case "$A_KR" in
  [0-9]*/[0-9]*) pass "①d killRate 形如 k/n（实得 $A_KR）" ;;
  *)             fail "①d killRate 不是 k/n 形态。EXPECT=k/n GOT=$A_KR（n=$A_N）；$(got)" ;;
esac
if grep -qF -- '--mutate' "$GOLDEN"; then
  pass "①e harness-golden.mjs 源码里列出了 --mutate（usage / 文件头文档位）"
else
  fail "①e harness-golden.mjs 源码里找不到 --mutate——新模式没有被 usage 或文件头登记，调用方无从发现"
fi

# ---------------------------------------------------------------------------
# ② 真实清单 .claude/tests/golden/MUTANTS.json 的静态契约（不真跑，秒级）
# ---------------------------------------------------------------------------
cat > "$TMP/mutlint.mjs" <<'EOF'
import fs from 'node:fs';
import path from 'node:path';
const [, , manifest, repo] = process.argv;
const out = [];
const emit = (...a) => out.push(a.join('\t'));
// 提前返回时把逐条类字段填成哨兵而不是 '-'：否则清单不存在时「每条 find 恰好一次」
// 这种断言会因为「一条都没有」而**空转全绿**，正是这份测试要防的假绿。
const bail = () => {
  for (const k of ['ENTRIES', 'FILES']) emit(k, '<NOT-CHECKED>');
  for (const k of ['BADFIELD', 'DUPNAME', 'NONLIB', 'OCCBAD']) emit(k, '<NOT-CHECKED>');
  console.log(out.join('\n'));
  process.exit(0);
};
let raw;
try { raw = fs.readFileSync(manifest, 'utf8'); }
catch (e) { emit('EXISTS', 'NO', String(e && e.code || e)); bail(); }
emit('EXISTS', 'YES');
let j;
try { j = JSON.parse(raw); } catch (e) { emit('PARSE', 'ERR', String(e && e.message || e)); bail(); }
emit('PARSE', 'OK');
if (!Array.isArray(j)) { emit('ARRAY', 'NO', typeof j); bail(); }
emit('ARRAY', 'YES');
emit('ENTRIES', String(j.length));

const REQUIRED = ['name', 'file', 'find', 'replace', 'why'];
const badFields = [];
const names = new Map();
const files = new Set();
const nonLib = [];
const occBad = [];
j.forEach((m, i) => {
  const label = (m && m.name) ? m.name : '#' + i;
  for (const k of REQUIRED) {
    if (typeof m?.[k] !== 'string' || m[k].trim() === '') badFields.push(label + ':' + k);
  }
  if (typeof m?.name === 'string') names.set(m.name, (names.get(m.name) || 0) + 1);
  if (typeof m?.file !== 'string' || typeof m?.find !== 'string') return;
  files.add(m.file);
  const posix = m.file.split(path.sep).join('/');
  if (!posix.startsWith('.claude/harness/lib/')) nonLib.push(label + ':' + m.file);
  let src;
  try { src = fs.readFileSync(path.resolve(repo, m.file), 'utf8'); }
  catch (_e) { occBad.push(label + ':' + m.file + ':NOFILE'); return; }
  const n = src.split(m.find).length - 1;
  if (n !== 1) occBad.push(label + ':' + m.file + ':x' + n);
});
emit('FILES', String(files.size));
emit('BADFIELD', badFields.length ? badFields.join(',') : '-');
emit('DUPNAME', [...names].filter(([, c]) => c > 1).map(([k]) => k).join(',') || '-');
emit('NONLIB', nonLib.join(',') || '-');
emit('OCCBAD', occBad.join(',') || '-');
console.log(out.join('\n'));
EOF

ML=$(node "$TMP/mutlint.mjs" "$MUTANTS" "$REPO")
mlget() { printf '%s\n' "$ML" | awk -F'\t' -v k="$1" '$1==k{print $2; found=1} END{if(!found) print "-"}'; }
mlnote() { printf '%s\n' "$ML" | awk -F'\t' -v k="$1" '$1==k{print $3}'; }

ML_EXISTS=$(mlget EXISTS); ML_PARSE=$(mlget PARSE); ML_ARRAY=$(mlget ARRAY)
ML_ENTRIES=$(mlget ENTRIES); ML_FILES=$(mlget FILES)
ML_BADFIELD=$(mlget BADFIELD); ML_DUPNAME=$(mlget DUPNAME)
ML_NONLIB=$(mlget NONLIB); ML_OCCBAD=$(mlget OCCBAD)

if [ "$ML_EXISTS" = "YES" ]; then
  pass "②a 真实清单 .claude/tests/golden/MUTANTS.json 存在"
else
  fail "②a 找不到 .claude/tests/golden/MUTANTS.json（$(mlnote EXISTS)）"
  echo "         ↑ 文件不在，②b~②i 会连带全红——它们红的是同一个根因，不是九个独立缺陷。"
fi
[ "$ML_PARSE" = "OK" ] && pass "②b MUTANTS.json 可解析" \
                        || fail "②b MUTANTS.json 解析失败：$(mlnote PARSE)"
[ "$ML_ARRAY" = "YES" ] && pass "②c MUTANTS.json 顶层是数组" \
                         || fail "②c MUTANTS.json 顶层不是数组（实得 $(mlnote ARRAY)）"
if [ "$ML_ENTRIES" != "-" ] && [ "$ML_ENTRIES" -ge 10 ] 2>/dev/null; then
  pass "②d MUTANTS.json 至少 10 条（实得 $ML_ENTRIES）"
else
  fail "②d MUTANTS.json 条数不足。EXPECT=>=10 GOT=$ML_ENTRIES"
fi
if [ "$ML_FILES" != "-" ] && [ "$ML_FILES" -ge 5 ] 2>/dev/null; then
  pass "②e MUTANTS.json 覆盖至少 5 个不同文件（实得 $ML_FILES）"
else
  fail "②e MUTANTS.json 覆盖的文件数不足。EXPECT=>=5 GOT=$ML_FILES"
fi
[ "$ML_BADFIELD" = "-" ] && pass "②f 每条都带齐 name/file/find/replace/why 且非空" \
                          || fail "②f 有条目字段缺失或为空：$ML_BADFIELD"
[ "$ML_DUPNAME" = "-" ] && pass "②g 突变名互不重复" \
                         || fail "②g 突变名重复：$ML_DUPNAME"
[ "$ML_NONLIB" = "-" ] && pass "②h 每条的 file 都落在 .claude/harness/lib/ 下" \
                        || fail "②h 有条目的 file 不在 .claude/harness/lib/ 下：$ML_NONLIB"
[ "$ML_OCCBAD" = "-" ] && pass "②i 每条的 find 在目标文件里恰好出现一次" \
                        || fail "②i 有条目的 find 出现次数不是 1（name:file:x次数，NOFILE=文件不存在）：$ML_OCCBAD"

# ---------------------------------------------------------------------------
# ③ 机制：killed / not-applicable / survived / 还原 / 脏树拒跑
#
# 注意：③c（还原）这三条在模式落地之前是**偶然绿**——工具压根没碰过源文件，sha 当然没变。
# 它们是防回归位，实现落地后才开始真正干活；别把它们的绿读成「还原已实现」。
# ③ 里真正现在必红的是 ③a / ③b / ③d / ③e 的判定与计数。
# ---------------------------------------------------------------------------

# ③a killed —— 复用 ① 那一趟的结果（同一次运行，不重复烧 18s）
[ "$A_M0STATUS" = "killed" ] && pass "③a 能改变 golden 输出的突变被判 killed" \
  || fail "③a 该突变必须是 killed（catalogFilePath 指错文件，catalog-good 会整片变）。EXPECT=killed GOT=$A_M0STATUS；rc=$RUN_A_RC stdout[0:200]=$(printf '%s' "$RUN_A_OUT" | head -c 200 | tr '\n' ' ')"
[ "$RUN_A_RC" = "0" ] && pass "③a-rc 全部 killed 时 rc 0" \
  || fail "③a-rc 全 killed 应 rc 0。EXPECT=0 GOT=$RUN_A_RC"
[ "$A_OK" = "true" ] && pass "③a-ok 全部 killed 时 ok=true" \
  || fail "③a-ok EXPECT=true GOT=$A_OK"
[ "$A_KILLED" = "1" ] && [ "$A_SURV" = "0" ] && [ "$A_KR" = "1/1" ] \
  && pass "③a-计数 killed=1 survived=0 killRate=1/1" \
  || fail "③a-计数 EXPECT=killed:1 survived:0 killRate:1/1 GOT=killed:$A_KILLED survived:$A_SURV killRate:$A_KR"
[ "$A_M0NAME" = "core-catalog-file-path" ] && [ "$A_M0FILE" = "$CORE_REL" ] \
  && pass "③a-回显 逐条结果原样带回 name 与 file（仓相对）" \
  || fail "③a-回显 EXPECT=name:core-catalog-file-path file:$CORE_REL GOT=name:$A_M0NAME file:$A_M0FILE"
# scenarios 的具体形态（数组 / 字符串 / 计数）契约没写死，这里只锁「存在且非空」，
# 别赌形态——形态一旦定下来，这条断言会自然继续成立。
[ "$A_M0SCEN" = "1" ] && pass "③a-scenarios killed 条目带非空 scenarios" \
  || fail "③a-scenarios killed 条目的 scenarios 缺失或为空。EXPECT=非空 GOT=$A_M0SCEN"
assert_sources_intact "killed 那趟"

# ③b not-applicable —— 清单坏了不许当 killed
cat > "$TMP/mut-absent.json" <<'EOF'
[
  {
    "name": "needle-not-in-file",
    "file": ".claude/harness/lib/core.mjs",
    "find": "cc-base-golden-mutate-absent-needle-do-not-add-this-string",
    "replace": "x",
    "why": "清单坏了：find 在目标文件里一次都不出现。工具必须判 not-applicable 并计入失败，不许当 killed 蒙混"
  }
]
EOF
run_mutate "$TMP/mut-absent.json"
[ "$P_M0STATUS" = "not-applicable" ] && pass "③b find 找不到 → status=not-applicable" \
  || fail "③b EXPECT=not-applicable GOT=$P_M0STATUS；$(got)"
# rc 断言必须连着「stdout 真是 JSON」一起判：光看 rc=2 会被**用法错**冒充——
# 现在 `--mutate` 不在 mode 白名单里，裸跑就是 rc 2，这条单看 rc 会假绿。
if [ "$RC" = "2" ] && [ "$P_PARSE" = "OK" ]; then
  pass "③b-rc not-applicable → rc 2（且是真跑出来的 rc，不是用法错）"
else
  fail "③b-rc EXPECT=rc 2 且 stdout 是 JSON GOT=rc:$RC parse:$P_PARSE；$(got)"
fi
[ "$P_KILLED" = "0" ] && pass "③b-计数 not-applicable 不计进 killed" \
  || fail "③b-计数 EXPECT=killed:0 GOT=killed:$P_KILLED（清单坏了被当成 killed 就是假绿）"
[ "$P_OK" = "false" ] && pass "③b-ok not-applicable → ok=false" \
  || fail "③b-ok EXPECT=false GOT=$P_OK"
if printf '%s' "$ERR" | grep -qF 'needle-not-in-file'; then
  pass "③b-stderr 人读行点名到具体突变"
else
  fail "③b-stderr stderr 没点名 needle-not-in-file。stderr[0:300]=$(printf '%s' "$ERR" | head -c 300 | tr '\n' ' ')"
fi
assert_sources_intact "not-applicable 那趟"

# ③e survived —— 证明「活下来」这个判定存在，不是恒 killed
cat > "$TMP/mut-comment.json" <<'EOF'
[
  {
    "name": "catalog-banner-comment",
    "file": ".claude/harness/lib/catalog.mjs",
    "find": "// S4 catalog",
    "replace": "// S4 catalog -- banner text moved by the mutation ruler, behaviour unchanged",
    "why": "纯注释改动，golden 看不见也不该看得见。它必须报 survived——否则 killed 判定恒真，整把尺子无意义"
  }
]
EOF
run_mutate "$TMP/mut-comment.json"
[ "$P_M0STATUS" = "survived" ] && pass "③e 注释级突变被判 survived（killed 不是恒真）" \
  || fail "③e EXPECT=survived GOT=$P_M0STATUS；$(got)"
[ "$RC" = "1" ] && pass "③e-rc 有 survived → rc 1" \
  || fail "③e-rc EXPECT=1 GOT=$RC；$(got)"
[ "$P_OK" = "false" ] && pass "③e-ok 有 survived → ok=false" \
  || fail "③e-ok EXPECT=false GOT=$P_OK"
[ "$P_SURV" = "1" ] && [ "$P_KILLED" = "0" ] && [ "$P_KR" = "0/1" ] \
  && pass "③e-计数 survived=1 killed=0 killRate=0/1" \
  || fail "③e-计数 EXPECT=survived:1 killed:0 killRate:0/1 GOT=survived:$P_SURV killed:$P_KILLED killRate:$P_KR"
assert_sources_intact "survived 那趟"

# ③d 目标文件有未提交改动 → 拒跑 rc 2 并点名；且不许顺手把那些改动抹掉
DIRT_MARK='// dirty-marker-from-test-golden-mutate'
printf '%s\n' "$DIRT_MARK" >> "$CORE"
run_mutate "$TMP/mut-kill.json"
# rc 2 和「点名」写成一条：单看 rc=2 会被用法错冒充（同 ③b-rc 的理由），
# 点名才是这条真正要锁的东西——拒跑必须说清楚是哪个文件挡住了。
if [ "$RC" = "2" ] && printf '%s' "$BOTH" | grep -qF "$CORE_REL"; then
  pass "③d 目标文件脏 → 拒跑 rc 2 且点名 $CORE_REL"
else
  fail "③d EXPECT=rc 2 且输出点名 $CORE_REL GOT=rc:$RC；stdout[0:200]=$(printf '%s' "$OUT" | head -c 200 | tr '\n' ' ') stderr[0:300]=$(printf '%s' "$ERR" | head -c 300 | tr '\n' ' ')"
fi
# 下面两条现在是**偶然绿**（模式没实现、工具压根没碰文件，所以自然成立）：
# 标成防回归位，别把它们读成「已实现」。实现落地后它们才开始真正干活。
if [ "$P_KILLED" = "0" ] || [ "$P_KILLED" = "-" ]; then
  pass "③d-计数 拒跑时不报 killed（防回归位——现在偶然绿）"
else
  fail "③d-计数 拒跑却报了 killed=$P_KILLED"
fi
# 防砖：拒跑是保护用户的在制品，不是清场的许可证。
if grep -qF "$DIRT_MARK" "$CORE"; then
  pass "③d-防砖 拒跑后用户的未提交改动仍在（防回归位——现在偶然绿）"
else
  fail "③d-防砖 拒跑后 $CORE_REL 里的未提交改动被抹掉了——拒跑不等于允许清场"
fi
# 手工还原脏标记（不走 git checkout：索引版还原会吃掉别人未暂存的活儿）
cp "$TMP/core.bak" "$CORE"
assert_sources_intact "脏树拒跑那趟（已手工去掉脏标记）"

# ---------------------------------------------------------------------------
# ④ 崩溃还原：被 kill / 抛异常时也得把源码放回去。
#    进程被 SIGKILL 的场景造不出稳定夹具，改为静态锁「兜底 handler 存在且真的在还原」。
# ---------------------------------------------------------------------------
cat > "$TMP/exithook.mjs" <<'EOF'
import fs from 'node:fs';
const src = fs.readFileSync(process.argv[2], 'utf8');
const m = /process\s*\.\s*on\s*\(\s*['"]exit['"]/.exec(src);
if (!m) { console.log('NOHOOK\t-'); process.exit(0); }
const win = src.slice(m.index, m.index + 600);
const r = /restore|revert|rollback|writeFileSync|renameSync|copyFileSync/i.exec(win);
console.log('HOOK\t' + (r ? r[0] : '-'));
EOF
EH=$(node "$TMP/exithook.mjs" "$GOLDEN")
EH_KIND=$(printf '%s' "$EH" | cut -f1)
EH_TOKEN=$(printf '%s' "$EH" | cut -f2)
[ "$EH_KIND" = "HOOK" ] && pass "④a harness-golden.mjs 装了 process.on('exit' 兜底" \
  || fail "④a 源码里找不到 process.on('exit'——突变中途被 kill 时源码会被留在突变态"
if [ "$EH_KIND" = "HOOK" ] && [ "$EH_TOKEN" != "-" ]; then
  pass "④b 该 handler 体内引用了还原动作（命中 '$EH_TOKEN'）"
else
  fail "④b process.on('exit' 的 handler 体内看不到任何还原动作（restore/revert/rollback/writeFileSync/renameSync/copyFileSync 之一）——空 handler 挡不住任何东西"
fi

echo ""
echo "==== test-golden-mutate：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ]
