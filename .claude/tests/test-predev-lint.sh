#!/usr/bin/env bash
# test-predev-lint.sh — 前期文档机器闸（scripts/predev-lint.mjs）的回归测试。
#
# 断言按 **契约** 写，不照抄实现（写这份测试时实现尚不存在）：
#   契约：node predev-lint.mjs [--root <dir>] [--json]
#         五份文件按存在性检查，缺的跳过；一份都没有 → rc 0；任一 error → rc 1；未知参数 → rc 2。
#
# 这份测试的立身之本是「接受用例」和「拒绝用例」等重：
#   一个把所有文档都判红的 lint 和一个什么都不判的 lint，一样没用。所以合规夹具（P1/P2/P12/P22/P24）
#   和坏样例（P3-P20）在这里是同一等级的断言——只锁坏样例的话，实现可以无脑 rc 1 全绿。
#
# 每条拒绝用例都同时判 rc **和** --json 里的 code：
#   只判 rc=1 的话，「脚本不存在 / node 崩了」也会给 rc 1，红锁测试会被伪绿冒充过去。
#
# 夹具全部在 mktemp 沙箱里现造，不落 tests/fixtures——五份文档是互相引用的一套（Brief 引 Spec 的
#   FLOW-1/SCOPE-1），拆成静态夹具反而看不出哪一处被改坏了。
#
# 用法：bash test-predev-lint.sh [predev-lint.mjs 路径]
set -u

SRC=$(cd "$(dirname "$0")/.." && pwd)
LINT=${1:-"$SRC/scripts/predev-lint.mjs"}
EXAMPLE="$SRC/skills/product-spec-builder/examples/after-sales-dispatch.md"

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
#   「这条 finding 指着哪一行」是两回事，诱饵段那类用例只有后者说得清。
fjq() { # <json> <code> → 该 code 的 finding 行号，升序空格分隔
    printf '%s' "$1" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let j;try{j=JSON.parse(s)}catch{return console.log("PARSE_ERROR")}console.log((j.findings||[]).filter(x=>x.code===process.argv[1]).map(x=>x.line).sort((a,b)=>a-b).join(" "))})' -- "$2"
}
lineno() { grep -n "$2" "$1" | head -1 | cut -d: -f1; }
slotcount() { # <文件> → 新口径下应报的 {{…}} 槽数
    # 围栏外全算；围栏内除「模板/代码语言」外都算；开栏行自带的槽（```{{lang}}）也算。
    node -e '
      const EX=new Set(["html","vue","jinja","hbs","handlebars","mustache","njk","liquid","js","ts","jsx","tsx","svelte","php"]);
      const L=require("fs").readFileSync(process.argv[1],"utf8").split("\n");
      const cnt=s=>(s.replace(/`[^`]*`/g,"``").match(/\{\{[^{}\n]{1,200}\}\}/g)||[]).length;
      let inF=false,lang="",n=0;
      for(const raw of L){ const m=/^\s{0,3}(?:```|~~~)(.*)$/.exec(raw);
        if(m){ if(!inF){ lang=(m[1].trim().split(/\s+/)[0]||"").toLowerCase(); n+=cnt(raw); } inF=!inF; continue; }
        if(!inF||!EX.has(lang)) n+=cnt(raw); }
      console.log(n);' "$1"
}
fall() { # <json> → 所有 finding 的行号，升序空格分隔
    printf '%s' "$1" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let j;try{j=JSON.parse(s)}catch{return console.log("PARSE_ERROR")}console.log([...new Set((j.findings||[]).map(x=>x.line))].sort((a,b)=>a-b).join(" "))})'
}
sfall() { # <spec 文件> → spec-lint 报出的行号，升序空格分隔（两闸 code 词表不同，只能按行号对拍）
    node "$SRC/harness/harness.mjs" spec-lint --file "$1" 2>/dev/null | tail -1 \
      | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let j;try{j=JSON.parse(s)}catch{return console.log("PARSE_ERROR")}console.log([...new Set((j.findings||[]).map(x=>x.line))].sort((a,b)=>a-b).join(" "))})'
}
fcnt() { # <json> <code> → 该 code 的 finding 条数
    printf '%s' "$1" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let j;try{j=JSON.parse(s)}catch{return console.log(-1)}console.log((j.findings||[]).filter(x=>x.code===process.argv[1]).length)})' -- "$2"
}

RC=0
OUT=""
run_json() { OUT=$(node "$LINT" --root "$1" --json 2>&1); RC=$?; }
run_plain() { OUT=$(node "$LINT" --root "$1" 2>&1); RC=$?; }

# ---------------------------------------------------------------------------
# 夹具：五份合规文档 + 逐条规则的单点变异
# ---------------------------------------------------------------------------
write_spec() { # <dir> [variant]
    local d=$1 v=${2:-good}
    {
        printf '%s\n' '# 派单小工具 Product Spec' ''
        printf '%s\n' '## 产品概述' '给三人售后班组用的派单小工具：组长派单，师傅回单。' ''
        printf '%s\n' '## 应用场景：工作现状故事' '- 早上八点，组长在群里往回翻消息，找昨天没关掉的单。'
        [ "$v" != tpl_angle ] || printf '%s\n' "$TPL_LINE" '并发 < 100 且 延迟 > 1s' '数据量 <10 万行，单表 >100 万行' '<=3 个>'
        [ "$v" != curly ] || printf '%s\n' '产品定位：{{产品一句话}}' '写法示例 `{{产品一句话}}` 只是举例' \
                                          '```text' '文本围栏：{{文本围栏里的槽}}' '```' \
                                          '```html' '<b>{{ 模板语言里的槽 }}</b>' '```'
        printf '%s\n' ''
        if [ "$v" = align_crit ]; then
            printf '%s\n' '## 成功判据' '| 判据 | 目标 |' '|:--|--:|' '| 派单不漏 | 0 单 |'
        else
        printf '%s\n' '## 成功判据' '| 判据 | 度量 | 目标 |' '| --- | --- | --- |'
        case "$v" in
            empty_criteria) ;;
            cmp|cmp_angle)  printf '%s\n' '| SC-1 首屏 | 首屏 <1s | 并发 >100 |' ;;
            tpl_angle)      printf '%s\n' '| 首屏 <1s | 并发 >100 | 0 |' ;;
            *)              printf '%s\n' '| 派单不漏 | 每日未派单数 | 0 |' ;;
        esac
        fi
        printf '%s\n' ''
        printf '%s\n' '## 范围与非目标' '- [SCOPE-1] 只做派单与回单，不做库存。' ''
        printf '%s\n' '## 功能需求'
        case "$v" in
            no_mark)     printf '%s\n' '- 派单：组长选单 -> 指派师傅 -> 师傅手机收到' ;;
            pending_req) printf '%s\n' '- [确认] 派单：组长选单 -> 指派师傅 -> 师傅手机收到' \
                                       '- [默认] 导出：组长点导出 -> 下载文件，导出格式 [待定]' ;;
            *)           printf '%s\n' '- [确认] 派单：组长选单 -> 指派师傅 -> 师傅手机收到' \
                                       '- [推断] 回单：师傅传照片 -> 系统记完成时间' ;;
        esac
        printf '%s\n' ''
        if [ "$v" != drop_rules ]; then
            printf '%s\n' '## 规则与例外' '- 规则：一单只挂一个当班师傅。' '- 例外：老张不在时，退回组长。' ''
        fi
        printf '%s\n' '## 关键流程' '- [FLOW-1] 派单：接单 -> 派单 -> 回单 -> 归档' ''
        printf '%s\n' '## 决策依据'
        case "$v" in
            bare_pending) printf '%s\n' '- 导出格式待定，先按组长口头说的来。' ;;
            angle|cmp_angle) printf '%s\n' '- 存储选型：<数据库选型>' ;;
            *)            printf '%s\n' '- 选 CSV 不选 Excel：班组只在手机上看。' ;;
        esac
        printf '%s\n' ''
        printf '%s\n' '## 技术方向' '| 维度 | 选择 | 理由 |' '| --- | --- | --- |' '| 前端 | 移动端网页 | 师傅只有手机 |' ''
        if [ "$v" = fence ]; then
            printf '%s\n' '示例配置（围栏内不该被扫）：' '```ts' 'const x: Array<Thing> = [];' '// TODO: 驱动待选' '```' \
                          '- 行内反引号里的 `<占位示例>` 与 `TBD` 只是举例，不是没写完。' ''
        fi
        case "$v" in
            pending_decoy|numbered_pending|pending_param)
                printf '%s\n' '## 待定问题的填法说明' '| 问题 | 谁能定 | 何时 |' '| --- | --- | --- |' \
                              '| 示例问题 | 用户 | Phase 2 |' '' ;;
        esac
        # 真段标题带序号写法（## 1) 待定问题）——归一化要吃得下 ) 与 ．，不然锚点又被诱饵抢走
        case "$v" in
            numbered_pending) printf '%s\n' '## 1) 待定问题' ;;
            pending_param)    printf '%s\n' "${PENDING_HEAD:-## 待定问题}" ;;
            *)                printf '%s\n' '## 待定问题' ;;
        esac
        printf '%s\n' '| 问题 | 领域 | 谁能定 | 何时需要 | 临时默认 |' '| --- | --- | --- | --- | --- |'
        case "$v" in
            row_short|pending_decoy|numbered_pending|pending_param) printf '%s\n' '| Q-2 电话可见范围 | 数据权限 | | | |' ;;
            angle_row) printf '%s\n' '| <还没想好的问题> | 派单 | 老王 | 上线前 | 按 A |' ;;
            pending_marks) printf '%s\n' '| 待补 | 派单 | 老王 | 上线前 | 按 A |' \
                                         '| TBD: 还没定的那条 | 派单 | 老王 | 上线前 | 按 A |' ;;
            esc_pipe)  printf '%s\n' '| 用 A \\| B 哪个 | 派单 | 老王 | 上线前 | 按 A |' ;;
            six_cells) printf '%s\n' '| 六格但一个空格都没有 | 派单 | 老王 | 上线前 | 按 A | 多出来的一格 |' ;;
            *)         printf '%s\n' '| Q-1 老张不在时怎么走 | 派单规则 | 用户 | Phase 2 前 | 退回组长 |' ;;
        esac
        [ "$v" != pending_bypass ] || printf '%s\n' '' '### 附：验收清单' 'TBD: 验收标准还没写' '- TODO' '待补' '<这里还没填>'
        printf '%s\n' ''
        printf '%s\n' '## 澄清记录' '- 2026-09-09 与组长确认：一单一师傅。'
        case "$v" in
            unclosed)   printf '%s\n' '' '```' '模块清单：<还没定的模块>' ;;
            closed_ctl) printf '%s\n' '' '```' '模块清单：<还没定的模块>' '```' ;;
            fences)     printf '%s\n' '' '```' '无标签围栏：{{x}}' '```' '' '```markdown' '示例围栏：{{y}}' '```' '' \
                                       '```html' '<b>{{ label }}</b>' '```' '' '```{{lang}}' 'z' '```' ;;
            fence_bq)   printf '%s\n' '' '围栏外反引号：主色用 `{{品牌主色}}`。' \
                                       '```' '围栏内反引号：主色用 `{{品牌主色}}`。' '```' ;;
        esac
    } > "$d/Product-Spec.md"
}

write_brief() { # <dir> [variant]
    local d=$1 v=${2:-good}
    {
        printf '%s\n' '# Design Brief' ''
        printf '%s\n' '## 设计方向' '克制、信息优先，手机上单手能用。' ''
        printf '%s\n' '## 信息架构'
        if [ "$v" = no_screen ]; then
            printf '%s\n' '- 一级是派单列表，二级是回单详情。'
        else
            printf '%s\n' '- SCREEN-1 派单列表' '- SCREEN-2 回单详情'
        fi
        printf '%s\n' '' '## 页面规格'
        if [ "$v" = no_screen ]; then
            printf '%s\n' '- 列表页用卡片流。' ''
        else
            printf '%s\n' '### SCREEN-1 派单列表'
            [ "$v" = screen_incomplete ] || printf '%s\n' '**必需状态**：加载中 / 空 / 出错 / 正常'
            printf '%s\n' '**响应式**：768px 以下单列，768px 及以上两栏'
            if [ "$v" = dangling ]; then
                printf '%s\n' '对应 FLOW-9 与 SCOPE-7。'
            else
                printf '%s\n' '对应 FLOW-1 与 SCOPE-1。'
            fi
            printf '%s\n' '' '### SCREEN-2 回单详情' '**必需状态**：加载中 / 空 / 出错 / 正常' '**响应式**：768px 以下单列' ''
        fi
        printf '%s\n' '## 组件规格' '- 派单卡片：标题 + 状态徽标 + 主按钮' ''
        printf '%s\n' '## 交互与反馈' '- 点派单后 200ms 内出 loading，失败原地报错。' ''
        printf '%s\n' '## 文案' '- 空态：今天没有要派的单' ''
        printf '%s\n' '## 可访问性与响应式' '- 触控目标不小于 44px，正文对比度不低于 4.5:1。' ''
        printf '%s\n' '## 假设与待确认' '- 假设师傅都在微信内置浏览器里打开。'
        [ "$v" != md_fence ] || printf '%s\n' '' '```markdown' '- 卡片标题：{{页面名}}' '```'
        [ "$v" != fence_bq ] || printf '%s\n' '' '## 附录 B' '围栏外反引号：主色用 `{{品牌主色}}`。' \
                                              '```' '围栏内反引号：主色用 `{{品牌主色}}`。' '```'
    } > "$d/Design-Brief.md"
}

write_design() { # <dir> [variant]
    local d=$1 v=${2:-good} txt
    case "$v" in
        numbered|dup_token|angle_space|backtick_token|paren_sections|noncanon_section|dup_numbered|fm_slot|fence_slot)
            {
                printf '%s\n' '---' 'name: 派单小工具' 'colors:' '  primary: "#1F6FEB"' '  surface: "#FFFFFF"'
                [ "$v" != fm_slot ] || printf '%s\n' 'radius:' '  sm: {{px}}'
                printf '%s\n' 'typography:' '  body:' '    family: system-ui' '---' ''
                case "$v" in
                    dup_token) printf '%s\n' '## Overview' '基调克制。' '' '## Colors' '一 {colors.nope}' '二 {colors.nope}' '三 {colors.nope}' '' \
                                             "## Do's and Don'ts" '- 不要引入第二主色。' ;;
                    numbered)  printf '%s\n' '## 1. Overview' '基调克制。' '' '## 3. Typography' '正文 {typography.body.family}。' '' \
                                             '## 2. Colors' '主色 {colors.primary}。' '' '## 2. Colors' '这一段是重复的标题。' '' \
                                             "## 8. Do's and Don'ts" '- 不要引入第二主色。' ;;
                    angle_space) printf '%s\n' '## Overview' '存储选型：< 数据库选型 >' '并发 < 100 且 延迟 > 1s' '' \
                                               "## Do's and Don'ts" '- 不要引入第二主色。' ;;
                    backtick_token) printf '%s\n' '## Overview' '写法示例 `{colors.nope}` 只是举例' '真的写错了 {colors.nope}' '' \
                                                  "## Do's and Don'ts" '- 不要引入第二主色。' ;;
                    paren_sections) printf '%s\n' '## Overview' '基调克制。' '' '## Colors（浅色）' '主色 {colors.primary}。' '' \
                                                  '## Colors（深色）' '底色 {colors.surface}。' '' "## Do's and Don'ts" '- 不要引入第二主色。' ;;
                    noncanon_section) printf '%s\n' '## Overview' '基调克制。' '' '## Downloads' '下载区：字体与图标包。' '' \
                                                    '## Colors' '主色 {colors.primary}。' '' '## Typography' '正文 {typography.body.family}。' '' \
                                                    "## Do's and Don'ts" '- 不要引入第二主色。' ;;
                    dup_numbered) printf '%s\n' '## Overview' '基调克制。' '' '## 2. Colors' '主色 {colors.primary}。' '' \
                                                '## 2. Colors' '这一段是重复的标题。' '' "## Do's and Don'ts" '- 不要引入第二主色。' ;;
                    fm_slot)    printf '%s\n' '## Overview' '基调克制。' '' '## Colors' '主色 {colors.nope}。' '' \
                                              "## Do's and Don'ts" '- 不要引入第二主色。' ;;
                    fence_slot) printf '%s\n' '## Overview' '基调克制。' '' '## Shapes' '```css' '.card { border-radius: {{px}}; }' '```' '' \
                                              "## Do's and Don'ts" '- 不要引入第二主色。' ;;
                esac
            } > "$d/DESIGN.md"
            return ;;
    esac
    case "$v" in
        unresolved) txt='主色 {colors.accent}，背景 {colors.surface}。' ;;
        no_primary) txt='主色按品牌色走，背景 {colors.surface}。' ;;
        hyphen)     txt='主色 {colors.primary}，前景 {colors.on-surfase}。' ;;
        *)          txt='主色 {colors.primary}，背景 {colors.surface}。' ;;
    esac
    {
        if [ "$v" != no_fm ]; then
            printf '%s\n' '---' 'name: 派单小工具' 'colors:'
            [ "$v" = no_primary ] || printf '%s\n' '  primary: "#1F6FEB"'
            printf '%s\n' '  surface: "#FFFFFF"' 'typography:' '  body:' '    family: system-ui'
            [ "$v" != composite ] || printf '%s\n' '    size: "16px"'
            printf '%s\n' '---' ''
        fi
        printf '%s\n' '## Overview' '基调克制，颜色只用来分状态。' ''
        if [ "$v" = order ]; then
            printf '%s\n' '## Typography' '正文 {typography.body.family}。' '' '## Colors' "$txt" ''
        else
            printf '%s\n' '## Colors' "$txt" '' '## Typography' '正文 {typography.body.family}。' ''
        fi
        printf '%s\n' '## Layout' '8px 栅格，页边距 16px。' ''
        printf '%s\n' '## Elevation & Depth' '只有一级阴影，用于浮层。' ''
        printf '%s\n' '## Shapes' '圆角 8px。' ''
        printf '%s\n' '## Components' '按钮、卡片、状态徽标。'
        [ "$v" != composite ] || printf '%s\n' '- 标签排版：typography: "{typography.body}"'
        printf '%s\n' ''
        [ "$v" != dup ] || printf '%s\n' '## Colors' '这一段是重复的标题。' ''
        printf '%s\n' "## Do's and Don'ts" '- 不要引入第二主色。'
    } > "$d/DESIGN.md"
}

write_arch() { # <dir> [variant]
    local d=$1 v=${2:-good}
    # madr* 变体照 architecture-design-template.md 的真实长相写：编号二级标题 + MADR 形态的 ADR 块
    if [ "$v" = madr ] || [ "$v" = madr_no_dep ]; then
        {
            printf '%s\n' '# Architecture Design — 派单小工具' ''
            printf '%s\n' '## 1. 架构概览' '单体 Web + SQLite，一个进程。' ''
            printf '%s\n' '## 2. 模块划分' '- dispatch：派单' '- report：回单' ''
            [ "$v" = madr_no_dep ] || printf '%s\n' '## 3. 依赖规则' '- report 不得反向依赖 dispatch 的内部模型。' ''
            printf '%s\n' '## 7. 运行与部署包络' '- 单进程，2 核 2G 起，日备份一次。' ''
            printf '%s\n' '## 8. 关键决策记录（ADR）' '### ADR-1：用 SQLite 而不是 PostgreSQL' \
                          '- **状态**：accepted' \
                          '- **背景与问题**：三人班组日单量两位数，dispatch 与 report 共用一份单据表。' \
                          '- **决策驱动**：运维成本、故障后果可接受、团队只有一个后端。' \
                          '- **候选与优劣**：' \
                          '  - SQLite：好——零运维，单文件备份；坏——写并发受限。' \
                          '  - PostgreSQL：好——并发与扩展好；坏——三人班组养不起。' \
                          '- **决策**：选 SQLite，因为满足了运维成本这条驱动。' \
                          '- **后果**：好——部署只有一个文件；坏——将来单量上千要迁移。' \
                          '- **被拒备选与理由**：PostgreSQL，因为运维成本对三人班组过高。' \
                          '- **执法方式**：人工评审' ''
        } > "$d/Architecture-Design.md"
        return
    fi
    {
        printf '%s\n' '# 架构设计' ''
        printf '%s\n' '## 架构概览' '单体 Web + SQLite，一个进程。' ''
        printf '%s\n' '## 模块划分' '- dispatch：派单' '- report：回单' ''
        printf '%s\n' '## 依赖规则' '- report 不得反向依赖 dispatch 的内部模型。' ''
        printf '%s\n' '## 关键决策记录' '### ADR-1 用 SQLite 而不是 PostgreSQL' \
                      '**背景**：三人班组，日单量两位数。' \
                      '**决策**：用 SQLite 单文件。' \
                      '**被拒备选**：PostgreSQL——运维成本对三人班组过高。'
        [ "$v" = adr_incomplete ] || printf '%s\n' '**执法方式**：CI 里禁止引入 pg 依赖。'
        printf '%s\n' ''
        printf '%s\n' '## 运行与部署包络' '- 单进程，2 核 2G 起，日备份一次。'
        case "$v" in
            cmp)              printf '%s\n' '' '## 押后决定' '| 决定 | 为什么可以等 |' '| --- | --- |' \
                                            '| 分库 | 数据量 <10 万行，单表 >100 万行时回来定 |' ;;
            deferred_pending) printf '%s\n' '' '## 押后决定' '| 决定 | 为什么可以等 |' '| --- | --- |' \
                                            '| 分库 | 数据量待定，先不拆 |' ;;
        esac
    } > "$d/Architecture-Design.md"
}

write_dfx() { # <dir> [variant]
    local d=$1 v=${2:-good}
    {
        printf '%s\n' '# DFX Spec' ''
        printf '%s\n' '## 优先级栈' '1. 可靠性：派单不能丢'
        [ "$v" = short_stack ] || printf '%s\n' '2. 可服务性：现场能自查' '3. 性能：列表 1 秒内出'
        printf '%s\n' ''
        if [ "$v" = align_sep ]; then
            printf '%s\n' '## 维度总表' '| 维度 | 档位 | 度量 |' '|:-:|:-:|:-:|' '| 可靠性 | high | 说不清 |' ''
        elif [ "$v" = two_col_extra ] || [ "$v" = empty_metric ] || [ "$v" = cmp ]; then
            printf '%s\n' '## 维度总表' '| 维度 | 档位 | 度量 | 验证落点 |' '| --- | --- | --- | --- |'
            case "$v" in
                empty_metric) printf '%s\n' '| 可服务性 | medium |  | 现场演练 |' '' ;;
                cmp)          printf '%s\n' '| 性能 | medium | P95 <200ms，错误率 >0.1% | 压测一次 |' '' ;;
                *)            printf '%s\n' '| 可靠性 | high | 丢单率 0 | 回归测试 |' '' \
                                            '| 项 | 值 |' '| --- | --- |' '| 备注 | 见上表 |' '' ;;
            esac
        elif [ "$v" = numbered_title ]; then
            printf '%s\n' '## 2. 维度总表（十三维）' '| 维度 | 档位 | 场景 | 责任模块 | 手段 | 度量 |' '| --- | --- | --- | --- | --- | --- |' \
                          '| 可靠性 | high | 派单不丢 | dispatch | 写前落盘 |  |' ''
        else
        printf '%s\n' '## 维度总表'
        if [ "$v" = verify_col ]; then
            # dfx-spec-template.md 的总表最后一列是「验证落点」，度量排在中间
            printf '%s\n' '| 维度 | 档位 | 场景 | 度量 | 设计对策 | 验证落点 |' '| --- | --- | --- | --- | --- | --- |' \
                          '| 可靠性 | high | 派单不丢 | 丢单率 0 | 写前落盘 | 回归测试 |' \
                          '| 可服务性 | medium | 现场排障 | 定位耗时 N/A | 结构化日志 | 现场演练 |' ''
        else
            printf '%s\n' '| 维度 | 档位 | 场景 | 责任模块 | 手段 | 度量 |' '| --- | --- | --- | --- | --- | --- |'
            if [ "$v" = unmeasured ]; then
                printf '%s\n' '| 可靠性 | high | 派单不丢 | dispatch | 写前落盘 | 尽量不丢 |'
            else
                printf '%s\n' '| 可靠性 | high | 派单不丢 | dispatch | 写前落盘 | 丢单率 0 |'
            fi
            printf '%s\n' '| 可服务性 | medium | 现场排障 | report | 结构化日志 | 定位耗时 N/A |' ''
        fi
        fi
        printf '%s\n' '## 取舍记录' '- 放弃多副本：三人班组不值当，接受单点。'
    } > "$d/DFX-Spec.md"
}

seed_all() { write_spec "$1"; write_brief "$1"; write_design "$1"; write_arch "$1"; write_dfx "$1"; }

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

# ---------------------------------------------------------------------------
# P0 被测脚本本身
# ---------------------------------------------------------------------------
if [ -f "$LINT" ]; then
    chk 0 "P0 被测脚本存在：$LINT" "predev-lint.mjs 存在" "存在"
else
    chk 1 "P0 被测脚本存在：$LINT" "predev-lint.mjs 存在" "不存在——下面每条都会红，红因是功能缺失"
fi

# ---------------------------------------------------------------------------
# 接受用例：合规文档必须放行（防「一律判红」的假闸）
# ---------------------------------------------------------------------------
D=$(newdir); seed_all "$D"
expect_clean "$D" "P1 五份全合规 → 放行"

D=$(newdir); write_spec "$D" fence
expect_clean "$D" "P2 围栏块内的 <Thing>/TODO 与行内反引号里的 TBD 不算占位"

D=$(newdir); seed_all "$D"; write_brief "$D" dangling
run_json "$D"
if [ "$RC" -eq 0 ] && contains DANGLING_REF "$OUT"; then r=0; else r=1; fi
chk "$r" "P12 Brief 引用 Spec 里没有的 FLOW-9 → 只是 warning，不阻断" \
    "rc=0 且 --json 含 DANGLING_REF" \
    "rc=$RC；含 DANGLING_REF=$(contains DANGLING_REF "$OUT" && echo yes || echo no)；输出：$(brief "$OUT")"

D=$(newdir); write_design "$D"
run_plain "$D"
if [ "$RC" -eq 0 ] && contains '跳过' "$OUT"; then r=0; else r=1; fi
chk "$r" "P22 只有 DESIGN.md：另外四份缺 → 跳过，不当错" "rc=0 且输出含「跳过」" "rc=$RC；输出：$(brief "$OUT")"

D=$(newdir)
run_plain "$D"
if [ "$RC" -eq 0 ] && contains '跳过' "$OUT"; then r=0; else r=1; fi
chk "$r" "P21 空目录 → 无前期文档，跳过" "rc=0 且输出含「跳过」" "rc=$RC；输出：$(brief "$OUT")"

D=$(newdir)
if [ -f "$EXAMPLE" ]; then
    cp "$EXAMPLE" "$D/Product-Spec.md"
    expect_clean "$D" "P24 模板自洽：随 skill 发布的示例 Spec 必须过自己的闸"
else
    echo "  [NOTE] P24 跳过：示例 Spec 不在 $EXAMPLE"
fi

# ---------------------------------------------------------------------------
# 拒绝用例：一条规则一份坏样例，每条单点变异
# ---------------------------------------------------------------------------
D=$(newdir); write_spec "$D" no_mark;        expect_code "$D" NO_SOURCE_MARK         "P3 功能条目没有 [确认]/[推断]/[默认] 来源标记"
D=$(newdir); write_spec "$D" pending_req;    expect_code "$D" PENDING_IN_REQUIREMENT "P4 功能条目里挂着 [待定]"
D=$(newdir); write_spec "$D" row_short;      expect_code "$D" PENDING_ROW_INCOMPLETE "P5 待定问题表行有空格子（没人认领、没有时限）"
D=$(newdir); write_spec "$D" bare_pending;   expect_code "$D" PLACEHOLDER            "P6 待定问题段之外出现裸「待定」"
D=$(newdir); write_spec "$D" empty_criteria; expect_code "$D" NO_SUCCESS_CRITERIA    "P7 成功判据只有表头没有数据行"
D=$(newdir); write_spec "$D" drop_rules;     expect_code "$D" MISSING_SECTION        "P8 缺「规则与例外」必需段"
D=$(newdir); write_spec "$D" angle;          expect_code "$D" PLACEHOLDER            "P9 <数据库选型> 这类尖括号占位"

D=$(newdir); write_brief "$D" no_screen;         expect_code "$D" NO_SCREEN        "P10 Brief 的信息架构里一个 SCREEN-n 都没有"
D=$(newdir); write_brief "$D" screen_incomplete; expect_code "$D" SCREEN_INCOMPLETE "P11 SCREEN 块缺 **必需状态**"

D=$(newdir); write_design "$D" no_fm;      expect_code "$D" NO_FRONTMATTER   "P13 DESIGN.md 没有前言"
D=$(newdir); write_design "$D" order;      expect_code "$D" SECTION_ORDER    "P14 DESIGN.md 规范八段顺序颠倒"
D=$(newdir); write_design "$D" dup;        expect_code "$D" DUPLICATE_SECTION "P15 DESIGN.md 有重复的 ## 标题"
D=$(newdir); write_design "$D" unresolved; expect_code "$D" UNRESOLVED_TOKEN "P16 {colors.accent} 在前言里解析不到"
D=$(newdir); write_design "$D" no_primary; expect_code "$D" MISSING_TOKEN    "P17 前言缺 colors.primary"

D=$(newdir); write_arch "$D" adr_incomplete; expect_code "$D" ADR_INCOMPLETE "P18 ADR 块缺 **执法方式**（写了不落地等于没写）"

D=$(newdir); write_dfx "$D" unmeasured;  expect_code "$D" UNMEASURED               "P19 维度总表的度量列「尽量不丢」不含数字也不是 N/A"
D=$(newdir); write_dfx "$D" short_stack; expect_code "$D" PRIORITY_STACK_TOO_SHORT "P20 优先级栈只有 1 项（没排序等于没取舍）"

D=$(newdir); seed_all "$D"
OUT=$(node "$LINT" --root "$D" --bogus 2>&1); RC=$?
if [ "$RC" -eq 2 ]; then r=0; else r=1; fi
chk "$r" "P23 未知参数 → rc 2" "rc=2" "rc=$RC；输出：$(brief "$OUT")"

# ---------------------------------------------------------------------------
# 红锁：三个已核实的缺陷。断言写「修好之后应该成立的行为」，所以现在必红——
#   红因是功能缺失，不是夹具写歪：每条旁边都标了「把致红那一处换成同族的合规写法就绿」。
# ---------------------------------------------------------------------------
D=$(newdir); write_design "$D" hyphen
expect_code "$D" UNRESOLVED_TOKEN \
    "P25 带连字符的记号写错也要报：{colors.on-surfase} 解析不到（规范里 colors.primary-60 这类名字本就带连字符）"

D=$(newdir); write_design "$D" composite
expect_clean "$D" "P26 Components 段引用复合值 {typography.body} 是规范许可的（design.md 第 98 行），不许误报成解析不到"

D=$(newdir); write_dfx "$D" verify_col
expect_clean "$D" "P27 度量列按表头定位：总表最后一列是「验证落点」时，度量在中间列，不许判 UNMEASURED"

# P28/P29 修后的匹配口径（写在这里供实现者对齐，别各猜各的）：
#   ADR 标签——`**背景` 与 `**被拒备选` 按前缀匹配（吃得下「背景与问题」「被拒备选与理由」）；
#             `**决策**` 精确匹配，只有 `**决策驱动**` 而没有 `**决策**` 的块仍该判缺；`**执法方式**` 精确。
#   必需段——按 includes 匹配二级标题，五个：架构概览 / 模块划分 / 依赖规则 / 运行与部署包络 / 关键决策记录。
D=$(newdir); write_arch "$D" madr
expect_clean "$D" "P28 ADR 按模板的 MADR 标签写全（背景与问题 / 决策驱动 / 候选与优劣 / 决策 / 后果 / 被拒备选与理由 / 执法方式）→ 不许判 ADR_INCOMPLETE"

D=$(newdir); write_arch "$D" madr_no_dep
expect_code "$D" MISSING_SECTION "P29 Architecture-Design.md 缺「## 3. 依赖规则」必需段（五段缺一即红，现在 lintArch 根本不查段）"

# P30 修后口径：段标题行豁免；表行只查五格齐；段内其余行照常扫尖括号 / TBD / TODO / 待补，
#   只有「待定」二字不报。现状是整段（含子段）免检，等于给未完成内容开了条后门。
#   顺带锁缺陷 D：尖括号在段内也要报——spec-lint 那边本来就报，两个闸不能各说各话。
D=$(newdir); write_spec "$D" pending_bypass
F="$D/Product-Spec.md"
WANT="$(lineno "$F" '^TBD: ') $(lineno "$F" '^- TODO$') $(lineno "$F" '^待补$') $(lineno "$F" '这里还没填')"
HEADL=$(lineno "$F" '^## 待定问题$')
run_json "$D"; GOTL=$(fjq "$OUT" PLACEHOLDER)
if [ "$RC" -eq 1 ] && [ "$GOTL" = "$WANT" ]; then r=0; else r=1; fi
chk "$r" "P30 待定问题段里挂个「### 附：验收清单」子段，TBD / TODO / 待补 / 尖括号就整段免检了" \
    "rc=1 且 PLACEHOLDER 恰在第 $WANT 行（段标题行 $HEADL 不许报）" \
    "rc=$RC；PLACEHOLDER 行=[$GOTL]"

# P31 修后口径：标题去掉前导编号（2. / 2.1）与尾部括注（（十三维））后与段名相等者优先，
#   无则退回 includes 首个命中。现状 includes 让诱饵段抢走锚点：诱饵表被误报三条
#   （表头行 / 分隔行 / 数据行都是 3 格），真段标题反被当正文报 PLACEHOLDER，真正缺三格那行零输出。
D=$(newdir); write_spec "$D" pending_decoy
F="$D/Product-Spec.md"
ROWL=$(lineno "$F" 'Q-2 电话可见范围')
HEADL=$(lineno "$F" '^## 待定问题$')
run_json "$D"
PRI=$(fjq "$OUT" PENDING_ROW_INCOMPLETE); PH=$(fjq "$OUT" PLACEHOLDER)
r=0
[ "$RC" -eq 1 ] || r=1
[ "$PRI" = "$ROWL" ] || r=1
case " $PH " in *" $HEADL "*) r=1 ;; esac
chk "$r" "P31 「## 待定问题的填法说明」排在真段之前时，锚点不许被诱饵段抢走" \
    "rc=1 且 PENDING_ROW_INCOMPLETE 恰一条指向第 $ROWL 行；真段标题行 $HEADL 不在 PLACEHOLDER 里" \
    "rc=$RC；PENDING_ROW_INCOMPLETE 行=[$PRI]；PLACEHOLDER 行=[$PH]"

# P32 是**防回归位，现在就绿**：锁的是修 sectionNamed 时别把 includes 兜底弄丢——
#   带编号带括注的「## 2. 维度总表（十三维）」仍须命中「维度总表」。绿不代表已实现新口径。
D=$(newdir); write_dfx "$D" numbered_title
expect_code "$D" UNMEASURED "P32 防回归位：「## 2. 维度总表（十三维）」这种带编号带括注的标题仍要命中段名"

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

# ---------------------------------------------------------------------------
# 第四批红锁：复审第二轮的发现。口径见 progress.md 2026-09-10 Decisions。
# ---------------------------------------------------------------------------
# P34 阈值比较式不是模板占位：候选内含 | ，或 < 后紧跟数字 / = / 空白 / - ，一律当比较式放过。
D=$(newdir); write_spec "$D" cmp; write_arch "$D" cmp; write_dfx "$D" cmp
expect_clean "$D" "P34 首屏 <1s / 数据量 <10 万行 / P95 <200ms 是阈值比较式，不是没填的模板占位"

D=$(newdir); write_spec "$D" cmp_angle; write_arch "$D" cmp; write_dfx "$D" cmp
run_json "$D"; N=$(fcnt "$OUT" PLACEHOLDER)
if [ "$RC" -eq 1 ] && [ "$N" = 1 ] && contains 数据库选型 "$OUT"; then r=0; else r=1; fi
chk "$r" "P34b 防修过头：放过比较式之后，真占位 <数据库选型> 仍须报，且只报它一条" \
    "rc=1 且 PLACEHOLDER 恰 1 条、指着 <数据库选型>" "rc=$RC；PLACEHOLDER 条数=$N；输出：$(brief "$OUT")"

# P35 「## 1) 待定问题」——归一化正则要吃下 ) 与 ．，否则诱饵段又抢走锚点。
#   两闸报同一组行号：诱饵段标题（段外的裸「待定」）报、诱饵表不报、真段标题不报、真段缺格行报。
D=$(newdir); write_spec "$D" numbered_pending
F="$D/Product-Spec.md"
DECOYH=$(lineno "$F" '^## 待定问题的填法说明$'); REALH=$(lineno "$F" '^## 1) 待定问题$'); ROWL=$(lineno "$F" 'Q-2 电话可见范围')
run_json "$D"; PRI=$(fjq "$OUT" PENDING_ROW_INCOMPLETE); PH=$(fjq "$OUT" PLACEHOLDER)
r=0; [ "$RC" -eq 1 ] || r=1; [ "$PRI" = "$ROWL" ] || r=1; [ "$PH" = "$DECOYH" ] || r=1
chk "$r" "P35 真段标题写成「## 1) 待定问题」时，锚点不许被诱饵段抢走（两闸同判）" \
    "rc=1；PENDING_ROW_INCOMPLETE=[$ROWL]；PLACEHOLDER=[$DECOYH]（真段标题 $REALH 与诱饵表都不报）" \
    "rc=$RC；PENDING_ROW_INCOMPLETE=[$PRI]；PLACEHOLDER=[$PH]"

# P36 待定问题表行只豁免「待定」二字，尖括号 / TBD / TODO / 待补 照常扫；五格齐所以不叠格数那条。
D=$(newdir); write_spec "$D" angle_row
F="$D/Product-Spec.md"; ROWL=$(lineno "$F" '还没想好的问题')
run_json "$D"; PH=$(fjq "$OUT" PLACEHOLDER); PRI=$(fjq "$OUT" PENDING_ROW_INCOMPLETE)
if [ "$RC" -eq 1 ] && [ "$PH" = "$ROWL" ] && [ -z "$PRI" ]; then r=0; else r=1; fi
chk "$r" "P36 待定问题表行里的尖括号照报（整行免检等于给未填内容开后门）" \
    "rc=1；PLACEHOLDER=[$ROWL]；PENDING_ROW_INCOMPLETE 为空（这行五格齐）" \
    "rc=$RC；PLACEHOLDER=[$PH]；PENDING_ROW_INCOMPLETE=[$PRI]"

# P37 段序与重复都要在归一化之后比：DUPLICATE 现在就能报（防修过头位），SECTION_ORDER 现在报不出来。
D=$(newdir); write_design "$D" numbered
run_json "$D"
if [ "$RC" -eq 1 ] && contains SECTION_ORDER "$OUT" && contains DUPLICATE_SECTION "$OUT"; then r=0; else r=1; fi
chk "$r" "P37 DESIGN.md 段标题带编号（## 1. Overview / ## 3. Typography / ## 2. Colors）时段序与重复仍要查" \
    "rc=1 且同时含 SECTION_ORDER 与 DUPLICATE_SECTION" \
    "rc=$RC；含 SECTION_ORDER=$(contains SECTION_ORDER "$OUT" && echo yes || echo no)；含 DUPLICATE_SECTION=$(contains DUPLICATE_SECTION "$OUT" && echo yes || echo no)"

# P38 维度总表段里跟着的第二张小表不是维度行，别拿正表的列下标去套它。
D=$(newdir); write_dfx "$D" two_col_extra
expect_clean "$D" "P38 维度总表段内追加的两列小表不许被当成缺度量的维度行"

D=$(newdir); write_dfx "$D" empty_metric
run_json "$D"
if [ "$RC" -eq 1 ] && contains UNMEASURED "$OUT" && contains 可服务性 "$OUT"; then r=0; else r=1; fi
chk "$r" "P38b 度量真为空时文案要点名是哪一维（现在只会说「度量「」」，读的人不知道改哪行）" \
    "rc=1 且 UNMEASURED 的文案含维度名「可服务性」" "rc=$RC；含可服务性=$(contains 可服务性 "$OUT" && echo yes || echo no)；输出：$(brief "$OUT")"

# P39 转义管道是格子里的字，不是分隔符。
D=$(newdir); write_spec "$D" esc_pipe
expect_clean "$D" "P39 待定问题表行里的 \\| 是内容不是分隔符，这行仍是五格"

D=$(newdir); write_spec "$D" six_cells
run_json "$D"
if [ "$RC" -eq 1 ] && contains PENDING_ROW_INCOMPLETE "$OUT" && ! contains 且有空格 "$OUT"; then r=0; else r=1; fi
chk "$r" "P39b 六格但一个空格都没有时，文案不许硬说「且有空格」" \
    "rc=1 含 PENDING_ROW_INCOMPLETE，且文案不含「且有空格」" \
    "rc=$RC；含「且有空格」=$(contains 且有空格 "$OUT" && echo yes || echo no)；输出：$(brief "$OUT")"

# P40 同一个错记号在正文出现三次，报三条只是噪音——去重按记号名，不按行。
D=$(newdir); write_design "$D" dup_token
run_json "$D"; N=$(fcnt "$OUT" UNRESOLVED_TOKEN)
if [ "$RC" -eq 1 ] && [ "$N" = 1 ]; then r=0; else r=1; fi
chk "$r" "P40 同一个 {colors.nope} 写了三行，只报一条（消息里提「另 N 处」随实现，不硬编）" \
    "rc=1 且 UNRESOLVED_TOKEN 恰 1 条" "rc=$RC；UNRESOLVED_TOKEN 条数=$N"

# P41 非 Spec 文档没有「待定问题」表可搬，文案指过去等于让人无处可去。
D=$(newdir); write_arch "$D" deferred_pending
run_json "$D"
if [ "$RC" -eq 1 ] && contains PLACEHOLDER "$OUT" && ! contains 待定问题 "$OUT" && contains 押后 "$OUT"; then r=0; else r=1; fi
chk "$r" "P41 Architecture-Design.md 里的裸「待定」，文案该说「押后」而不是让人搬进「待定问题」表" \
    "rc=1 含 PLACEHOLDER；文案不含「待定问题」、含「押后」" \
    "rc=$RC；含待定问题=$(contains 待定问题 "$OUT" && echo yes || echo no)；含押后=$(contains 押后 "$OUT" && echo yes || echo no)"

# ---------------------------------------------------------------------------
# 第五批红锁：复审第三轮。口径见 progress.md 2026-09-10 Decisions
#   「占位闸口径①细化 + 表格识别四条」。
# ---------------------------------------------------------------------------
# P42 比较式判据要跳过 < 后的空白再看首字符：是数字 / = / - 才算比较式。
#   现在拿原始首字符判，空格一律当比较式，于是「< 数据库选型 >」这种带空格的真占位溜过去了。
D=$(newdir); write_design "$D" angle_space
F="$D/DESIGN.md"; PHL=$(lineno "$F" '数据库选型'); CMPL=$(lineno "$F" '^并发 ')
run_json "$D"; PH=$(fjq "$OUT" PLACEHOLDER)
if [ "$RC" -eq 1 ] && [ "$PH" = "$PHL" ]; then r=0; else r=1; fi
chk "$r" "P42 「< 数据库选型 >」带空格也是占位；「并发 < 100 且 延迟 > 1s」仍是比较式" \
    "rc=1；PLACEHOLDER=[$PHL]（比较式那行 $CMPL 不许报）" "rc=$RC；PLACEHOLDER=[$PH]"

# P43 GFM 的分隔行单元格是 ^:?-+:?$，一个连字符也算；|:-:| 现在不认，整张表跟着失灵。
D=$(newdir); write_dfx "$D" align_sep
F="$D/DFX-Spec.md"; SEPL=$(lineno "$F" '^|:-:|'); ROWL=$(lineno "$F" '说不清')
run_json "$D"; UM=$(fjq "$OUT" UNMEASURED)
if [ "$RC" -eq 1 ] && [ "$UM" = "$ROWL" ]; then r=0; else r=1; fi
chk "$r" "P43 「|:-:|」是对齐分隔行：度量「说不清」要报，分隔行自身不许被当数据行" \
    "rc=1；UNMEASURED=[$ROWL]（分隔行 $SEPL 不许报）" "rc=$RC；UNMEASURED=[$UM]"

D=$(newdir); write_spec "$D" align_crit
expect_clean "$D" "P43b 防回归位（现在就绿）：成功判据用「|:--|--:|」分隔且有数据行时，不许报 NO_SUCCESS_CRITERIA"

# P44 反引号里的记号是举例，不是引用——正文教人怎么写的那行不该被当成写错了。
D=$(newdir); write_design "$D" backtick_token
F="$D/DESIGN.md"; BQL=$(lineno "$F" '写法示例'); BAREL=$(lineno "$F" '真的写错了')
run_json "$D"; UT=$(fjq "$OUT" UNRESOLVED_TOKEN); N=$(fcnt "$OUT" UNRESOLVED_TOKEN)
if [ "$RC" -eq 1 ] && [ "$N" = 1 ] && [ "$UT" = "$BAREL" ]; then r=0; else r=1; fi
chk "$r" "P44 反引号里的 {colors.nope} 是写法示例不扫；同份里裸写的那个才报" \
    "rc=1；UNRESOLVED_TOKEN 恰 1 条且在第 $BAREL 行（反引号那行 $BQL 不许报）" \
    "rc=$RC；条数=$N；UNRESOLVED_TOKEN=[$UT]"

# P45 重复段只去前导编号比对、保留括注；八段名整词匹配，非规范段直接忽略。
D=$(newdir); write_design "$D" paren_sections
expect_clean "$D" "P45 「## Colors（浅色）」与「## Colors（深色）」是两段，不是同一段写了两遍"

D=$(newdir); write_design "$D" noncanon_section
expect_clean "$D" "P45b 「## Downloads」不是 Do's and Don'ts，不许拿它把后面的段序带偏"

D=$(newdir); write_design "$D" dup_numbered
run_json "$D"
if [ "$RC" -eq 1 ] && contains DUPLICATE_SECTION "$OUT"; then r=0; else r=1; fi
chk "$r" "P45c 防修过头位（现在就绿）：「## 2. Colors」写两遍仍是重复段" \
    "rc=1 且含 DUPLICATE_SECTION" "rc=$RC；含 DUPLICATE_SECTION=$(contains DUPLICATE_SECTION "$OUT" && echo yes || echo no)"

# P46 防回归位：待定问题表行只豁免「待定」，待补 / TBD / TODO 照报。predev 侧现在就对，
#   钉住它是防「为了让两闸一致，反过来把 predev 放松」——同口径的 spec 侧在 selftest lane 里锁。
D=$(newdir); write_spec "$D" pending_marks
F="$D/Product-Spec.md"; AL=$(lineno "$F" '^| 待补 '); BL=$(lineno "$F" 'TBD: 还没定的那条')
run_json "$D"; PH=$(fjq "$OUT" PLACEHOLDER)
if [ "$RC" -eq 1 ] && [ "$PH" = "$AL $BL" ]; then r=0; else r=1; fi
chk "$r" "P46 防回归位（现在就绿）：待定表行里的「待补」与「TBD:」照报，只有「待定」二字豁免" \
    "rc=1；PLACEHOLDER=[$AL $BL]" "rc=$RC；PLACEHOLDER=[$PH]"

# ---------------------------------------------------------------------------
# 第六批红锁：复审第四轮。口径见 progress.md 2026-09-10 Decisions
#   「比较式判定看两侧 + 编号字符集 + rc 2 也不留旧证据」。
# 比较式要两侧都像：< 后跳空白首字符 ∈ 数字 / = / -，且配对的 > 后跳空白首字符
#   ∈ 数字 / = / - / $（货币符号）。> 落在行尾不算比较式——模板原句正是这一种。
# ---------------------------------------------------------------------------
TPL_LINE=$(grep -m1 '^<2-3 ' "$SRC/skills/product-spec-builder/templates/product-spec-template.md" 2>/dev/null)
TPL_SRC=模板原文
if [ -z "$TPL_LINE" ]; then
    TPL_LINE='<2-3 个真实发生过的案例，不写「一般来说」。每个案例：谁（有名字，可化名）→ 做什么 → 用什么 → 然后呢 → 为什么这么干。例外单独一段。>'
    TPL_SRC=内置副本
fi
D=$(newdir); write_spec "$D" tpl_angle
F="$D/Product-Spec.md"
TPLL=$(lineno "$F" '^<2-3 '); EQL=$(lineno "$F" '^<=3 个>$')
C1=$(lineno "$F" '^并发 < 100'); C2=$(lineno "$F" '^数据量 <10'); C3=$(lineno "$F" '首屏 <1s')
run_json "$D"; PH=$(fjq "$OUT" PLACEHOLDER)
if [ "$RC" -eq 1 ] && [ "$PH" = "$TPLL $EQL" ]; then r=0; else r=1; fi
chk "$r" "P47 模板原句「<2-3 个真实发生过的案例…>」是没填的占位（取自$TPL_SRC），不是比较式" \
    "rc=1；PLACEHOLDER=[$TPLL $EQL]（三行比较式 $C1 / $C2 / $C3 不许报）" \
    "rc=$RC；PLACEHOLDER=[$PH]"

# P48 七种编号写法逐一对拍。两闸的 code 词表本就不同（predev 用 PENDING_ROW_INCOMPLETE，
#   spec 用 PLACEHOLDER 表达同一件事），所以对拍判据是**行号集合**：同一份文档，
#   两个闸认定「有问题的行」必须是同一组，且都把真段（不是诱饵段）认作待定段。
if [ -f "$SRC/harness/harness.mjs" ]; then
    BAD=""; DETAIL=""
    for HEAD in '## 1）待定问题' '## 1) 待定问题' '## 1. 待定问题' '## 1、待定问题' '## 1．待定问题' '## 1.1 待定问题' '## 1)待定问题'; do
        D=$(newdir); PENDING_HEAD="$HEAD" write_spec "$D" pending_param
        F="$D/Product-Spec.md"
        DEC=$(lineno "$F" '^## 待定问题的填法说明$'); ROW=$(lineno "$F" 'Q-2 电话可见范围')
        run_json "$D"; PL=$(fall "$OUT"); SL=$(sfall "$F")
        if [ "$PL" != "$SL" ] || [ "$PL" != "$DEC $ROW" ]; then
            BAD="$BAD $HEAD"; DETAIL="$DETAIL；[$HEAD] predev=[$PL] spec=[$SL] 应为[$DEC $ROW]"
        fi
    done
    if [ -z "$BAD" ]; then r=0; else r=1; fi
    chk "$r" "P48 七种编号写法下两闸对拍：行号集合相同，且都把真段认作待定段" \
        "七种写法下 predev 与 spec 的行号集合都等于 [诱饵段标题 真段缺格行]" \
        "不一致的写法：${BAD:-无}${DETAIL}"
else
    echo "  [NOTE] P48 跳过：找不到 $SRC/harness/harness.mjs，两闸对拍需要 spec-lint"
fi

# ---------------------------------------------------------------------------
# 第七批红锁：复审第五轮。口径见 progress.md 2026-09-10 Decisions
#   「填槽语法统一为 {{…}} 并进占位闸」。方括号 […] 不进闸（复选框 - [ ] 与 mermaid 不受影响）。
# ---------------------------------------------------------------------------
# P49 五份模板原样拷成正式文件名，一份都不许放行——模板没填完就是没写完。
#   判据要求「rc=1 **且** 含 PLACEHOLDER」：DESIGN 模板今天 rc 已经是 1，但报的是
#   MISSING_TOKEN / UNRESOLVED_TOKEN，只判 rc 的话它会拿别的缺陷撑绿。
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

# P49b 反引号里的 {{…}} 是在教人怎么写，不报；围栏则按**用途**分——文本围栏里的槽照样是没填的槽，
#   只有标了模板/代码语言（html 等）的围栏才是在演示写法。
#   【期望已改】第八批原为「围栏里的一律不报」，第九批口径取代之：只有排除名单里的语言才不报。
D=$(newdir); write_spec "$D" curly
F="$D/Product-Spec.md"
BARE=$(lineno "$F" '^产品定位：'); BQ=$(lineno "$F" '^写法示例')
TXT=$(lineno "$F" '^文本围栏：'); HTM=$(lineno "$F" '模板语言里的槽')
run_json "$D"; PH=$(fjq "$OUT" PLACEHOLDER)
if [ "$RC" -eq 1 ] && [ "$PH" = "$BARE $TXT" ]; then r=0; else r=1; fi
chk "$r" "P49b 裸写与 text 围栏里的槽都报；反引号里的、html 围栏里的不报" \
    "rc=1；PLACEHOLDER=[$BARE $TXT]（反引号行 $BQ 与 html 围栏行 $HTM 不许报）" "rc=$RC；PLACEHOLDER=[$PH]"

# ---------------------------------------------------------------------------
# 第八批红锁：复审第六轮。口径见 progress.md 2026-09-10 Decisions
#   「DESIGN.md 围栏内也扫槽；前言里的槽只报一次」。
# ---------------------------------------------------------------------------
# P50 前言里写 `sm: {{px}}`，闸现在报两条：既说槽没填，又说 {px} 这个记号解析不到。
#   后者是把槽的内层花括号当成了记号引用——同一处毛病报两次，读的人不知道要改几个地方。
D=$(newdir); write_design "$D" fm_slot
F="$D/DESIGN.md"; SLOT=$(lineno "$F" 'sm: {{px}}'); NOPE=$(lineno "$F" 'colors.nope')
run_json "$D"; UT=$(fjq "$OUT" UNRESOLVED_TOKEN); PH=$(fjq "$OUT" PLACEHOLDER)
r=0; [ "$RC" -eq 1 ] || r=1; [ "$PH" = "$SLOT" ] || r=1; [ "$UT" = "$NOPE" ] || r=1
chk "$r" "P50 前言里的 {{px}} 只算没填的槽，不再顺带报一条 UNRESOLVED_TOKEN {px}" \
    "rc=1；PLACEHOLDER=[$SLOT]；UNRESOLVED_TOKEN=[$NOPE]（正文裸 {colors.nope} 仍要报，第 $SLOT 行不许再出记号错）" \
    "rc=$RC；PLACEHOLDER=[$PH]；UNRESOLVED_TOKEN=[$UT]"

# P51 DESIGN.md 的 CSS / YAML 围栏是交付物本身，里面的槽照样是没填的槽；
#   其余四份文档的围栏仍免检（Spec 那条由 P49b 锁着）。
D=$(newdir); write_design "$D" fence_slot
F="$D/DESIGN.md"; FL=$(lineno "$F" 'border-radius')
run_json "$D"; PH=$(fjq "$OUT" PLACEHOLDER)
if [ "$RC" -eq 1 ] && [ "$PH" = "$FL" ]; then r=0; else r=1; fi
chk "$r" "P51 css 围栏里的 {{px}} 照报（css 不在模板/代码语言排除名单里）" \
    "rc=1；PLACEHOLDER=[$FL]" "rc=$RC；PLACEHOLDER=[$PH]"

# P51b 模板原样当 DESIGN.md：报出的槽数必须等于独立数出来的槽数（围栏内外都算）。
#   写死数字会随模板改动而假红，所以这里现数——数法只依赖「反引号里的不算」这条公开规则。
TPLD="$SRC/skills/design-brief-builder/templates/design-md-template.md"
if [ -f "$TPLD" ]; then
    D=$(newdir); cp "$TPLD" "$D/DESIGN.md"
    WANT=$(slotcount "$D/DESIGN.md")
    run_json "$D"; N=$(fcnt "$OUT" PLACEHOLDER)
    if [ "$RC" -eq 1 ] && [ "$N" = "$WANT" ]; then r=0; else r=1; fi
    chk "$r" "P51b design-md-template.md 里的槽要一个不漏地报出来（围栏内的也算）" \
        "rc=1 且 PLACEHOLDER 条数=$WANT（独立数出来的槽数）" "rc=$RC；PLACEHOLDER 条数=$N"
else
    echo "  [NOTE] P51b 跳过：模板不在 $TPLD"
fi

# ---------------------------------------------------------------------------
# 第九批红锁：复审第七轮。口径见 progress.md 2026-09-10 Decisions
#   「未闭合围栏报错 + 围栏扫槽按用途不按文件名」。
# ---------------------------------------------------------------------------
# P52 少打一个 ``` ，后面所有内容就被当成围栏静静吞掉——文档看着通过，其实半篇没被检查。
D=$(newdir); write_spec "$D" unclosed
F="$D/Product-Spec.md"; FL=$(lineno "$F" '^```$'); ANG=$(lineno "$F" '还没定的模块')
run_json "$D"; UF=$(fjq "$OUT" UNCLOSED_FENCE)
if [ "$RC" -eq 1 ] && [ "$UF" = "$FL" ]; then r=0; else r=1; fi
chk "$r" "P52 未闭合的围栏要报 UNCLOSED_FENCE，行号指着开栏那行" \
    "rc=1；UNCLOSED_FENCE=[$FL]（被吞掉的第 $ANG 行本身仍按围栏内规则处理）" \
    "rc=$RC；UNCLOSED_FENCE=[$UF]"

D=$(newdir); write_spec "$D" closed_ctl
expect_clean "$D" "P52b 防修过头位（现在就绿）：围栏闭合时，围栏内的尖括号仍不报，也不许误判未闭合"

# P53 围栏扫不扫槽看**用途**：标了模板/代码语言（html 等）的是在演示写法，其余一律是交付内容。
#   开栏行自带的槽（```{{lang}}）也算没填。两闸报同一组行号。
D=$(newdir); write_spec "$D" fences
F="$D/Product-Spec.md"
NT=$(lineno "$F" '^无标签围栏：'); MD=$(lineno "$F" '^示例围栏：'); HT=$(lineno "$F" 'b>{{ label'); OL=$(lineno "$F" '^```{{lang}}$')
WANT=$(printf '%s\n%s\n%s\n' "$NT" "$MD" "$OL" | sort -n | tr '\n' ' ' | sed 's/ $//')
run_json "$D"; PH=$(fjq "$OUT" PLACEHOLDER); PL=$(fall "$OUT")
# 哨兵值区分「没跑 spec-lint」与「spec-lint 报了空」——后者也是不一致，不能当没这回事跳过
SL=未跑; [ -f "$SRC/harness/harness.mjs" ] && SL=$(sfall "$F")
r=0; [ "$RC" -eq 1 ] || r=1; [ "$PH" = "$WANT" ] || r=1
[ "$SL" = 未跑 ] || [ "$SL" = "$PL" ] || r=1
chk "$r" "P53 无标签 / markdown 围栏里的槽要报，html 围栏里的不报，开栏行自带的槽也报（两闸同判）" \
    "rc=1；PLACEHOLDER=[$WANT]（html 行 $HT 不许报）；spec-lint 行号集合与 predev 相同" \
    "rc=$RC；PLACEHOLDER=[$PH]；predev 全部=[$PL]；spec=[$SL]"

D=$(newdir); write_brief "$D" md_fence
F="$D/Design-Brief.md"; BL=$(lineno "$F" '卡片标题')
run_json "$D"; PH=$(fjq "$OUT" PLACEHOLDER)
if [ "$RC" -eq 1 ] && [ "$PH" = "$BL" ]; then r=0; else r=1; fi
chk "$r" "P53b Brief 的 markdown 围栏里包着的页面规格示例，槽没填照样要报" \
    "rc=1；PLACEHOLDER=[$BL]" "rc=$RC；PLACEHOLDER=[$PH]"

# ---------------------------------------------------------------------------
# 第十批红锁：复审第八轮。口径见 progress.md 2026-09-10 Decisions
#   「围栏内反引号是字面字符」。围栏外的行内反引号免检不变。
# ---------------------------------------------------------------------------
# P54 围栏里没有「行内代码跨度」这回事——那一对反引号就是两个普通字符，
#   它们夹着的槽照样是没填的槽。围栏外才是「在教人怎么写」，免检。
D=$(newdir); write_brief "$D" fence_bq
F="$D/Design-Brief.md"; OUTB=$(lineno "$F" '^围栏外反引号'); INB=$(lineno "$F" '^围栏内反引号')
run_json "$D"; PH=$(fjq "$OUT" PLACEHOLDER)
if [ "$RC" -eq 1 ] && [ "$PH" = "$INB" ]; then r=0; else r=1; fi
chk "$r" "P54 围栏内被反引号夹着的槽照报；围栏外反引号里的仍免检" \
    "rc=1；PLACEHOLDER=[$INB]（围栏外那行 $OUTB 不许报）" "rc=$RC；PLACEHOLDER=[$PH]"

# P54b 同样内容放进 Spec 做两闸对拍：spec-lint 现在就报对了，predev 漏报，
#   一份文档两个答案本身就是缺陷。哨兵值保证「spec 报空」也算不一致。
D=$(newdir); write_spec "$D" fence_bq
F="$D/Product-Spec.md"; INB=$(lineno "$F" '^围栏内反引号')
run_json "$D"; PL=$(fall "$OUT")
SL=未跑; [ -f "$SRC/harness/harness.mjs" ] && SL=$(sfall "$F")
r=0; [ "$RC" -eq 1 ] || r=1; [ "$PL" = "$INB" ] || r=1
[ "$SL" = 未跑 ] || [ "$SL" = "$PL" ] || r=1
chk "$r" "P54b 两闸对拍：同一份 Spec 里围栏内的反引号槽，两个闸必须报同一行" \
    "rc=1；predev 行号=[$INB]；spec-lint 行号集合与之相同" \
    "rc=$RC；predev=[$PL]；spec=[$SL]"

# ---------------------------------------------------------------------------
# 覆盖缺口，明说不假装
# ---------------------------------------------------------------------------
echo "  [NOTE] 未覆盖：--out/多 root、DESIGN.md 前言的 YAML 异常形态（列表、锚点、行内 JSON），"
echo "         以及 Brief 与 Spec 编号双向一致（这里只验 Brief -> Spec 单向悬挂引用）。"
echo "  [NOTE] 未覆盖：五份文档同时有 error 时的 findings 聚合顺序——契约只定了 rc，没定顺序，不硬编。"
echo "  [NOTE] P0-P51b 现在全是绿的。其中 P32 / P43b / P45c / P46 是防回归位、P34b / P49b 是防修过头位——"
echo "         它们绿不代表「没实现」，而是钉住已经对的那一半；改口径时先看它们有没有跟着红。"

echo ""
echo "==== test-predev-lint：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ]
