#!/usr/bin/env bash
# risk: high
# test-predev-lint.sh — 前期文档机器闸（scripts/predev-lint.mjs）的回归测试。
#
# 断言按**契约**写：node predev-lint.mjs [--root <dir>] [--json]，五份文件按存在性检查，
#   缺的跳过；一份都没有 → rc 0；任一 error → rc 1；未知参数 → rc 2。
# 只留两把准绳：**范例必绿、模板原样必红**，外加各闸自己那条核心判据。
#   花样输入（编号写法、围栏变体、诱饵段、转义管道…）一律不追——测试量有上限，
#   多出来的那些既没挡住过缺陷，也让改口径的人要同时改十几个夹具。
# 每条拒绝用例同时判 rc **和** --json 里的 code：只判 rc=1 的话，「脚本不存在 / node 崩了」
#   也给 rc 1，红锁会被伪绿冒充过去。
# 夹具在 mktemp 沙箱里现造，不落 tests/fixtures。
#
# 用法：bash test-predev-lint.sh [predev-lint.mjs 路径]
set -u

SRC=$(cd "$(dirname "$0")/.." && pwd)
LINT=${1:-"$SRC/scripts/predev-lint.mjs"}

echo "===== test-predev-lint ====="
command -v node >/dev/null 2>&1 || {
    echo 'SKIPPED: 无 node——被测脚本是 .mjs，未执行 != 通过。'
    exit 0
}

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
brief() { printf '%s' "$1" | tr '\n' ' ' | cut -c1-200 | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null; }
newdir() { mktemp -d "$TMP/caseXXXXXX"; }
# 判据从 --json 的 findings 里取行号，别拿 grep 在 JSON 文本上猜——「有没有这个词」和
#   「这条 finding 指着哪一行」是两回事。
fjq() { # <json> <code> → 该 code 的 finding 行号，升序空格分隔
    printf '%s' "$1" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let j;try{j=JSON.parse(s)}catch{return console.log("PARSE_ERROR")}console.log((j.findings||[]).filter(x=>x.code===process.argv[1]).map(x=>x.line).sort((a,b)=>a-b).join(" "))})' -- "$2"
}
lineno() { grep -n "$2" "$1" | head -1 | cut -d: -f1; }

RC=0
OUT=""
run_json() { OUT=$(node "$LINT" --root "$1" --json 2>&1); RC=$?; }

# 模板原句取模板原文，取不到用内置副本——判的是「模板没填完就是没写完」，不是本文件抄得准不准。
TPL_LINE=$(grep -m1 '^<2-3 ' "$SRC/skills/product-spec-builder/templates/product-spec-template.md" 2>/dev/null)
TPL_SRC=模板原文
if [ -z "$TPL_LINE" ]; then
    TPL_LINE='<2-3 个真实发生过的案例，不写「一般来说」。每个案例：谁（有名字，可化名）→ 做什么 → 用什么 → 然后呢 → 为什么这么干。例外单独一段。>'
    TPL_SRC=内置副本
fi

# ---------------------------------------------------------------------------
# 夹具：一份合规 Spec / DFX + 逐条规则的单点变异
# ---------------------------------------------------------------------------
write_spec() { # <dir> [variant]
    local d=$1 v=${2:-good}
    {
        printf '%s\n' '# 派单小工具 Product Spec' ''
        printf '%s\n' '## 产品概述' '给三人售后班组用的派单小工具：组长派单，师傅回单。' ''
        printf '%s\n' '## 应用场景：工作现状故事' '- 早上八点，组长在群里往回翻消息，找昨天没关掉的单。'
        [ "$v" != tpl_angle ] || printf '%s\n' "$TPL_LINE" '并发 < 100 且 延迟 > 1s' '数据量 <10 万行，单表 >100 万行' '<=3 个>'
        printf '%s\n' ''
        printf '%s\n' '## 成功判据' '| 判据 | 度量 | 目标 |' '| --- | --- | --- |'
        case "$v" in
            cmp)       printf '%s\n' '| SC-1 首屏 | 首屏 <1s | 并发 >100 |' ;;
            tpl_angle) printf '%s\n' '| 首屏 <1s | 并发 >100 | 0 |' ;;
            *)         printf '%s\n' '| 派单不漏 | 每日未派单数 | 0 |' ;;
        esac
        printf '%s\n' ''
        printf '%s\n' '## 范围与非目标' '- [SCOPE-1] 只做派单与回单，不做库存。' ''
        printf '%s\n' '## 功能需求'
        case "$v" in
            pending_req) printf '%s\n' '- [确认] 派单：组长选单 -> 指派师傅 -> 师傅手机收到' \
                                       '- [默认] 导出：组长点导出 -> 下载文件，导出格式 [待定]' ;;
            *)           printf '%s\n' '- [确认] 派单：组长选单 -> 指派师傅 -> 师傅手机收到' \
                                       '- [推断] 回单：师傅传照片 -> 系统记完成时间' ;;
        esac
        printf '%s\n' ''
        printf '%s\n' '## 规则与例外' '- 规则：一单只挂一个当班师傅。' '- 例外：老张不在时，退回组长。' ''
        printf '%s\n' '## 关键流程' '- [FLOW-1] 派单：接单 -> 派单 -> 回单 -> 归档' ''
        printf '%s\n' '## 决策依据' '- 选 CSV 不选 Excel：班组只在手机上看。' ''
        printf '%s\n' '## 技术方向' '| 维度 | 选择 | 理由 |' '| --- | --- | --- |' '| 前端 | 移动端网页 | 师傅只有手机 |' ''
        printf '%s\n' '## 待定问题' '| 问题 | 领域 | 谁能定 | 何时需要 | 临时默认 |' '| --- | --- | --- | --- | --- |'
        case "$v" in
            row_short) printf '%s\n' '| Q-2 电话可见范围 | 数据权限 | | | |' ;;
            *)         printf '%s\n' '| Q-1 老张不在时怎么走 | 派单规则 | 用户 | Phase 2 前 | 退回组长 |' ;;
        esac
        printf '%s\n' ''
        printf '%s\n' '## 澄清记录' '- 2026-09-09 与组长确认：一单一师傅。'
    } > "$d/Product-Spec.md"
}

write_dfx() { # <dir> [variant]
    local d=$1 v=${2:-good}
    {
        printf '%s\n' '# DFX Spec' ''
        printf '%s\n' '## 优先级栈' '1. 可靠性：派单不能丢'
        [ "$v" = short_stack ] || printf '%s\n' '2. 可服务性：现场能自查' '3. 性能：列表 1 秒内出'
        printf '%s\n' '' '## 维度总表'
        case "$v" in
            cmp) printf '%s\n' '| 维度 | 档位 | 度量 | 验证落点 |' '| --- | --- | --- | --- |' \
                               '| 性能 | medium | P95 <200ms，错误率 >0.1% | 压测一次 |' '' ;;
            # dfx-spec-template.md 的总表最后一列是「验证落点」，度量排在中间
            verify_col) printf '%s\n' '| 维度 | 档位 | 场景 | 度量 | 设计对策 | 验证落点 |' '| --- | --- | --- | --- | --- | --- |' \
                               '| 可靠性 | high | 派单不丢 | 丢单率 0 | 写前落盘 | 回归测试 |' \
                               '| 可服务性 | medium | 现场排障 | 定位耗时 N/A | 结构化日志 | 现场演练 |' '' ;;
            *)   printf '%s\n' '| 维度 | 档位 | 场景 | 责任模块 | 手段 | 度量 |' '| --- | --- | --- | --- | --- | --- |'
                 if [ "$v" = unmeasured ]; then
                     printf '%s\n' '| 可靠性 | high | 派单不丢 | dispatch | 写前落盘 | 尽量不丢 |'
                 else
                     printf '%s\n' '| 可靠性 | high | 派单不丢 | dispatch | 写前落盘 | 丢单率 0 |'
                 fi
                 printf '%s\n' '| 可服务性 | medium | 现场排障 | report | 结构化日志 | 定位耗时 N/A |' '' ;;
        esac
        printf '%s\n' '## 取舍记录' '- 放弃多副本：三人班组不值当，接受单点。'
    } > "$d/DFX-Spec.md"
}

expect_clean() { # <dir> <说明>
    local r
    run_json "$1"
    if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qE '"ok"[[:space:]]*:[[:space:]]*true'; then r=0; else r=1; fi
    chk "$r" "$2" "rc=0 且 --json 的 ok=true" "rc=$RC；输出：$(brief "$OUT")"
}

expect_code() { # <dir> <code> <说明>
    local r
    run_json "$1"
    if [ "$RC" -eq 1 ] && contains "$2" "$OUT"; then r=0; else r=1; fi
    chk "$r" "$3" "rc=1 且 --json 含 $2" \
        "rc=$RC；含 $2=$(contains "$2" "$OUT" && echo yes || echo no)；输出：$(brief "$OUT")"
}

if [ -f "$LINT" ]; then
    chk 0 "P0 被测脚本存在：$LINT" "predev-lint.mjs 存在" "存在"
else
    chk 1 "P0 被测脚本存在：$LINT" "predev-lint.mjs 存在" "不存在——下面每条都会红，红因是功能缺失"
fi

# ---------------------------------------------------------------------------
# 各闸的核心判据
# ---------------------------------------------------------------------------
D=$(newdir); write_spec "$D" pending_req; expect_code "$D" PENDING_IN_REQUIREMENT "P4 功能条目里挂着 [待定]"
D=$(newdir); write_spec "$D" row_short;   expect_code "$D" PENDING_ROW_INCOMPLETE "P5 待定问题表行有空格子（没人认领、没有时限）"
D=$(newdir); write_dfx "$D" unmeasured;   expect_code "$D" UNMEASURED             "P19 维度总表的度量列「尽量不丢」不含数字也不是 N/A"
D=$(newdir); write_dfx "$D" short_stack;  expect_code "$D" PRIORITY_STACK_TOO_SHORT "P20 优先级栈只有 1 项（没排序等于没取舍）"
D=$(newdir); write_dfx "$D" verify_col
expect_clean "$D" "P27 度量列按表头定位：总表最后一列是「验证落点」时，度量在中间列，不许判 UNMEASURED"

D=$(newdir); write_spec "$D"
OUT=$(node "$LINT" --root "$D" --bogus 2>&1); RC=$?
if [ "$RC" -eq 2 ]; then r=0; else r=1; fi
chk "$r" "P23 未知参数 → rc 2" "rc=2" "rc=$RC；输出：$(brief "$OUT")"

# ---------------------------------------------------------------------------
# 两把准绳：范例必绿、模板原样必红
# ---------------------------------------------------------------------------
# P33 dogfood：五份随 skill 发布的范例拼成一个 root，自家闸必须放行自家范例。
D=$(newdir); MISS=""
for pair in "product-spec-builder/examples/after-sales-dispatch.md:Product-Spec.md" \
            "design-brief-builder/examples/after-sales-dispatch-brief.md:Design-Brief.md" \
            "design-brief-builder/examples/after-sales-dispatch-DESIGN.md:DESIGN.md" \
            "arch-designer/examples/after-sales-dispatch-arch.md:Architecture-Design.md" \
            "dfx-designer/examples/after-sales-dispatch-dfx.md:DFX-Spec.md"; do
    src="$SRC/skills/${pair%%:*}"; dst="$D/${pair##*:}"
    if [ -f "$src" ]; then cp "$src" "$dst"; else MISS="$MISS ${pair%%:*}"; fi
done
if [ -z "$MISS" ]; then
    expect_clean "$D" "P33 五份范例互为一套，必须过自己的闸（dogfood）"
else
    echo "  [NOTE] P33 跳过：范例缺$MISS"
fi

# P49 五份模板原样拷成正式文件名，一份都不许放行——模板没填完就是没写完。
#   判据要求「rc=1 **且** 含 PLACEHOLDER」：DESIGN 模板报的是 MISSING_TOKEN / UNRESOLVED_TOKEN，
#   只判 rc 的话它会拿别的缺陷撑绿。
BADT=""; DETAIL=""
for pair in "product-spec-builder/templates/product-spec-template.md:Product-Spec.md" \
            "design-brief-builder/templates/design-brief-template.md:Design-Brief.md" \
            "design-brief-builder/templates/design-md-template.md:DESIGN.md" \
            "arch-designer/templates/architecture-design-template.md:Architecture-Design.md" \
            "dfx-designer/templates/dfx-spec-template.md:DFX-Spec.md"; do
    src="$SRC/skills/${pair%%:*}"; dst="${pair##*:}"
    if [ ! -f "$src" ]; then BADT="$BADT $dst(源缺失)"; continue; fi
    D=$(newdir); cp "$src" "$D/$dst"; run_json "$D"
    if [ "$RC" -ne 1 ] || ! contains PLACEHOLDER "$OUT"; then
        BADT="$BADT $dst"
        DETAIL="$DETAIL；[$dst] rc=$RC 含 PLACEHOLDER=$(contains PLACEHOLDER "$OUT" && echo yes || echo no)"
    fi
done
if [ -z "$BADT" ]; then r=0; else r=1; fi
chk "$r" "P49 五份模板原样当正式文档，每份都要 rc 1 且报 PLACEHOLDER（没填的槽就是没写完）" \
    "五份都 rc=1 且 --json 含 PLACEHOLDER" "放行或没报 PLACEHOLDER 的：${BADT:-无}${DETAIL}"

# ---------------------------------------------------------------------------
# 比较式与占位的分界：两侧都像数字才是比较式，> 落在行尾的是没填的占位
# ---------------------------------------------------------------------------
D=$(newdir); write_spec "$D" cmp; write_dfx "$D" cmp
expect_clean "$D" "P34 首屏 <1s / 数据量 <10 万行 / P95 <200ms 是阈值比较式，不是没填的模板占位"

D=$(newdir); write_spec "$D" tpl_angle
F="$D/Product-Spec.md"
TPLL=$(lineno "$F" '^<2-3 '); EQL=$(lineno "$F" '^<=3 个>$')
C1=$(lineno "$F" '^并发 < 100'); C2=$(lineno "$F" '^数据量 <10'); C3=$(lineno "$F" '首屏 <1s')
run_json "$D"; PH=$(fjq "$OUT" PLACEHOLDER)
if [ "$RC" -eq 1 ] && [ "$PH" = "$TPLL $EQL" ]; then r=0; else r=1; fi
chk "$r" "P47 模板原句「<2-3 个真实发生过的案例…>」是没填的占位（取自$TPL_SRC），不是比较式" \
    "rc=1；PLACEHOLDER=[$TPLL $EQL]（三行比较式 $C1 / $C2 / $C3 不许报）" \
    "rc=$RC；PLACEHOLDER=[$PH]"

echo "  [NOTE] 未覆盖：--out/多 root、DESIGN.md 前言的 YAML 异常形态、Brief 与 Spec 编号双向一致。"

echo ""
echo "==== test-predev-lint：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ]
