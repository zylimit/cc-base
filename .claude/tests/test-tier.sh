#!/usr/bin/env bash
# test-tier.sh — Phase A「档位」的规格回归：`node harness.mjs tier` 四个子命令
#   （validate / set / status / explain）、自动升档、坏状态留痕、旧入口薄壳、引擎接线。
#
# red-locks-the-bug：本文件写的是**档位落地后应该成立的行为**，不是「现状能复现」。
#   `hooks/lib/tier.mjs` / `harness/profile.json` / `tier` 子命令都还不存在时整体必然 FAIL
#   （引擎对未知子命令 die(usage, 3)）——这是它的成功状态。落地后它是永久防线：
#   谁改坏一条单调性校验、把 8 小时上限放宽、让地板闸吃了 fast 档，哪条立刻红。
#
# 契约来源（从底本来，不从实现反推措辞）：
#   docs/v3-work-packs.md          A.1 数据模型（profile.json / .runtime/tier.json 字段与取值域）
#                                  A.2 判定函数（effectiveTier 返回 {tier, source, raisedBy}）
#                                  A.3 tier 子命令四行表与退出码
#   docs/v3-tiered-harness-proposal.md §三（三档 + 安全地板 / 单调性「升自动降留痕」）
#
# 本文件写死的几处口径假设（A.1–A.3 没写到字段级，主 Agent 裁定后如有出入改这里，别改实现）：
#   ① `tier status` 走引擎通用 emit 契约：stdout 单行 JSON，字段名取 A.2 的返回类型
#      —— tier / source / raisedBy（人读摘要走 stderr，与其余 39 个子命令一致）。
#   ② `tier explain <id>` 的字段名 A.3 没定，故只断言 stdout 里三档取值、当前值、来源标记
#      都出现，并用「有 override 时出现 override / 无 override 时不出现」这种对照锁语义，
#      不赌具体键名。
#   ③ `fast-mode.sh off` 锁的是「effective 回 default」这一可观测结果，不锁 tier.json
#      是被删还是被改写成 standard——两种实现都合规。
#
# 跨平台：只用 bash + node + git + coreutils；`.ps1` 段现查 `command -v pwsh`，缺席打 SKIP。
# 纪律：一切写操作只落 mktemp 沙箱（真仓根写 tier.json 会当场影响本 session 在跑的 hook），
#   对本仓只读；每条断言打印 EXPECT / GOT，判定不依赖措辞。
#
# 组号：TV validate / TS set / TT status / TE explain / TP raise 自动升档 /
#       TC 坏状态 / TL 旧入口薄壳 / TG 引擎接线
set -eu

# CC_BASE_ROOT 覆盖是给「拿候选实现验修得好」留的口子：把本脚本拷去 /tmp、指向打过补丁的
# 仓库副本跑同一批断言，零改动本仓。不设时按脚本自身位置推。
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

skip() { echo "  [SKIP] $1"; }

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

# ---------------------------------------------------------------------------
# 沙箱夹具
# ---------------------------------------------------------------------------

# newsb <名> —— 造沙箱项目：git 仓 + .claude 骨架 + 引擎所需的 settings.json / hooks / scripts。
#   引擎本体不拷，用仓里那份 + CLAUDE_PROJECT_DIR 指向沙箱（与 test-hooks-node.sh 同法）：
#   拷贝会让「跑的是哪一份实现」多一层间接，也拖慢每条用例。
newsb() {
    local d="$TMP/$1"
    rm -rf "$d"
    mkdir -p "$d/.claude/harness" "$d/.claude/hooks/lib" "$d/.claude/scripts" \
             "$d/.claude/evidence" "$d/.claude/.runtime" "$d/src"
    cp "$ROOT/.claude/settings.json" "$d/.claude/settings.json" 2>/dev/null || true
    # 引擎整台搬进沙箱：tier 的判定与 quarantine 落点都从**引擎自身位置**推，跑仓里那份
    # 会把沙箱的答案写回本仓。lib/ 按目录整拷、不枚举模块名（拆库后少一个就是起不来的假红）。
    mkdir -p "$d/.claude/harness/lib"
    cp "$ROOT/.claude/harness/harness.mjs" "$d/.claude/harness/" 2>/dev/null || true
    cp "$ROOT"/.claude/harness/lib/*.mjs "$d/.claude/harness/lib/" 2>/dev/null || true
    cp "$HOOKS"/*.mjs "$d/.claude/hooks/" 2>/dev/null || true
    cp -R "$HOOKS/lib/." "$d/.claude/hooks/lib/" 2>/dev/null || true
    cp "$SCRIPTS/fast-mode.sh" "$d/.claude/scripts/" 2>/dev/null || true
    cp "$SCRIPTS/fast-mode.ps1" "$d/.claude/scripts/" 2>/dev/null || true
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
    # 提交掉：.claude/harness/** 在 raise.paths 里，profile 与引擎以未跟踪状态留着，
    # 每个沙箱都会被自动升档抬成 strict，TT/TE/TC 那些「默认档」的断言就全成了红。
    ( cd "$d" && git add -A -f .claude/harness && git commit -qm profile ) >/dev/null 2>&1
}

# mktier <沙箱> <fast|standard|strict> [live|expired|badjson|crlf] —— 造运行态覆盖文件。
mktier() {
    local d="$1" t="$2" st="${3:-live}" now exp f
    mkdir -p "$d/.claude/.runtime"
    f="$d/.claude/.runtime/tier.json"
    now=$(date +%s)
    exp=$((now + 3600))
    case "$st" in
        live)    printf '{"tier":"%s","reason":"t","by":"user","set_epoch":%s,"expires_epoch":%s}\n' "$t" "$now" "$exp" > "$f" ;;
        expired) printf '{"tier":"%s","reason":"t","by":"user","set_epoch":1000,"expires_epoch":2000}\n' "$t" > "$f" ;;
        badjson) printf '{"tier":"%s","reason": broken,,\n' "$t" > "$f" ;;
        crlf)    printf '{"tier":"%s","reason":"t","by":"user","set_epoch":%s,"expires_epoch":%s}\r\n' "$t" "$now" "$exp" > "$f" ;;
    esac
}

# 运行夹具：RC / OUT(stdout) / ERRT(stderr) 回填。
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

# srun <沙箱> <脚本> <argv…> —— 在沙箱跑旧入口薄壳。
srun() {
    local d="$1" s="$2"
    shift 2
    RC=0
    ( cd "$d" && CLAUDE_PROJECT_DIR="$d" bash "$s" "$@" ) >"$TMP/.o" 2>"$TMP/.e" || RC=$?
    OUT=$(cat "$TMP/.o" 2>/dev/null || true)
    ERRT=$(cat "$TMP/.e" 2>/dev/null || true)
}

tierfile() { cat "$1/.claude/.runtime/tier.json" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
echo ""
echo "--- TV tier validate（A.3：0 合规 / 1 违规；每条规则一正一反）---"

SB=$(newsb tv-ok); mkprofile "$SB"
hrun "$SB" tier validate
chk "$([ "$RC" -eq 0 ] && echo 0 || echo 1)" \
    "TV-1 A.1 原样 profile → rc 0（这条红 = tier 子命令还不存在；下面所有红的根因都是它）" \
    "rc=0" "rc=$RC out=[$(show "$OUT")] err=[$(show "$ERRT")]"

SB=$(newsb tv-mono-bad); mkprofile "$SB" 'p.hooks["stop-gate"].fast = "block"; p.hooks["stop-gate"].standard = "advise";'
hrun "$SB" tier validate
TV_MONO_RC="$RC"; TV_MONO_ALL="$OUT$ERRT"
chk "$([ "$TV_MONO_RC" -eq 1 ] && echo 0 || echo 1)" \
    "TV-2 三档非单调（stop-gate fast=block > standard=advise）→ rc 1" \
    "rc=1" "rc=$TV_MONO_RC out=[$(show "$OUT")] err=[$(show "$ERRT")]"
chk "$(hasq 'stop-gate' "$TV_MONO_ALL" && echo 0 || echo 1)" \
    "TV-3 非单调报告点名违规 hook（不点名的校验没法处理）" \
    "输出含 stop-gate" "输出=[$(show "$TV_MONO_ALL")]"

SB=$(newsb tv-mono-ok); mkprofile "$SB" 'p.hooks["stop-gate"].fast = "off";'
hrun "$SB" tier validate
chk "$([ "$RC" -eq 0 ] && echo 0 || echo 1)" \
    "TV-4 对照正例：stop-gate fast 降到 off（仍 off ≤ block ≤ block）→ rc 0（证明 TV-2 判的是单调性不是「改过就报」）" \
    "rc=0" "rc=$RC out=[$(show "$OUT")] err=[$(show "$ERRT")]"

SB=$(newsb tv-floor-bad); mkprofile "$SB" 'p.hooks["secret-exfil-guard"] = { kind: "guard", fast: "block", standard: "block", strict: "block" };'
hrun "$SB" tier validate
TV_FL_RC="$RC"; TV_FL_ALL="$OUT$ERRT"
chk "$([ "$TV_FL_RC" -eq 1 ] && echo 0 || echo 1)" \
    "TV-5 floor 里的闸出现在 hooks 表 → rc 1（地板结构上就不该在档位表里，写进去等于给它开了可调的口子）" \
    "rc=1" "rc=$TV_FL_RC out=[$(show "$OUT")] err=[$(show "$ERRT")]"
chk "$(hasq 'secret-exfil-guard' "$TV_FL_ALL" && echo 0 || echo 1)" \
    "TV-6 越界报告点名该 floor 闸" "输出含 secret-exfil-guard" "输出=[$(show "$TV_FL_ALL")]"

SB=$(newsb tv-kind-bad); mkprofile "$SB" 'p.hooks["mark-review-needed"].standard = "block";'
hrun "$SB" tier validate
TV_KD_RC="$RC"; TV_KD_ALL="$OUT$ERRT"
chk "$([ "$TV_KD_RC" -eq 1 ] && echo 0 || echo 1)" \
    "TV-7 kind=recorder 取 guard 才有的 block → rc 1（recorder 只有 off|on）" \
    "rc=1" "rc=$TV_KD_RC out=[$(show "$OUT")] err=[$(show "$ERRT")]"
chk "$(hasq 'mark-review-needed' "$TV_KD_ALL" && echo 0 || echo 1)" \
    "TV-8 取值域报告点名该 hook" "输出含 mark-review-needed" "输出=[$(show "$TV_KD_ALL")]"

SB=$(newsb tv-kind-ok); mkprofile "$SB" 'p.hooks["auto-push"].fast = "on";'
hrun "$SB" tier validate
chk "$([ "$RC" -eq 0 ] && echo 0 || echo 1)" \
    "TV-9 对照正例：recorder 取 on → rc 0（证明 TV-7 判的是取值域，不是「recorder 不许改」）" \
    "rc=0" "rc=$RC out=[$(show "$OUT")] err=[$(show "$ERRT")]"

SB=$(newsb tv-raise-bad); mkprofile "$SB" 'p.raise.to = "paranoid";'
hrun "$SB" tier validate
chk "$([ "$RC" -eq 1 ] && echo 0 || echo 1)" \
    "TV-10 raise.to 不是三档之一 → rc 1（非法目标档 = 自动升档静默失效）" \
    "rc=1" "rc=$RC out=[$(show "$OUT")] err=[$(show "$ERRT")]"

SB=$(newsb tv-raise-ok); mkprofile "$SB" 'p.raise.to = "standard";'
hrun "$SB" tier validate
chk "$([ "$RC" -eq 0 ] && echo 0 || echo 1)" \
    "TV-11 对照正例：raise.to = standard（合法档名）→ rc 0" \
    "rc=0" "rc=$RC out=[$(show "$OUT")] err=[$(show "$ERRT")]"

SB=$(newsb tv-unknown-top); mkprofile "$SB" 'p.tiers = { fast: {} };'
hrun "$SB" tier validate
chk "$([ "$RC" -eq 1 ] && echo 0 || echo 1)" \
    "TV-12 顶层未知字段（tiers）→ rc 1（拼错的键静默被忽略＝用户以为调了档其实没调）" \
    "rc=1" "rc=$RC out=[$(show "$OUT")] err=[$(show "$ERRT")]"

SB=$(newsb tv-unknown-hook); mkprofile "$SB" 'p.hooks["tdd-gate"].fastest = "off";'
hrun "$SB" tier validate
chk "$([ "$RC" -eq 1 ] && echo 0 || echo 1)" \
    "TV-13 hook 条目里的未知字段（fastest）→ rc 1（同上，错拼的档名不许静默）" \
    "rc=1" "rc=$RC out=[$(show "$OUT")] err=[$(show "$ERRT")]"

SB=$(newsb tv-missing); mkprofile "$SB" 'delete p.hooks["tdd-gate"];'
hrun "$SB" tier validate
TV_MS_RC="$RC"; TV_MS_ALL="$OUT$ERRT"
chk "$([ "$TV_MS_RC" -eq 1 ] && echo 0 || echo 1)" \
    "TV-14 已注册 hook 不在 hooks 表也不在 floor → rc 1（漏登记的闸按最严跑，但那是兜底不是许可）" \
    "rc=1" "rc=$TV_MS_RC out=[$(show "$OUT")] err=[$(show "$ERRT")]"
chk "$(hasq 'tdd-gate' "$TV_MS_ALL" && echo 0 || echo 1)" \
    "TV-15 缺登记报告点名缺的那个 hook id" "输出含 tdd-gate" "输出=[$(show "$TV_MS_ALL")]"

SB=$(newsb tv-extra-hook); mkprofile "$SB" 'p.hooks["not-a-hook-at-all"] = { kind: "guard", fast: "off", standard: "block", strict: "block" };'
hrun "$SB" tier validate
chk "$([ "$RC" -eq 1 ] && echo 0 || echo 1)" \
    "TV-16 表里有个根本不存在的 hook id → rc 1（写了半天没生效的条目比没写更糟）" \
    "rc=1" "rc=$RC out=[$(show "$OUT")] err=[$(show "$ERRT")]"

# ---------------------------------------------------------------------------
echo ""
echo "--- TS tier set（A.1/A.3：写 .runtime/tier.json + 记 gate log；fast 必须给理由且 ≤ 8h）---"

SB=$(newsb ts-fast); mkprofile "$SB"
hrun "$SB" tier set fast --hours 4 --reason "原型期赶进度"
TS_RC="$RC"; TS_F=$(tierfile "$SB")
chk "$([ "$TS_RC" -eq 0 ] && [ -n "$TS_F" ] && echo 0 || echo 1)" \
    "TS-1 set fast --hours 4 --reason … → rc 0 且写出 .claude/.runtime/tier.json" \
    "rc=0 且 tier.json 非空" "rc=$TS_RC 文件=[$(show "$TS_F")] err=[$(show "$ERRT")]"
chk "$([ "$(jq_ "$TS_F" 'String(d.tier)')" = "fast" ] && echo 0 || echo 1)" \
    "TS-2 tier 字段是 fast" "tier=fast" "文件=[$(show "$TS_F")]"
MISSF=""
for k in tier reason by set_epoch expires_epoch; do
    [ "$(jq_ "$TS_F" "String(Object.prototype.hasOwnProperty.call(d,'$k'))")" = "true" ] || MISSF="$MISSF $k"
done
chk "$([ -z "$MISSF" ] && echo 0 || echo 1)" \
    "TS-3 五个字段齐全：tier / reason / by / set_epoch / expires_epoch（A.1 数据模型）" \
    "0 个缺失" "缺失：${MISSF:- 无}"
chk "$([ "$(jq_ "$TS_F" 'String(Number(d.expires_epoch) - Number(d.set_epoch))')" = "14400" ] && echo 0 || echo 1)" \
    "TS-4 --hours 4 落成 14400 秒的过期差值" "expires-set=14400" \
    "实得=[$(jq_ "$TS_F" 'String(Number(d.expires_epoch) - Number(d.set_epoch))')]"
chk "$(hasq 'tier' "$(cat "$SB/.claude/evidence/gate-block.log" 2>/dev/null || true)" && echo 0 || echo 1)" \
    "TS-5 降档留痕：gate-block.log 追加一行 tier（gate-audit 靠它统计「fast 开着跳过了什么」）" \
    "账本含 tier" "账本=[$(show "$(cat "$SB/.claude/evidence/gate-block.log" 2>/dev/null || true)")]"
chk "$([ "$TS_RC" -eq 0 ] && [ ! -f "$SB/.claude/.fast-mode" ] && echo 0 || echo 1)" \
    "TS-6 不再写 .claude/.fast-mode（A.1：旧开关文件不写也不读，两个开关并存＝一边判开一边判关）" \
    "set 成功（rc=0）且 .fast-mode 不存在" \
    "rc=$TS_RC $([ -f "$SB/.claude/.fast-mode" ] && echo 存在 || echo 不存在)"

SB=$(newsb ts-clamp); mkprofile "$SB"
hrun "$SB" tier set fast --hours 12 --reason "想开一整天"
TS_C_RC="$RC"; TS_C_ERR="$ERRT"; TS_C_F=$(tierfile "$SB")
chk "$([ "$TS_C_RC" -eq 0 ] && [ "$(jq_ "$TS_C_F" 'String(Number(d.expires_epoch) - Number(d.set_epoch))')" = "28800" ] && echo 0 || echo 1)" \
    "TS-7 --hours 12 截到 8 小时（28800 秒）而不是照单全收（硬上限，防「开着忘了关」）" \
    "rc=0 且 expires-set=28800" \
    "rc=$TS_C_RC 差值=[$(jq_ "$TS_C_F" 'String(Number(d.expires_epoch) - Number(d.set_epoch))')]"
chk "$([ "$TS_C_RC" -eq 0 ] && [ -n "$TS_C_ERR" ] && echo 0 || echo 1)" \
    "TS-8 截断时 stderr 说明（静默截断＝用户以为开了 12 小时，4 小时后闸回来了还以为是 bug）" \
    "rc=0 且 stderr 非空（rc 一起判：用法错的 usage 也走 stderr，不带 rc 就是「失败也算说明过了」）" \
    "rc=$TS_C_RC err=[$(show "$TS_C_ERR")]"

SB=$(newsb ts-noreason); mkprofile "$SB"
hrun "$SB" tier set fast --hours 2
chk "$([ "$RC" -eq 2 ] && [ ! -f "$SB/.claude/.runtime/tier.json" ] && echo 0 || echo 1)" \
    "TS-9 set fast 缺 --reason → rc 2 用法错且不落盘（降档必须留理由，这是「降档留痕」的机器闸）" \
    "rc=2 且无 tier.json" "rc=$RC 文件=[$(show "$(tierfile "$SB")")]"

SB=$(newsb ts-std); mkprofile "$SB"
hrun "$SB" tier set standard
TS_S_RC="$RC"; TS_S_F=$(tierfile "$SB")
chk "$([ "$TS_S_RC" -eq 0 ] && [ "$(jq_ "$TS_S_F" 'String(d.tier)')" = "standard" ] && echo 0 || echo 1)" \
    "TS-10 set standard 无需 --reason → rc 0 且 tier=standard（升/平档不留痕，只有降档要）" \
    "rc=0 且 tier=standard" "rc=$TS_S_RC 文件=[$(show "$TS_S_F")]"
chk "$([ "$(jq_ "$TS_S_F" "String(d.expires_epoch === undefined || d.expires_epoch === null)")" = "true" ] && echo 0 || echo 1)" \
    "TS-11 standard 无过期字段（只有 fast 是有时限的临时降档）" \
    "expires_epoch 缺省或 null" "文件=[$(show "$TS_S_F")]"

SB=$(newsb ts-strict); mkprofile "$SB"
hrun "$SB" tier set strict
chk "$([ "$RC" -eq 0 ] && [ "$(jq_ "$(tierfile "$SB")" 'String(d.tier)')" = "strict" ] && echo 0 || echo 1)" \
    "TS-12 set strict → rc 0 且 tier=strict" "rc=0 且 tier=strict" \
    "rc=$RC 文件=[$(show "$(tierfile "$SB")")]"

SB=$(newsb ts-bogus); mkprofile "$SB"
hrun "$SB" tier set turbo --reason x
chk "$([ "$RC" -eq 2 ] && [ ! -f "$SB/.claude/.runtime/tier.json" ] && echo 0 || echo 1)" \
    "TS-13 非法档名 turbo → rc 2 用法错且不落盘（写进去就是个谁也解释不了的运行态）" \
    "rc=2 且无 tier.json" "rc=$RC 文件=[$(show "$(tierfile "$SB")")]"

# ---------------------------------------------------------------------------
echo ""
echo "--- TT tier status（A.2 返回类型：tier / source / raisedBy；stdout 单行 JSON）---"

SB=$(newsb tt-default); mkprofile "$SB"
hrun "$SB" tier status
TT_D="$OUT"
chk "$([ "$RC" -eq 0 ] && [ "$(jq_ "$TT_D" 'String(d.tier)')" = "standard" ] && echo 0 || echo 1)" \
    "TT-1 无运行态覆盖 → effective = profile.default（standard）" \
    "rc=0 且 tier=standard" "rc=$RC out=[$(show "$TT_D")]"
chk "$([ "$(jq_ "$TT_D" 'String(d.source)')" = "default" ] && echo 0 || echo 1)" \
    "TT-2 source=default" "source=default" "out=[$(show "$TT_D")]"

SB=$(newsb tt-session); mkprofile "$SB"; mktier "$SB" fast live
hrun "$SB" tier status
TT_S="$OUT"
chk "$([ "$(jq_ "$TT_S" 'String(d.tier)')" = "fast" ] && echo 0 || echo 1)" \
    "TT-3 未过期的 tier.json → effective=fast" "tier=fast" "out=[$(show "$TT_S")]"
chk "$([ "$(jq_ "$TT_S" 'String(d.source)')" = "session" ] && echo 0 || echo 1)" \
    "TT-4 source=session（A.2 三种来源之一）" "source=session" "out=[$(show "$TT_S")]"

SB=$(newsb tt-expired); mkprofile "$SB"; mktier "$SB" fast expired
hrun "$SB" tier status
TT_E="$OUT"
chk "$([ "$(jq_ "$TT_E" 'String(d.tier)')" = "standard" ] && echo 0 || echo 1)" \
    "TT-5 过期的 tier.json → 视为无覆盖，effective 回 default（过期自动失效，不靠人记得关）" \
    "tier=standard" "out=[$(show "$TT_E")]"
chk "$([ "$(jq_ "$TT_E" 'String(d.source)')" = "default" ] && echo 0 || echo 1)" \
    "TT-6 过期时 source 报 default 而不是 session（来源报错会让人以为覆盖还在生效）" \
    "source=default" "out=[$(show "$TT_E")]"

SB=$(newsb tt-nofile); mkprofile "$SB"
hrun "$SB" tier status
chk "$([ "$RC" -eq 0 ] && [ "$(jq_ "$OUT" 'String(d.tier)')" = "standard" ] && echo 0 || echo 1)" \
    "TT-7 tier.json 缺文件 → rc 0 且回 default（缺运行态是常态，不是错误）" \
    "rc=0 且 tier=standard" "rc=$RC out=[$(show "$OUT")]"

# ---------------------------------------------------------------------------
echo ""
echo "--- TE tier explain（A.3：三档各值 + 当前值 + 来源；override / floor 要标出来）---"

SB=$(newsb te-basic); mkprofile "$SB"
hrun "$SB" tier explain stop-gate
TE_B_RC="$RC"; TE_B="$OUT$ERRT"
chk "$([ "$TE_B_RC" -eq 0 ] && echo 0 || echo 1)" \
    "TE-1 explain stop-gate → rc 0" "rc=0" "rc=$TE_B_RC out=[$(show "$OUT")] err=[$(show "$ERRT")]"
TE_MISS=""
for w in stop-gate fast standard strict advise block; do
    hasq "$w" "$TE_B" || TE_MISS="$TE_MISS $w"
done
chk "$([ -z "$TE_MISS" ] && echo 0 || echo 1)" \
    "TE-2 输出同时给出三档档名与各自取值（stop-gate: fast=advise / standard=block / strict=block）" \
    "输出含 stop-gate fast standard strict advise block 全部" "缺：${TE_MISS:- 无}｜输出=[$(show "$TE_B")]"
chk "$([ "$TE_B_RC" -eq 0 ] && hasq 'default' "$TE_B" && echo 0 || echo 1)" \
    "TE-3 无覆盖时标来源 default（A.3 的五种来源：default/session/raise/override/floor）" \
    "rc=0 且输出含 default（rc 一起判：usage 文本里也有 default 这个词）" \
    "rc=$TE_B_RC 输出=[$(show "$TE_B")]"
chk "$([ "$TE_B_RC" -eq 0 ] && ! hasq 'override' "$TE_B" && echo 0 || echo 1)" \
    "TE-4 对照：没配 overrides 时输出不许出现 override（否则 TE-6 的标记等于恒真、锁不住任何东西）" \
    "rc=0 且输出不含 override" "rc=$TE_B_RC 输出=[$(show "$TE_B")]"

SB=$(newsb te-unknown); mkprofile "$SB"
hrun "$SB" tier explain no-such-hook
chk "$([ "$RC" -eq 2 ] && echo 0 || echo 1)" \
    "TE-5 explain 未知 hook id → rc 2 用法错（A.3 那一行的退出码）" \
    "rc=2" "rc=$RC out=[$(show "$OUT")] err=[$(show "$ERRT")]"

SB=$(newsb te-override); mkprofile "$SB" 'p.overrides = { "tdd-gate": "off" };'
hrun "$SB" tier explain tdd-gate
TE_O_RC="$RC"; TE_O="$OUT$ERRT"
chk "$([ "$TE_O_RC" -eq 0 ] && hasq 'override' "$TE_O" && echo 0 || echo 1)" \
    "TE-6 配了 overrides.tdd-gate=off → explain 标出 override（用户有最终话语权，但必须看得见）" \
    "rc=0 且输出含 override" "rc=$TE_O_RC 输出=[$(show "$TE_O")]"

SB=$(newsb te-ov-eff); mkprofile "$SB" 'p.overrides = { "tdd-gate": "off" };'
hrun "$SB" tier status
chk "$([ "$(jq_ "$OUT" 'String((d.hooks||d.modes||{})["tdd-gate"])')" = "off" ] && echo 0 || echo 1)" \
    "TE-7 override 真的改变生效值：status 的每 hook 模式表里 tdd-gate = off（只标不生效＝装饰）" \
    "模式表 tdd-gate=off" "out=[$(show "$OUT")]"

SB=$(newsb te-floor); mkprofile "$SB"; mktier "$SB" fast live
hrun "$SB" tier explain secret-exfil-guard
TE_F_RC="$RC"; TE_F="$OUT$ERRT"
chk "$([ "$TE_F_RC" -eq 0 ] && hasq 'floor' "$TE_F" && echo 0 || echo 1)" \
    "TE-8 地板闸 secret-exfil-guard 的来源标 floor（它结构上不在档位表里）" \
    "rc=0 且输出含 floor" "rc=$TE_F_RC 输出=[$(show "$TE_F")]"
chk "$([ "$TE_F_RC" -eq 0 ] && hasq 'block' "$TE_F" && echo 0 || echo 1)" \
    "TE-9 fast 档下地板闸的当前值仍是 block（放水不放安全）" \
    "rc=0 且输出含 block（rc 一起判：usage 文本里也有 block 这个词）" \
    "rc=$TE_F_RC 输出=[$(show "$TE_F")]"

SB=$(newsb te-floorstatus); mkprofile "$SB"; mktier "$SB" fast live
hrun "$SB" tier status
chk "$([ "$(jq_ "$OUT" 'String((d.hooks||d.modes||{})["secret-exfil-guard"])')" = "block" ] && echo 0 || echo 1)" \
    "TE-10 fast 档 status 模式表里 secret-exfil-guard 仍是 block（判定层的地板，不只是 explain 的措辞）" \
    "模式表 secret-exfil-guard=block" "out=[$(show "$OUT")]"

# ---------------------------------------------------------------------------
echo ""
echo "--- TP 自动升档（A.2：raise.paths 命中工作树改动 → 抬到 raise.to，并点名路径）---"

SB=$(newsb tp-hit); mkprofile "$SB"
mkdir -p "$SB/.claude/hooks"
printf '// touched\n' >> "$SB/.claude/hooks/x.mjs"
hrun "$SB" tier status
TP_H="$OUT"
chk "$([ "$(jq_ "$TP_H" 'String(d.tier)')" = "strict" ] && echo 0 || echo 1)" \
    "TP-1 工作树有未提交的 .claude/hooks/x.mjs → effective 抬到 strict（治理面自动升档，不需要人）" \
    "tier=strict" "out=[$(show "$TP_H")]"
chk "$([ "$(jq_ "$TP_H" 'String(d.source)')" = "raise" ] && echo 0 || echo 1)" \
    "TP-2 source=raise（抬上来的和用户设的必须分得清）" "source=raise" "out=[$(show "$TP_H")]"
chk "$(printf '%s' "$(jq_ "$TP_H" 'JSON.stringify(d.raisedBy||[])')" | grep -q 'x\.mjs' && echo 0 || echo 1)" \
    "TP-3 raisedBy 点名命中的那个路径（不点名的自动升档没法解释，用户只会觉得闸抽风）" \
    "raisedBy 含 .claude/hooks/x.mjs" "raisedBy=[$(show "$(jq_ "$TP_H" 'JSON.stringify(d.raisedBy||[])')")]"

SB=$(newsb tp-miss); mkprofile "$SB"
printf 'export const b = 2;\n' >> "$SB/src/a.ts"
hrun "$SB" tier status
TP_M="$OUT"
chk "$([ "$(jq_ "$TP_M" 'String(d.tier)')" = "standard" ] && echo 0 || echo 1)" \
    "TP-4 只改业务代码 src/a.ts → 不抬（raise.paths 是治理面白名单，不是「有改动就抬」）" \
    "tier=standard" "out=[$(show "$TP_M")]"
chk "$([ "$(jq_ "$TP_M" 'String(d.source)')" = "default" ] && echo 0 || echo 1)" \
    "TP-5 未命中时 source 仍是 default" "source=default" "out=[$(show "$TP_M")]"

SB=$(newsb tp-overfast); mkprofile "$SB"; mktier "$SB" fast live
printf '// touched\n' >> "$SB/.claude/hooks/x.mjs"
hrun "$SB" tier status
chk "$([ "$(jq_ "$OUT" 'String(d.tier)')" = "strict" ] && echo 0 || echo 1)" \
    "TP-6 会话开着 fast 时改家底 → 秩取高者，仍是 strict（单调合并：升自动，fast 压不住 raise）" \
    "tier=strict" "out=[$(show "$OUT")]"

# ---------------------------------------------------------------------------
echo ""
echo "--- TC 坏状态（A.1：坏 JSON 视为无覆盖 + quarantine 留痕；CRLF 照常读）---"

SB=$(newsb tc-bad); mkprofile "$SB"; mktier "$SB" fast badjson
hrun "$SB" tier status
TC_B_RC="$RC"; TC_B="$OUT"
chk "$([ "$TC_B_RC" -eq 0 ] && [ "$(jq_ "$TC_B" 'String(d.tier)')" = "standard" ] && echo 0 || echo 1)" \
    "TC-1 坏 JSON 的 tier.json → 视为无覆盖回 default，命令本身不崩" \
    "rc=0 且 tier=standard" "rc=$TC_B_RC out=[$(show "$TC_B")] err=[$(show "$ERRT")]"
QF="$SB/.claude/harness/state/quarantine.jsonl"
chk "$([ -f "$QF" ] && grep -q '"kind":"tier"' "$QF" 2>/dev/null && echo 0 || echo 1)" \
    "TC-2 坏 JSON 往 quarantine.jsonl 记一条 kind=tier（静默回默认＝用户永远不知道自己的档位没生效）" \
    "quarantine.jsonl 含 \"kind\":\"tier\"" "账本=[$(show "$(cat "$QF" 2>/dev/null || true)")]"

SB=$(newsb tc-crlf); mkprofile "$SB"; mktier "$SB" fast crlf
hrun "$SB" tier status
TC_C_RC="$RC"
chk "$([ "$TC_C_RC" -eq 0 ] && [ "$(jq_ "$OUT" 'String(d.tier)')" = "fast" ] && echo 0 || echo 1)" \
    "TC-3 CRLF 行尾的 tier.json 正常读成 fast（#38 的老坑：一边判开一边判关比两边都关更糟）" \
    "rc=0 且 tier=fast" "rc=$TC_C_RC out=[$(show "$OUT")]"
chk "$([ "$TC_C_RC" -eq 0 ] && [ ! -f "$SB/.claude/harness/state/quarantine.jsonl" ] && echo 0 || echo 1)" \
    "TC-4 对照：CRLF 是合法输入，不许留 quarantine（留了说明「坏」的判据把行尾也算进去了）" \
    "rc=0 且无 quarantine.jsonl" \
    "rc=$TC_C_RC $([ -f "$SB/.claude/harness/state/quarantine.jsonl" ] && echo 存在 || echo 不存在)"

# ---------------------------------------------------------------------------
echo ""
echo "--- TL 旧入口薄壳（A.1：fast-mode.sh/.ps1 转发 tier set，不再自己写 .fast-mode）---"

SB=$(newsb tl-on); mkprofile "$SB"
srun "$SB" "$SB/.claude/scripts/fast-mode.sh" on 4
TL_RC="$RC"; TL_F=$(tierfile "$SB")
chk "$([ "$TL_RC" -eq 0 ] && [ "$(jq_ "$TL_F" 'String(d.tier)')" = "fast" ] && echo 0 || echo 1)" \
    "TL-1 fast-mode.sh on 4 → 产生 tier.json 且 tier=fast（薄壳转发 tier set fast）" \
    "rc=0 且 tier=fast" "rc=$TL_RC 文件=[$(show "$TL_F")] err=[$(show "$ERRT")]"
chk "$([ ! -f "$SB/.claude/.fast-mode" ] && echo 0 || echo 1)" \
    "TL-2 不再产生 .claude/.fast-mode（薄壳的意思是自己不再解析、不再落盘）" \
    ".fast-mode 不存在" "$([ -f "$SB/.claude/.fast-mode" ] && echo 存在 || echo 不存在)"

srun "$SB" "$SB/.claude/scripts/fast-mode.sh" status
chk "$([ -n "$(tierfile "$SB")" ] && hasq 'fast' "$OUT$ERRT" && echo 0 || echo 1)" \
    "TL-3 fast-mode.sh status 输出含 fast（防忘关的可见性靠它，不能转发完丢了输出）" \
    "tier.json 已存在（状态从新通道来）且输出含 fast" \
    "文件=[$(show "$(tierfile "$SB")")] 输出=[$(show "$OUT$ERRT")]"

srun "$SB" "$SB/.claude/scripts/fast-mode.sh" off
TL_OFF_RC="$RC"
hrun "$SB" tier status
chk "$([ "$TL_OFF_RC" -eq 0 ] && [ "$(jq_ "$OUT" 'String(d.tier)')" = "standard" ] \
      && [ "$(jq_ "$OUT" 'String(d.source)')" = "default" ] && echo 0 || echo 1)" \
    "TL-4 fast-mode.sh off → effective 回 default（锁可观测结果，不锁 tier.json 是删是改写）" \
    "off rc=0 且随后 tier=standard source=default" \
    "off rc=$TL_OFF_RC status=[$(show "$OUT")]"

if command -v pwsh >/dev/null 2>&1; then
    SB=$(newsb tl-ps); mkprofile "$SB"
    RC=0
    ( cd "$SB" && CLAUDE_PROJECT_DIR="$SB" pwsh -NoProfile -File "$SB/.claude/scripts/fast-mode.ps1" on 4 ) \
        >"$TMP/.o" 2>"$TMP/.e" || RC=$?
    TLP_RC="$RC"; TLP_F=$(tierfile "$SB")
    chk "$([ "$TLP_RC" -eq 0 ] && [ "$(jq_ "$TLP_F" 'String(d.tier)')" = "fast" ] && echo 0 || echo 1)" \
        "TL-5 fast-mode.ps1 on 4 → 同形：tier.json 的 tier=fast" \
        "rc=0 且 tier=fast" "rc=$TLP_RC 文件=[$(show "$TLP_F")] err=[$(show "$(cat "$TMP/.e" 2>/dev/null || true)")]"
    chk "$([ ! -f "$SB/.claude/.fast-mode" ] && echo 0 || echo 1)" \
        "TL-6 fast-mode.ps1 也不再产生 .fast-mode（两个平台一个开关文件，不然又是 #38）" \
        ".fast-mode 不存在" "$([ -f "$SB/.claude/.fast-mode" ] && echo 存在 || echo 不存在)"
    RC=0
    ( cd "$SB" && CLAUDE_PROJECT_DIR="$SB" pwsh -NoProfile -File "$SB/.claude/scripts/fast-mode.ps1" off ) \
        >"$TMP/.o" 2>"$TMP/.e" || RC=$?
    TLP_OFF="$RC"
    hrun "$SB" tier status
    chk "$([ "$TLP_OFF" -eq 0 ] && [ "$(jq_ "$OUT" 'String(d.tier)')" = "standard" ] && echo 0 || echo 1)" \
        "TL-7 fast-mode.ps1 off → effective 回 default" \
        "off rc=0 且随后 tier=standard" "off rc=$TLP_OFF status=[$(show "$OUT")]"
    # grep -c 零命中时自己就印 0 并 rc 1，再 `|| echo 0` 会拼成两行「0\n0」，和 "0" 比永远不等。
    NONASCII=$(LC_ALL=C grep -c '[^ -~	]' "$SCRIPTS/fast-mode.ps1" 2>/dev/null || true)
    chk "$([ "${NONASCII:-1}" = "0" ] && echo 0 || echo 1)" \
        "TL-8 fast-mode.ps1 仍是纯 ASCII（Pinned 约束；改薄壳时最容易顺手带进中文）" \
        "非 ASCII 行数=0" "非 ASCII 行数=${NONASCII:-?}"
else
    skip "TL-5..8 无 pwsh——.ps1 薄壳跑不起来（未执行 != 通过）"
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- TG 引擎接线（A.3：release 的 fast-mode 项改名 tier / invariants 的 tier 段 / dod 加一步）---"

SB=$(newsb tg-release); mkprofile "$SB"; mktier "$SB" fast live
hrun "$SB" release
TG_R="$OUT"
chk "$([ "$(jq_ "$TG_R" 'String((d.checks||[]).some(c => c.id === "tier"))')" = "true" ] && echo 0 || echo 1)" \
    "TG-1 release 的检查项里有 id=tier（A.3：fast-mode 项改名 tier）" \
    "checks 含 id=tier" "ids=[$(show "$(jq_ "$TG_R" 'JSON.stringify((d.checks||[]).map(c=>c.id))')")]"
chk "$([ "$(jq_ "$TG_R" 'String(((d.checks||[]).find(c => c.id === "tier")||{}).status)')" = "FAIL" ] && echo 0 || echo 1)" \
    "TG-2 fast 生效时 tier 项 FAIL（effective ≠ fast 才 PASS——带着降档发版是把跳过的闸带进产物）" \
    "tier 项 status=FAIL" "tier 项=[$(show "$(jq_ "$TG_R" 'JSON.stringify((d.checks||[]).find(c=>c.id==="tier")||null)')")]"
chk "$([ "$(jq_ "$TG_R" 'String((d.checks||[]).some(c => c.id === "fast-mode"))')" = "false" ] && echo 0 || echo 1)" \
    "TG-3 旧的 fast-mode 项不再出现（改名不是加一项，两项并存会各判各的）" \
    "checks 不含 id=fast-mode" "ids=[$(show "$(jq_ "$TG_R" 'JSON.stringify((d.checks||[]).map(c=>c.id))')")]"

SB=$(newsb tg-relok); mkprofile "$SB"
hrun "$SB" release
chk "$([ "$(jq_ "$OUT" 'String(((d.checks||[]).find(c => c.id === "tier")||{}).status)')" = "PASS" ] && echo 0 || echo 1)" \
    "TG-4 对照：standard 档下 tier 项 PASS（证明 TG-2 判的是档位，不是恒 FAIL）" \
    "tier 项 status=PASS" "tier 项=[$(show "$(jq_ "$OUT" 'JSON.stringify((d.checks||[]).find(c=>c.id==="tier")||null)')")]"

SB=$(newsb tg-inv); mkprofile "$SB"; mktier "$SB" fast live
hrun "$SB" invariants
TG_I=$(jq_ "$OUT" 'String(d.text || "")')
chk "$(printf '%s' "$TG_I" | grep -q '^\s*-\{0,1\}\s*[-*]\{0,1\}\s*tier:' && echo 0 || echo 1)" \
    "TG-5 invariants 的处境段有一行 tier:（Fast Mode 段改成 tier 段）" \
    "渲染文本含一行以 tier: 起头的条目" "text=[$(show "$TG_I")]"
chk "$(printf '%s' "$TG_I" | grep -qi 'debt\|债' && echo 0 || echo 1)" \
    "TG-6 fast 生效时措辞仍是「债」（A.3 明写保留：降档不是免费的）" \
    "渲染文本含 debt 或 债" "text=[$(show "$TG_I")]"

SB=$(newsb tg-dod); mkprofile "$SB"
hrun "$SB" dod
TG_D="$OUT"
chk "$([ "$(jq_ "$TG_D" 'String((d.steps||[]).some(s => (s.argv||[]).join(" ") === "tier validate"))')" = "true" ] && echo 0 || echo 1)" \
    "TG-7 dod 的步骤列表含一步 tier validate（profile 写错了不许一路走到发版）" \
    "steps 里有 argv = [tier, validate]" \
    "argv 列表=[$(show "$(jq_ "$TG_D" 'JSON.stringify((d.steps||[]).map(s=>(s.argv||[]).join(" ")))')")]"

echo ""
echo "==== test-tier：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ]
