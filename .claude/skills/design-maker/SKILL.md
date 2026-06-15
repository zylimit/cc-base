---
name: design-maker
description: 当 Design Brief 完成后、用户需要生成设计稿时使用。
---

[任务]
    读取 Product-Spec.md 和 Design-Brief.md，通过 Open Design CLI（odc）生成一份完整的可交互 HTML 设计稿。
    **一份产物两用**：开发照着它实现（编码核心参照）；给领导/干系人评审直接浏览器打开看。HTML 就是最终成品的真容，所见即所得。
    确保 Product Spec 中每个有 UI 的功能都有对应页面，每个页面覆盖关键状态变体。
    分三个阶段，每阶段完成后向用户确认再进入下一阶段。

[工具安装]
    **Open Design CLI（odc）** —— 唯一依赖，本地 daemon 驱动，内部调用 Claude/Codex agent 生成 HTML。
    - 封装命令为 `odc`（避开 GNU coreutils 的 `/usr/bin/od`）。daemon 默认 `http://127.0.0.1:17456`。
    - 自带 142 个品牌级 design system（apple/linear/notion/stripe/minimal/clean/modern…），无需手画设计 token。
    - ⚠️ **所有 `odc ... --json` 输出前面会混入 `[plugins] registered ...` 日志行**，解析前必须 `grep -v '^\[plugins\]'`，否则 JSON 解析失败。
    - 安装参考 https://github.com/nexu-io/open-design ；本项目环境已部署。

[依赖检测]
    必需：Product-Spec.md → 缺失则提示先调用 /product-spec-builder
    必需：Design-Brief.md → 缺失则提示先调用 /design-brief-builder
    必需：odc daemon 在跑 → `odc daemon status --json | grep -v '^\[plugins\]'` 返回 `"ok": true`；
          未起则 `odc daemon start --headless --serve-web --no-open --port 17456` 后重试
    缺任一项 → 退出，提示补全后重新调用

[第一性原则]
    **完整覆盖原则**：Product Spec 中每个有 UI 的功能都必须在生成 prompt 里点名，确保产物覆盖。漏一个页面，开发时就少一个参照。
    **状态完备原则**：每个页面不只默认态。空状态、加载态、错误态、激活态——有交互的页面必须在 prompt 里要求覆盖关键状态变体。
    **文档驱动原则**：一切设计决策来自 Product-Spec.md 和 Design-Brief.md。不凭个人偏好发挥，不添加文档未描述的功能。
    **真实内容原则**：prompt 里提供真实文案和样本业务数据，要求产物不使用 Lorem ipsum 或无意义占位符。
    **离线自包含原则**：产物必须单文件 index.html、CSS/JS 全内联、零外部依赖（无 CDN/unpkg/googleapis），浏览器双击即开、完全离线可用。

[设计交付物]
    一次生成产出一份 `demo/index.html`：
    - **给开发**：编码核心参照，照着它实现像素与交互
    - **给领导/干系人**：评审时浏览器直接打开看，可点可交互；它就是最终成品的真容，所见即所得

    产物必须满足 [第一性原则]：完整页面覆盖、关键状态变体、真实数据、离线自包含。

[视觉方向 → design system 映射]
    Design-Brief.md 的视觉方向决定选哪个 odc design system（替代手画 token）：
    1. `odc design-systems list` 列出全部（输出第一列就是 create 要用的**短 ID**）
    2. 按 Design-Brief 的情绪关键词/参考品牌匹配最接近的一个（用**短 ID，不带 `design-system-` 前缀**），例如：
       - 极简/克制 → `minimal` / `clean`
       - 现代中性 → `modern` / `default`（Neutral Modern）
       - 高级感/苹果风 → `apple`
       - 效率工具/Linear 风 → `linear-app`
       - 文档/Notion 风 → `notion`
       - 金融/数据密集 → `stripe` / `binance`
    3. 拿不准时列 2-3 个候选给用户选；选定后记下短 ID 备用

[Phase 1：准备]
    1. 检测依赖（[依赖检测]），daemon 必须在跑
    2. 读 Product-Spec.md → 提取页面清单、状态变体清单、真实样本数据、页面间跳转关系
    3. 读 Design-Brief.md → 提取视觉方向、密度、动效风格、核心页面视觉备注
    4. 选 design system（[视觉方向 → design system 映射]）
    5. 选 skill —— `odc skills list` 列出，用**真实 registry ID**，按产品类型挑：
       - 通用前端/Web 应用 → `frontend-design`
       - 其余按 skills list 输出里语义最贴近的 ID 选
       ⚠️ 不要用 `example-*`——那是 scenario 示例，不是 skill，create 会 `SKILL_NOT_FOUND`
       拿不准列候选给用户选
    6. **构建生成 prompt**（写入临时文件 `design-prompt.md`）——一份 prompt 两条路通用，
       视觉规范必须写进正文（odc 有 design-system 注入，AI Studio 路全靠 prompt）：
       - **完整视觉规范**（从 Design-Brief 提取）：所有色值（十六进制）、字体族（UI + 等宽）、信息密度、动效风格（时长/缓动/明确禁止的效果）
       - 逐页面：布局分区 + 真实内容 + 交互（每个交互写明「点击 X → Y」）+ 页面间跳转关系
       - 状态变体要求（每页要覆盖哪些态）
       - 末尾固定追加：
         ```
         Output: single self-contained index.html, all CSS and JS inlined.
         ZERO external dependencies — no CDN, no unpkg, no googleapis. Must work fully offline.
         Cover every page and the required state variants. Use the provided real data, no Lorem ipsum.
         ```
    7. 向用户展示计划（页面数/变体数 + 选定的 skill + design system），确认后进 Phase 2

[Phase 2：生成（odc 为主，AI Studio 兜底）]
    默认走 odc（2A）。仅当 odc daemon 不可用 / agent 鉴权失败 / 产物验收始终不过时，降级到 AI Studio（2B）。

    [2A：odc 自动（默认）]
        1. 建项目（**不带 `--mode`**，--mode 只接受 design|chat）：
           ```
           odc project create --name "<项目名> Design" --skill <skillId> --design-system <designSystemId> --json
           ```
           输出过滤 `[plugins]` 后取 **`.project.id`**（不是顶层 projectId）
        2. 发起生成 run：
           ```
           odc run start --project <projectId> --agent claude --message "$(cat design-prompt.md)" --json
           ```
           取顶层 `runId`（出 HTML 走 agent，用 claude/codex 的 CLI 登录态即可，不需要额外 image key）
        3. 轮询直到完成（异步，几分钟级）：
           ```
           odc run info <runId> --json | grep -v '^\[plugins\]'
           ```
           - `status: running` → 继续等，每 30-60s 一次，向用户报进度
           - `status: succeeded` → **别轻信，继续核 `exitCode`（必须 == 0）**。succeeded+exitCode≠0 = 假成功
           - `status: failed` 或 exitCode≠0 → 读 events 日志定位真因（鉴权/agent 报错都在这）：
             `~/open-design/.od/runs/<runId>/events.jsonl`，别盲目重试
        4. 取产物：`odc project info <projectId> --json | grep -v '^\[plugins\]'` 取顶层 `resolvedDir` → 产物 = `<resolvedDir>/index.html`
        5. 验收（见下）→ 进 Phase 3

    [2B：Google AI Studio 手动（兜底）]
        1. 将 `design-prompt.md` 完整原文输出给用户（已含完整视觉规范，AI Studio 无需 design-system）
        2. 提示用户：「打开 aistudio.google.com，把上面 prompt 整段粘进去生成；完成后把生成的完整 HTML 原样拷回来」
        3. 用户回传 HTML → 写入项目 `demo/index.html`
        4. 验收（见下）→ 进 Phase 3

    [验收]（两路统一，客观判据，对照 [第一性原则]）：
        - **完整无截断**：含 `</html>`、`<style>`/`<script>` 配平、正常收尾（硬判据，不是体积）✓
        - 无 `cdn.`/`unpkg.`/`googleapis` 字样（离线自包含）✓
        - 包含 Spec 里每个核心页面的结构（grep 核心页面/功能关键词）✓
        - 体积仅参考：多页面应用通常 >20KB；极简单页可低至几 KB，不据此判失败（<3KB 才警惕空壳）
        验收失败 → 调 prompt 重新生成（A 路重新 run / B 路让用户重生成），或在 odc web UI 手动迭代

[Phase 3：交付]
    [落地]
        - 2A（odc）：`cp <resolvedDir>/index.html <项目根>/demo/index.html`
        - 2B（AI Studio）：用户回传的 HTML 已在 Phase 2 写入 `demo/index.html`，跳过
        - `git add demo/index.html && git commit -m "design: 生成可交互 HTML 设计稿（demo/index.html）"`

    输出完成报告：

    "✅ 设计稿已生成（Open Design 一套出 HTML）

     **产物**：demo/index.html（N KB，可交互、离线）
     **skill / design system**：<skillId> / <designSystemId>

     ---

     **给开发**：编码照此 demo 实现。
     **给领导/干系人评审**：浏览器直接打开 demo/index.html，可点可交互，这就是最终成品的样子。

     编码参照优先级：demo/index.html（最高）→ Design-Brief.md → Product-Spec.md

     调用 /dev-planner 制定开发计划，设计稿作为 Phase 拆分和编码实现的核心参照。"
