#!/usr/bin/env bash
# test-hook-failopen.sh — stop-gate / pre-commit-check 在 harness 引擎异常退出时静默放行的红锁回归测试。
# 与 cases/test-harness.sh 的分工：那份锁「引擎端到端链路该有的行为」（该全绿），这份锁「引擎崩掉时闸不许假绿」。
#
# red-locks-the-bug：本文件的断言写的是**修复后应该成立的行为**，不是「缺陷能复现」。
#   所以在缺陷修好之前，本脚本整体必然 FAIL —— 这是它的成功状态，不是它写坏了。
#   修完转绿后它就变成永久回归防线：谁把契约外退出码的处理去掉，哪条立刻红。
#
# 缺陷本体（主 Agent 已读源码裁定）：
#   stop-gate.sh 只在 receipt verify 返回 rc=4 时拦停，其余退出码一律 rm .needs-review + exit 0；
#   pre-commit-check.sh 只在 verify 返回 rc=2 时阻断，其余退出码一律放行。
#   而两条子命令的退出码契约分别是 {0,3,4} 和 {0,2,3}（.claude/rules/harness-large-repo.md 退出码契约表）——
#   引擎崩掉时 node 给的是契约外的 rc=1，被两个闸当成放行处理，且不留任何可见痕迹。
#   目标项目里只要 lib/ 没装全、node 版本出岔、引擎哪天真崩了，闸就无声失效且没人会知道。
#
# 目标行为：
#   契约外退出码 -> 不许静默放行（stop-gate 给 decision:block，pre-commit 给 exit 2），
#   且诊断里必须带上**实际退出码**，让人能区分「引擎崩了」和「回执确实不匹配」。
#   同时不许 fail-closed 到砖机：stop-gate 的 .stop-gate-strikes 三振熔断在这条新分支下必须照样兜底。
#
# 两种故障形态都覆盖：
#   broken —— 只有 harness.mjs、没有 lib/（拆库后的真实故障形态，node 抛 ERR_MODULE_NOT_FOUND）
#   fake:N —— 直接 process.exit(N) 的假引擎（纯退出码语义，且能验诊断是否真把码带出来）
#
# 覆盖面：只覆盖 .sh 侧。.ps1 侧同构缺陷未覆盖（本机无 pwsh），下方有显式 SKIP 说明。
# 纪律：可变样例一律写进 mktemp 出来的临时 git 仓，trap 清理；对 cc-base 只读。
#   每条断言打印 EXPECT / GOT，判定不依赖措辞。
# 依赖：node + git。jq 有则多验两条「诊断带退出码」（无 jq 时 hook 走硬编码兜底文案，显式 SKIP 不假绿）。
set -eu

REPO="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"

STOP_GATE="$REPO/.claude/hooks/stop-gate.sh"
PRECOMMIT="$REPO/.claude/hooks/pre-commit-check.sh"
HARNESS="$REPO/.claude/harness/harness.mjs"

echo "===== test-hook-failopen ====="

if ! command -v node >/dev/null 2>&1; then
    echo "SKIPPED: 无 node（command -v node 未找到）——引擎异常退出场景造不出来，未执行 != 通过。" >&2
    exit 1
fi
if ! command -v git >/dev/null 2>&1; then
    echo "SKIPPED: 无 git（command -v git 未找到）——沙箱仓造不出来，未执行 != 通过。" >&2
    exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

# chk <判定 0=过/1=不过> <标题> <EXPECT 描述> <GOT 描述>
# EXPECT / GOT 无论过不过都打印：判定要能被第三方复核，不能靠本文件的措辞。
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

# newsandbox <名> —— 造一个启用了 harness（有 catalog）的临时 git 项目，回显路径。
# 刻意只放 .md 源文件：避开 pre-commit-check 的 TS / Python 分栈检查，隔离出 harness 那一段。
newsandbox() {
    local d="$TMP/$1"
    mkdir -p "$d/.claude/harness" "$d/core"
    printf '{"version":1,"modules":[{"id":"core","paths":["core/**"],"riskTier":"medium"}]}' \
        > "$d/.claude/harness/module-catalog.json"
    (
        cd "$d" && git init -q . \
            && git config core.autocrlf false \
            && git config user.email t@example.com && git config user.name t \
            && echo x > core/a.md && git add -A && git commit -qm init
    ) >/dev/null 2>&1
    echo changed >> "$d/core/a.md"
    printf '%s' "$d"
}

# install_engine <沙箱目录> <broken|fake:N> —— 往沙箱装一台会以指定方式失败的引擎。
install_engine() {
    local d="$1" mode="$2"
    case "$mode" in
        broken)
            # 真实故障形态：拆库后 harness.mjs import 同级 lib/，只搬单文件必 ERR_MODULE_NOT_FOUND。
            cp "$HARNESS" "$d/.claude/harness/harness.mjs"
            rm -rf "$d/.claude/harness/lib"
            ;;
        fake:*)
            printf 'process.exit(%s);\n' "${mode#fake:}" > "$d/.claude/harness/harness.mjs"
            ;;
    esac
}

# engine_rc <沙箱目录> <子命令...> —— 直接跑沙箱里的引擎，回显它的退出码（用于前置条件自证）。
engine_rc() {
    local d="$1"; shift
    local rc=0
    ( cd "$d" && CLAUDE_PROJECT_DIR="$d" node "$d/.claude/harness/harness.mjs" "$@" ) >/dev/null 2>&1 || rc=$?
    printf '%s' "$rc"
}

# run_stop_gate <沙箱目录> —— 跑 stop-gate，回填 RC / OUT。
RC=0
OUT=""
run_stop_gate() {
    local d="$1"
    RC=0
    OUT=$( cd "$d" && CLAUDE_PROJECT_DIR="$d" bash "$STOP_GATE" 2>&1 ) || RC=$?
}

# run_precommit <沙箱目录> —— 喂 git commit 的 PreToolUse JSON 跑 pre-commit-check，回填 RC / OUT。
run_precommit() {
    local d="$1"
    RC=0
    OUT=$( echo '{"tool_input":{"command":"git commit -m t"}}' \
        | ( cd "$d" && CLAUDE_PROJECT_DIR="$d" bash "$PRECOMMIT" ) 2>&1 ) || RC=$?
}

# blocked <输出> —— stop-gate 是否拦停（Stop hook 靠 stdout JSON 的 decision 表态，不靠退出码）。
blocked() { printf '%s' "$1" | grep -q '"decision":"block"'; }

# mentions <数字> <文本> —— 文本里是否出现该数字（独立数，不被别的数字粘连）。
mentions() { printf '%s' "$2" | grep -qE "(^|[^0-9])$1([^0-9]|\$)"; }

HAS_JQ=0
command -v jq >/dev/null 2>&1 && HAS_JQ=1

# ---------------------------------------------------------------------------
echo ""
echo "--- 脚手架自证（这几条必须绿；红了说明是夹具坏了，不是 hook 的问题）---"

chk "$([ -f "$STOP_GATE" ] && [ -r "$STOP_GATE" ] && echo 0 || echo 1)" \
    "被测 hook stop-gate.sh 存在可读" \
    "$STOP_GATE 可读" \
    "$([ -f "$STOP_GATE" ] && echo 存在 || echo 不存在)"

chk "$([ -f "$PRECOMMIT" ] && [ -r "$PRECOMMIT" ] && echo 0 || echo 1)" \
    "被测 hook pre-commit-check.sh 存在可读" \
    "$PRECOMMIT 可读" \
    "$([ -f "$PRECOMMIT" ] && echo 存在 || echo 不存在)"

SB_SELF=$(newsandbox selfcheck)
GITOK=$( (cd "$SB_SELF" && git rev-parse --is-inside-work-tree 2>/dev/null) || echo NO )
chk "$([ "$GITOK" = "true" ] && echo 0 || echo 1)" \
    "沙箱是可用的 git 工作树" \
    "git rev-parse --is-inside-work-tree = true" \
    "= $GITOK"

chk "$([ -f "$SB_SELF/.claude/harness/module-catalog.json" ] && echo 0 || echo 1)" \
    "沙箱带 catalog（harness_enabled 前置条件成立，闸才会走 harness 分支）" \
    "module-catalog.json 存在" \
    "$([ -f "$SB_SELF/.claude/harness/module-catalog.json" ] && echo 存在 || echo 缺失)"

install_engine "$SB_SELF" broken
BROKEN_RC=$(engine_rc "$SB_SELF" receipt verify)
chk "$([ "$BROKEN_RC" != 0 ] && [ "$BROKEN_RC" != 3 ] && [ "$BROKEN_RC" != 4 ] && echo 0 || echo 1)" \
    "broken 引擎（缺 lib/）确实给出契约外退出码（receipt verify 契约是 0/3/4）" \
    "rc 不在 {0,3,4} 内" \
    "rc=$BROKEN_RC"

install_engine "$SB_SELF" fake:7
FAKE_RC=$(engine_rc "$SB_SELF" receipt verify)
chk "$([ "$FAKE_RC" = 7 ] && echo 0 || echo 1)" \
    "fake:7 假引擎确实按 7 退出（退出码语义可控）" \
    "rc=7" \
    "rc=$FAKE_RC"

# ---------------------------------------------------------------------------
echo ""
echo "--- stop-gate：receipt verify 契约（0=PASS / 3=降级 / 4=STALE）之外的退出码 ---"

# S1/S2 真实故障形态：只搬了 harness.mjs、没搬 lib/
SB=$(newsandbox sg-broken)
install_engine "$SB" broken
echo clean > "$SB/.claude/.needs-review"
run_stop_gate "$SB"
SG_BROKEN_OUT="$OUT"; SG_BROKEN_RC="$RC"
chk "$(blocked "$SG_BROKEN_OUT" && echo 0 || echo 1)" \
    "S1 引擎缺 lib/ 崩掉（rc=$BROKEN_RC，契约外）-> stop-gate 拦停，不许静默放行" \
    'stdout 含 "decision":"block"' \
    "rc=$SG_BROKEN_RC stdout=[${SG_BROKEN_OUT:-空}]"

chk "$([ -n "$SG_BROKEN_OUT" ] && echo 0 || echo 1)" \
    "S2 引擎崩掉时必须留下可读诊断，不许零输出下班" \
    "stdout/stderr 非空" \
    "长度=${#SG_BROKEN_OUT} 内容=[${SG_BROKEN_OUT:-空}]"

chk "$([ -f "$SB/.claude/.needs-review" ] && echo 0 || echo 1)" \
    "S3 拦停时保留 .needs-review（照 rc=4 先例；删了则下一轮早退放行，拦停变一次性）" \
    ".needs-review 仍在" \
    "$([ -f "$SB/.claude/.needs-review" ] && echo 仍在 || echo 已被删)"

chk "$([ "$SG_BROKEN_RC" -eq 0 ] && echo 0 || echo 1)" \
    "S4 拦停仍走 Stop hook 协议（stdout JSON 表态，退出码保持 0）〔现有行为·防回归位〕" \
    "退出码 0" \
    "rc=$SG_BROKEN_RC"

# S5-S8 纯退出码语义：假引擎按指定码退出，验诊断是否真把码带出来
SB7=$(newsandbox sg-fake7)
install_engine "$SB7" fake:7
echo clean > "$SB7/.claude/.needs-review"
run_stop_gate "$SB7"
SG7_OUT="$OUT"
chk "$(blocked "$SG7_OUT" && echo 0 || echo 1)" \
    "S5 假引擎 exit(7)（契约外）-> stop-gate 拦停" \
    'stdout 含 "decision":"block"' \
    "stdout=[${SG7_OUT:-空}]"

SB9=$(newsandbox sg-fake9)
install_engine "$SB9" fake:9
echo clean > "$SB9/.claude/.needs-review"
run_stop_gate "$SB9"
SG9_OUT="$OUT"
chk "$(blocked "$SG9_OUT" && echo 0 || echo 1)" \
    "S6 假引擎 exit(9)（契约外）-> stop-gate 拦停" \
    'stdout 含 "decision":"block"' \
    "stdout=[${SG9_OUT:-空}]"

if [ "$HAS_JQ" -eq 1 ]; then
    chk "$(mentions 7 "$SG7_OUT" && mentions 9 "$SG9_OUT" && echo 0 || echo 1)" \
        "S7 诊断点出实际退出码（exit 7 的诊断出现 7、exit 9 的出现 9）" \
        "两份诊断各自含自己的退出码" \
        "含7=$(mentions 7 "$SG7_OUT" && echo Y || echo N) 含9=$(mentions 9 "$SG9_OUT" && echo Y || echo N)"

    chk "$([ "$SG7_OUT" != "$SG9_OUT" ] && echo 0 || echo 1)" \
        "S8 诊断随实际退出码变化，不是一句固定文案（能区分引擎崩了 vs 回执不匹配）" \
        "exit7 的输出 != exit9 的输出" \
        "相同?=$([ "$SG7_OUT" = "$SG9_OUT" ] && echo YES || echo NO)"
else
    skip "S7/S8 诊断带退出码 —— 无 jq，stop-gate 走硬编码兜底文案，此机器上判不了（未执行 != 通过）"
fi

# S9 rc=4 与契约外的诊断必须能区分开：同一句文案糊过去不算修好
SB4=$(newsandbox sg-fake4)
install_engine "$SB4" fake:4
echo clean > "$SB4/.claude/.needs-review"
run_stop_gate "$SB4"
SG4_OUT="$OUT"
chk "$([ "$SG4_OUT" != "$SG7_OUT" ] && echo 0 || echo 1)" \
    "S9 契约外退出码的诊断 != rc=4(STALE) 的诊断（两种失效原因不许混为一谈）〔缺陷未修时偶然绿：现在 exit7 根本没输出·防回归位〕" \
    "rc4 的文案与 exit7 的不同" \
    "文案相同=$([ "$SG4_OUT" = "$SG7_OUT" ] && echo YES || echo NO) rc4=[${SG4_OUT:-空}] exit7=[${SG7_OUT:-空}]"

# ---------------------------------------------------------------------------
echo ""
echo "--- stop-gate：不许 fail-closed 到砖机（三振熔断在契约外分支上照样兜底）---"

SBB=$(newsandbox sg-brick)
install_engine "$SBB" broken
echo clean > "$SBB/.claude/.needs-review"
BLOCKS=0
RUNS=5
TRACE=""
i=1
while [ "$i" -le "$RUNS" ]; do
    run_stop_gate "$SBB"
    if blocked "$OUT"; then BLOCKS=$((BLOCKS + 1)); TRACE="${TRACE}B"; else TRACE="${TRACE}."; fi
    i=$((i + 1))
done

chk "$([ "$BLOCKS" -ge 1 ] && echo 0 || echo 1)" \
    "S10 引擎持续崩溃时至少拦停过（$RUNS 次里 block 次数 >= 1）" \
    "block 次数 >= 1" \
    "block=$BLOCKS/$RUNS 轨迹=$TRACE（B=拦停 .=放行）"

case "${TRACE:0:4}" in *.*) BRICK=0 ;; *) BRICK=1 ;; esac
chk "$BRICK" \
    "S11 引擎持续崩溃时不许拦成砖机（三振熔断兜底：前 4 次里至少放行 1 次）〔缺陷未修时偶然绿·防回归位〕" \
    "前 4 次轨迹里含 '.'（放行）" \
    "block=$BLOCKS/$RUNS 轨迹=$TRACE（B=拦停 .=放行）"

# ---------------------------------------------------------------------------
echo ""
echo "--- stop-gate：契约内退出码的既有行为不许被改坏〔防回归位，现在就该绿〕---"

for code in 0 3; do
    SBC=$(newsandbox "sg-ok-$code")
    install_engine "$SBC" "fake:$code"
    echo clean > "$SBC/.claude/.needs-review"
    run_stop_gate "$SBC"
    LEFT=$([ -f "$SBC/.claude/.needs-review" ] && echo YES || echo NO)
    if ! blocked "$OUT" && [ "$LEFT" = NO ]; then r=0; else r=1; fi
    chk "$r" "S12/$code receipt verify rc=$code（契约内）-> 放行并清 .needs-review" \
        "不含 decision:block 且 .needs-review 被清" \
        "拦停=$(blocked "$OUT" && echo Y || echo N) .needs-review残留=$LEFT out=[${OUT:-空}]"
done

chk "$(blocked "$SG4_OUT" && echo 0 || echo 1)" \
    "S13 receipt verify rc=4（契约内 STALE）-> 照旧拦停" \
    'stdout 含 "decision":"block"' \
    "stdout=[${SG4_OUT:-空}]"

# ---------------------------------------------------------------------------
echo ""
echo "--- pre-commit-check：verify 契约（0=PASS / 2=门未过 / 3=降级）之外的退出码 ---"

if ! command -v python3 >/dev/null 2>&1; then
    skip "P 组全部 —— pre-commit-check.sh 靠 python3 解析 PreToolUse JSON，无 python3 时它对任何输入都直接放行，此机器上判不了（未执行 != 通过）"
else
    SP=$(newsandbox pc-broken)
    install_engine "$SP" broken
    ( cd "$SP" && git add -A ) >/dev/null 2>&1
    PC_BROKEN_VRC=$(engine_rc "$SP" verify)
    run_precommit "$SP"
    PC_BROKEN_RC="$RC"; PC_BROKEN_OUT="$OUT"
    chk "$([ "$PC_BROKEN_RC" -eq 2 ] && echo 0 || echo 1)" \
        "P1 引擎缺 lib/ 崩掉（verify rc=$PC_BROKEN_VRC，契约外）-> pre-commit exit 2 阻断 commit" \
        "退出码 2（PreToolUse 里只有 2 能拦住命令）" \
        "rc=$PC_BROKEN_RC out=[${PC_BROKEN_OUT:-空}]"

    chk "$([ -n "$PC_BROKEN_OUT" ] && echo 0 || echo 1)" \
        "P2 引擎崩掉时必须留下可读诊断，不许零输出放行" \
        "stdout/stderr 非空" \
        "长度=${#PC_BROKEN_OUT} 内容=[${PC_BROKEN_OUT:-空}]"

    SP7=$(newsandbox pc-fake7)
    install_engine "$SP7" fake:7
    ( cd "$SP7" && git add -A ) >/dev/null 2>&1
    run_precommit "$SP7"
    PC7_RC="$RC"; PC7_OUT="$OUT"
    chk "$([ "$PC7_RC" -eq 2 ] && echo 0 || echo 1)" \
        "P3 假引擎 exit(7)（契约外）-> pre-commit exit 2" \
        "退出码 2" \
        "rc=$PC7_RC out=[${PC7_OUT:-空}]"

    SP9=$(newsandbox pc-fake9)
    install_engine "$SP9" fake:9
    ( cd "$SP9" && git add -A ) >/dev/null 2>&1
    run_precommit "$SP9"
    PC9_RC="$RC"; PC9_OUT="$OUT"
    chk "$([ "$PC9_RC" -eq 2 ] && echo 0 || echo 1)" \
        "P4 假引擎 exit(9)（契约外）-> pre-commit exit 2" \
        "退出码 2" \
        "rc=$PC9_RC out=[${PC9_OUT:-空}]"

    chk "$(mentions 7 "$PC7_OUT" && mentions 9 "$PC9_OUT" && echo 0 || echo 1)" \
        "P5 诊断点出实际退出码（exit 7 的诊断出现 7、exit 9 的出现 9）" \
        "两份诊断各自含自己的退出码" \
        "含7=$(mentions 7 "$PC7_OUT" && echo Y || echo N) 含9=$(mentions 9 "$PC9_OUT" && echo Y || echo N)"

    echo ""
    echo "--- pre-commit-check：契约内退出码的既有行为不许被改坏〔防回归位，现在就该绿〕---"

    for code in 0 3; do
        SPC=$(newsandbox "pc-ok-$code")
        install_engine "$SPC" "fake:$code"
        ( cd "$SPC" && git add -A ) >/dev/null 2>&1
        run_precommit "$SPC"
        chk "$([ "$RC" -eq 0 ] && echo 0 || echo 1)" \
            "P6/$code verify rc=$code（契约内）-> 放行 exit 0" \
            "退出码 0" \
            "rc=$RC out=[${OUT:-空}]"
    done

    SP2=$(newsandbox pc-fake2)
    install_engine "$SP2" fake:2
    ( cd "$SP2" && git add -A ) >/dev/null 2>&1
    run_precommit "$SP2"
    chk "$([ "$RC" -eq 2 ] && echo 0 || echo 1)" \
        "P7 verify rc=2（契约内，门未过）-> 照旧 exit 2 阻断" \
        "退出码 2" \
        "rc=$RC out=[${OUT:-空}]"
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- .ps1 侧 ---"
if command -v pwsh >/dev/null 2>&1; then
    skip "stop-gate.ps1 / pre-commit-check.ps1 的同构缺陷本文件未覆盖（本机有 pwsh，但断言尚未编写）——未覆盖面，不是通过"
else
    skip "stop-gate.ps1 / pre-commit-check.ps1 的同构缺陷未覆盖（本机无 pwsh）——未覆盖面，不是通过"
fi

# ---------------------------------------------------------------------------
echo ""
echo "==== test-hook-failopen：PASS=$PASS FAIL=$FAIL ===="
if [ "$FAIL" -gt 0 ]; then
    echo "test-hook-failopen: failed —— 修复前这是预期状态（红锁）；修复后必须转全绿" >&2
    exit 1
fi
echo "test-hook-failopen: passed（引擎异常退出时两个闸都不再静默放行）"
