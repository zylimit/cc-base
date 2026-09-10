---
name: design-maker
description: 当 Design Brief 完成后、用户需要生成设计稿时使用。
---

[任务]
    读取 Product-Spec.md、Design-Brief.md、DESIGN.md，通过 Open Design CLI（odc）生成一份完整的可交互 HTML 设计稿。
    **一份产物两用**：开发照着它实现（编码核心参照）；给领导/干系人评审直接浏览器打开看。HTML 就是最终成品的真容，所见即所得。
    先出三个首屏方向样张让用户选，再出全稿；生成前走两遍法把「给任何页面都会给的默认」挑出来；产物过 UI 审计与质量地板才交付。
    确保 Product Spec 中每个有 UI 的功能都有对应页面，每个页面覆盖八态。
    分三个阶段，每阶段完成后向用户确认再进入下一阶段。
    本机没有 odc 时不退出：前期功课照做，改出一份提示词交用户拿去任意工具生成（[提示词模式]）。

[工具安装]
    **Open Design CLI（odc）** —— 生成侧唯一依赖，本地 daemon 驱动，内部调用 Claude/Codex agent 生成 HTML。
    - 封装命令为 `odc`（避开 GNU coreutils 的 `/usr/bin/od`）。daemon 默认 `http://127.0.0.1:17456`。
    - 自带 142 个品牌级 design system（apple/linear/notion/stripe/minimal/clean/modern…），当基底用；token 以 DESIGN.md 为准。
    - ⚠️ **所有 `odc ... --json` 输出前面会混入 `[plugins] registered ...` 日志行**，解析前必须 `grep -v '^\[plugins\]'`，否则 JSON 解析失败。
    - 安装参考 https://github.com/nexu-io/open-design ；本项目环境已部署。
    **UI 审计**：`node .claude/scripts/ui-audit.mjs`，需要 `playwright-core` + 本机 Chrome（或一次性安装 playwright）；没有就审计缺席，报告里注明，不冒充通过。

[依赖检测]
    必需：Product-Spec.md → 缺失则提示先调用 /product-spec-builder
    必需：Design-Brief.md → 缺失则提示先调用 /design-brief-builder
    强烈建议：DESIGN.md → 缺失则从 Design-Brief 的视觉方向临时抽一组 token 写进 prompt，产物标「未经 DESIGN.md」，并建议回 /design-brief-builder 补
    分路：`which odc` 查得到 → `odc daemon status --json | grep -v '^\[plugins\]'` 要返回 `"ok": true`，
          未起则 `odc daemon start --headless --serve-web --no-open --port 17456` 后重试，走 Phase 1-3 的生成流程；
          查不到 odc → 进 [提示词模式]，不退出不报错，开口第一句告诉用户这次走的是哪条路
    可选：`node -e "require('playwright-core')"` 成功 → 验收跑 ui-audit；失败 → 报告注明「UI 审计缺席」
    缺 Product-Spec.md 或 Design-Brief.md → 退出，提示补全后重新调用

[第一性原则]
    **完整覆盖原则**：Product Spec 中每个有 UI 的功能、Design-Brief 里每个 SCREEN 都必须在生成 prompt 里点名，确保产物覆盖。漏一个页面，开发时就少一个参照。
    **状态完备原则**：每个页面不只默认态。八态（空 / 加载 / 成功 / 错误 / 冲突 / 离线 / 无权限 / AI 工作中）在 prompt 里逐页要求，Design-Brief 已写的照抄不改。
    **文档驱动原则**：一切设计决策来自三份文档。颜色、字号、圆角、间距只从 DESIGN.md token 来，不散写 hex；DESIGN.md 的 Do's and Don'ts 原样进 prompt 当护栏；不添加文档未描述的功能。
    **两遍法原则**：生成前先写一页紧凑的设计计划（token 摘录、每页 ASCII 线框与对齐、大胆放在哪一处、动效只留哪一处），再对照 brief 与 `../design-brief-builder/references/style-vocabulary.md` 的 AI 通病清单审一遍——任何一处是「给任何同类页面都会给的默认」而不是给这个产品的选择，就改并说出改了什么；只有审过才生成。
    **真实内容原则**：prompt 里提供 Spec 与 Brief 里的真实文案和样本业务数据（案例里的人名、型号、地址），要求产物不使用 Lorem ipsum 或无意义占位符。
    **质量地板原则**：`../design-brief-builder/references/ui-quality-floor.md` 的 MUST 不宣告地做到——键盘可达、焦点可见、reduced-motion、对比达标、命中区、空 / 错态有下一步。
    **离线自包含原则**：产物必须单文件 index.html、CSS/JS 全内联、零外部依赖（无 CDN/unpkg/googleapis，字体用系统栈回退），浏览器双击即开、完全离线可用。

[设计交付物]
    - `demo/design-plan.md`：两遍法的设计计划与自审记录（token 摘录、线框、大胆一处、通病自检结果、选定方向）
    - `demo/design-prompt.md`：整段可粘的生成提示词（提示词模式下的产物，交用户拿去任意工具生成）
    - `demo/directions/direction-{1,2,3}.html`：三个首屏方向样张（同一页面三种完整人格，不是换色）
    - `demo/index.html`：全稿——**给开发**编码核心参照；**给领导/干系人**评审时浏览器直接打开看，可点可交互
    - `demo/ui-audit/`：审计 JSON 与截图（有引擎时）
    产物必须满足 [第一性原则]：完整页面覆盖、八态、真实数据、离线自包含、质量地板。

[视觉方向 → design system 映射]
    DESIGN.md 是 token 的唯一来源，odc 的 design system 只当基底：
    1. `odc design-systems list` 列出全部（输出第一列就是 create 要用的**短 ID**）
    2. 按 DESIGN.md 的 Overview 参照物与情绪词匹配最接近的一个（用**短 ID，不带 `design-system-` 前缀**），例如：
       - 极简/克制/纸感 → `minimal` / `clean`
       - 现代中性 → `modern` / `default`（Neutral Modern）
       - 高级感/苹果风 → `apple`
       - 效率工具/Linear 风 → `linear-app`
       - 文档/Notion 风 → `notion`
       - 金融/数据密集 → `stripe` / `binance`
    3. 基底与 DESIGN.md 冲突时 DESIGN.md 赢：prompt 里明写「以下 token 覆盖 design system 默认值」
    4. 拿不准时列 2-3 个候选给用户选；选定后记下短 ID 备用

[Phase 1：准备]
    1. 检测依赖（[依赖检测]），有 odc 时 daemon 必须在跑；没有 odc 转 [提示词模式]
    2. 读 Product-Spec.md → 提取真实样本数据、关键流程、成功判据里的可见指标
    3. 读 Design-Brief.md → 提取 SCREEN 清单（页面目的 / 首要动作 / 首屏开在哪 / 布局 / 内容层级 / 八态 / 响应式）、CMP 清单、交互原语、文案规则、动效「只留哪一处」、§A（Agent 形态时）
    4. 读 DESIGN.md → 前言 token 全量 + 八段 prose + Do's and Don'ts + Motion；缺 DESIGN.md 时从 Brief 视觉方向临时抽 token 并标注
    5. 选 design system（[视觉方向 → design system 映射]）
    6. 选 skill —— `odc skills list` 列出，用**真实 registry ID**，按产品类型挑：
       - 通用前端/Web 应用 → `frontend-design`
       - 其余按 skills list 输出里语义最贴近的 ID 选
       ⚠️ 不要用 `example-*`——那是 scenario 示例，不是 skill，create 会 `SKILL_NOT_FOUND`
       拿不准列候选给用户选
    7. **两遍法第一遍——写 `demo/design-plan.md`**：token 摘录（4-6 个具名色、字族角色、圆角与间距刻度）；每个 SCREEN 一段 ASCII 线框 + 对齐说明（左对齐 / 居中 / 两端）；首屏开在题材最有特征的什么上；大胆放在哪一处；动效只留哪一处；组件复用清单
    8. **两遍法第二遍——自审**：逐项对照 style-vocabulary 的 AI 通病清单（五类聚簇、排版通病、动效通病、首屏通病）与 DESIGN.md 的 Don'ts；命中的写「原本 → 改成 → 为什么」进 design-plan.md；brief 钉死的照 brief
    9. **构建生成 prompt**（写入临时文件 `design-prompt.md`，[提示词模式] 下落盘到 `demo/design-prompt.md`）——一份 prompt 两条路通用，视觉规范必须写进正文（odc 有 design-system 注入，交人拿去生成的那条全靠 prompt，2C 与 [提示词模式] 都走它）：
       - **DESIGN.md 原文**（前言 token + 八段 prose + Do's and Don'ts + Motion），并声明「token 覆盖 design system 默认，不许出现 token 之外的 hex」
       - **设计计划**（design-plan.md 的线框、大胆一处、动效一处）
       - 逐页面：SCREEN 编号 + 布局分区 + 内容层级 + 真实内容 + 交互（每个交互写明「点击 X → Y」）+ 八态 + 响应式断点 + 页面间跳转关系
       - 组件清单与变体状态（引用 CMP 编号）
       - 文案规则（动词开头、同一动作同名、错误给下一步、空态是邀请）
       - **质量地板摘要**（键盘可达与焦点环、命中区 ≥44px 移动端、reduced-motion、对比 ≥4.5:1、状态不只靠颜色、`…` 不是 `...`、tabular-nums）
       - 末尾固定追加：
         ```
         Output: single self-contained index.html, all CSS and JS inlined.
         ZERO external dependencies — no CDN, no unpkg, no googleapis. Must work fully offline.
         Cover every page and all required state variants. Use the provided real data, no Lorem ipsum.
         Use only the color / type / radius / spacing tokens given above; do not invent new hex values.
         Respect prefers-reduced-motion; all interactive elements keyboard-reachable with visible focus.
         ```
    10. 向用户展示计划（页面数 / 变体数 + 选定的 skill + design system + 通病自审改了什么），确认后进 Phase 2

[Phase 2：生成（odc 为主，AI Studio 兜底）]
    默认走 odc（2A + 2B）。仅当 odc daemon 不可用 / agent 鉴权失败 / 产物验收始终不过时，降级到 AI Studio（2C）。

    [2A：方向样张（先选方向再出全稿）]
        1. 建项目（**不带 `--mode`**，--mode 只接受 design|chat）：
           ```
           odc project create --name "<项目名> Design" --skill <skillId> --design-system <designSystemId> --json
           ```
           输出过滤 `[plugins]` 后取 **`.project.id`**（不是顶层 projectId）
        2. 发起方向样张 run：message = design-prompt.md 的 DESIGN.md 与设计计划部分 + 「只做首屏（SCREEN-1）的三个完整视觉方向，各自独立成一个 section 并排：三者在密度、字重、动效暗示、品牌气质上明显不同，都遵守同一套 token 与 Don'ts；用真实内容；单文件离线」
           ```
           odc run start --project <projectId> --agent claude --message "$(cat direction-prompt.md)" --json
           ```
        3. 轮询到 `succeeded` 且 `exitCode == 0`（判据同 2B），取 `resolvedDir/index.html` 复制到 `demo/directions/`
        4. 让用户在浏览器里看三个方向选一个（或一主一辅），把选择与理由写进 design-plan.md；无 odc 时用文字各描一句画面让用户选
        5. 没有方向被选中 → 按用户的反馈改 design-plan.md 重出一次，不第三次

    [2B：全稿生成]
        1. 同一项目发起生成 run（prompt = 完整 design-prompt.md + 「按用户选定的方向 N」）：
           ```
           odc run start --project <projectId> --agent claude --message "$(cat design-prompt.md)" --json
           ```
           取顶层 `runId`（出 HTML 走 agent，用 claude/codex 的 CLI 登录态即可，不需要额外 image key）
        2. 轮询直到完成（异步，几分钟级）：
           ```
           odc run info <runId> --json | grep -v '^\[plugins\]'
           ```
           - `status: running` → 继续等，每 30-60s 一次，向用户报进度
           - `status: succeeded` → **别轻信，继续核 `exitCode`（必须 == 0）**。succeeded+exitCode≠0 = 假成功
           - `status: failed` 或 exitCode≠0 → 读 events 日志定位真因（鉴权/agent 报错都在这）：
             `~/open-design/.od/runs/<runId>/events.jsonl`，别盲目重试
        3. 取产物：`odc project info <projectId> --json | grep -v '^\[plugins\]'` 取顶层 `resolvedDir` → 产物 = `<resolvedDir>/index.html`
        4. 验收（见下）→ 进 Phase 3

    [2C：Google AI Studio 手动（兜底）]
        1. 将 `design-prompt.md` 完整原文输出给用户（已含完整视觉规范，AI Studio 无需 design-system）
        2. 提示用户：「打开 aistudio.google.com，把上面 prompt 整段粘进去生成；完成后把生成的完整 HTML 原样拷回来」
        3. 用户回传 HTML → 写入项目 `demo/index.html`
        4. 验收（见下）→ 进 Phase 3

    [验收]（两路统一，客观判据，对照 [第一性原则]；逐条跑，不凭看）：
        - **完整无截断**：含 `</html>`、`<style>`/`<script>` 配平、正常收尾（硬判据，不是体积）✓
        - **离线自包含**：无 `cdn.`/`unpkg.`/`googleapis` 字样 ✓
        - **页面覆盖**：grep Brief 里每个 SCREEN 的页面名或功能关键词都在 ✓
        - **八态覆盖**：grep 每页的空 / 加载 / 错误等状态文案（Brief 写了什么就查什么）✓
        - **token 一致**：产物里出现的 hex 值全部在 DESIGN.md 的 colors 里（`grep -o '#[0-9a-fA-F]\{6\}' | sort -u` 对照），多出来的要么改回 token 要么说明理由 ✓
        - **UI 审计**：`node .claude/scripts/ui-audit.mjs demo --themes light --widths 1280,390 --out demo/ui-audit --strict`（DESIGN.md 有深色 token 时 `--themes light,dark`）→ 溢出 / 折行 / 对比度 / 空白渲染为零；无引擎时 rc 3，报告注明「UI 审计缺席」，不冒充通过 ✓
        - **AI 通病自检**：ui-audit 的 `genericTells` 与人工过一遍 style-vocabulary 清单（ALL-CAPS 小标签、中点串、按钮尾巴「→」、一律圆角、每段淡入、奶油底陶土橙）——命中的说明留或改 ✓
        - **质量地板抽查**：Tab 一遍主流程焦点可见；缩到 390px 无横向滚动；`prefers-reduced-motion` 下无动画（ui-audit 已覆盖溢出，其余人工）✓
        - 体积仅参考：多页面应用通常 >20KB；极简单页可低至几 KB，不据此判失败（<3KB 才警惕空壳）
        验收失败 → 调 prompt 重新生成（A 路重新 run / B 路让用户重生成），或在 odc web UI 手动迭代；同一失败两轮无新证据 → 停下向用户报阻塞

[Phase 3：交付]
    [落地]
        - 2B（odc）：`cp <resolvedDir>/index.html <项目根>/demo/index.html`
        - 2C（AI Studio）：用户回传的 HTML 已在 Phase 2 写入 `demo/index.html`，跳过
        - `git add demo/ && git commit -m "design: 生成可交互 HTML 设计稿（demo/index.html，含方向样张与设计计划）"`

    输出完成报告：

    "✅ 设计稿已生成（Open Design 一套出 HTML）

     **产物**：demo/index.html（N KB，可交互、离线）；方向样张 demo/directions/（用户选定方向 N）；设计计划 demo/design-plan.md
     **skill / design system**：<skillId> / <designSystemId>（token 以 DESIGN.md 为准）
     **验收**：页面 N/N 覆盖、八态 N/N、token 一致 ✓、UI 审计 [通过 / 缺席（无引擎）]、通病自检改了 X 处

     ---

     **给开发**：编码照此 demo 实现，颜色字号圆角只用 DESIGN.md token。
     **给领导/干系人评审**：浏览器直接打开 demo/index.html，可点可交互，这就是最终成品的样子。

     编码参照优先级：demo/index.html（最高）→ DESIGN.md（token）→ Design-Brief.md（行为）→ Product-Spec.md

     调用 /dev-planner 制定开发计划，设计稿作为 Phase 拆分和编码实现的核心参照。"

[提示词模式]
    没有 odc 时的另一条路：前期功课一步不省，只是 HTML 换成用户拿提示词去别处生成。
    1. Phase 1 的 1-9 步照走，只跳过第 6 步——选 skill 是 odc 的东西，没有 odc 就没这回事；第 5 步选基底直接按 [视觉方向 → design system 映射] 的表挑，不跑 `design-systems list`。第 10 步没有 Phase 2 可进，换成下面第 3 步的交付话术
    2. 第 9 步构建出来的那份 prompt 就是产物，与 odc 路只差两点：落盘到 `demo/design-prompt.md`，不写临时文件；「DESIGN.md 原文」那一项后面补上 DESIGN.md 硬约束节整表
    3. 输出交付话术：

    "✅ 设计提示词已生成（本机没有 odc，走的提示词模式）

     **产物**：demo/design-prompt.md（整段可粘）；设计计划 demo/design-plan.md
     **覆盖**：页面 N/N、八态逐页写明、真实样本数据 N 组；参照基底 <designSystemId>（token 以 DESIGN.md 为准，提示词里已写明覆盖）

     ---

     把 demo/design-prompt.md 整段粘到任意生成工具（网页版 Claude、v0、Lovable 等），生成的单文件 HTML 存回 demo/index.html。
     存好回来说一声，我按 [验收] 过一遍质量地板，再跑 `node .claude/scripts/ui-slop-scan.mjs` 复核。"

[初始化]
    执行 Phase 1 第 1 步。
