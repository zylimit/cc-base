#!/usr/bin/env bash
# test-release-binding.sh — 批 3「发版与证据绑定」五条契约（L3a~L3e）的红锁回归测试。
#
# 与既有测试的分工：
#   test-release-manifest.sh  锁 release 的 manifest 项对排除表的口径（已实现，该全绿）
#   test-evidence-defects.sh  锁证据层「证据留得住、不能被静默改写」（另一批）
#   本文件                    锁「发版结论必须绑在证据上」这五条——**现在一条都不成立**
#
# red-locks-the-bug：断言写的是**修复后应该成立的行为**，不是「缺陷能复现」。
#   所以实现补齐之前本脚本整体必然 FAIL —— 那是它的成功状态，不是它写坏了。
#   转绿之后它就是永久回归防线：谁把哪条绑定摘掉，哪条立刻红。
#
# 五条契约（引擎 .claude/harness/harness.mjs + lib/{release,quality,evidence}.mjs）：
#   L3a  release 新增检查项 gate-fresh：有 catalog 时须存在一条 gate 记录
#        （.claude/harness/state/ledger.jsonl）满足 gate==='PASS' 且 diffHash 等于当前工作树
#        指纹、且不是 fast-mode 下的全 SKIPPED，才 PASS；否则 FAIL，blocker 的下一步命令点名
#        `node .claude/harness/harness.mjs gate`。无 catalog -> DEGRADED 且不阻断
#        （cc-base 自己没 catalog，不能因此发不了版）。
#   L3b  release 输出恒带 trustBoundary，四个字段永远 false：producerIdentityAuthenticated /
#        ciProvenanceVerified / externalSignatureVerified / releaseAuthorized，
#        并且人读 stderr 有一行说明「这是候选证明，不是授权」。
#   L3c  receipt write 记 engineHash（运行中引擎目录 harness.mjs + lib/*.mjs 的内容 sha256）；
#        receipt verify 发现回执 engineHash 与当前引擎不同 -> STALE rc 4 note engine-moved；
#        老回执没有该字段 -> 放行但输出 engineHash:null（升级不砖化存量回执）。
#   L3d  risk 治理面告警：工作树改动落在 .claude/hooks|harness|skills|agents|rules/** 、
#        .claude/CLAUDE.md 或 .github/** -> finding GOVERNANCE_SURFACE_CHANGED（severity warning，
#        列出路径）。
#   L3e  lib/quality.mjs 的命令可执行判定在找不到命令时回落扫描 shim 目录
#        （win32 默认 WinGet/scoop/chocolatey；任何平台可用 CC_HARNESS_SHIM_DIRS 覆盖，
#        path.delimiter 分隔），命中则把该目录前置进子进程 PATH 让 check 真跑，而不是判 BLOCKED。
#
# 本机实测到的两处「契约描述与引擎现状不符」，断言按契约写、按实测选形态（详见各段注释）：
#   ① 契约把「fast-mode 全 SKIPPED」括注成「现在 rc 3、不算 PASS」——实测不是：
#      cmdGate 对全 SKIPPED 聚合出 gate:'PASS' 且 rc 0，账本里也是一条 gate:'PASS' 记录。
#      所以 gate-fresh 必须自己把这种记录挡掉，否则一次 fast-mode 空跑就能喂饱发版闸。
#   ② 契约的「非 git -> gate-fresh DEGRADED」在现有 cmdRelease 结构下不可达：非 git 时
#      cmdRelease 早返回 {error:'non-git', checks:[]}，七项检查一项都不跑。本文件不为它写
#      「gate-fresh 存在」的断言（那会逼实现改 cmdRelease 的整体结构），只按 L3b 的「恒带」
#      要求那条早返回路径也带 trustBoundary。
#
# 三种标记，别把它们当成一样的东西：
#   【防回归位】     现在就绿而且**现在就有信息量**（引擎真的做到了那件事），留着防修复时把
#                    对照那一侧改坏。L3e①⑥ 是这种。
#   【现在恒绿·…】   现在也绿，但绿得毫无信息量——功能整个不存在，否定式判据自然成立。
#                    要等实现补齐才开始真正守东西。L3c③⑥⑦、L3d①③ 是这种。
#   【超契约字面】   契约没写但同源方向的补洞（L3c⑤、L3d③），交主 Agent 裁定要不要保留。
#
# 覆盖面：只覆盖 .sh 可驱动的引擎行为。这批全是纯 node，.ps1 侧无同构代码。
# 纪律：一切样例写进 mktemp 出来的临时 git 仓，trap 清理；对 cc-base 只读。
#   每条断言打印 EXPECT / GOT，判定不依赖措辞——复核只看这两行。
# 依赖：node + git。python3 / jq / pwsh 都不需要。
#
# 用法：bash test-release-binding.sh [REPO]
#   REPO 默认本仓。传打了补丁的引擎副本可以跑同一份断言——全绿就证明每条红都是功能缺失。
set -eu

REPO="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"

HARNESS="$REPO/.claude/harness/harness.mjs"
LIBDIR="$(dirname "$HARNESS")/lib"
HOOKSLIB="$REPO/.claude/hooks/lib"
PROFILE="$REPO/.claude/harness/profile.json"

echo "===== test-release-binding ====="
echo "REPO=$REPO"

if ! command -v node >/dev/null 2>&1; then
    echo "SKIPPED: 无 node（command -v node 未找到）——被测的全是纯 node 引擎，一条都跑不了，未执行 != 通过。" >&2
    exit 1
fi
if ! command -v git >/dev/null 2>&1; then
    echo "SKIPPED: 无 git（command -v git 未找到）——沙箱仓造不出来，未执行 != 通过。" >&2
    exit 1
fi

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

# ---------------------------------------------------------------------------
# 沙箱与引擎驱动
# ---------------------------------------------------------------------------

# engdeps <项目根> —— 补齐引擎在别处也能起来所需的那两样：hooks/lib/ 与 profile.json。
#   档位只有一个解析器且放在 hook 侧，引擎 lib/tier.mjs import 的是 ../../hooks/lib/tier.mjs；
#   只搬 harness/ 的树里引擎会 ERR_MODULE_NOT_FOUND，以契约外的 rc 1 退出，
#   下面「gate 该 PASS」「receipt 该 STALE」这类断言全部读成同一个起不来。
engdeps() {
    local d="$1"
    mkdir -p "$d/.claude/hooks"
    cp -R "$HOOKSLIB" "$d/.claude/hooks/lib"
    cp "$PROFILE" "$d/.claude/harness/profile.json"
}

# mksandbox <名> <catalog yes|no> [check命令]
#   造一个临时项目：一个 core 模块、一条 medium 档 check、一个 src/ 非治理面文件。
#   引擎按目录整拷（harness.mjs import 同级 lib/，只拷单文件会 ERR_MODULE_NOT_FOUND）。
#   catalog 把 .claude/** 与 src/** 归入 ignored，好让 catalog-lint / dod 在沙箱里是干净的，
#   否则 release 里除 gate-fresh 之外还会多出一片跟本测试无关的红。
mksandbox() {
    local name="$1" withcat="$2" cmd="${3:-true}"
    local d="$TMP/$name"
    mkdir -p "$d/.claude/harness" "$d/core" "$d/src"
    cp "$HARNESS" "$d/.claude/harness/harness.mjs"
    cp -R "$LIBDIR" "$d/.claude/harness/lib"
    engdeps "$d"
    if [ "$withcat" = yes ]; then
        cat > "$d/.claude/harness/module-catalog.json" <<EOF
{"version":1,
 "modules":[{"id":"core","paths":["core/**"],"riskTier":"medium"}],
 "global":[],
 "ignored":[".claude/**","src/**"],
 "riskChecks":{"medium":["probe"]},
 "checks":{"probe":{"command":"$cmd","class":"test"}}}
EOF
    fi
    echo baseline > "$d/core/a.txt"
    echo source   > "$d/src/a.ts"
    (
        cd "$d" && git init -q . \
            && git config core.autocrlf false \
            && git config user.email t@example.com && git config user.name t \
            && git add -A && git commit -qm init
    ) >/dev/null 2>&1
    printf '%s' "$d"
}

RC=0
OUT=""
ERR=""

# run <沙箱> <子命令...> —— 用沙箱自带的引擎跑，回填 RC / OUT / ERR。
run() {
    local d="$1"; shift
    RC=0
    OUT=$( cd "$d" && CLAUDE_PROJECT_DIR="$d" node "$d/.claude/harness/harness.mjs" "$@" 2>"$TMP/.stderr" ) || RC=$?
    ERR=$(cat "$TMP/.stderr" 2>/dev/null || true)
}

# run_engine <引擎入口> <沙箱> <子命令...> —— 换一台引擎跑同一个项目（L3c 的引擎副本用）。
run_engine() {
    local eng="$1" d="$2"; shift 2
    RC=0
    OUT=$( cd "$d" && CLAUDE_PROJECT_DIR="$d" node "$eng" "$@" 2>"$TMP/.stderr" ) || RC=$?
    ERR=$(cat "$TMP/.stderr" 2>/dev/null || true)
}

# run_env <VAR=值> <沙箱> <子命令...> —— 多带一个环境变量（L3e 的 CC_HARNESS_SHIM_DIRS 用）。
run_env() {
    local kv="$1" d="$2"; shift 2
    RC=0
    OUT=$( cd "$d" && env "CLAUDE_PROJECT_DIR=$d" "$kv" node "$d/.claude/harness/harness.mjs" "$@" 2>"$TMP/.stderr" ) || RC=$?
    ERR=$(cat "$TMP/.stderr" 2>/dev/null || true)
}

# run_stdin <沙箱> <stdin 文本> <子命令...>
run_stdin() {
    local d="$1" payload="$2"; shift 2
    RC=0
    OUT=$( printf '%s' "$payload" | ( cd "$d" && CLAUDE_PROJECT_DIR="$d" node "$d/.claude/harness/harness.mjs" "$@" ) 2>"$TMP/.stderr" ) || RC=$?
    ERR=$(cat "$TMP/.stderr" 2>/dev/null || true)
}

# jval <json> <点路径> —— 取字段（不存在回空串，null 回字面量 "null"）。
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

# jfile <文件> <点路径> / jfile_has <文件> <键>
#   回执落盘时是多行 pretty JSON，jval / jhas 那套「取最后一行再 parse」在它身上必然解析失败
#   并回退成空串——拿它断言「文件里没有某字段」会得到一条假绿。读文件一律走这两个。
jfile() {
    node -e '
        const fs = require("fs");
        try {
            let v = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
            for (const k of process.argv[2].split(".")) v = (v == null ? undefined : v[k]);
            console.log(v === undefined ? "" : (typeof v === "object" && v !== null ? JSON.stringify(v) : String(v)));
        } catch (_e) { console.log(""); }
    ' "$1" "$2"
}
jfile_has() {
    node -e '
        const fs = require("fs");
        try {
            const o = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
            console.log(Object.prototype.hasOwnProperty.call(o, process.argv[2]) ? "yes" : "no");
        } catch (_e) { console.log("READ-ERR"); }
    ' "$1" "$2"
}

# rel_check <json> <检查 id> —— 制表符四列：status / nextStep / 是否进 blockers / blocker 的 nextStep
#   检查项不存在回 ABSENT（跟 DEGRADED 分得开：一个是没实现，一个是实现了但答不出）。
rel_check() {
    printf '%s' "$1" | node -e '
        let s = "";
        process.stdin.on("data", d => s += d).on("end", () => {
            let j;
            try { j = JSON.parse(s.trim().split("\n").filter(Boolean).pop()); }
            catch (_e) { console.log(["PARSE-ERR", "", "", ""].join("\t")); return; }
            const id = process.argv[1];
            const c = (j.checks || []).find(x => x && x.id === id);
            const b = (j.blockers || []).find(x => x && x.id === id);
            console.log([
                c ? String(c.status) : "ABSENT",
                c ? String(c.nextStep === null || c.nextStep === undefined ? "" : c.nextStep) : "",
                b ? "yes" : "no",
                b ? String(b.nextStep === null || b.nextStep === undefined ? "" : b.nextStep) : "",
            ].join("\t"));
        });
    ' "$2"
}

# trust_probe <json> —— 制表符三列：字段在不在 / 四字段是否全为布尔 false / 原样 JSON
#   四个字段名写死，不从输出里反推——反推等于「实现写了什么就断言什么」。
trust_probe() {
    printf '%s' "$1" | node -e '
        const KEYS = ["producerIdentityAuthenticated", "ciProvenanceVerified",
                      "externalSignatureVerified", "releaseAuthorized"];
        let s = "";
        process.stdin.on("data", d => s += d).on("end", () => {
            let j;
            try { j = JSON.parse(s.trim().split("\n").filter(Boolean).pop()); }
            catch (_e) { console.log(["PARSE-ERR", "no", ""].join("\t")); return; }
            const t = j.trustBoundary;
            const present = (t && typeof t === "object" && !Array.isArray(t)) ? "yes" : "no";
            const allFalse = present === "yes" && KEYS.every(k => t[k] === false) ? "yes" : "no";
            console.log([present, allFalse, JSON.stringify(t === undefined ? null : t)].join("\t"));
        });
    '
}

# risk_gov <json> —— 制表符三列：GOVERNANCE_SURFACE_CHANGED 在不在 / severity / files 的 JSON
risk_gov() {
    printf '%s' "$1" | node -e '
        let s = "";
        process.stdin.on("data", d => s += d).on("end", () => {
            let j;
            try { j = JSON.parse(s.trim().split("\n").filter(Boolean).pop()); }
            catch (_e) { console.log(["PARSE-ERR", "", ""].join("\t")); return; }
            const f = (j.findings || []).find(x => x && x.code === "GOVERNANCE_SURFACE_CHANGED");
            console.log([
                f ? "yes" : "no",
                f ? String(f.severity) : "",
                f ? JSON.stringify(f.files === undefined ? null : f.files) : "",
            ].join("\t"));
        });
    '
}

# verify_probe <json> <check id> —— 制表符三列：该 check 的 state / reason / 整体 gate
verify_probe() {
    printf '%s' "$1" | node -e '
        let s = "";
        process.stdin.on("data", d => s += d).on("end", () => {
            let j;
            try { j = JSON.parse(s.trim().split("\n").filter(Boolean).pop()); }
            catch (_e) { console.log(["PARSE-ERR", "", ""].join("\t")); return; }
            const c = (j.checks || []).find(x => x && x.id === process.argv[1]);
            console.log([
                c ? String(c.state) : "ABSENT",
                c ? String(c.reason === undefined ? "" : c.reason) : "",
                String(j.gate === undefined ? "" : j.gate),
            ].join("\t"));
        });
    ' "$2"
}

# jhas <json> <键> —— 顶层键在不在（"yes"/"no"）。区分「字段缺失」与「字段为 null」。
jhas() {
    printf '%s' "$1" | node -e '
        let s = "";
        process.stdin.on("data", d => s += d).on("end", () => {
            try {
                const o = JSON.parse(s.trim().split("\n").filter(Boolean).pop());
                console.log(Object.prototype.hasOwnProperty.call(o, process.argv[1]) ? "yes" : "no");
            } catch (_e) { console.log("no"); }
        });
    ' "$2"
}

# 老回执改写器：删掉 engineHash，用**引擎自己导出的** contentHash 重算，产出一份「升级前写的」
#   合法回执。手搓哈希算法会在实现换算法时假红；借引擎自己的实现就永远对得上。
cat > "$TMP/legacy-receipt.mjs" <<'MJSEOF'
import fs from 'node:fs';
import { pathToFileURL } from 'node:url';
const [, , qualityPath, receiptPath] = process.argv;
const { contentHash } = await import(pathToFileURL(qualityPath).href);
const r = JSON.parse(fs.readFileSync(receiptPath, 'utf8'));
delete r.engineHash;
delete r.contentHash;
r.contentHash = contentHash(r);
fs.writeFileSync(receiptPath, JSON.stringify(r, null, 2) + '\n', 'utf8');
console.log(r.contentHash);
MJSEOF

# ---------------------------------------------------------------------------
echo ""
echo "--- 脚手架自证（这几条必须绿；红了说明夹具坏了，不许赖在行为断言头上）---"

chk "$([ -f "$HARNESS" ] && [ -d "$LIBDIR" ] && echo 0 || echo 1)" \
    "被测引擎 harness.mjs + lib/ 存在" \
    "$HARNESS 与同级 lib/ 都在" \
    "harness=$([ -f "$HARNESS" ] && echo 有 || echo 无) lib=$([ -d "$LIBDIR" ] && echo 有 || echo 无)"

SB_A=$(mksandbox l3a yes)
echo worktree-change >> "$SB_A/core/a.txt"

GITOK=$( (cd "$SB_A" && git rev-parse --is-inside-work-tree 2>/dev/null) || echo NO )
chk "$([ "$GITOK" = "true" ] && echo 0 || echo 1)" \
    "沙箱是可用的 git 工作树" \
    "git rev-parse --is-inside-work-tree = true" \
    "= $GITOK"

run "$SB_A" doctor
DOC_CAT=$(jval "$OUT" catalogPresent)
chk "$([ "$RC" -eq 0 ] && [ "$DOC_CAT" = "true" ] && echo 0 || echo 1)" \
    "沙箱里引擎能跑且 catalog 已启用" \
    "doctor rc=0 且 catalogPresent=true" \
    "rc=$RC catalogPresent=$DOC_CAT"

run "$SB_A" catalog-lint
CL_OK=$(jval "$OUT" ok)
chk "$([ "$CL_OK" = "true" ] && echo 0 || echo 1)" \
    "沙箱 catalog 本身是干净的（否则 release 的 dod 项会带一片无关的红）" \
    "catalog-lint ok=true" \
    "ok=$CL_OK rc=$RC 输出首 200 字：$(printf '%s' "$OUT" | head -c 200)"

run "$SB_A" release
REL_IDS=$(printf '%s' "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s.trim().split("\n").filter(Boolean).pop());console.log((j.checks||[]).map(c=>c.id).join(","));}catch(_e){console.log("PARSE-ERR");}})')
chk "$(printf '%s' "$REL_IDS" | grep -q 'worktree' && echo 0 || echo 1)" \
    "沙箱里 release 能跑出带 checks 的 JSON" \
    "checks 里至少有既有的 worktree 项" \
    "checks ids = $REL_IDS（rc=$RC）"

# ---------------------------------------------------------------------------
echo ""
echo "--- L3a  release 的 gate-fresh：发版结论必须绑在一条新鲜的 gate 记录上 ---"
# 现状：release 只有七项（worktree/remote/dod/manifest/review-queue/fast-mode/ci），
#   跑没跑过闸、跑的是不是这棵树，发版命令一个字都不问。

REL_A1=$(rel_check "$OUT" gate-fresh)
A1_STATUS=$(printf '%s' "$REL_A1" | cut -f1)
A1_BLOCK=$(printf '%s' "$REL_A1" | cut -f3)
A1_BNEXT=$(printf '%s' "$REL_A1" | cut -f4)

chk "$([ "$A1_STATUS" = "FAIL" ] && echo 0 || echo 1)" \
    "L3a① 有 catalog、有代码改动、账本里没有 gate 记录 -> gate-fresh = FAIL" \
    "checks 里有 id=gate-fresh 且 status=FAIL" \
    "status=$A1_STATUS（ABSENT = 这个检查项还不存在）"

chk "$([ "$A1_BLOCK" = "yes" ] && printf '%s' "$A1_BNEXT" | grep -q 'gate' && echo 0 || echo 1)" \
    "L3a② 该 FAIL 进 blockers，且下一步命令点名 gate" \
    "blockers 含 gate-fresh，其 nextStep 含 'gate'（契约给的是 node .claude/harness/harness.mjs gate）" \
    "inBlockers=$A1_BLOCK nextStep=[$A1_BNEXT]"

# 跑一趟真闸：PASS + 账本落一条记录。
run "$SB_A" gate
GATE_VERDICT=$(jval "$OUT" gate)
GATE_DH=$(jval "$OUT" diffHash)
chk "$([ "$RC" -eq 0 ] && [ "$GATE_VERDICT" = "PASS" ] && echo 0 || echo 1)" \
    "脚手架：沙箱里 gate 真跑出 PASS（后面两条断言的前提）" \
    "gate rc=0 且 gate=PASS" \
    "rc=$RC gate=$GATE_VERDICT diffHash=$GATE_DH"

# 指纹稳定性自证：gate/release 自己写的运行态文件如果动了指纹，L3a③ 就会是假红。
run "$SB_A" diff-hash
NOW_DH=$(jval "$OUT" diffHash)
chk "$([ "$GATE_DH" = "$NOW_DH" ] && echo 0 || echo 1)" \
    "脚手架：跑完 gate 后工作树指纹没变（运行态写入被 STATE_EXCLUDE 挡住）" \
    "gate 记录的 diffHash == 事后 diff-hash" \
    "gate=$GATE_DH now=$NOW_DH"

run "$SB_A" release
REL_A3=$(rel_check "$OUT" gate-fresh)
A3_STATUS=$(printf '%s' "$REL_A3" | cut -f1)
chk "$([ "$A3_STATUS" = "PASS" ] && echo 0 || echo 1)" \
    "L3a③ 账本里有一条 gate=PASS 且 diffHash 等于当前指纹 -> gate-fresh = PASS" \
    "status=PASS" \
    "status=$A3_STATUS（ledger 行数=$(wc -l < "$SB_A/.claude/harness/state/ledger.jsonl" 2>/dev/null || echo 0)）"

# 代码往前走一步：那条记录背书的已经不是这棵树了。
echo one-more-change >> "$SB_A/core/a.txt"
run "$SB_A" diff-hash
MOVED_DH=$(jval "$OUT" diffHash)
run "$SB_A" release
REL_A4=$(rel_check "$OUT" gate-fresh)
A4_STATUS=$(printf '%s' "$REL_A4" | cut -f1)
chk "$([ "$A4_STATUS" = "FAIL" ] && echo 0 || echo 1)" \
    "L3a④ 改一个文件后 diffHash 不再匹配 -> gate-fresh 回到 FAIL" \
    "status=FAIL（旧 gate 记录不再背书新的树）" \
    "status=$A4_STATUS gate记录diffHash=$GATE_DH 当前diffHash=$MOVED_DH"

# 无 catalog：cc-base 自己就是这种树，不能因为「没跑过 catalog 闸」就发不了版。
SB_NOCAT=$(mksandbox l3a-nocat no)
echo worktree-change >> "$SB_NOCAT/core/a.txt"
run "$SB_NOCAT" release
REL_A5=$(rel_check "$OUT" gate-fresh)
A5_STATUS=$(printf '%s' "$REL_A5" | cut -f1)
A5_BLOCK=$(printf '%s' "$REL_A5" | cut -f3)
chk "$([ "$A5_STATUS" = "DEGRADED" ] && echo 0 || echo 1)" \
    "L3a⑤ 无 catalog -> gate-fresh = DEGRADED（答不出，不是没通过）" \
    "status=DEGRADED" \
    "status=$A5_STATUS"
# 判据里要求这项**存在**：只写「不在 blockers 里」的话，检查项压根没实现时它也绿，
#   那种绿毫无信息量（ABSENT 本来就不会进 blockers）。
chk "$([ "$A5_STATUS" != "ABSENT" ] && [ "$A5_STATUS" != "PARSE-ERR" ] && [ "$A5_BLOCK" = "no" ] && echo 0 || echo 1)" \
    "L3a⑥ 无 catalog 时 gate-fresh 不许进 blockers（DEGRADED 不阻断发版）" \
    "gate-fresh 这项存在，且 blockers 里没有它" \
    "status=$A5_STATUS inBlockers=$A5_BLOCK；本次 release rc=$RC，blockers=$(jval "$OUT" blockers | head -c 200)"

# fast-mode 全 SKIPPED 的那条记录：实测 gate 对它聚合出 gate:'PASS' 且 rc 0（不是契约括注里说的
#   rc 3），所以 gate-fresh 必须自己认出来并拒收——否则开着 Fast Mode 空跑一趟就能喂饱发版闸。
#   契约明文「不是 fast-mode 下的全 SKIPPED」，任务清单里没单列这一条，见文件头说明①。
SB_FAST=$(mksandbox l3a-fast yes)
# allowFastSkip 只有单独写进 check 才成立，mksandbox 的默认模板不带，这里就地覆盖。
cat > "$SB_FAST/.claude/harness/module-catalog.json" <<'EOF'
{"version":1,
 "modules":[{"id":"core","paths":["core/**"],"riskTier":"medium"}],
 "global":[],
 "ignored":[".claude/**","src/**"],
 "riskChecks":{"medium":["probe"]},
 "checks":{"probe":{"command":"true","class":"test","allowFastSkip":true}}}
EOF
(cd "$SB_FAST" && git add -A && git commit -qm catalog) >/dev/null 2>&1
echo worktree-change >> "$SB_FAST/core/a.txt"
# fast 档只有一个开关：.claude/.runtime/tier.json（旧的 .claude/.fast-mode 判定不再读）。
mkdir -p "$SB_FAST/.claude/.runtime"
printf '{"tier":"fast","reason":"test","by":"test","set_epoch":%s,"expires_epoch":%s}\n' \
    "$(date +%s)" "$(( $(date +%s) + 3600 ))" > "$SB_FAST/.claude/.runtime/tier.json"
run "$SB_FAST" gate
FAST_VERDICT=$(jval "$OUT" gate)
FAST_SKIPPED=$(jval "$OUT" skippedByFastMode)
FAST_RESULTS=$(jval "$OUT" results)
chk "$([ "$FAST_VERDICT" = "PASS" ] && [ "$FAST_SKIPPED" != "[]" ] && echo 0 || echo 1)" \
    "脚手架：fast-mode 下的 gate 确实落了一条 gate=PASS 的全 SKIPPED 记录（这就是要挡的东西）" \
    "gate=PASS 且 skippedByFastMode 非空" \
    "gate=$FAST_VERDICT rc=$RC skipped=$FAST_SKIPPED results=$(printf '%s' "$FAST_RESULTS" | head -c 160)"
run "$SB_FAST" release
REL_A7=$(rel_check "$OUT" gate-fresh)
A7_STATUS=$(printf '%s' "$REL_A7" | cut -f1)
# 同上：要求这项存在，否则「检查项还没实现」也能撑出一条绿。
chk "$([ "$A7_STATUS" != "PASS" ] && [ "$A7_STATUS" != "ABSENT" ] && [ "$A7_STATUS" != "PARSE-ERR" ] && echo 0 || echo 1)" \
    "L3a⑦ fast-mode 全 SKIPPED 的 gate 记录不许喂饱 gate-fresh（契约说这种判 FAIL）" \
    "gate-fresh 这项存在，且 status != PASS（写否定形式：FAIL 或 DEGRADED 都算合规修法）" \
    "status=$A7_STATUS"

# ---------------------------------------------------------------------------
echo ""
echo "--- L3b  release 恒带 trustBoundary：结构性防止本地绿灯被读成发布授权 ---"

run "$SB_A" release
TB=$(trust_probe "$OUT")
TB_PRESENT=$(printf '%s' "$TB" | cut -f1)
TB_ALLFALSE=$(printf '%s' "$TB" | cut -f2)
TB_RAW=$(printf '%s' "$TB" | cut -f3)
chk "$([ "$TB_PRESENT" = "yes" ] && echo 0 || echo 1)" \
    "L3b① release JSON 顶层带 trustBoundary 对象" \
    "trustBoundary 是个对象" \
    "present=$TB_PRESENT raw=$TB_RAW"
chk "$([ "$TB_ALLFALSE" = "yes" ] && echo 0 || echo 1)" \
    "L3b② 四个字段全是布尔 false（producerIdentityAuthenticated / ciProvenanceVerified / externalSignatureVerified / releaseAuthorized）" \
    "四个键都存在且 === false" \
    "allFalse=$TB_ALLFALSE raw=$TB_RAW"
chk "$(printf '%s' "$ERR" | grep -qi 'authoriz' && echo 0 || echo 1)" \
    "L3b③ 人读 stderr 有一行说明这是候选证明、不是授权" \
    "stderr 里有一行提到 authoriz（authorization / authorized / authorize 任一）" \
    "命中行=[$(printf '%s' "$ERR" | grep -i 'authoriz' | head -1)]；stderr 末行=[$(printf '%s' "$ERR" | tail -1)]"

run "$SB_NOCAT" release
TB_NC=$(trust_probe "$OUT")
chk "$([ "$(printf '%s' "$TB_NC" | cut -f2)" = "yes" ] && echo 0 || echo 1)" \
    "L3b④ 无 catalog 的树上同样带（『恒带』不是『catalog 启用时才带』）" \
    "allFalse=yes" \
    "present=$(printf '%s' "$TB_NC" | cut -f1) allFalse=$(printf '%s' "$TB_NC" | cut -f2) raw=$(printf '%s' "$TB_NC" | cut -f3)"

# 非 git 的早返回路径：cmdRelease 在这里一项检查都不跑，但『恒带』覆盖它。
# 这条也是 gate-fresh 在非 git 下不可达的那处结构冲突的落点，见文件头说明②。
NONGIT="$TMP/nongit"
mkdir -p "$NONGIT/.claude/harness"
cp "$HARNESS" "$NONGIT/.claude/harness/harness.mjs"
cp -R "$LIBDIR" "$NONGIT/.claude/harness/lib"
engdeps "$NONGIT"
run "$NONGIT" release
TB_NG=$(trust_probe "$OUT")
chk "$([ "$(printf '%s' "$TB_NG" | cut -f2)" = "yes" ] && echo 0 || echo 1)" \
    "L3b⑤ 非 git 的早返回路径（rc 3，checks 为空）也带 trustBoundary" \
    "allFalse=yes" \
    "rc=$RC present=$(printf '%s' "$TB_NG" | cut -f1) raw=$(printf '%s' "$TB_NG" | cut -f3) 输出=$(printf '%s' "$OUT" | head -c 160)"

# ---------------------------------------------------------------------------
echo ""
echo "--- L3c  receipt 绑引擎哈希：引擎自己改了，旧回执不再背书 ---"

SB_C=$(mksandbox l3c yes)
echo worktree-change >> "$SB_C/core/a.txt"

run_stdin "$SB_C" '{"taskId":"t1","reviewer":"r","verdict":"pass"}' receipt write
C_WRITE_RC=$RC
C_EH=$(jval "$OUT" engineHash)
chk "$([ "$C_WRITE_RC" -eq 0 ] && printf '%s' "$C_EH" | grep -Eq '^[0-9a-f]{64}$' && echo 0 || echo 1)" \
    "L3c① receipt write 的输出带 engineHash（64 位小写 hex）" \
    "engineHash 匹配 ^[0-9a-f]{64}$" \
    "rc=$C_WRITE_RC engineHash=[$C_EH]"

RCPT="$SB_C/.claude/harness/receipts/t1.json"
FILE_EH=$(jfile "$RCPT" engineHash)
chk "$(printf '%s' "$FILE_EH" | grep -Eq '^[0-9a-f]{64}$' && echo 0 || echo 1)" \
    "L3c② 落盘的回执文件里也有 engineHash（不是只在 stdout 上造个字段）" \
    "receipts/t1.json 的 engineHash 匹配 ^[0-9a-f]{64}$" \
    "文件里的 engineHash=[$FILE_EH]"

# 引擎副本①：逐字节照抄，只是换了个位置。哈希算的是内容不是路径，这条必须仍放行。
#   副本连 .claude/ 这层壳一起搬：引擎 lib/tier.mjs 的 ../../hooks/lib/tier.mjs 是按自身位置解析的，
#   把引擎摊在 $TMP/eng-same/ 下那条路径会落到 $TMP/hooks/，副本一台都起不来。
ENG_SAME="$TMP/eng-same/.claude/harness"
mkdir -p "$ENG_SAME"
cp -R "$SB_C/.claude/harness/." "$ENG_SAME/"
engdeps "$TMP/eng-same"
run_engine "$ENG_SAME/harness.mjs" "$SB_C" receipt verify --task t1
SAME_STATE=$(jval "$OUT" state)
chk "$([ "$RC" -eq 0 ] && [ "$SAME_STATE" != "STALE" ] && echo 0 || echo 1)" \
    "L3c③【现在恒绿·防砖位】换了路径但内容一致的引擎副本：verify 不许因此 STALE（哈希是内容不是位置）" \
    "rc=0 且 state != STALE" \
    "rc=$RC state=$SAME_STATE note=$(jval "$OUT" note)"

# 引擎副本②：往一个 lib 文件末尾加一行注释——语义没变，字节变了，回执的背书就该失效。
ENG_MUT="$TMP/eng-moved/.claude/harness"
mkdir -p "$ENG_MUT"
cp -R "$SB_C/.claude/harness/." "$ENG_MUT/"
engdeps "$TMP/eng-moved"
printf '\n// mutation: one comment line, enough to move the engine hash\n' >> "$ENG_MUT/lib/core.mjs"
run_engine "$ENG_MUT/harness.mjs" "$SB_C" receipt verify --task t1
MUT_STATE=$(jval "$OUT" state)
MUT_NOTE=$(jval "$OUT" note)
chk "$([ "$RC" -eq 4 ] && [ "$MUT_STATE" = "STALE" ] && [ "$MUT_NOTE" = "engine-moved" ] && echo 0 || echo 1)" \
    "L3c④ 引擎内容变了 -> receipt verify --task rc 4 / STALE / note=engine-moved" \
    "rc=4 state=STALE note=engine-moved" \
    "rc=$RC state=$MUT_STATE note=$MUT_NOTE"

# 默认形态（stop-gate 用的就是这个，不带 --task）：契约没点名形态，但真正被消费的是这一条。
# 写否定形式：不许还报 PASS rc 0；note 叫 engine-moved 还是 no-matching-receipt 都算合规。
# 【超契约字面 —— 交主 Agent 裁定是否保留】
run_engine "$ENG_MUT/harness.mjs" "$SB_C" receipt verify
DEF_STATE=$(jval "$OUT" state)
chk "$([ "$RC" -ne 0 ] && [ "$DEF_STATE" != "PASS" ] && echo 0 || echo 1)" \
    "L3c⑤ 引擎变了以后，不带 --task 的默认形态也不许再报 PASS（stop-gate 消费的是这条）" \
    "rc != 0 且 state != PASS" \
    "rc=$RC state=$DEF_STATE note=$(jval "$OUT" note)"

# 原引擎（就是写这份回执的那台）：对照组，现在就该绿。【防回归位】
run "$SB_C" receipt verify --task t1
ORIG_STATE=$(jval "$OUT" state)
chk "$([ "$RC" -eq 0 ] && [ "$ORIG_STATE" = "PASS" ] && echo 0 || echo 1)" \
    "L3c⑥【现在恒绿·防砖位】原引擎跑同一份回执：仍是 PASS rc 0（别把对照那一侧一起判死）" \
    "rc=0 state=PASS" \
    "rc=$RC state=$ORIG_STATE note=$(jval "$OUT" note)"

# 老回执：升级前写的，压根没有 engineHash 字段（contentHash 用引擎自己的实现重算，所以它是
#   一份合法回执，不是被篡改的）。放行，但要在输出里把 engineHash 报成 null 提示。
LEGACY_CH=$(node "$TMP/legacy-receipt.mjs" "$SB_C/.claude/harness/lib/quality.mjs" "$RCPT")
LEGACY_HAS=$(jfile_has "$RCPT" engineHash)
LEGACY_TASK=$(jfile "$RCPT" taskId)
chk "$([ "$LEGACY_HAS" = "no" ] && [ "$LEGACY_TASK" = "t1" ] && [ -n "$LEGACY_CH" ] && echo 0 || echo 1)" \
    "脚手架：老回执确实造出来了（engineHash 字段已删、contentHash 用引擎自己的算法重算过）" \
    "回执文件读得动（taskId=t1）、里面没有 engineHash 键、且重算出了 contentHash" \
    "hasEngineHash=$LEGACY_HAS taskId=$LEGACY_TASK contentHash=$LEGACY_CH"

run "$SB_C" receipt verify --task t1
LEG_STATE=$(jval "$OUT" state)
chk "$([ "$RC" -eq 0 ] && [ "$LEG_STATE" != "STALE" ] && echo 0 || echo 1)" \
    "L3c⑦【现在恒绿·防砖位】老回执（无 engineHash）不许被判 STALE——升级不能把存量回执全砖化" \
    "rc=0 且 state != STALE" \
    "rc=$RC state=$LEG_STATE note=$(jval "$OUT" note)"

LEG_OUT_HAS=$(jhas "$OUT" engineHash)
LEG_OUT_VAL=$(jval "$OUT" engineHash)
chk "$([ "$LEG_OUT_HAS" = "yes" ] && [ "$LEG_OUT_VAL" = "null" ] && echo 0 || echo 1)" \
    "L3c⑧ 老回执的 verify 输出里 engineHash 字段在、值为 null（放行但留提示，不是静默放过）" \
    "输出含 engineHash 键且值为 null" \
    "hasKey=$LEG_OUT_HAS value=[$LEG_OUT_VAL] 输出=$(printf '%s' "$OUT" | head -c 200)"

# 写入侧的两条：把「内容不是路径」和「一个字节就该翻」直接锁在 receipt write 上，不绕 verify。
# ③ 那条防砖位在实现补齐前是恒绿的（现在压根没有 engineHash），这两条则现在就红、修完才绿。
# 顺序放在最后：这两次 write 会往 receipts/ 里多塞回执，早写会把上面 ⑤ 的默认形态判据搅浑。
OUT=$( printf '%s' '{"taskId":"t2","reviewer":"r","verdict":"pass"}' \
    | ( cd "$SB_C" && CLAUDE_PROJECT_DIR="$SB_C" node "$ENG_SAME/harness.mjs" receipt write ) 2>/dev/null ) || true
EH_SAME=$(jval "$OUT" engineHash)
chk "$(printf '%s' "$EH_SAME" | grep -Eq '^[0-9a-f]{64}$' && [ "$EH_SAME" = "$C_EH" ] && echo 0 || echo 1)" \
    "L3c⑨ 内容一致、位置不同的引擎写出的 engineHash 必须相同（算的是内容）" \
    "engineHash 是 64 位 hex 且 == 原引擎写的那个" \
    "副本=[$EH_SAME] 原引擎=[$C_EH]"

OUT=$( printf '%s' '{"taskId":"t3","reviewer":"r","verdict":"pass"}' \
    | ( cd "$SB_C" && CLAUDE_PROJECT_DIR="$SB_C" node "$ENG_MUT/harness.mjs" receipt write ) 2>/dev/null ) || true
EH_MUT=$(jval "$OUT" engineHash)
chk "$(printf '%s' "$EH_MUT" | grep -Eq '^[0-9a-f]{64}$' && [ "$EH_MUT" != "$C_EH" ] && echo 0 || echo 1)" \
    "L3c⑩ lib 里多一行注释的引擎写出的 engineHash 必须不同（一个字节就该翻）" \
    "engineHash 是 64 位 hex 且 != 原引擎写的那个" \
    "变异副本=[$EH_MUT] 原引擎=[$C_EH]"

# ---------------------------------------------------------------------------
echo ""
echo "--- L3d  risk 治理面告警：改闸的改动要走最严档 ---"

SB_D=$(mksandbox l3d yes)

# 控制组先跑：只改业务文件，不许报。【防回归位——现在本来就不报，别让它变成见改就喊】
echo more-source >> "$SB_D/src/a.ts"
run "$SB_D" risk
D_CTRL=$(risk_gov "$OUT")
chk "$([ "$(printf '%s' "$D_CTRL" | cut -f1)" = "no" ] && echo 0 || echo 1)" \
    "L3d①【现在恒绿·对照组】只改 src/a.ts -> findings 不含 GOVERNANCE_SURFACE_CHANGED" \
    "present=no" \
    "present=$(printf '%s' "$D_CTRL" | cut -f1) files=$(printf '%s' "$D_CTRL" | cut -f3) rc=$RC"

# 治理面七条路径逐条过：只实现一条也算漏，所以每条各造一次。
# 管道里的 while 是子 shell，PASS/FAIL 计数加不回来，所以用 for + IFS 换行。
GOV_PATHS='.claude/hooks/x.sh
.claude/harness/notes.md
.claude/skills/demo/SKILL.md
.claude/agents/demo.md
.claude/CLAUDE.md
.claude/rules/demo.md
.github/workflows/ci.yml'

OLDIFS=$IFS
IFS='
'
for p in $GOV_PATHS; do
    [ -n "$p" ] || continue
    IFS=$OLDIFS
    mkdir -p "$SB_D/$(dirname "$p")"
    printf 'governance surface change\n' > "$SB_D/$p"
    run "$SB_D" risk
    G=$(risk_gov "$OUT")
    G_PRESENT=$(printf '%s' "$G" | cut -f1)
    G_SEV=$(printf '%s' "$G" | cut -f2)
    G_FILES=$(printf '%s' "$G" | cut -f3)
    NAMED=no
    printf '%s' "$G_FILES" | grep -qF "$p" && NAMED=yes
    chk "$([ "$G_PRESENT" = "yes" ] && [ "$NAMED" = "yes" ] && [ "$G_SEV" = "warning" ] && echo 0 || echo 1)" \
        "L3d② 改 $p -> GOVERNANCE_SURFACE_CHANGED（warning）且 files 点名该路径" \
        "present=yes severity=warning files 含 $p" \
        "present=$G_PRESENT severity=$G_SEV files=$G_FILES rc=$RC"
    rm -f "$SB_D/$p"
    IFS='
'
done
IFS=$OLDIFS

# 运行态写入不是治理面改动。gate 会往 .claude/harness/state|evidence 里落文件，而 changedPaths()
#   不做运行态过滤（过滤只发生在 canonicalDiff / isStateExcluded 那一侧）——照字面实现的话，
#   跑过一次闸之后这条告警就永远亮着，等于没有告警。
# 先改 core/a.txt 让闸真的有 check 要跑，否则 evidence/ 一个文件都不落，这条只测到 state/ 半边。
# 【现在恒绿·超契约字面 —— 交主 Agent 裁定是否保留】
echo make-the-gate-do-work >> "$SB_D/core/a.txt"
run "$SB_D" gate
STATE_FILES=$( (cd "$SB_D" && git status --porcelain) | tr '\n' ' ')
EVID_N=$(ls "$SB_D/.claude/harness/evidence" 2>/dev/null | wc -l)
run "$SB_D" risk
D_STATE=$(risk_gov "$OUT")
chk "$([ "$(printf '%s' "$D_STATE" | cut -f1)" = "no" ] && [ "$EVID_N" -gt 0 ] && echo 0 || echo 1)" \
    "L3d③ gate 自己写的运行态文件（.claude/harness/state|evidence/**）不许触发治理面告警" \
    "present=no（否则跑过一次闸这条告警就永远亮着）；且 evidence/ 里真落了文件，两半边都测到" \
    "present=$(printf '%s' "$D_STATE" | cut -f1) files=$(printf '%s' "$D_STATE" | cut -f3) evidence文件数=$EVID_N；此时 git status=[$STATE_FILES]"

# ---------------------------------------------------------------------------
echo ""
echo "--- L3e  Windows shim 发现：找不到命令先扫 shim 目录，别一上来判 BLOCKED ---"

SHIM="$TMP/shim"
SENTINEL="$TMP/mytool-ran"
mkdir -p "$SHIM"
cat > "$SHIM/mytool" <<EOF
#!/bin/sh
printf 'ran\n' > "$SENTINEL"
exit 0
EOF
chmod +x "$SHIM/mytool"

EMPTY_SHIM="$TMP/shim-empty"
mkdir -p "$EMPTY_SHIM"

SB_E=$(mksandbox l3e yes mytool)
echo worktree-change >> "$SB_E/core/a.txt"

chk "$(command -v mytool >/dev/null 2>&1 && echo 1 || echo 0)" \
    "脚手架：mytool 确实不在 PATH 上（否则整段 L3e 测的是别的东西）" \
    "command -v mytool 找不到" \
    "which=$(command -v mytool 2>/dev/null || echo 无) shim=$SHIM/mytool（可执行=$([ -x "$SHIM/mytool" ] && echo 是 || echo 否)）"

# 对照组：没给 shim 目录，就该 BLOCKED。【防回归位——绝不能变成「找不到就放行」】
rm -f "$SENTINEL"
run "$SB_E" verify
E_CTRL=$(verify_probe "$OUT" probe)
chk "$([ "$(printf '%s' "$E_CTRL" | cut -f1)" = "BLOCKED" ] && [ ! -f "$SENTINEL" ] && echo 0 || echo 1)" \
    "L3e①【防回归位】未指定 shim 目录 -> 该 check 仍 BLOCKED（命令没跑）" \
    "state=BLOCKED 且哨兵文件不存在" \
    "state=$(printf '%s' "$E_CTRL" | cut -f1) reason=$(printf '%s' "$E_CTRL" | cut -f2) gate=$(printf '%s' "$E_CTRL" | cut -f3) rc=$RC 哨兵=$([ -f "$SENTINEL" ] && echo 有 || echo 无)"

# 主断言：CC_HARNESS_SHIM_DIRS 指到 shim 目录 -> 命中、前置进子进程 PATH、命令真跑起来。
rm -f "$SENTINEL"
run_env "CC_HARNESS_SHIM_DIRS=$SHIM" "$SB_E" verify
E_HIT=$(verify_probe "$OUT" probe)
E_HIT_STATE=$(printf '%s' "$E_HIT" | cut -f1)
chk "$([ "$E_HIT_STATE" = "PASS" ] && echo 0 || echo 1)" \
    "L3e② CC_HARNESS_SHIM_DIRS 命中 -> 该 check 判 PASS，不再 BLOCKED" \
    "state=PASS" \
    "state=$E_HIT_STATE reason=$(printf '%s' "$E_HIT" | cut -f2) gate=$(printf '%s' "$E_HIT" | cut -f3) rc=$RC"

chk "$([ -f "$SENTINEL" ] && echo 0 || echo 1)" \
    "L3e③ 命令是真跑了（哨兵文件被 shim 脚本写出来），不是把状态改绿了事" \
    "$SENTINEL 存在" \
    "哨兵=$([ -f "$SENTINEL" ] && echo 有 || echo 无)"

chk "$(printf '%s%s' "$OUT" "$ERR" | grep -qF "$SHIM" && echo 0 || echo 1)" \
    "L3e④ 输出（stdout 或 stderr）点名是从哪个 shim 目录找到的" \
    "输出里出现 $SHIM" \
    "stdout=$(printf '%s' "$OUT" | head -c 200) stderr=$(printf '%s' "$ERR" | head -c 200)"

# 多目录：path.delimiter 分隔，前一个不存在，后一个命中。
rm -f "$SENTINEL"
run_env "CC_HARNESS_SHIM_DIRS=$TMP/does-not-exist:$SHIM" "$SB_E" verify
E_MULTI=$(verify_probe "$OUT" probe)
chk "$([ "$(printf '%s' "$E_MULTI" | cut -f1)" = "PASS" ] && [ -f "$SENTINEL" ] && echo 0 || echo 1)" \
    "L3e⑤ 多个目录用 path.delimiter 分隔，跳过不存在的、命中后面那个" \
    "state=PASS 且哨兵存在" \
    "state=$(printf '%s' "$E_MULTI" | cut -f1) reason=$(printf '%s' "$E_MULTI" | cut -f2) 哨兵=$([ -f "$SENTINEL" ] && echo 有 || echo 无) rc=$RC"

# 防砖：设了变量但目录里没有该命令，仍须 BLOCKED——这个变量是回落扫描，不是无条件放行开关。
rm -f "$SENTINEL"
run_env "CC_HARNESS_SHIM_DIRS=$EMPTY_SHIM" "$SB_E" verify
E_EMPTY=$(verify_probe "$OUT" probe)
chk "$([ "$(printf '%s' "$E_EMPTY" | cut -f1)" = "BLOCKED" ] && [ ! -f "$SENTINEL" ] && echo 0 || echo 1)" \
    "L3e⑥ shim 目录里没有该命令 -> 仍 BLOCKED（变量是回落扫描，不是放行开关）" \
    "state=BLOCKED 且哨兵不存在" \
    "state=$(printf '%s' "$E_EMPTY" | cut -f1) reason=$(printf '%s' "$E_EMPTY" | cut -f2) 哨兵=$([ -f "$SENTINEL" ] && echo 有 || echo 无) rc=$RC"

# ---------------------------------------------------------------------------
echo ""
echo "==== test-release-binding：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
