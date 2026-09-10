#!/usr/bin/env bash
# risk: medium
# test-tier.sh — 档位规格回归：`node harness.mjs tier` 的两条要害语义。
#
# 分级取舍（2026-09-10 测试预算表）：档位判错的代价是「闸松了一档」，不在高风险五种之列，
#   四个子命令的正反穷举（TV/TS/TT/TE/TP/TC/TL/TG 五十余条）不再养，只留两条——
#   三档单调性校验、fast 会话覆盖过期后回默认档；「地板不可 override」归 test-tier-hardening.sh。
#
# 契约来源：docs/v3-work-packs.md A.1 数据模型 / A.2 判定函数 / A.3 tier 子命令退出码。
# 纪律：一切写操作只落 mktemp 沙箱（真仓根写 tier.json 会当场影响本 session 在跑的 hook），
#   对本仓只读；每条断言打印 EXPECT / GOT，判定不依赖措辞。
set -eu

# CC_BASE_ROOT 覆盖是给「拿候选实现验修得好」留的口子：指向打过补丁的仓库副本跑同一批断言。
ROOT=${CC_BASE_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
HARNESS="$ROOT/.claude/harness/harness.mjs"
HOOKS="$ROOT/.claude/hooks"
SCRIPTS="$ROOT/.claude/scripts"
FIX="$ROOT/.claude/tests/fixtures/tier/profile-base.json"

echo "===== test-tier ====="

if ! command -v node >/dev/null 2>&1; then
    echo "SKIPPED: 无 node——引擎与 hook 全是 .mjs，跑不起来；未执行 != 通过。" >&2
    exit 1
fi
if ! command -v git >/dev/null 2>&1; then
    echo "SKIPPED: 无 git——沙箱仓造不出来（自动升档要读工作树）；未执行 != 通过。" >&2
    exit 1
fi
[ -f "$HARNESS" ] || { echo "  [FAIL] 缺 harness.mjs：$HARNESS" >&2; exit 1; }
[ -f "$FIX" ] || { echo "  [FAIL] 缺基线 profile 夹具：$FIX" >&2; exit 1; }
TMP=$(mktemp -d)
trap 'chmod -R u+rwX "$TMP" 2>/dev/null || true; rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

# chk <判定 0=过/1=不过> <标题> <EXPECT 描述> <GOT 描述>
chk() {
    if [ "$1" -eq 0 ]; then
        PASS=$((PASS + 1)); echo "  [PASS] $2"
    else
        FAIL=$((FAIL + 1)); echo "  [FAIL] $2"
    fi
    echo "         EXPECT $3"
    echo "         GOT    $4"
}

show() { printf '%s' "${1:-空}" | tr '\n' '~' | cut -c1-300; }

# jq_ <json 文本> <js 表达式（变量 d）> —— 用 node 取字段（故意不依赖 jq）。
jq_() {
    printf '%s' "$1" | node -e '
let s = "";
process.stdin.on("data", (c) => { s += c; });
process.stdin.on("end", () => {
  try { const d = JSON.parse(s); process.stdout.write(String(eval(process.argv[1]))); }
  catch (e) { process.stdout.write("<not-json>"); }
});
' "$2"
}

hasq() { printf '%s' "$2" | grep -qF "$1"; }

# newsb <名> —— 造沙箱项目：git 仓 + .claude 骨架 + 引擎所需的 settings.json / hooks / scripts。
newsb() {
    local d="$TMP/$1"
    rm -rf "$d"
    mkdir -p "$d/.claude/harness/lib" "$d/.claude/hooks/lib" "$d/.claude/scripts" \
             "$d/.claude/evidence" "$d/.claude/.runtime" "$d/src"
    cp "$ROOT/.claude/settings.json" "$d/.claude/settings.json" 2>/dev/null || true
    # lib/ 按目录整拷、不枚举模块名（拆库后少一个就是起不来的假红）。
    cp "$ROOT/.claude/harness/harness.mjs" "$d/.claude/harness/" 2>/dev/null || true
    cp "$ROOT"/.claude/harness/lib/*.mjs "$d/.claude/harness/lib/" 2>/dev/null || true
    cp "$HOOKS"/*.mjs "$d/.claude/hooks/" 2>/dev/null || true
    cp -R "$HOOKS/lib/." "$d/.claude/hooks/lib/" 2>/dev/null || true
    cp "$SCRIPTS/fast-mode.sh" "$d/.claude/scripts/" 2>/dev/null || true
    printf 'export const a = 1;\n' > "$d/src/a.ts"
    printf '# progress\n' > "$d/progress.md"
    ( cd "$d" && git init -q . \
        && git config core.autocrlf false \
        && git config user.email t@example.com && git config user.name t \
        && git add -A && git commit -qm init ) >/dev/null 2>&1
    printf '%s' "$d"
}

# mkprofile <沙箱> [变异表达式] —— 从 A.1 基线 profile 起稿，可对对象 p 做一处变异后写入。
mkprofile() {
    local d="$1" mut="${2:-}"
    mkdir -p "$d/.claude/harness"
    node -e '
const fs = require("node:fs");
const [src, dest, mut] = process.argv.slice(1);
const p = JSON.parse(fs.readFileSync(src, "utf8"));
if (mut) { eval(mut); }
fs.writeFileSync(dest, JSON.stringify(p, null, 2) + "\n");
' "$FIX" "$d/.claude/harness/profile.json" "$mut"
    # 提交掉：.claude/harness/** 在 raise.paths 里，留未跟踪会把沙箱自动抬成 strict。
    ( cd "$d" && git add -A -f .claude/harness && git commit -qm profile ) >/dev/null 2>&1
}

# mktier <沙箱> <fast|standard|strict> [live|expired] —— 造运行态覆盖文件。
mktier() {
    local d="$1" t="$2" st="${3:-live}" now exp f
    mkdir -p "$d/.claude/.runtime"
    f="$d/.claude/.runtime/tier.json"
    now=$(date +%s)
    exp=$((now + 3600))
    case "$st" in
        live)    printf '{"tier":"%s","reason":"t","by":"user","set_epoch":%s,"expires_epoch":%s}\n' "$t" "$now" "$exp" > "$f" ;;
        expired) printf '{"tier":"%s","reason":"t","by":"user","set_epoch":1000,"expires_epoch":2000}\n' "$t" > "$f" ;;
    esac
}

RC=0
OUT=""
ERRT=""

# hrun <沙箱> <argv…> —— 在沙箱当项目根跑仓里的引擎。
hrun() {
    local d="$1"
    shift
    RC=0
    ( cd "$d" && CLAUDE_PROJECT_DIR="$d" node "$HARNESS" "$@" ) >"$TMP/.o" 2>"$TMP/.e" || RC=$?
    OUT=$(cat "$TMP/.o" 2>/dev/null || true)
    ERRT=$(cat "$TMP/.e" 2>/dev/null || true)
}

echo ""
echo "--- TV tier validate：三档单调（fast ≤ standard ≤ strict）---"

SB=$(newsb tv-nonmono); mkprofile "$SB" 'p.hooks["tdd-gate"].fast = "block";'
hrun "$SB" tier validate
TV_RC="$RC"; TV_ALL="$OUT$ERRT"
chk "$([ "$TV_RC" -eq 1 ] && echo 0 || echo 1)" \
    "TV-1 三档非单调（tdd-gate fast=block > standard=advise）→ rc 1" \
    "rc=1" "rc=$TV_RC out=[$(show "$OUT")] err=[$(show "$ERRT")]"
chk "$(hasq 'tdd-gate' "$TV_ALL" && echo 0 || echo 1)" \
    "TV-2 非单调报告点名违规 hook（不点名的校验没法处理）" \
    "输出含 tdd-gate" "输出=[$(show "$TV_ALL")]"

echo ""
echo "--- TT tier status：fast 会话覆盖的过期回落 ---"

SB=$(newsb tt-expired); mkprofile "$SB"; mktier "$SB" fast expired
hrun "$SB" tier status
TT_E="$OUT"
chk "$([ "$RC" -eq 0 ] && [ "$(jq_ "$TT_E" 'String(d.tier)')" = "standard" ] && echo 0 || echo 1)" \
    "TT-1 过期的 tier.json → 视为无覆盖，effective 回 default（过期自动失效，不靠人记得关）" \
    "rc=0 且 tier=standard" "rc=$RC out=[$(show "$TT_E")]"
chk "$([ "$(jq_ "$TT_E" 'String(d.source)')" = "default" ] && echo 0 || echo 1)" \
    "TT-2 过期时 source 报 default 而不是 session（来源报错会让人以为覆盖还在生效）" \
    "source=default" "out=[$(show "$TT_E")]"

echo ""
echo "==== test-tier：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ]
