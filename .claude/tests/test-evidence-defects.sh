#!/usr/bin/env bash
# test-evidence-defects.sh — P1 证据层（lib/evidence.mjs 的 gate/ledger/gate-audit/retention/risk
#   + lib/task.mjs 的 task/budget）七条缺陷的红锁回归测试。
#
# 与 cases/test-harness.sh 的分工：那份锁「引擎端到端链路该有的行为」（该全绿），
#   这份锁「证据层的核心主张——证据留得住、不能被静默改写——现在还不成立」。
#
# red-locks-the-bug：本文件的断言写的是**修复后应该成立的行为**，不是「缺陷能复现」。
#   所以在缺陷修好之前，本脚本整体必然 FAIL —— 这是它的成功状态，不是它写坏了。
#   修完转绿后它就变成永久回归防线：谁把哪条防护摘掉，哪条立刻红。
#
# 七条缺陷（每条都在本机实测复现过，观察写在各段的注释里）：
#   E1 readLedger 对两种失败方向相反：行解析不了 -> {corrupt:true}（fail-closed，对），
#      文件读不了 -> []（fail-open，错）。chmod 000 后 ledger 报 ok:true rc 0，
#      retention --apply 认为保护集为空、把证据真删了。
#   E2 并发追加无锁（read-then-append），12 个并发 gate 打断链；而新行只往后追加，
#      旧断裂永留，task complete 从此永久阻断——文案却写着「re-run the gates」。
#   E3 上次写被 kill 留下的无换行尾行，会被下一次 append 直接拼上去，两条一起 unparseable：
#      一条完好的记录被相邻的半行吃掉。
#   E4 evidenceSha256 / planHash 写而不读：全仓只有写入点。跑完 gate 把 evidence/*.log
#      内容换掉或删掉，ledger / risk / gate-audit / retention 四个命令全 rc 0。
#   E5 保护集依赖可解析的记录：一条损坏行就让它引用的证据脱保，retention --apply 真删。
#   E6 闸的输入范围可由调用方伪造：gate --changed <运行态路径> 得到 PASS + modules:[]，
#      diffHash 却仍是真工作树指纹；task complete 只看 gate==='PASS' && diffHash 相等，
#      于是一棵真跑会 FAIL 的树被判完成。
#   E7 waiver / Fast Mode 把降级洗成绿，聚合统计分不出「被压制」与「从没接线」：
#      被 waiver 压制的连败进了 neverExecuted/neverIntervened 并配文案 genuinely stable；
#      risk 的 FAIL_STREAK 也不计；Fast Mode 全 SKIP 时 task complete 照过。
#   N1 非 git 树里 gitFingerprint() 恒为 sha256("NON_GIT")，绑 diffHash 的凭据全退化成常量；
#      而 task complete 是唯一不做 non-git 降级的消费者，rc 2 且提示 run: harness.mjs gate——
#      那条命令在同一棵树里必 rc 3。
#
# 与 reviewer 描述不符、以实测为准的一处：E6 的复现路径不是「映射不到任何模块的路径」。
#   unmapped 路径会触发 analyzeImpact 的保守扩张（degraded + 全模块 fanout），反而 fail-safe。
#   真正能拿到 PASS + modules:[] 的是**运行态排除路径**（.claude/harness/state/** 之类）、
#   catalog.ignored 路径、以及 --changed ""。本文件用运行态排除路径这一条。
#
# 断言写否定形式 / 析取形式：一条缺陷若有多种合规修法（降级 rc 3 / 报错 rc 1 / 加字段标注），
#   不钉死某一种，只钉「不许再是现在这样」。
#
# 覆盖面：只覆盖 .sh 可驱动的引擎行为。.ps1 侧无同构代码（证据层是纯 node，无 pwsh 副本）。
# 纪律：可变样例一律写进 mktemp 出来的临时 git 仓，trap 清理；对 cc-base 只读。
#   每条断言打印 EXPECT / GOT，判定不依赖措辞。
# 依赖：node + git + sleep。python3 / jq 都不需要。
#
# 用法：bash test-evidence-defects.sh [REPO]
#   REPO 默认本仓。传别的路径可以对着打了补丁的副本跑同一份断言——绿了就证明每条红是功能缺失。
set -eu

REPO="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"

HARNESS="$REPO/.claude/harness/harness.mjs"
LIBDIR="$(dirname "$HARNESS")/lib"
HOOKSLIB="$REPO/.claude/hooks/lib"
PROFILE="$REPO/.claude/harness/profile.json"

echo "===== test-evidence-defects ====="
echo "REPO=$REPO"

if ! command -v node >/dev/null 2>&1; then
    echo "SKIPPED: 无 node（command -v node 未找到）——证据层是纯 node，一条都跑不了，未执行 != 通过。" >&2
    exit 1
fi
if ! command -v git >/dev/null 2>&1; then
    echo "SKIPPED: 无 git（command -v git 未找到）——沙箱仓造不出来，未执行 != 通过。" >&2
    exit 1
fi
if ! command -v sleep >/dev/null 2>&1; then
    echo "SKIPPED: 无 sleep——E2 的并发对齐造不出来，未执行 != 通过。" >&2
    exit 1
fi

TMP=$(mktemp -d)
trap 'chmod -R u+rwX "$TMP" 2>/dev/null || true; rm -rf "$TMP"' EXIT

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

# ---------------------------------------------------------------------------
# 沙箱与引擎驱动
# ---------------------------------------------------------------------------

# newsandbox <名> <check命令> [check类] [--nogit]
#   造一个启用了 harness 的临时项目：一个 core 模块、一条 medium 档 check。
#   引擎按目录整拷（harness.mjs import 同级 lib/，只拷单文件会 ERR_MODULE_NOT_FOUND）。
#   hooks/lib/ 与 profile.json 一起进来：档位只有一个解析器且在 hook 侧，引擎 lib/tier.mjs
#   import 的是 ../../hooks/lib/tier.mjs——缺它引擎以契约外的 rc 1 退出，下面每条「期望非零」
#   的断言都会因为同一个起不来而变绿，整份文件读起来全过、其实一条都没跑。
newsandbox() {
    local name="$1" cmd="$2" cls="${3:-test}" mode="${4:-git}"
    local d="$TMP/$name"
    mkdir -p "$d/.claude/harness" "$d/.claude/hooks" "$d/core" "$d/docs"
    cp "$HARNESS" "$d/.claude/harness/harness.mjs"
    cp -R "$LIBDIR" "$d/.claude/harness/lib"
    cp -R "$HOOKSLIB" "$d/.claude/hooks/lib"
    cp "$PROFILE" "$d/.claude/harness/profile.json"
    cat > "$d/.claude/harness/module-catalog.json" <<EOF
{"version":1,
 "modules":[{"id":"core","paths":["core/**"],"riskTier":"medium"}],
 "global":[],
 "ignored":["docs/**"],
 "riskChecks":{"medium":["probe"]},
 "checks":{"probe":{"command":"$cmd","class":"$cls","allowFastSkip":true}}}
EOF
    echo baseline > "$d/core/a.txt"
    echo doc > "$d/docs/x.md"
    if [ "$mode" = git ]; then
        (
            cd "$d" && git init -q . \
                && git config core.autocrlf false \
                && git config user.email t@example.com && git config user.name t \
                && git add -A && git commit -qm init
        ) >/dev/null 2>&1
        echo worktree-change >> "$d/core/a.txt"
    fi
    printf '%s' "$d"
}

# run <沙箱> <子命令...> —— 跑引擎，回填 RC / OUT（stdout）/ ERR（stderr）。
RC=0
OUT=""
ERR=""
run() {
    local d="$1"; shift
    RC=0
    OUT=$( cd "$d" && CLAUDE_PROJECT_DIR="$d" node "$d/.claude/harness/harness.mjs" "$@" 2>"$TMP/.stderr" ) || RC=$?
    ERR=$(cat "$TMP/.stderr" 2>/dev/null || true)
}

# run_stdin <沙箱> <stdin 文本> <子命令...>
run_stdin() {
    local d="$1" payload="$2"; shift 2
    RC=0
    OUT=$( printf '%s' "$payload" | ( cd "$d" && CLAUDE_PROJECT_DIR="$d" node "$d/.claude/harness/harness.mjs" "$@" ) 2>"$TMP/.stderr" ) || RC=$?
    ERR=$(cat "$TMP/.stderr" 2>/dev/null || true)
}

# jval <json> <点路径> —— 取字段（不存在回空串）。数组/对象回 JSON 串。
jval() {
    printf '%s' "$1" | node -e '
        let s = "";
        process.stdin.on("data", d => s += d).on("end", () => {
            try {
                const line = s.trim().split("\n").filter(Boolean).pop();
                let v = JSON.parse(line);
                for (const k of process.argv[1].split(".")) v = (v == null ? undefined : v[k]);
                console.log(v === undefined ? "" : (typeof v === "object" && v !== null ? JSON.stringify(v) : String(v)));
            } catch (_e) { console.log(""); }
        });
    ' "$2"
}

# gate_records <账本文件> —— 可解析且 command==="gate" 的记录条数（直接读文件，不经引擎）。
gate_records() {
    node -e '
        const fs = require("fs");
        let raw = "";
        try { raw = fs.readFileSync(process.argv[1], "utf8"); } catch (_e) { }
        let n = 0;
        for (const l of raw.split("\n")) {
            if (!l) continue;
            try { const o = JSON.parse(l); if (o && o.command === "gate") n++; } catch (_e) { }
        }
        console.log(n);
    ' "$1"
}

# start_task <沙箱> <id> —— 写一份合规六字段信封。
start_task() {
    run_stdin "$1" \
        "{\"id\":\"$2\",\"goal\":\"g\",\"scope\":\"s\",\"outOfScope\":\"o\",\"existingPattern\":\"p\",\"businessContext\":\"b\",\"verification\":\"v\",\"escalation\":\"e\"}" \
        task start
}

FUTURE_ISO=$(node -e 'console.log(new Date(Date.now() + 30 * 86400000).toISOString())')

# ---------------------------------------------------------------------------
echo ""
echo "--- 脚手架自证（这几条必须绿；红了说明是夹具坏了，不是证据层的问题）---"

chk "$([ -f "$HARNESS" ] && [ -d "$LIBDIR" ] && echo 0 || echo 1)" \
    "被测引擎 harness.mjs + lib/ 存在" \
    "$HARNESS 与同级 lib/ 都在" \
    "harness=$([ -f "$HARNESS" ] && echo 有 || echo 无) lib=$([ -d "$LIBDIR" ] && echo 有 || echo 无)"

SB_SELF=$(newsandbox selfcheck true)
GITOK=$( (cd "$SB_SELF" && git rev-parse --is-inside-work-tree 2>/dev/null) || echo NO )
chk "$([ "$GITOK" = "true" ] && echo 0 || echo 1)" \
    "沙箱是可用的 git 工作树" \
    "git rev-parse --is-inside-work-tree = true" \
    "= $GITOK"

run "$SB_SELF" doctor
DOC_CAT=$(jval "$OUT" catalogPresent)
chk "$([ "$RC" -eq 0 ] && [ "$DOC_CAT" = "true" ] && echo 0 || echo 1)" \
    "沙箱里引擎能跑且 catalog 已启用（harness 分支的前置条件成立）" \
    "doctor rc=0 且 catalogPresent=true" \
    "rc=$RC catalogPresent=$DOC_CAT"

run "$SB_SELF" gate
SELF_GATE=$(jval "$OUT" gate)
SELF_EV=$(jval "$OUT" results.0.evidence)
chk "$([ "$RC" -eq 0 ] && [ "$SELF_GATE" = "PASS" ] && echo 0 || echo 1)" \
    "check 通过时 gate=PASS rc=0（基线能力自证）" \
    "rc=0 且 gate=PASS" \
    "rc=$RC gate=$SELF_GATE evidence=$SELF_EV"

run "$SB_SELF" ledger
SELF_LOK=$(jval "$OUT" ok)
SELF_LN=$(jval "$OUT" entries)
chk "$([ "$RC" -eq 0 ] && [ "$SELF_LOK" = "true" ] && [ "$SELF_LN" = "1" ] && echo 0 || echo 1)" \
    "一次 gate 后账本一条记录、链完好（账本读写自证）" \
    "ledger rc=0 ok=true entries=1" \
    "rc=$RC ok=$SELF_LOK entries=$SELF_LN"

SB_FAILSELF=$(newsandbox selfcheck-fail false)
run "$SB_FAILSELF" gate
SELF_FGATE=$(jval "$OUT" gate)
chk "$([ "$RC" -eq 2 ] && [ "$SELF_FGATE" = "FAIL" ] && echo 0 || echo 1)" \
    "check 失败时 gate=FAIL rc=2（对照组自证：这棵树的真 gate 确实不过）" \
    "rc=2 且 gate=FAIL" \
    "rc=$RC gate=$SELF_FGATE"

# chmod 000 对 root 无效——E1 整组依赖「文件真读不了」，先自证本机不是 root。
printf 'x' > "$TMP/.permprobe"
chmod 000 "$TMP/.permprobe"
PERM_BLOCKS=$(node -e 'try{require("fs").readFileSync(process.argv[1],"utf8");console.log("NO");}catch(e){console.log("YES");}' "$TMP/.permprobe")
chmod 644 "$TMP/.permprobe"
chk "$([ "$PERM_BLOCKS" = "YES" ] && echo 0 || echo 1)" \
    "chmod 000 在本机确实挡住读取（E1 组的前置条件；以 root 跑则挡不住）" \
    "node 读 000 权限文件抛错" \
    "挡住=$PERM_BLOCKS"

# ---------------------------------------------------------------------------
echo ""
echo "--- E1 账本读不出来时必须降级，不许 fail-open ---"
# 实测（缺陷未修）：chmod 000 ledger.jsonl 后
#   ledger      -> {"ok":true,"entries":0,...} rc 0
#   risk        -> {"ok":true,"findings":[]}   rc 0
#   retention --apply --max-evidence 0 -> protectedByLedger:0 removed:1，证据文件被真删

if [ "$PERM_BLOCKS" != "YES" ]; then
    skip "E1 全组 —— 本机 chmod 000 挡不住读（多半是 root），造不出「文件读不了」，未执行 != 通过"
else
    SB1=$(newsandbox e1 "echo probe-output")
    run "$SB1" gate
    E1_EV=$(jval "$OUT" results.0.evidence)
    chmod 000 "$SB1/.claude/harness/state/ledger.jsonl"

    run "$SB1" ledger
    E1_LRC="$RC"; E1_LOK=$(jval "$OUT" ok); E1_LN=$(jval "$OUT" entries)
    chk "$([ "$E1_LRC" -ne 0 ] && echo 0 || echo 1)" \
        "E1a 账本文件读不出来 -> ledger 不许 rc 0（读不出 = 无法判定，不是「链完好」）" \
        "rc != 0（降级 3 或报错 1 都行，就是不许 0）" \
        "rc=$E1_LRC ok=$E1_LOK entries=$E1_LN"

    chk "$([ "$E1_LOK" != "true" ] && echo 0 || echo 1)" \
        "E1b 账本文件读不出来 -> 输出不许自称 ok:true" \
        "ok != true" \
        "ok=$E1_LOK entries=$E1_LN（entries=0 是把「读不了」当成了「空账本」）"

    run "$SB1" retention --apply --max-evidence 0
    E1_RRC="$RC"; E1_REMOVED=$(jval "$OUT" removed); E1_PROT=$(jval "$OUT" protectedByLedger)
    E1_EV_LEFT=$([ -f "$SB1/$E1_EV" ] && echo YES || echo NO)
    chk "$([ "$E1_EV_LEFT" = "YES" ] && echo 0 || echo 1)" \
        "E1c 账本读不出来时 retention --apply 一个文件都不许删（保护集未知 != 保护集为空）" \
        "被账本引用的证据文件仍在" \
        "证据文件=$E1_EV 仍在=$E1_EV_LEFT removed=$E1_REMOVED protectedByLedger=$E1_PROT"

    if [ "$E1_RRC" -ne 0 ] || [ "$(jval "$OUT" ok)" != "true" ]; then r=0; else r=1; fi
    chk "$r" \
        "E1d 这次拒绝删除必须机器可见，不许静默报成一次成功的修剪" \
        "rc != 0 或 ok != true" \
        "rc=$E1_RRC ok=$(jval "$OUT" ok) removed=$E1_REMOVED"

    chmod 644 "$SB1/.claude/harness/state/ledger.jsonl"
    run "$SB1" ledger
    chk "$([ "$RC" -eq 0 ] && [ "$(jval "$OUT" ok)" = "true" ] && echo 0 || echo 1)" \
        "E1e 权限恢复后照旧 rc 0 ok:true〔防回归位，现在就该绿：修 E1 不许把可读账本也判成断链〕" \
        "rc=0 且 ok=true" \
        "rc=$RC ok=$(jval "$OUT" ok)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- E2 并发追加不许打断链，且断了不许指一条修不好的路 ---"
# 实测（缺陷未修）：12 个并发 gate（check 为 sleep，让进程对齐）-> ledger 报 12 处断裂
#   （6 行 × chain-predecessor-mismatch + chain-hash-mismatch）；
#   再串行跑 2 次 gate，断裂仍是那 12 处——新行只往后追加，旧断裂永留。

SB2=$(newsandbox e2 "sleep 2")
BURSTS=0
E2_LOK=""
E2_BREAKS=""
E2_ENTRIES=""
while [ "$BURSTS" -lt 2 ]; do
    BURSTS=$((BURSTS + 1))
    i=1
    while [ "$i" -le 12 ]; do
        ( cd "$SB2" && CLAUDE_PROJECT_DIR="$SB2" node "$SB2/.claude/harness/harness.mjs" gate >/dev/null 2>&1 ) &
        i=$((i + 1))
    done
    wait
    run "$SB2" ledger
    E2_LOK=$(jval "$OUT" ok)
    E2_BREAKS=$(jval "$OUT" breaks | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).length);}catch(e){console.log("?");}})')
    E2_ENTRIES=$(jval "$OUT" entries)
    [ "$E2_LOK" = "true" ] || break
done

chk "$([ "$E2_LOK" = "true" ] && echo 0 || echo 1)" \
    "E2a 12 个并发 gate 之后账本链必须完好（read-then-append 无锁 = 互相覆盖 prev）" \
    "ledger ok=true，breaks=0" \
    "ok=$E2_LOK breaks=$E2_BREAKS entries=$E2_ENTRIES 并发轮数=$BURSTS"

E2_EXPECTED=$((12 * BURSTS))
chk "$([ "$E2_ENTRIES" = "$E2_EXPECTED" ] && echo 0 || echo 1)" \
    "E2b 并发下一条记录都不许丢〔现在偶然绿·防回归位：appendFileSync 小写入本身原子〕" \
    "entries=$E2_EXPECTED（每次 gate 一条）" \
    "entries=$E2_ENTRIES 并发轮数=$BURSTS"

# 砖机那半：链一旦断了，错误信息不许推荐一条跑完也解决不了的命令。
# 判定方式与措辞无关——从 blocker 里抠出它推荐的 harness 子命令，真跑一遍，看 blocker 是否还在。
SB2B=$(newsandbox e2-brick true)
run "$SB2B" gate
printf '{"command":"gate","at":"2020-01-01T00:00:00.000Z","gate":"PA' >> "$SB2B/.claude/harness/state/ledger.jsonl"
printf '\n' >> "$SB2B/.claude/harness/state/ledger.jsonl"
start_task "$SB2B" brick >/dev/null 2>&1 || true
run "$SB2B" task complete
E2_BLOCK_BEFORE="$ERR"
E2_RECOMMENDS=0
printf '%s' "$E2_BLOCK_BEFORE" | grep -qiE 're-run the gates|run: harness\.mjs gate' && E2_RECOMMENDS=1
run "$SB2B" gate
run "$SB2B" task complete
E2_STILL=0
printf '%s' "$ERR" | grep -qi 'ledger chain is broken' && E2_STILL=1
if [ "$E2_RECOMMENDS" -eq 1 ] && [ "$E2_STILL" -eq 1 ]; then r=1; else r=0; fi
chk "$r" \
    "E2c 链断后的诊断不许指一条走不通的路（推荐重跑 gate 就必须真能解掉这条 blocker）" \
    "推荐重跑 gate 则跑完 blocker 消失；否则文案不推荐重跑（改说需人工介入）" \
    "推荐重跑=$E2_RECOMMENDS 跑完仍阻断=$E2_STILL 首次诊断=[$(printf '%s' "$E2_BLOCK_BEFORE" | tr '\n' '|')]"

# ---------------------------------------------------------------------------
echo ""
echo "--- E3 半行残留不许吃掉相邻记录 ---"
# 实测（缺陷未修）：gate1 落一条 -> 手工追加一行无换行的 JSON 片段 -> gate2 的整行被拼进那个片段，
#   两条一起 unparseable。3 次 gate 之后文件里可解析的 gate 记录只剩 2 条（gate1 + gate3）。

SB3=$(newsandbox e3 true)
LEDGER3="$SB3/.claude/harness/state/ledger.jsonl"
run "$SB3" gate
printf '{"command":"gate","at":"2020-01-01T00:00:00.000Z","gate":"PA' >> "$LEDGER3"
run "$SB3" gate
run "$SB3" gate
E3_N=$(gate_records "$LEDGER3")
chk "$([ "$E3_N" -ge 3 ] && echo 0 || echo 1)" \
    "E3a 尾行没有换行时，后续 append 不许把自己和残行拼成一条（3 次 gate = 3 条可解析记录）" \
    "文件里 command==gate 且可解析的记录数 >= 3" \
    "记录数=$E3_N（残行吃掉一条则为 2）文件行数=$(wc -l < "$LEDGER3" | tr -d ' ')"

SB3B=$(newsandbox e3-clean true)
run "$SB3B" gate; run "$SB3B" gate; run "$SB3B" gate
E3B_N=$(gate_records "$SB3B/.claude/harness/state/ledger.jsonl")
chk "$([ "$E3B_N" -eq 3 ] && echo 0 || echo 1)" \
    "E3b 无残行时 3 次 gate = 3 条〔防回归位，现在就该绿：证明上面的计数法本身没问题〕" \
    "记录数=3" \
    "记录数=$E3B_N"

# ---------------------------------------------------------------------------
echo ""
echo "--- E4 evidenceSha256 必须被读，证据被改写/删除要有命令能看见 ---"
# 实测（缺陷未修）：全仓 grep evidenceSha256 只有 evidence.mjs 的四个写入点，零读取点。
#   跑完 gate 把 evidence/*.log 内容换掉、再删掉，ledger / risk / gate-audit / retention
#   四个命令全 rc 0。证据校验默认就开着，引擎只认 --no-verify-evidence 把它关掉——
#   「开着校验」的写法就是不带 flag 的 ledger 本身，没有 --verify-evidence 这个开关。

SB4=$(newsandbox e4 "echo real-check-output")
run "$SB4" gate
E4_EV=$(jval "$OUT" results.0.evidence)
E4_SHA=$(jval "$OUT" results.0.evidenceSha256)

# notices <沙箱> —— 跑四个读取者，回填 NOTICE_TRACE（各自退出码）、NOTICED（1=至少一个报非 0）
#   与 NOTICE_LEDGER（ledger 自己的退出码——证据摘要归它校验，别的命令报不报是它们的事）。
NOTICE_TRACE=""
NOTICED=0
NOTICE_LEDGER=0
notices() {
    local d="$1" trace="" c rc
    NOTICED=0
    NOTICE_LEDGER=0
    for c in "ledger" "risk" "gate-audit" "retention"; do
        rc=0
        # shellcheck disable=SC2086
        ( cd "$d" && CLAUDE_PROJECT_DIR="$d" node "$d/.claude/harness/harness.mjs" $c ) >/dev/null 2>&1 || rc=$?
        trace="$trace $c=$rc"
        if [ "$rc" -ne 0 ]; then NOTICED=1; fi
        if [ "$c" = "ledger" ]; then NOTICE_LEDGER=$rc; fi
    done
    NOTICE_TRACE="$trace"
}

notices "$SB4"
chk "$([ "$NOTICED" -eq 0 ] && echo 0 || echo 1)" \
    "E4a 证据未被动过时四个读取者全 rc 0〔防回归位，现在就该绿：挡住「改成永远报错」的假修〕" \
    "ledger / risk / gate-audit / retention 全 rc 0" \
    "$NOTICE_TRACE"

echo "TAMPERED - the check never printed this" > "$SB4/$E4_EV"
notices "$SB4"
chk "$([ "$NOTICE_LEDGER" -ne 0 ] && echo 0 || echo 1)" \
    "E4b 证据日志内容被改写后，ledger 必须报非 0（记了哈希却从不校验 = 没记）" \
    "ledger rc != 0（证据摘要校验默认开，重读对不上就是 evidence-tampered）" \
    "$NOTICE_TRACE 记录的 evidenceSha256=$E4_SHA 证据现内容=[$(head -c 60 "$SB4/$E4_EV")]"

rm -f "$SB4/$E4_EV"
notices "$SB4"
chk "$([ "$NOTICE_LEDGER" -ne 0 ] && echo 0 || echo 1)" \
    "E4c 证据日志被删除后，ledger 必须报非 0" \
    "ledger rc != 0（账本引用的日志没了就是 evidence-missing）" \
    "$NOTICE_TRACE 证据文件=$E4_EV 存在=$([ -f "$SB4/$E4_EV" ] && echo YES || echo NO)"

# ---------------------------------------------------------------------------
echo ""
echo "--- E5 链不完好时删除类命令必须 fail-closed ---"
# 实测（缺陷未修）：链完好时 retention --apply --max-evidence 0 -> candidates:0 removed:0（对）；
#   把那条记录改成不可解析后 -> protectedByLedger:0 candidates:1 removed:1 rc 0，证据被真删。

SB5=$(newsandbox e5 "echo e5-output")
run "$SB5" gate
E5_EV=$(jval "$OUT" results.0.evidence)

run "$SB5" retention --apply --max-evidence 0
E5_INTACT_LEFT=$([ -f "$SB5/$E5_EV" ] && echo YES || echo NO)
chk "$([ "$E5_INTACT_LEFT" = "YES" ] && [ "$(jval "$OUT" removed)" = "0" ] && echo 0 || echo 1)" \
    "E5a 链完好时被引用的证据不许删〔防回归位，现在就该绿〕" \
    "removed=0 且证据文件仍在" \
    "removed=$(jval "$OUT" removed) protectedByLedger=$(jval "$OUT" protectedByLedger) 仍在=$E5_INTACT_LEFT"

node -e '
    const fs = require("fs"), p = process.argv[1];
    const lines = fs.readFileSync(p, "utf8").split("\n");
    lines[0] = "{{CORRUPTED" + lines[0];
    fs.writeFileSync(p, lines.join("\n"));
' "$SB5/.claude/harness/state/ledger.jsonl"

run "$SB5" ledger
E5_LRC="$RC"
run "$SB5" retention --apply --max-evidence 0
E5_RRC="$RC"; E5_REMOVED=$(jval "$OUT" removed); E5_OK=$(jval "$OUT" ok)
E5_LEFT=$([ -f "$SB5/$E5_EV" ] && echo YES || echo NO)
chk "$([ "$E5_LEFT" = "YES" ] && echo 0 || echo 1)" \
    "E5b 链已断裂（ledger rc=$E5_LRC）时 retention --apply 一个文件都不许删" \
    "证据文件仍在（先验链再决定删不删）" \
    "证据文件=$E5_EV 仍在=$E5_LEFT removed=$E5_REMOVED protectedByLedger=$(jval "$OUT" protectedByLedger)"

if [ "$E5_RRC" -ne 0 ] || [ "$E5_OK" != "true" ]; then r=0; else r=1; fi
chk "$r" \
    "E5c 链断时的这次拒绝必须机器可见" \
    "rc != 0 或 ok != true" \
    "rc=$E5_RRC ok=$E5_OK removed=$E5_REMOVED"

# ---------------------------------------------------------------------------
echo ""
echo "--- E6 闸的输入范围不许由调用方伪造 ---"
# 实测（缺陷未修）：core 模块改坏（check 恒 false）时
#   真 gate                                   -> gate=FAIL modules=["core"] rc 2
#   gate --changed .claude/harness/state/...  -> gate=PASS modules=[] rc 0，diffHash 与真 gate 相同
#   两条记录除 modules/planHash/results/reason/at 外无任何差异（看不出范围是谁给的）
#   task complete（不带 --changed，计划非空）  -> ok:true rc 0 —— 一棵真跑会 FAIL 的树被判完成
# 注：reviewer 描述的「映射不到任何模块的路径」（docs/x.md 之类 unmapped）实测反而 fail-safe：
#   analyzeImpact 保守扩张成全模块 fanout，gate 照样 FAIL。这里用的是运行态排除路径。

SB6=$(newsandbox e6 false)
FORGED_SCOPE=".claude/harness/state/ledger.jsonl"

run "$SB6" gate
E6_REAL_RC="$RC"; E6_REAL_GATE=$(jval "$OUT" gate); E6_REAL_REC="$OUT"
rm -rf "$SB6/.claude/harness/state" "$SB6/.claude/harness/evidence"

run "$SB6" gate --changed "$FORGED_SCOPE"
E6_FORGED_RC="$RC"; E6_FORGED_GATE=$(jval "$OUT" gate); E6_FORGED_REC="$OUT"
E6_FORGED_MODULES=$(jval "$OUT" modules)
E6_SAME_DIFF=$([ "$(jval "$E6_REAL_REC" diffHash)" = "$(jval "$E6_FORGED_REC" diffHash)" ] && echo YES || echo NO)

E6_MARKER=$(node -e '
    const a = JSON.parse(process.argv[1]), b = JSON.parse(process.argv[2]);
    // 计划本身、判决、时间戳、账本句柄天然会不同——它们不构成「范围是谁给的」这个事实。
    // gate 必须排除：伪造范围本来就是为了把 FAIL 变成 PASS，拿判决当来源标记等于没标。
    const skip = new Set(["at", "gate", "modules", "results", "planHash", "reason", "ledger",
                          "attributeCoverage", "attributeGaps", "waivers", "skippedByFastMode"]);
    const diff = [];
    for (const k of new Set([...Object.keys(a), ...Object.keys(b)])) {
        if (skip.has(k)) continue;
        if (JSON.stringify(a[k]) !== JSON.stringify(b[k])) diff.push(k + "=" + JSON.stringify(b[k]));
    }
    console.log(diff.join(" "));
' "$E6_REAL_REC" "$E6_FORGED_REC")

chk "$([ -n "$E6_MARKER" ] && echo 0 || echo 1)" \
    "E6a gate 记录必须标出范围是自动算的还是调用方指定的（否则事后无从分辨）" \
    "两条记录在 modules/planHash/results/reason/at 之外至少有一个字段不同" \
    "可区分字段=[${E6_MARKER:-无}] 真gate=$E6_REAL_GATE(rc=$E6_REAL_RC) 伪造gate=$E6_FORGED_GATE(rc=$E6_FORGED_RC) modules=$E6_FORGED_MODULES diffHash相同=$E6_SAME_DIFF"

start_task "$SB6" e6 >/dev/null 2>&1 || true
run_stdin "$SB6" '{"taskId":"e6","verdict":"accept","reviewer":"r"}' receipt write
run "$SB6" task complete
E6_TC_RC="$RC"; E6_TC_OK=$(jval "$OUT" ok)
chk "$([ "$E6_TC_RC" -ne 0 ] && echo 0 || echo 1)" \
    "E6b 一棵真 gate 会 FAIL 的树，靠伪造范围拿到的 PASS 不许让 task complete 通过" \
    "task complete rc != 0" \
    "rc=$E6_TC_RC ok=$E6_TC_OK blockers=$(jval "$OUT" blockers) 真gate=$E6_REAL_GATE 账本里最新gate=$E6_FORGED_GATE"

SB6B=$(newsandbox e6-honest true)
run "$SB6B" gate
E6B_GATE=$(jval "$OUT" gate)
start_task "$SB6B" e6b >/dev/null 2>&1 || true
run_stdin "$SB6B" '{"taskId":"e6b","verdict":"accept","reviewer":"r"}' receipt write
run "$SB6B" task complete
chk "$([ "$RC" -eq 0 ] && [ "$(jval "$OUT" ok)" = "true" ] && echo 0 || echo 1)" \
    "E6c 诚实路径照旧能过〔防回归位，现在就该绿：修 E6 不许顺手把正常的 task complete 也堵死〕" \
    "真 PASS + 新鲜回执 + 链完好 + 计划非空 -> rc=0 ok=true" \
    "rc=$RC ok=$(jval "$OUT" ok) gate=$E6B_GATE blockers=$(jval "$OUT" blockers)"

# ---------------------------------------------------------------------------
echo ""
echo "--- E7 被压制的失败不许和「从没跑过」混成同一个数 ---"
# 实测（缺陷未修）：check 恒 false、装一条 scope=probe 的有效 waiver、连跑 5 次 gate ->
#   gate 每次 rc 0；gate-audit -> neverIntervened:["probe"] neverExecuted:["probe"]
#   并配文案 "genuinely stable"；risk -> findings:[] rc 0（FAIL_STREAK 一次不计）。
#   对照：不装 waiver 连败 4 次时 neverIntervened:[] 且 risk 报 FAIL_STREAK。

SB7=$(newsandbox e7 false)
run "$SB7" waiver create --owner o --reason "under investigation" --scope probe \
    --expiry "$FUTURE_ISO" --compensation "manual run"
E7_WAIVER_RC="$RC"
i=1
while [ "$i" -le 5 ]; do run "$SB7" gate || true; i=$((i + 1)); done
E7_GATE_RC="$RC"

run "$SB7" gate-audit
E7_AUDIT="$OUT"
E7_NEVEREXEC=$(jval "$OUT" neverExecuted)
E7_NEVERINT=$(jval "$OUT" neverIntervened)

chk "$([ "$E7_WAIVER_RC" -eq 0 ] && echo 0 || echo 1)" \
    "E7-夹具 waiver 写入成功（后面几条的前置条件）" \
    "waiver create rc=0" \
    "rc=$E7_WAIVER_RC 最后一次 gate rc=$E7_GATE_RC（waiver 把 FAIL 洗成 SKIPPED 后 gate 变 PASS）"

# waiver 改成事前声明之后，被豁免的 check 是**真的一次都没跑**，把它算进 neverExecuted 是唯一不撒谎的
# 答案——旧断言「不许算进 neverExecuted」编码的是事后改写模型（先跑、失败、再被洗成 SKIPPED）的前提。
# 但该段要防的东西没变：被豁免压住的，不许和「从没接线过」在读者眼里长成同一个数。所以判据换成更强的
# 蕴含式——只要它出现在 neverExecuted 里，就必须同时被独立的「被压制」桶点名（那个桶由 E7b 守着）。
case "$E7_NEVEREXEC" in
    *'"probe"'*)
        case "$E7_AUDIT" in
            *'"suppressed"'*'probe'*|*'suppressed'*'"probe"'*) r=0 ;;
            *) r=1 ;;
        esac ;;
    *) r=0 ;;
esac
chk "$r" \
    "E7a 被 waiver 压制的 check 若算进 neverExecuted，必须同时被「被压制」桶点名（不许与从没接线的混成一个数）" \
    "probe 要么不在 neverExecuted，要么同时出现在 suppressed 桶里" \
    "neverExecuted=$E7_NEVEREXEC neverIntervened=$E7_NEVERINT suppressed点名probe=$(case "$E7_AUDIT" in *suppressed*probe*) echo yes ;; *) echo no ;; esac)"

E7_BUCKET=$(printf '%s' "$E7_AUDIT" | node -e '
    let s = "";
    process.stdin.on("data", d => s += d).on("end", () => {
        try {
            const o = JSON.parse(s.trim().split("\n").filter(Boolean).pop());
            const known = new Set(["ok", "scope", "gateRuns", "declaredChecks",
                                   "neverIntervened", "neverExecuted", "advice"]);
            const hits = [];
            for (const [k, v] of Object.entries(o)) {
                if (known.has(k)) continue;
                if (JSON.stringify(v).includes("probe")) hits.push(k + "=" + JSON.stringify(v));
            }
            console.log(hits.join(" "));
        } catch (_e) { console.log(""); }
    });
')
chk "$([ -n "$E7_BUCKET" ] && echo 0 || echo 1)" \
    "E7b gate-audit 要有独立的「被压制」桶，把它和 neverIntervened/neverExecuted 分开" \
    "输出里存在 neverIntervened/neverExecuted 之外的字段点名 probe" \
    "被压制桶=[${E7_BUCKET:-无}] advice=[$(jval "$E7_AUDIT" advice)]"

run "$SB7" risk
E7_RISK_RC="$RC"; E7_RISK_FINDINGS=$(jval "$OUT" findings)
E7_RISK_N=$(printf '%s' "$E7_RISK_FINDINGS" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).length);}catch(e){console.log("?");}})')
chk "$([ "$E7_RISK_N" != "0" ] && [ "$E7_RISK_N" != "?" ] && echo 0 || echo 1)" \
    "E7c 连败 5 次被 waiver 压下去之后 risk 不许零 findings（压制是状态，不是没事）" \
    "findings 数 > 0" \
    "findings 数=$E7_RISK_N rc=$E7_RISK_RC findings=$E7_RISK_FINDINGS"

SB7B=$(newsandbox e7-nowaiver false)
i=1
while [ "$i" -le 4 ]; do run "$SB7B" gate || true; i=$((i + 1)); done
run "$SB7B" risk
E7B_FIND=$(jval "$OUT" findings)
case "$E7B_FIND" in *FAIL_STREAK*) r=0 ;; *) r=1 ;; esac
chk "$r" \
    "E7d 无 waiver 的真连败照旧报 FAIL_STREAK〔防回归位，现在就该绿〕" \
    "risk findings 含 FAIL_STREAK" \
    "findings=$E7B_FIND"

# Fast Mode 那半：全 SKIP 的 gate 不许关闭任务。
SB7C=$(newsandbox e7-fast false)
mkdir -p "$SB7C/.claude/.runtime"
node -e 'const fs=require("fs"); const now=Math.floor(Date.now()/1000);
    fs.writeFileSync(process.argv[1], JSON.stringify({tier:"fast",reason:"test",by:"test",set_epoch:now,expires_epoch:now+3600}) + "\n");' \
    "$SB7C/.claude/.runtime/tier.json"
run "$SB7C" gate
E7C_GATE=$(jval "$OUT" gate); E7C_REASON=$(jval "$OUT" reason); E7C_SKIPPED=$(jval "$OUT" skippedByFastMode)
start_task "$SB7C" e7c >/dev/null 2>&1 || true
run_stdin "$SB7C" '{"taskId":"e7c","verdict":"accept","reviewer":"r"}' receipt write
run "$SB7C" task complete
E7C_RC="$RC"
chk "$([ "$E7C_RC" -ne 0 ] && echo 0 || echo 1)" \
    "E7e Fast Mode 把全部 check 跳掉时，那条 PASS 不许关闭任务（证据是延后了，不是拿到了）" \
    "task complete rc != 0" \
    "rc=$E7C_RC ok=$(jval "$OUT" ok) gate=$E7C_GATE reason=$E7C_REASON skippedByFastMode=$E7C_SKIPPED（risk 同时报 FAST_MODE_DEBT 为 error）"

# ---------------------------------------------------------------------------
echo ""
echo "--- N1 非 git 树里 diffHash 是常量，不许给走不通的指引 ---"
# 实测（缺陷未修）：非 git 树里 diff-hash = 0327d770...（= sha256("NON_GIT")，任何非 git 树都一样）；
#   gate / verify / receipt verify 一律 rc 3 降级；只有 task complete 出 rc 2 并提示
#   "run: harness.mjs gate"——那条命令在同一棵树里必 rc 3，是条死路。

SB8=$(newsandbox n1 true test nogit)
NONGIT_CONST=$(node -e 'console.log(require("node:crypto").createHash("sha256").update(Buffer.from("NON_GIT")).digest("hex"))')
run "$SB8" diff-hash
N1_DH=$(jval "$OUT" diffHash); N1_NONGIT=$(jval "$OUT" nonGit)

run "$SB8" gate
N1_GATE_RC="$RC"
start_task "$SB8" n1 >/dev/null 2>&1 || true
run "$SB8" task complete
N1_TC_RC="$RC"; N1_TC_ERR="$ERR"; N1_TC_OUT="$OUT"

# 从 blocker 文本里抠出它推荐的 harness 子命令，逐个在同一棵树里真跑一遍。
N1_DEAD=""
for sub in $(printf '%s' "$N1_TC_ERR" | grep -oE 'harness\.mjs [a-z][a-z-]*' | awk '{print $2}' | sort -u); do
    rc=0
    ( cd "$SB8" && CLAUDE_PROJECT_DIR="$SB8" node "$SB8/.claude/harness/harness.mjs" "$sub" ) >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 3 ] && N1_DEAD="$N1_DEAD $sub(rc=3)"
done
chk "$([ -z "$N1_DEAD" ] && echo 0 || echo 1)" \
    "N1a 非 git 下 task complete 推荐的每条命令，在同一棵树里都必须真能跑（不许推荐必降级的命令）" \
    "blocker 里推荐的 harness 子命令没有一条在本树 rc=3" \
    "走不通的推荐=[${N1_DEAD:-无}] 诊断=[$(printf '%s' "$N1_TC_ERR" | tr '\n' '|')]"

N1_MARKED=1
printf '%s%s' "$N1_TC_OUT" "$N1_TC_ERR" | grep -qiE 'non-git|nonGit|not a git|非 ?git' && N1_MARKED=0
if [ "$N1_TC_RC" -eq 0 ]; then r=1
elif [ "$N1_TC_RC" -eq 3 ] || [ "$N1_MARKED" -eq 0 ]; then r=0
else r=1; fi
chk "$r" \
    "N1b 非 git 下 task complete 要按降级处理（rc=3，同 gate/verify/receipt verify），或至少明说本树非 git" \
    "rc=3，或输出里标出非 git；两者都不满足即判红" \
    "rc=$N1_TC_RC 标出非git=$([ "$N1_MARKED" -eq 0 ] && echo YES || echo NO) 同树 gate rc=$N1_GATE_RC"

chk "$([ "$N1_DH" = "$NONGIT_CONST" ] && [ "$N1_NONGIT" = "true" ] && echo 0 || echo 1)" \
    "N1c 非 git 下 diffHash 确实是那个常量〔夹具自证，现在就该绿：N1a/N1b 的前提〕" \
    "diff-hash = sha256(\"NON_GIT\") 且 nonGit=true" \
    "diffHash=$N1_DH 常量=$NONGIT_CONST nonGit=$N1_NONGIT"

# ---------------------------------------------------------------------------
echo ""
echo "--- .ps1 侧 ---"
skip "证据层是纯 node（lib/evidence.mjs + lib/task.mjs），无 .ps1 副本，不存在同构缺陷面"

# ---------------------------------------------------------------------------
echo ""
echo "==== test-evidence-defects：PASS=$PASS FAIL=$FAIL ===="
if [ "$FAIL" -gt 0 ]; then
    echo "test-evidence-defects: failed —— 修复前这是预期状态（红锁）；修复后必须转全绿" >&2
    exit 1
fi
echo "test-evidence-defects: passed（证据留得住、改写看得见、范围伪造不了、压制不冒充没跑过）"
