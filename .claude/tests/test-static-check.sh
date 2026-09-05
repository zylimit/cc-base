#!/usr/bin/env bash
# test-static-check.sh — static-check 必须认 JS 家族（批 4 · L4e）。
#
# 锁的行为（断言写「修好后应成立」）：
#   ① 仓里有 .mjs/.cjs/.js 且没有 tsc 可跑时，用 `node --check` 逐个校验；
#      语法错 → rc 非 0 且点名到 文件:行。三个扩展名各一条断言——只锁 .mjs 的话，
#      另外两个扩展名天生免检（这正是这类「一张表漏成员」缺陷的老形态）。
#   ② 全对时 rc 0，且输出里出现 `node --check` 字样。这条不是可见性摆设：
#      现在这个目录走的是「未识别到可跑的静态检查……跳过」的 rc 0，
#      光断言 rc=0 会被这条空绿路径冒充过去，必须连「跑过了」一起判。
#   ③ node_modules 里的坏文件不算数（排除规则），但排除完仍要真的跑过。
#
# 为什么沙箱里不放 .sh/.py/tsconfig.json：那样 `ran` 会被 shellcheck/ruff/tsc 填上，
#   「输出含 node --check」就不再是 JS 分支的证据。这个目录里只有 JS，判据才干净。
#
# 用法：bash test-static-check.sh [static-check.mjs 路径]
#   带参数是给突变/修复验证用的——把候选实现放 /tmp，跑同一份断言看它转不转绿。
set -u

SRC=$(cd "$(dirname "$0")/.." && pwd)
CHECK=${1:-"$SRC/hooks/static-check.mjs"}

echo "===== test-static-check ====="
command -v node >/dev/null 2>&1 || {
    echo 'SKIPPED: 无 node——node --check 这条分支本身跑不了，未执行 != 通过。'
    exit 0
}
[ -f "$CHECK" ] || { echo "test-static-check: 找不到被测 static-check.mjs：$CHECK" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  [PASS] $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }
chk() {
    if [ "$1" -eq 0 ]; then pass "$2"; else fail "$2"; fi
    echo "         EXPECT $3"
    echo "         GOT    $4"
}
contains() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

SC_RC=0
SC_OUT=""
run_check() {
    SC_RC=0
    SC_OUT=$(node "$CHECK" "$1" 2>&1) || SC_RC=$?
}
# 输出可能很长，GOT 里只留前几行。
brief() { printf '%s\n' "$1" | head -6 | tr '\n' '|'; }

# 每个场景一间干净屋子：不放 .sh / .py / tsconfig.json，判据才只关乎 JS 分支。
mkbox() {
    local d="$TMP/$1"
    rm -rf "$d"; mkdir -p "$d"
    printf 'export const y = 1;\n' > "$d/ok.mjs"
    printf '%s' "$d"
}
# `const x = ;` 在 ESM 与 CJS 下都是语法错，不受 .cjs/.mjs 解析差异影响。
BAD_SRC='const x = ;'

# ---------------------------------------------------------------------------
# ⓪ 脚手架自证：坏样例得是真的坏，好样例得是真的好
# ---------------------------------------------------------------------------
echo "-- ⓪ 脚手架自证 --"
B0=$(mkbox probe)
printf '%s\n' "$BAD_SRC" > "$B0/bad.mjs"
if node --check "$B0/bad.mjs" >/dev/null 2>&1; then r=1; else r=0; fi
chk "$r" "⓪a 坏样例确实过不了 node --check" "node --check 对 bad.mjs 非 0" "rc=$(node --check "$B0/bad.mjs" >/dev/null 2>&1; echo $?)"
if node --check "$B0/ok.mjs" >/dev/null 2>&1; then r=0; else r=1; fi
chk "$r" "⓪b 好样例确实过得了 node --check" "node --check 对 ok.mjs 为 0" "rc=$(node --check "$B0/ok.mjs" >/dev/null 2>&1; echo $?)"

# ---------------------------------------------------------------------------
# ① 三个扩展名各一条：语法错 → rc 非 0 且点名 文件:行
# ---------------------------------------------------------------------------
echo "-- ① 语法错必须被抓到并点名 --"
for ext in mjs cjs js; do
    BOX=$(mkbox "bad-$ext")
    if [ "$ext" = "mjs" ]; then
        printf 'export const x = ;\n' > "$BOX/bad.$ext"
    else
        printf '%s\n' "$BAD_SRC" > "$BOX/bad.$ext"
    fi
    run_check "$BOX"

    r=1
    if [ "$SC_RC" -ne 0 ] && contains "bad.$ext" "$SC_OUT"; then r=0; fi
    chk "$r" "①$ext 坏的 .$ext → rc 非 0 且点名 bad.$ext" \
        "rc != 0 且输出含 bad.$ext" "rc=$SC_RC；输出：$(brief "$SC_OUT")"

    # 点到行：node --check 自己就打 <路径>:<行号>，实现把它透出来即可。
    printf '%s\n' "$SC_OUT" | grep -q "bad\.$ext:[0-9]"; r=$?
    chk "$r" "①$ext 点名到行号（bad.$ext:<行>）" \
        "输出含形如 bad.$ext:1 的位置" "匹配行：[$(printf '%s\n' "$SC_OUT" | grep -o "bad\.$ext:[0-9]*" | head -3 | tr '\n' ' ')]"
done

# ---------------------------------------------------------------------------
# ② 全对：rc 0 且看得出真的跑了（不是走「未识别到可跑的静态检查」那条空绿）
# ---------------------------------------------------------------------------
echo "-- ② 全对时必须是「跑过且通过」，不是「没识别所以跳过」 --"
BOX=$(mkbox good)
printf 'export function f(a) { return a + 1; }\n' > "$BOX/util.js"
printf 'module.exports = { a: 1 };\n' > "$BOX/conf.cjs"
run_check "$BOX"

r=1
if [ "$SC_RC" -eq 0 ] && contains 'node --check' "$SC_OUT"; then r=0; fi
chk "$r" "②a 三个好文件 → rc 0 且输出出现 node --check" \
    "rc=0 且输出含 'node --check'" "rc=$SC_RC；输出：$(brief "$SC_OUT")"

if contains '未识别到可跑的静态检查' "$SC_OUT"; then r=1; else r=0; fi
chk "$r" "②b 不再走「未识别到可跑的静态检查」的空绿路径" \
    "输出不含「未识别到可跑的静态检查」" "输出：$(brief "$SC_OUT")"

# ---------------------------------------------------------------------------
# ③ node_modules 排除：里面的坏文件不算数，但排除完仍要真的跑过
#    只断言 rc=0 会被「压根没看 JS」冒充，所以和「跑过了」绑在一起判。
# ---------------------------------------------------------------------------
echo "-- ③ node_modules 里的坏文件不算数 --"
BOX=$(mkbox deps)
mkdir -p "$BOX/node_modules/somedep"
printf '%s\n' "$BAD_SRC" > "$BOX/node_modules/somedep/broken.mjs"
run_check "$BOX"

r=1
if [ "$SC_RC" -eq 0 ] && contains 'node --check' "$SC_OUT" && ! contains 'broken.mjs' "$SC_OUT"; then r=0; fi
chk "$r" "③ node_modules 下的语法错被排除，但仓内 JS 仍被真的检查过" \
    "rc=0 且输出含 'node --check' 且不含 broken.mjs" \
    "rc=$SC_RC；含 node --check=$(contains 'node --check' "$SC_OUT" && echo yes || echo no)；含 broken.mjs=$(contains 'broken.mjs' "$SC_OUT" && echo yes || echo no)；输出：$(brief "$SC_OUT")"

# ---------------------------------------------------------------------------
# 覆盖缺口，明说不假装
# ---------------------------------------------------------------------------
LEFTOVER=$(find "$SRC/hooks" -maxdepth 1 \( -name 'static-check.sh' -o -name 'static-check.ps1' \) 2>/dev/null | tr '\n' ' ')
if [ -n "$LEFTOVER" ]; then
    echo "  [NOTE] hooks/ 下仍有 static-check 的 shell 形态（$LEFTOVER）：Phase D 之后只该剩 .mjs 一份，"
    echo "         本文件只验 .mjs 侧，那些残留无人守——归 test-hooks-settings 的 HS-17/HS-18 判。"
fi
echo "  [NOTE] 「有 tsc 时不跑 node --check」这条优先级没测：要真装 node_modules + typescript，"
echo "         代价与环境依赖都过高，列为已知覆盖缺口。"

echo ""
echo "==== test-static-check：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ]
