#!/usr/bin/env bash
# test-tier-hardening.sh — Phase A 档位的**韧性与执法面**红锁：Phase A 审查报告
#   （P1-1 / P2-1 / P2-2 / P2-3 / P3-1 / P3-5 / P3-6a）逐条钉成可重跑用例。
#
# 与 test-tier.sh 的分工：那份锁「四个子命令的正常语义」（validate/set/status/explain 说得对不对），
#   这份锁「输入坏掉时它还站不站得住，以及地板到底拦不拦」——两类断言混一份会让谁红了都要翻半天。
#
# red-locks-the-bug：本文件写的是**修好之后应该成立的行为**，不是「现状能复现」。
#   PH / PB / PS / PX 四组现在必然 FAIL——这是它们的成功状态：
#     PH  引擎顶层读 profile.json，文件一缺一坏整台引擎 rc 1 + 空 stdout（连 doctor 一起崩）
#     PB  session-rules-banner 在档位表里却从不问 gateMode，overrides 说 off 它照喊
#     PS  settings.json 读不出时三条校验规则静默关掉，仍报 ok:true rc 0
#     PX  8h 硬上限只在写侧，手写一份 tier.json 就能拿到 720 小时的 fast
#   PF / PL / PR 三组现在应当全绿——它们补的是**覆盖缺口**不是缺陷：突变实验证明这几条路径
#   （地板 override、薄壳的引擎缺席分支、banner 的 raise 播报）删掉后现有 71/0 与 277/0 双绿，
#   没有任何断言响。绿着入库的意义是从今天起它们删不掉。
#
# 契约来源（从底本与审查结论来，不从实现反推措辞）：
#   docs/v3-work-packs.md            A.1 profile.json「进分发包、用户可改」；fast 硬上限 8h
#   docs/v3-tiered-harness-proposal.md §3.1 fast 的 8 小时硬上限；§3.4「档位只改拦不拦，不改报什么」
#   .claude/hooks/lib/tier.mjs:12-14 「profile.json 缺席不等于没有档位：缺文件就按内置默认表跑」
#   .claude/harness/lib/tier.mjs:22-23 validate 的退出码 0 合规 / 1 违规 / 3 无 profile
#
# 本文件写死的几处口径假设（底本没写到字段级；主 Agent 裁定后如有出入改这里，别改实现）：
#   ① 缺 profile 时 `tier validate` 判 **rc 3**——引擎自己的头注释与 dod golden 都按 3 走
#      （3 = DEGRADED，不进 blockingFailures）。派单口述的「rc 0」与之冲突，取引擎自述契约，
#      并把「stdout 必须是合法 JSON」单列一条：那条才是 P1-1 的要害，rc 取 0 还是 3 只影响一条。
#   ② settings.json 读不出时 `tier validate` 判 **rc 3 + 一个为真的 degraded 字段**——
#      「三条规则一条没跑」既不是合规（rc 0）也不是 profile 有违规（rc 1），四态里它是降级。
#   ③ 读侧 8h 夹只断言可观测结果（expiresEpoch 被夹、过了 8h 回默认档），不锁夹在
#      readSession 还是 effectiveTier，也不锁 set_epoch 缺失时怎么兜底（那条另议）。
#
# 跨平台：只用 bash + node + git + coreutils；`.ps1` 段现查 `command -v pwsh`，缺席打 SKIP。
#   pwsh 的 Write-Error 会按终端宽度折行并插 ANSI —— PL 组比对前先剥色码再删掉所有空白，
#   否则同一句提示在别的宽度下就断在路径中间。
# 纪律：一切写操作只落 mktemp 沙箱（真仓根写 tier.json 会当场影响本 session 在跑的 hook），
#   对本仓只读；每条断言打印 EXPECT / GOT，判定不依赖措辞。
#
# 组号：PH 引擎对坏 profile 的韧性 / PF 地板不可 override / PB banner 读 gateMode /
#       PS settings 不可读 / PX 读侧 8h 夹 / PL 薄壳引擎缺席 / PR banner 新分支
set -eu

# CC_BASE_ROOT 覆盖是给「拿候选修复验修得好」留的口子：把本脚本拷去 /tmp、指向打过补丁的
# 仓库副本跑同一批断言，零改动本仓。不设时按脚本自身位置推。
ROOT=${CC_BASE_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
HARNESS="$ROOT/.claude/harness/harness.mjs"
HOOKS="$ROOT/.claude/hooks"
SCRIPTS="$ROOT/.claude/scripts"
FIX="$ROOT/.claude/tests/fixtures/tier/profile-base.json"

echo "===== test-tier-hardening ====="

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
# EXPECT / GOT 无论过不过都打印：判定要能被第三方复核，不靠本文件的措辞。
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
# 解析不了回 <not-json>：这正是 PH 组要抓的形态，不能让它静悄悄变成空串。
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

# isjson <文本> —— 是不是一份合法 JSON（emit 契约：每个子命令 stdout 单行 JSON）。
isjson() { [ "$(jq_ "$1" '"yes"')" = "yes" ]; }

hasq() { printf '%s' "$2" | grep -qF "$1"; }

# squash <文本> —— 剥 ANSI 色码 + 删掉所有空白。pwsh 的 Write-Error 按终端宽度折行，
# 提示里的路径会被 `\n     | ` 断开；比对无空白形态才不受宽度影响。
squash() { printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g' | tr -d ' \t\r\n'; }

# ---------------------------------------------------------------------------
# 沙箱夹具（与 test-tier.sh 同法：git 仓 + .claude 骨架 + 引擎整台搬进去）
# ---------------------------------------------------------------------------

# newsb <名> —— 造沙箱项目。引擎与 hook 都整目录拷贝、不枚举模块名（拆库后少一个就是假红）。
newsb() {
    local d="$TMP/$1"
    rm -rf "$d"
    mkdir -p "$d/.claude/harness/lib" "$d/.claude/hooks/lib" "$d/.claude/scripts" \
             "$d/.claude/evidence" "$d/.claude/.runtime" "$d/src"
    cp "$ROOT/.claude/settings.json" "$d/.claude/settings.json" 2>/dev/null || true
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
#   写完必须提交：.claude/harness/** 在 raise.paths 里，留成未跟踪会把沙箱自动抬成 strict，
#   那时候「默认档」的断言全变红，红因和断言想说的事就对不上了。
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
    commit_sb "$d" profile
}

# commit_sb <沙箱> <消息> —— 把当前工作树全提交掉，让自动升档不掺进来。
#   PH 组「删掉 profile.json」「写成坏 JSON」都改的是 raise.paths 命中的文件，不提交就是
#   在测 raise 而不是在测韧性。
commit_sb() {
    ( cd "$1" && git add -A && git commit -qm "$2" ) >/dev/null 2>&1 || true
}

# 运行夹具：RC / OUT(stdout) / ERRT(stderr) 回填。
RC=0
OUT=""
ERRT=""

# hrun <沙箱> <argv…> —— 在沙箱当项目根跑**本仓**的引擎（profile 从项目根读，与真实调用同形）。
hrun() {
    local d="$1"
    shift
    RC=0
    ( cd "$d" && CLAUDE_PROJECT_DIR="$d" node "$HARNESS" "$@" ) >"$TMP/.o" 2>"$TMP/.e" || RC=$?
    OUT=$(cat "$TMP/.o" 2>/dev/null || true)
    ERRT=$(cat "$TMP/.e" 2>/dev/null || true)
}

# sbrun <沙箱> <argv…> —— 跑**沙箱里那份引擎副本**。PH 组只能用它：出事的那处读盘按引擎
#   自身位置（HARNESS_DIR）取 profile.json，跑本仓的引擎读的就是本仓的 profile，测不到东西。
sbrun() {
    local d="$1"
    shift
    RC=0
    ( cd "$d" && CLAUDE_PROJECT_DIR="$d" node "$d/.claude/harness/harness.mjs" "$@" ) \
        >"$TMP/.o" 2>"$TMP/.e" || RC=$?
    OUT=$(cat "$TMP/.o" 2>/dev/null || true)
    ERRT=$(cat "$TMP/.e" 2>/dev/null || true)
}

# hookrun <hook 名> <沙箱> <stdin 文本> —— 跑沙箱里的 hook（状态与判定都落沙箱）。
hookrun() {
    local n="$1" d="$2" input="$3"
    RC=0
    printf '%s' "$input" | ( cd "$d" && CLAUDE_PROJECT_DIR="$d" node "$d/.claude/hooks/$n.mjs" ) \
        >"$TMP/.o" 2>"$TMP/.e" || RC=$?
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

# mkruntime <沙箱> <tier> <set_epoch> <expires_epoch|-> —— 手写一份运行态覆盖。
#   手写是本组的重点：`tier set` 写不出超过 8h 的窗口，读侧到底夹不夹只能这么问。
mkruntime() {
    local d="$1" t="$2" se="$3" ex="$4"
    mkdir -p "$d/.claude/.runtime"
    if [ "$ex" = "-" ]; then
        printf '{"tier":"%s","reason":"hand-written","by":"user","set_epoch":%s}\n' "$t" "$se" \
            > "$d/.claude/.runtime/tier.json"
    else
        printf '{"tier":"%s","reason":"hand-written","by":"user","set_epoch":%s,"expires_epoch":%s}\n' \
            "$t" "$se" "$ex" > "$d/.claude/.runtime/tier.json"
    fi
}

NOW=$(date +%s)
# 密钥文件名拼出来而不是写死：本文件会被 scan-secrets / secret-exfil-guard 自己扫到，
# 一个字面 id_rsa 会让审计报告里多一条本不存在的命中（test-hooks-node.sh 同法）。
DOTENV=".env"

# ---------------------------------------------------------------------------
echo ""
echo "--- PH 引擎对 profile.json 缺 / 坏的韧性（P1-1：顶层读盘 = 整台引擎的单点故障）---"

# 对照先行：同一份沙箱引擎副本、profile 齐全时必须跑得动。这条绿了，下面的红才能归因到
# 「profile 缺/坏」，而不是「引擎拷贝本身起不来」。
SB=$(newsb ph-sane); mkprofile "$SB"
sbrun "$SB" doctor
chk "$([ "$RC" -eq 0 ] && isjson "$OUT" && echo 0 || echo 1)" \
    "PH-0 对照：沙箱引擎副本 + profile 齐全 → doctor rc 0 且 stdout 合法 JSON（夹具自证）" \
    "rc=0 且 stdout 是 JSON" "rc=$RC out=[$(show "$OUT")] err=[$(show "$ERRT")]"

SB=$(newsb ph-missing); mkprofile "$SB"
rm -f "$SB/.claude/harness/profile.json"; commit_sb "$SB" drop-profile
sbrun "$SB" doctor
chk "$([ "$RC" -eq 0 ] && isjson "$OUT" && echo 0 || echo 1)" \
    "PH-1 profile.json 缺失 → doctor 仍 rc 0（自诊工具是排障的最后一根绳，不能跟着断）" \
    "rc=0 且 stdout 是 JSON" "rc=$RC out=[$(show "$OUT")] err1=[$(printf '%s' "$ERRT" | head -1)]"

sbrun "$SB" tier status
PH_ST_RC="$RC"; PH_ST="$OUT"
chk "$([ "$PH_ST_RC" -eq 0 ] && [ "$(jq_ "$PH_ST" 'String(d.tier)')" = "standard" ] \
      && [ "$(jq_ "$PH_ST" 'String(d.source)')" = "default" ] && echo 0 || echo 1)" \
    "PH-2 profile.json 缺失 → tier status rc 0，tier=standard source=default（内置默认表在跑）" \
    "rc=0 且 tier=standard source=default" "rc=$PH_ST_RC out=[$(show "$PH_ST")]"
chk "$([ "$(jq_ "$PH_ST" 'String(d.profilePresent)')" = "false" ] && echo 0 || echo 1)" \
    "PH-3 同上 → profilePresent=false（跑内置表 ≠ 假装装了一份，排障要分得清）" \
    "profilePresent=false" "out=[$(show "$PH_ST")]"

sbrun "$SB" tier validate
PH_V_RC="$RC"; PH_V="$OUT"
chk "$(isjson "$PH_V" && echo 0 || echo 1)" \
    "PH-4 profile.json 缺失 → tier validate 的 stdout 仍是合法 JSON（emit 契约不许在这条路上失效）" \
    "stdout 是 JSON" "rc=$PH_V_RC out=[$(show "$PH_V")] err1=[$(printf '%s' "$ERRT" | head -1)]"
chk "$([ "$PH_V_RC" -eq 3 ] && echo 0 || echo 1)" \
    "PH-5 同上 → rc=3（no-profile：内置表在跑，没东西可校验；rc 1 会跟「profile 有违规」撞码）" \
    "rc=3" "rc=$PH_V_RC out=[$(show "$PH_V")]"

sbrun "$SB" risk
chk "$([ "$RC" -eq 0 ] || [ "$RC" -eq 3 ] && isjson "$OUT" && echo 0 || echo 1)" \
    "PH-6 profile.json 缺失 → risk rc 0/3 且 stdout 合法 JSON（不是 rc 1 + 空 stdout）" \
    "rc∈{0,3} 且 stdout 是 JSON" "rc=$RC out=[$(show "$OUT")] err1=[$(printf '%s' "$ERRT" | head -1)]"

SB=$(newsb ph-corrupt); mkprofile "$SB"
printf '{"version": 1, "default": "standard",,\n' > "$SB/.claude/harness/profile.json"
commit_sb "$SB" corrupt-profile
sbrun "$SB" tier validate
PH_C_RC="$RC"; PH_C="$OUT"
chk "$([ "$PH_C_RC" -eq 1 ] && isjson "$PH_C" && echo 0 || echo 1)" \
    "PH-7 profile.json 坏 JSON → tier validate rc 1 且 stdout 是合法 JSON（用户改坏一个逗号，得到的要是判决不是 node 栈）" \
    "rc=1 且 stdout 是 JSON" "rc=$PH_C_RC out=[$(show "$PH_C")] err1=[$(printf '%s' "$ERRT" | head -1)]"
chk "$([ "$(jq_ "$PH_C" 'String((d.violations||[]).some(v => v.code === "UNREADABLE"))')" = "true" ] && echo 0 || echo 1)" \
    "PH-8 同上 → violations 里点名 UNREADABLE（引擎自己写好的那条错误路径必须真的走得到）" \
    "violations 含 code=UNREADABLE" "out=[$(show "$PH_C")]"
PH_Q=$(cat "$SB/.claude/harness/state/quarantine.jsonl" 2>/dev/null || true)
chk "$(printf '%s' "$PH_Q" | grep -q '"kind":"profile"' && echo 0 || echo 1)" \
    "PH-9 同上 → quarantine.jsonl 多一条 kind=profile（坏状态留痕，不许静默）" \
    "账本含 \"kind\":\"profile\"" "账本=[$(show "$PH_Q")]"

sbrun "$SB" doctor
chk "$([ "$RC" -eq 0 ] || [ "$RC" -eq 3 ] && isjson "$OUT" && echo 0 || echo 1)" \
    "PH-10 profile.json 坏 JSON → doctor rc 0/3 且 stdout 合法 JSON" \
    "rc∈{0,3} 且 stdout 是 JSON" "rc=$RC out=[$(show "$OUT")] err1=[$(printf '%s' "$ERRT" | head -1)]"
sbrun "$SB" risk
chk "$([ "$RC" -eq 0 ] || [ "$RC" -eq 3 ] && isjson "$OUT" && echo 0 || echo 1)" \
    "PH-11 profile.json 坏 JSON → risk rc 0/3 且 stdout 合法 JSON" \
    "rc∈{0,3} 且 stdout 是 JSON" "rc=$RC out=[$(show "$OUT")] err1=[$(printf '%s' "$ERRT" | head -1)]"

# JSON 数组这一支顶层 JSON.parse 成功、只在 loadProfile 那层被判 UNREADABLE，所以它现在就绿。
# 留着是给 PH-7 做对照：证明 UNREADABLE 这条路径本身是好的，红的是「进程先死在顶层读盘」。
SB=$(newsb ph-array); mkprofile "$SB"
printf '[]\n' > "$SB/.claude/harness/profile.json"; commit_sb "$SB" array-profile
sbrun "$SB" tier validate
chk "$([ "$RC" -eq 1 ] && [ "$(jq_ "$OUT" 'String((d.violations||[]).some(v => v.code === "UNREADABLE"))')" = "true" ] && echo 0 || echo 1)" \
    "PH-12 对照：profile.json 写成 JSON 数组 → rc 1 + UNREADABLE（UNREADABLE 路径本身没坏）" \
    "rc=1 且 violations 含 UNREADABLE" "rc=$RC out=[$(show "$OUT")]"

# 通例：模块顶层的读盘 = 整台引擎的单点故障，一处都不许有。相对路径 grep，输出里不带开发机绝对路径。
PH_TOP=$( cd "$ROOT" && LC_ALL=C grep -n '^const .*JSON\.parse(fs\.readFileSync' \
          .claude/harness/lib/*.mjs .claude/harness/harness.mjs 2>/dev/null || true )
chk "$([ -z "$PH_TOP" ] && echo 0 || echo 1)" \
    "PH-13 通例：引擎里没有模块顶层的 JSON.parse(fs.readFileSync(...))（顶层读盘 = 单点故障）" \
    "命中 0 处" "命中=[$(show "$PH_TOP")]"

# ---------------------------------------------------------------------------
echo ""
echo "--- PF 地板不可被 override 压掉（P2-1：floor 分支删掉后 71/0 + 277/0 双绿，无人测到）---"

SB=$(newsb pf-ov); mkprofile "$SB" 'p.overrides = { "secret-exfil-guard": "off" };'
hrun "$SB" tier explain secret-exfil-guard
PF_E_RC="$RC"; PF_E="$OUT"
chk "$([ "$PF_E_RC" -eq 0 ] && [ "$(jq_ "$PF_E" 'String(d.source)')" = "floor" ] && echo 0 || echo 1)" \
    "PF-1 overrides 把地板闸写成 off → explain 的 source 仍是 floor（不是 override）" \
    "rc=0 且 source=floor" "rc=$PF_E_RC out=[$(show "$PF_E")]"
chk "$([ "$(jq_ "$PF_E" 'String(d.effective)')" = "block" ] && echo 0 || echo 1)" \
    "PF-2 同上 → explain 的 effective=block（判定层的地板；这一条才杀得掉「删 floor 分支」的突变）" \
    "effective=block" "out=[$(show "$PF_E")]"

hrun "$SB" tier status
chk "$([ "$(jq_ "$OUT" 'String((d.hooks||{})["secret-exfil-guard"])')" = "block" ] && echo 0 || echo 1)" \
    "PF-3 同上 → status 模式表里 secret-exfil-guard=block（对外契约那一格不许说谎）" \
    "模式表 secret-exfil-guard=block" "out=[$(show "$OUT")]"

hrun "$SB" tier validate
PF_V_RC="$RC"; PF_V="$OUT"
chk "$([ "$PF_V_RC" -eq 1 ] \
      && [ "$(jq_ "$PF_V" 'String((d.violations||[]).some(v => v.code === "OVERRIDE_ON_FLOOR" && v.hook === "secret-exfil-guard"))')" = "true" ] \
      && echo 0 || echo 1)" \
    "PF-4 同上 → validate rc 1 且点名 OVERRIDE_ON_FLOOR + secret-exfil-guard（配错了要说清是哪一行）" \
    "rc=1 且 violations 含 {code:OVERRIDE_ON_FLOOR, hook:secret-exfil-guard}" \
    "rc=$PF_V_RC out=[$(show "$PF_V")]"

hookrun secret-exfil-guard "$SB" "{\"tool_input\":{\"command\":\"cat $DOTENV\"}}"
chk "$([ "$RC" -eq 2 ] && echo 0 || echo 1)" \
    "PF-5 同一沙箱喂外泄命令 → hook 仍 exit 2（validate 是可选步骤，gateMode 才是每个事件都跑的执法点）" \
    "rc=2" "rc=$RC err1=[$(printf '%s' "$ERRT" | head -1 | cut -c1-120)]"

# 对照组：同样一条 overrides 压在**非地板**闸上必须真的生效。缺了它，上面四条等价于「override 全无效」。
SB=$(newsb pf-ctl); mkprofile "$SB" 'p.overrides = { "tdd-gate": "off" };'
hrun "$SB" tier status
chk "$([ "$(jq_ "$OUT" 'String((d.hooks||{})["tdd-gate"])')" = "off" ] && echo 0 || echo 1)" \
    "PF-6 对照：overrides 压在非地板闸 tdd-gate 上真的生效（=off），证明 PF-1..5 判的是地板" \
    "模式表 tdd-gate=off" "out=[$(show "$OUT")]"

# 结构地板：profile 把 secret-exfil-guard 从 floor 里删掉、并给它一行 fast=off 的档位表 ——
# BUILTIN_FLOOR 是代码里的地板，profile 只能往里加不能往外拿。
SB=$(newsb pf-struct)
mkprofile "$SB" 'p.floor = p.floor.filter(x => x !== "secret-exfil-guard");
p.hooks["secret-exfil-guard"] = { kind: "guard", fast: "off", standard: "off", strict: "block" };'
mkruntime "$SB" fast "$NOW" "$((NOW + 3600))"
hrun "$SB" tier status
chk "$([ "$(jq_ "$OUT" 'String((d.hooks||{})["secret-exfil-guard"])')" = "block" ] && echo 0 || echo 1)" \
    "PF-7 profile 把地板闸移出 floor 并写成 fast=off + fast 生效 → 模式表仍 block（结构地板拿不掉）" \
    "模式表 secret-exfil-guard=block" "out=[$(show "$OUT")]"
hrun "$SB" tier validate
PF_S_RC="$RC"; PF_S="$OUT"
chk "$([ "$PF_S_RC" -eq 1 ] \
      && [ "$(jq_ "$PF_S" 'String((d.violations||[]).some(v => v.code === "FLOOR_IN_TABLE" && v.hook === "secret-exfil-guard"))')" = "true" ] \
      && echo 0 || echo 1)" \
    "PF-8 同上 → validate rc 1 报 FLOOR_IN_TABLE（给地板闸配一个可调档位是配置错，不是配置）" \
    "rc=1 且 violations 含 {code:FLOOR_IN_TABLE, hook:secret-exfil-guard}" \
    "rc=$PF_S_RC out=[$(show "$PF_S")]"
hookrun secret-exfil-guard "$SB" "{\"tool_input\":{\"command\":\"cat $DOTENV\"}}"
chk "$([ "$RC" -eq 2 ] && echo 0 || echo 1)" \
    "PF-9 同上 → hook 侧照拦 exit 2（fast 档 + profile 说 off，两头都放水也拦得住）" \
    "rc=2" "rc=$RC err1=[$(printf '%s' "$ERRT" | head -1 | cut -c1-120)]"

# ---------------------------------------------------------------------------
echo ""
echo "--- PB session-rules-banner 读 gateMode（P2-2：它在档位表里却从不问，status 报的模式是假的）---"

SB=$(newsb pb-off); mkprofile "$SB" 'p.overrides = { "session-rules-banner": "off" };'
hrun "$SB" tier status
chk "$([ "$(jq_ "$OUT" 'String((d.hooks||{})["session-rules-banner"])')" = "off" ] && echo 0 || echo 1)" \
    "PB-1 前提：overrides 把 banner 调成 off 后，status 模式表确实报 off（这一格是 A.3 的对外契约）" \
    "模式表 session-rules-banner=off" "out=[$(show "$OUT")]"

hookrun session-rules-banner "$SB" '{"source":"startup"}'
PB_RC="$RC"; PB_OUT="$OUT"
chk "$([ -z "$PB_OUT" ] && echo 0 || echo 1)" \
    "PB-2 同一沙箱实跑 banner → stdout 为空（引擎报 off、闸本人照喊，模式表就有一格在说谎）" \
    "stdout 为空" "stdout=[$(show "$PB_OUT")]"
chk "$([ "$PB_RC" -eq 0 ] && echo 0 || echo 1)" \
    "PB-3 同上 → rc 0（off 是静默放行，不是失败）" "rc=0" "rc=$PB_RC err=[$(show "$ERRT")]"

SB=$(newsb pb-on); mkprofile "$SB"
hookrun session-rules-banner "$SB" '{"source":"startup"}'
chk "$([ "$RC" -eq 0 ] && hasq '铁律' "$OUT" && echo 0 || echo 1)" \
    "PB-4 对照：不配 override 时照常播报横幅（证明 PB-2 判的是 off 生效，不是「这闸恒哑」）" \
    "rc=0 且 stdout 含横幅" "rc=$RC stdout=[$(show "$OUT")]"

# ---------------------------------------------------------------------------
echo ""
echo "--- PS settings.json 读不出时不许报合规（P2-3：三条规则静默关掉仍 ok:true rc 0）---"

SB=$(newsb ps-bad); mkprofile "$SB"
printf '{ "hooks": broken,,\n' > "$SB/.claude/settings.json"; commit_sb "$SB" bad-settings
hrun "$SB" tier validate
PS_B_RC="$RC"; PS_B="$OUT"
chk "$([ "$PS_B_RC" -eq 3 ] && echo 0 || echo 1)" \
    "PS-1 settings.json 坏 JSON → tier validate rc 3（三条规则一条没跑，是降级不是合规）" \
    "rc=3" "rc=$PS_B_RC out=[$(show "$PS_B")]"
chk "$([ "$(jq_ "$PS_B" 'String(Boolean(d.degraded))')" = "true" ] && echo 0 || echo 1)" \
    "PS-2 同上 → stdout JSON 里 degraded 为真（机器通道要读得出「这次判决打了折」）" \
    "degraded 为真" "out=[$(show "$PS_B")]"
chk "$(hasq 'settings.json' "$PS_B$ERRT" && echo 0 || echo 1)" \
    "PS-3 同上 → 输出点名 settings.json（说清是哪份读不出来，不然拿到 rc 3 也不知道修哪）" \
    "输出含 settings.json" "out=[$(show "$PS_B")] err=[$(show "$ERRT")]"

SB=$(newsb ps-miss); mkprofile "$SB"
rm -f "$SB/.claude/settings.json"; commit_sb "$SB" drop-settings
hrun "$SB" tier validate
chk "$([ "$RC" -eq 3 ] && echo 0 || echo 1)" \
    "PS-4 settings.json 缺失 → 同样 rc 3（缺和坏都是「登记表读不出来」，不该有两种口径）" \
    "rc=3" "rc=$RC out=[$(show "$OUT")]"

# 最要命的一格：profile 里真有违规，但 settings 坏掉把发现它的规则关了 —— 机器通道读成合规。
SB=$(newsb ps-mask); mkprofile "$SB" 'p.hooks["ghost-hook"] = { kind: "guard", fast: "off", standard: "advise", strict: "block" };'
printf '{ "hooks": broken,,\n' > "$SB/.claude/settings.json"; commit_sb "$SB" bad-settings
hrun "$SB" tier validate
chk "$([ "$RC" -ne 0 ] && echo 0 || echo 1)" \
    "PS-5 settings 坏 + profile 里有 ghost-hook → rc 不许是 0（发现它的规则没跑，不能读作合规）" \
    "rc≠0" "rc=$RC out=[$(show "$OUT")]"

SB=$(newsb ps-ok); mkprofile "$SB"
hrun "$SB" tier validate
PS_O_RC="$RC"; PS_O="$OUT"
chk "$([ "$PS_O_RC" -eq 0 ] && [ "$(jq_ "$PS_O" 'String(Boolean(d.degraded))')" = "false" ] && echo 0 || echo 1)" \
    "PS-6 对照：settings 正常 + profile 合规 → rc 0 且 degraded 不为真（证明 PS-1 判的是登记表读不出来）" \
    "rc=0 且 degraded 假" "rc=$PS_O_RC out=[$(show "$PS_O")]"

# ---------------------------------------------------------------------------
echo ""
echo "--- PX 读侧 8h 夹（P3-1：8h 上限只在写侧，手写一份 tier.json 就能拿到 720 小时 fast）---"

SB=$(newsb px-720); mkprofile "$SB"
PX_SET="$NOW"
mkruntime "$SB" fast "$PX_SET" "$((PX_SET + 2592000))"    # 手写 720 小时
hrun "$SB" tier status
PX_A="$OUT"
PX_EXP=$(jq_ "$PX_A" 'String(d.expiresEpoch)')
chk "$([ "$PX_EXP" != "<not-json>" ] && [ "$PX_EXP" != "undefined" ] \
      && [ "$PX_EXP" -le "$((PX_SET + 28800))" ] 2>/dev/null && echo 0 || echo 1)" \
    "PX-1 手写 expires=set+720h → status 的 expiresEpoch ≤ set_epoch+8h（上限是保证，不是写侧的礼貌）" \
    "expiresEpoch ≤ $((PX_SET + 28800))" "expiresEpoch=$PX_EXP（set_epoch=$PX_SET）"
chk "$([ "$(jq_ "$PX_A" 'String(Number(d.remainingHours) <= 8)')" = "true" ] && echo 0 || echo 1)" \
    "PX-2 同上 → remainingHours ≤ 8（报出去的剩余时间跟着夹，不然横幅还在说「剩 720h」）" \
    "remainingHours ≤ 8" "out=[$(show "$PX_A")]"

SB=$(newsb px-old); mkprofile "$SB"
mkruntime "$SB" fast "$((NOW - 32400))" "$((NOW + 2520000))"   # 9 小时前设的，expires 还很远
hrun "$SB" tier status
PX_B="$OUT"
chk "$([ "$(jq_ "$PX_B" 'String(d.tier)')" = "standard" ] \
      && [ "$(jq_ "$PX_B" 'String(d.source)')" = "default" ] && echo 0 || echo 1)" \
    "PX-3 set_epoch 在 9 小时前、expires 还很远 → effective 已回默认档（过了 8h 就该失效）" \
    "tier=standard source=default" "out=[$(show "$PX_B")]"

SB=$(newsb px-ok); mkprofile "$SB"
PX_OK_EXP=$((NOW + 14400))
mkruntime "$SB" fast "$NOW" "$PX_OK_EXP"                        # 正常 4 小时窗口
hrun "$SB" tier status
PX_C="$OUT"
chk "$([ "$(jq_ "$PX_C" 'String(d.tier)')" = "fast" ] \
      && [ "$(jq_ "$PX_C" 'String(d.expiresEpoch)')" = "$PX_OK_EXP" ] && echo 0 || echo 1)" \
    "PX-4 对照：8h 以内的正常窗口原样生效、expiresEpoch 不被改（夹的是越界，不是一律改写）" \
    "tier=fast 且 expiresEpoch=$PX_OK_EXP" "out=[$(show "$PX_C")]"

# ---------------------------------------------------------------------------
echo ""
echo "--- PL 薄壳的「引擎缺席」分支（P3-6a：引擎装坏时用户唯一的求助出口，零断言）---"

SB=$(newsb pl-sh); mkprofile "$SB"
rm -f "$SB/.claude/harness/harness.mjs"
srun "$SB" "$SB/.claude/scripts/fast-mode.sh" status
PL_RC="$RC"; PL_ERR="$ERRT"
chk "$([ "$PL_RC" -eq 3 ] && echo 0 || echo 1)" \
    "PL-1 引擎不在 → fast-mode.sh status rc 3（区别于 2 用法错、0 正常，说明是环境坏了）" \
    "rc=3" "rc=$PL_RC err=[$(show "$PL_ERR")]"
chk "$(hasq '.claude/.runtime/tier.json' "$(squash "$PL_ERR")" && echo 0 || echo 1)" \
    "PL-2 同上 → 提示里给出不依赖引擎的退路（点名 .claude/.runtime/tier.json）" \
    "stderr 含 .claude/.runtime/tier.json" "err=[$(show "$PL_ERR")]"

if command -v pwsh >/dev/null 2>&1; then
    SB=$(newsb pl-ps); mkprofile "$SB"
    rm -f "$SB/.claude/harness/harness.mjs"
    RC=0
    ( cd "$SB" && CLAUDE_PROJECT_DIR="$SB" pwsh -NoProfile -File "$SB/.claude/scripts/fast-mode.ps1" status ) \
        >"$TMP/.o" 2>"$TMP/.e" || RC=$?
    PLP_RC="$RC"; PLP_ERR=$(cat "$TMP/.e" 2>/dev/null || true)
    chk "$([ "$PLP_RC" -eq 3 ] && echo 0 || echo 1)" \
        "PL-3 .ps1 同形：引擎不在 → rc 3（两个平台一个语义，不然 Windows 侧自己发明一套）" \
        "rc=3" "rc=$PLP_RC err=[$(show "$PLP_ERR")]"
    chk "$(hasq '.claude/.runtime/tier.json' "$(squash "$PLP_ERR")" && echo 0 || echo 1)" \
        "PL-4 .ps1 同形：提示里同样给出 .claude/.runtime/tier.json 这条退路" \
        "stderr（剥 ANSI 去空白后）含 .claude/.runtime/tier.json" "err=[$(show "$PLP_ERR")]"
else
    skip "PL-3..4 无 pwsh——.ps1 薄壳跑不起来（未执行 != 通过）"
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- PR session-rules-banner 的两条无断言分支（P3-5：raise 播报 / fast 与 compact 谁赢）---"

SB=$(newsb pr-raise); mkprofile "$SB"
printf '// touched\n' > "$SB/.claude/hooks/x.mjs"
hookrun session-rules-banner "$SB" '{"source":"startup"}'
PR_A_RC="$RC"; PR_A="$OUT"
chk "$([ "$PR_A_RC" -eq 0 ] && hasq 'strict' "$PR_A" && hasq 'raise' "$PR_A" && echo 0 || echo 1)" \
    "PR-1 工作树改了 .claude/hooks/** → 播报 strict 且说明来源 raise（今天为什么全是硬拦，要说得出）" \
    "rc=0 且 stdout 同时含 strict 与 raise" "rc=$PR_A_RC line1=[$(printf '%s' "$PR_A" | head -1)]"
chk "$(hasq '.claude/hooks/x.mjs' "$PR_A" && echo 0 || echo 1)" \
    "PR-2 同上 → 点名是哪个文件把档位抬上去的（不点名就只能自己 git status 猜）" \
    "stdout 含 .claude/hooks/x.mjs" "line1=[$(printf '%s' "$PR_A" | head -1)]"

SB=$(newsb pr-exp); mkprofile "$SB"
mkruntime "$SB" fast 1000 2000
hookrun session-rules-banner "$SB" '{"source":"startup"}'
chk "$([ "$RC" -eq 0 ] && ! hasq 'tier: fast' "$OUT" && echo 0 || echo 1)" \
    "PR-3 fast 会话已过期 → 不再播报 fast（过期即失效，横幅不能还在喊「治理闸只提醒不拦」）" \
    "rc=0 且 stdout 不含 tier: fast" "rc=$RC line1=[$(printf '%s' "$OUT" | head -1)]"

SB=$(newsb pr-fc); mkprofile "$SB"
mkruntime "$SB" fast "$NOW" "$((NOW + 3600))"
hookrun session-rules-banner "$SB" '{"source":"compact"}'
chk "$([ "$RC" -eq 0 ] && hasq 'fast' "$OUT" && echo 0 || echo 1)" \
    "PR-4 fast + source=compact → 照喊（反向用法：压缩边界之后最该被记住的就是这条，它赢 SB-2）" \
    "rc=0 且 stdout 含 fast" "rc=$RC line1=[$(printf '%s' "$OUT" | head -1)]"

SB=$(newsb pr-sc); mkprofile "$SB"
hookrun session-rules-banner "$SB" '{"source":"compact"}'
chk "$([ "$RC" -eq 0 ] && [ -z "$OUT" ] && echo 0 || echo 1)" \
    "PR-5 对照：standard + source=compact → 静默（证明 PR-4 赢的是 fast，不是「compact 也照喊」）" \
    "rc=0 且 stdout 为空" "rc=$RC stdout=[$(show "$OUT")]"

# ---------------------------------------------------------------------------
echo ""
echo "--- PD 子目录 cwd 下的自动升档（hook 是被事件触发的，cwd 从来不保证是仓根）---"

# 派单口径 PR-1..PR-4；PR 已被上面的 banner 组占用，这里顺号改标 PD-1..PD-4，逐条对应、不改语义。
# 要害：raise 判定要读工作树，读盘的根若跟着进程 cwd 走（而不是跟 projectDir 走），
# 那么「在子目录里发生的 hook 事件」就查不到家底改动 —— 升档静默失效，而人在仓根一跑
# tier status 还是 strict，两边对不上也看不出来。仓根那条对照就是为了把这个差别钉死。

# tierjs <沙箱> <cwd> —— 在指定 cwd 直接问 hook 侧解析器 effectiveTier（不经引擎、不经 hook 本体）。
#   项目根用 CLAUDE_PROJECT_DIR 与入参双给：两条都给全了还错，就只剩 cwd 这一个变量。
tierjs() {
    local d="$1" c="$2"
    RC=0
    ( cd "$c" && CLAUDE_PROJECT_DIR="$d" node -e '
const { pathToFileURL } = require("node:url");
import(pathToFileURL(process.argv[1]).href)
  .then((m) => Promise.resolve(m.effectiveTier({ projectDir: process.argv[2] })))
  .then((r) => { console.log(JSON.stringify(r)); })
  .catch((e) => { console.error(String((e && e.stack) || e)); process.exit(1); });
' "$d/.claude/hooks/lib/tier.mjs" "$d" ) >"$TMP/.o" 2>"$TMP/.e" || RC=$?
    OUT=$(cat "$TMP/.o" 2>/dev/null || true)
    ERRT=$(cat "$TMP/.e" 2>/dev/null || true)
}

SB=$(newsb pd-sub); mkprofile "$SB"
printf '// touched\n' > "$SB/.claude/hooks/x.mjs"      # 故意不提交：命中 raise.paths 的未提交改动
SUB="$SB/some/sub/dir"; mkdir -p "$SUB"

tierjs "$SB" "$SUB"
PD_RC="$RC"; PD_A="$OUT"
chk "$([ "$(jq_ "$PD_A" 'String(d.tier)')" = "strict" ] && echo 0 || echo 1)" \
    "PD-1 家底改动未提交 + 在子目录里问 → effectiveTier 的 tier=strict（升档不能因为 cwd 换了就没了）" \
    "tier=strict" "rc=$PD_RC out=[$(show "$PD_A")] err1=[$(printf '%s' "$ERRT" | head -1)]"
chk "$([ "$(jq_ "$PD_A" 'String(d.source)')" = "raise" ] && echo 0 || echo 1)" \
    "PD-2 同上 → source=raise（抬上去的理由要说得出，不然跟用户手设 strict 分不开）" \
    "source=raise" "out=[$(show "$PD_A")]"

tierjs "$SB" "$SB"
PD_R_RC="$RC"; PD_R="$OUT"
chk "$([ "$(jq_ "$PD_R" 'String(d.tier)')" = "strict" ] && echo 0 || echo 1)" \
    "PD-3 对照：同一沙箱、同一命令，cwd 换回仓根 → tier=strict（证明 PD-1 判的是 cwd，不是这条路恒红）" \
    "tier=strict" "rc=$PD_R_RC out=[$(show "$PD_R")] err1=[$(printf '%s' "$ERRT" | head -1)]"

RC=0
( cd "$SUB" && CLAUDE_PROJECT_DIR="$SB" node "$SB/.claude/harness/harness.mjs" tier status ) \
    >"$TMP/.o" 2>"$TMP/.e" || RC=$?
PD_S_RC="$RC"; PD_S=$(cat "$TMP/.o" 2>/dev/null || true); PD_S_E=$(cat "$TMP/.e" 2>/dev/null || true)
chk "$([ "$(jq_ "$PD_S" 'String(d.tier)')" = "strict" ] && echo 0 || echo 1)" \
    "PD-4 同一处境走引擎：cwd 子目录 + CLAUDE_PROJECT_DIR 仓根 → tier status 报 strict（人查到的那一格也得对）" \
    "stdout JSON tier=strict" "rc=$PD_S_RC out=[$(show "$PD_S")] err1=[$(printf '%s' "$PD_S_E" | head -1)]"

# ---------------------------------------------------------------------------
echo ""
echo "--- PX 续 tier.json 缺 set_epoch（8h 夹的起算点没了 = 一份手写文件换永久 fast）---"

# 派单口径 PX-4/5/6；上面 PX 组已用到 PX-4，这里顺号为 PX-5..PX-7，逐条对应、不改语义。
# 8h 夹算的是 now - set_epoch，缺这个字段就没有起算点。缺字段的覆盖只有两种收场：认它
# （那 8h 上限等于不存在，expires_epoch 想写多远写多远，PX-1..3 夹了个寂寞）或不认它回默认档。
# 契约取后者 —— 与坏 JSON、档名非法同一口径：读不出来的状态一律视为无覆盖 + 留痕（tier.mjs:143）。

# gitignore_state <沙箱> —— 把运行态目录纳入忽略并提交。
#   quarantine.jsonl 落在 .claude/harness/state/，而那是 raise.paths 命中的目录：留痕这个动作
#   本身会把沙箱抬成 strict，「缺 set_epoch 认不认」的红因就串到「升档」上去了。
gitignore_state() {
    printf '.claude/harness/state/\n.claude/.runtime/\n' > "$1/.gitignore"
    commit_sb "$1" ignore-runtime
}

SB=$(newsb px-noset); mkprofile "$SB"; gitignore_state "$SB"
printf '{"tier":"fast","reason":"t","by":"t","expires_epoch":4102444800}\n' \
    > "$SB/.claude/.runtime/tier.json"                 # 2100 年才过期，且没有 set_epoch
tierjs "$SB" "$SB"
PXN_RC="$RC"; PXN="$OUT"; PXN_T=$(jq_ "$PXN" 'String(d.tier)')
chk "$([ "$PXN_T" != "fast" ] && [ "$PXN_T" != "<not-json>" ] && [ -n "$PXN_T" ] && echo 0 || echo 1)" \
    "PX-5 tier.json 缺 set_epoch + expires 写到 2100 年 → tier 不是 fast（认了它，8h 上限就只是写侧的礼貌）" \
    "tier≠fast 且 stdout 是 JSON" "tier=$PXN_T rc=$PXN_RC out=[$(show "$PXN")] err1=[$(printf '%s' "$ERRT" | head -1)]"
PXN_Q=$(cat "$SB/.claude/harness/state/quarantine.jsonl" 2>/dev/null || true)
chk "$(printf '%s' "$PXN_Q" | grep -q '"kind":"tier"' && echo 0 || echo 1)" \
    "PX-6 同上 → quarantine.jsonl 多一条 kind=tier（回默认档要留痕，不然用户只看到档位莫名其妙变了）" \
    "账本含 \"kind\":\"tier\"" "账本=[$(show "$PXN_Q")]"

SB=$(newsb px-setok); mkprofile "$SB"; gitignore_state "$SB"
mkruntime "$SB" fast "$NOW" "$((NOW + 3600))"          # 同形但字段齐全的 1 小时窗口
tierjs "$SB" "$SB"
PXO_RC="$RC"; PXO="$OUT"
chk "$([ "$(jq_ "$PXO" 'String(d.tier)')" = "fast" ] && echo 0 || echo 1)" \
    "PX-7 对照：set_epoch=now + expires=now+1h 的同形文件 → tier=fast（证明 PX-5 挡的是缺字段，不是这条路读不出 fast）" \
    "tier=fast" "rc=$PXO_RC out=[$(show "$PXO")] err1=[$(printf '%s' "$ERRT" | head -1)]"

echo ""
echo "==== test-tier-hardening：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ]
