#!/usr/bin/env bash
# risk: low
# test-static-check.sh — static-check 必须认 JS 家族并且真的跑过。
# 留两条（2026-09-10 预算表）：① 语法错 → rc 非 0 且点名到 文件:行；② 全对 → rc 0 且输出出现
#   `node --check`（光判 rc=0 会被「未识别到可跑的静态检查……跳过」那条空绿路径冒充）；
#   三个扩展名逐个验、node_modules 排除那批退休。
# 沙箱里不放 .sh/.py/tsconfig.json：那样 ran 会被 shellcheck/ruff/tsc 填上，判据就不干净了。
# 坏样例 `export const x = ;` 在 ESM 下必是语法错，不另设脚手架自证。
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
chk() {
    if [ "$1" -eq 0 ]; then PASS=$((PASS + 1)); echo "  [PASS] $2"; else FAIL=$((FAIL + 1)); echo "  [FAIL] $2"; fi
    echo "         EXPECT $3"
    echo "         GOT    $4"
}
contains() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

SC_RC=0; SC_OUT=""
run_check() { SC_RC=0; SC_OUT=$(node "$CHECK" "$1" 2>&1) || SC_RC=$?; }
brief() { printf '%s\n' "$1" | head -6 | tr '\n' '|'; }

# 每个场景一间干净屋子：只有 JS，判据才只关乎 JS 分支。
mkbox() {
    local d="$TMP/$1"; rm -rf "$d"; mkdir -p "$d"
    printf 'export const y = 1;\n' > "$d/ok.mjs"; printf '%s' "$d"
}

echo "-- ① 语法错必须被抓到并点名到行 --"
BOX=$(mkbox bad-mjs)
printf 'export const x = ;\n' > "$BOX/bad.mjs"
run_check "$BOX"
r=1
if [ "$SC_RC" -ne 0 ] && contains "bad.mjs" "$SC_OUT"; then r=0; fi
chk "$r" "① 坏的 .mjs → rc 非 0 且点名 bad.mjs" \
    "rc != 0 且输出含 bad.mjs" "rc=$SC_RC；输出：$(brief "$SC_OUT")"
printf '%s\n' "$SC_OUT" | grep -q "bad\.mjs:[0-9]"; r=$?
chk "$r" "① 点名到行号（bad.mjs:<行>）" \
    "输出含形如 bad.mjs:1 的位置" "匹配：[$(printf '%s\n' "$SC_OUT" | grep -o "bad\.mjs:[0-9]*" | head -3 | tr '\n' ' ')]"

echo "-- ② 全对时必须是「跑过且通过」，不是「没识别所以跳过」 --"
BOX=$(mkbox good)
printf 'export function f(a) { return a + 1; }\n' > "$BOX/util.js"
printf 'module.exports = { a: 1 };\n' > "$BOX/conf.cjs"
run_check "$BOX"
r=1
if [ "$SC_RC" -eq 0 ] && contains 'node --check' "$SC_OUT"; then r=0; fi
chk "$r" "② 三个好文件 → rc 0 且输出出现 node --check（判 rc=0 会被空绿路径冒充）" \
    "rc=0 且输出含 'node --check'" "rc=$SC_RC；输出：$(brief "$SC_OUT")"

echo ""
echo "==== test-static-check：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ]
