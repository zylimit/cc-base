---
name: design-maker
description: 当 Design Brief 完成后、用户需要生成设计交付物时使用。分三个阶段：Phase 1 用 Pencil MCP 生成原型图，Phase 2 生成可交互 HTML DEMO，Phase 3 输出交付报告。
---

[任务]
    读取 Product-Spec.md 和 Design-Brief.md，通过 Pencil MCP 和 Open Design MCP 生成完整的设计交付物。
    确保 Product Spec 中每个有 UI 的功能都有对应的设计页面，每个页面覆盖所有关键状态变体。
    分三个阶段执行，每个阶段完成后向用户确认再进入下一阶段。

[工具安装]
    **Pencil MCP**（原型图）
    - Mac / Linux：VS Code / Cursor 扩展市场搜索 `Pencil`（highagency），安装后重启自动注册 MCP。
    - Windows：Cursor 扩展在 Windows 下无法启动（已知问题：扩展依赖 node-ipc 的命名管道，Windows 上建管道失败，MCP server 连不上秒退），必须改装桌面 APP。
      1. pencil.dev 下载安装 Windows 桌面 APP
      2. 在 `~/.claude.json` 的 `mcpServers` 里手动添加：
         ```json
         "pencil": {
           "type": "stdio",
           "command": "C:\\Users\\<username>\\AppData\\Local\\Programs\\Pencil\\resources\\app.asar.unpacked\\out\\mcp-server-windows-x64.exe",
           "args": ["--app", "desktop", "--agent", "claudeCodeCLI"],
           "env": {}
         }
         ```
      ⚠️ Pencil 桌面 APP 必须保持运行，MCP 才能正常响应。

    **Open Design MCP**（DEMO 生成）
    ```
    npm install -g @opendesign/cli
    od mcp install
    ```
    安装后在 Claude Code 的 MCP 配置里确认 `open-design` 已列出即可。

[依赖检测]
    必需：Product-Spec.md → 缺失则提示先调用 /product-spec-builder
    必需：Design-Brief.md → 缺失则提示先调用 /design-brief-builder
    缺失任意一项 → 退出，提示补全后重新调用

[第一性原则]
    **完整覆盖原则**：Product Spec 中每个有 UI 的功能都必须有设计页面。漏一个页面，开发时就少一个参照，后果是开发靠猜。
    **状态完备原则**：每个页面不只有默认态。空状态、加载态、错误态、激活态，有交互的页面必须覆盖关键状态变体。
    **组件先行原则**：先建可复用组件，再用组件拼页面。避免同一个按钮在 10 个页面里画 10 遍、改一次要改 10 处。
    **文档驱动原则**：一切设计决策来自 Product-Spec.md 和 Design-Brief.md。不凭个人偏好发挥，不添加文档未描述的功能。
    **真实内容原则**：所有页面填充真实文案和样本数据，不使用 Lorem ipsum 或无意义占位符。

[技能]
    - **文档分析**：从 Product Spec 提取所有页面、功能、交互元素；从 Design Brief 提取视觉方向
    - **设计规划**：将提取的信息转化为设计交付清单，列出所有需要设计的页面和变体
    - **组件设计**：使用 Pencil MCP 创建可复用组件系统
    - **页面设计**：使用 Pencil MCP 逐页面生成完整设计
    - **DEMO 生成**：通过 Open Design MCP 或 Google AI Studio 生成可交互 HTML DEMO
    - **完整性校验**：对照 Product Spec 验证所有页面和状态是否覆盖

[设计交付物]
    一套完整的设计交付物必须包含以下内容：

    **1. 设计变量（Pencil 全局变量）**
    从 Design-Brief.md 提取并通过 set_variables 写入：
    - 颜色系统：背景色层级、文字色层级、品牌/强调色、语义色（成功/错误/警告/等待）
      每个语义色要有配套的 -dim（背景）和 -text（前景）变体，用于状态徽章场景
    - 字体系统：UI 字体族、等宽字体族
    - 间距/圆角：常用数值

    **2. 可复用组件**
    从 Product Spec 的 UI 布局和功能需求中提取通用组件，按需包含：
    - 按钮（Primary / Secondary / Danger 三变体）
    - 输入框
    - 导航项（选中态、未选中态）
    - 列表行（带操作按钮）
    - 消息块（用户/AI 两类）
    - 步骤项（waiting / running / success / error 四态）
    - 状态徽章 / 标签 / 筛选器
    - 其他页面中重复出现的元素

    **3. 所有页面**
    Product Spec UI 布局章节中描述的每个页面或视图都必须有对应设计：
    - 从 Product Spec 的 UI 布局、功能需求、用户流程三个章节交叉提取页面列表
    - 每个页面使用可复用组件拼装
    - 布局、间距、内容严格对照 Spec 描述

    **4. 状态变体**
    每个页面根据其交互复杂度覆盖对应状态：
    - 默认态：所有页面必须有
    - 空状态：有数据展示的页面必须有（纯文案引导，不用插画）
    - 加载/执行中：有异步操作的页面必须有
    - 错误态：有可能失败的操作必须有
    - 交互变体：同一区域有多种内容切换时，每种内容一个变体

    **5. 可交互 DEMO**
    单文件 index.html，所有 CSS/JS 内联，完全离线可用，覆盖所有核心页面和交互流程

---

[Phase 1：原型图（Pencil）]

    [准备]
        1. 调用 get_editor_state(include_schema: true) 获取当前 Pencil 文件和 schema
        2. 调用 get_guidelines() 获取可用指南列表
           再调用 get_guidelines(category: "guide", name: "Web App") 加载 Web App 设计规范
        3. 读取 Product-Spec.md → 提取页面清单、状态变体清单、组件清单
        4. 读取 Design-Brief.md → 提取情绪关键词、色彩值、字体、密度、交互风格、核心页面视觉备注
        5. 向用户展示设计计划（页面数/变体数/组件数），用户确认后开始

    [设计变量]
        从 Design-Brief.md 提取完整 Token 值，通过 set_variables 写入 Pencil 全局变量。
        变量命名规范：
        - 颜色：bg-primary / bg-surface / bg-surface-2 / bg-surface-3 / border / border-subtle
        - 文字：text-primary / text-secondary / text-muted
        - 语义：accent / accent-dim / accent-text / success / success-dim / error / error-dim / waiting
        - 字体：font-ui / font-mono
        - 尺寸：radius-sm / radius-md

    [可复用组件]
        按组件清单逐个用 batch_design 创建，每个组件单独一次 batch_design 调用：
        - 设置 reusable: true
        - 创建完立即 get_screenshot 截图验证结构正确
        - 注意：深色主题组件（浅色文字）在白色画布上不可见是正常的，验证结构即可

        batch_design 要点：
        - 每次 batch_design 独立 scope，组件 ID 用全局变量存储（不用 const/let）
        - 使用 FindEmptySpace 找空位，不手动猜坐标
        - 组件创建后立即拿到返回的 ID，后续页面设计用 ref 实例化

    [逐页面设计]
        每个页面执行以下流程：
        1. 用 FindEmptySpace 找空位，Insert 顶层 frame，clip: true，placeholder: true
        2. 用 ref 实例化可复用组件，通过 descendants 定制内容
        3. 填充真实内容（真实文案、样本数据）
        4. 对照 Product-Spec.md 确认：布局分区、功能入口、交互元素
        5. 对照 Design-Brief.md 确认：视觉风格、密度、核心页面视觉备注
        6. placeholder: false 完成
        7. get_screenshot 截图验证

        **Pencil 布局避坑**：
        - fill_container 含义是「占满父容器尺寸」，不是「占剩余空间」
          → flex 容器内同时有 fill_container 子项和 fit_content 子项时，后者会被推出可视区
          → 修复：给 fit_content 子项加显式高度，重新规划层级
        - 绝对定位覆盖层（遮罩/弹窗）不能用 fill_container，必须给显式 width/height
        - Copy 后子节点 ID 全部更新，不能用原 ID 更新后代，应在 Copy 的 descendants 参数里直接处理
        - 文字节点必须设 fill 属性，否则不可见

    [状态变体]
        按变体清单逐个设计，基于对应页面的默认态修改：
        - 变体之间只改必要内容，保持布局一致
        - 颜色状态：执行中=强调色 / 成功=低饱和绿 / 失败=红 / 等待=灰

    [校验]
        完整性：对照设计清单逐项确认组件/页面/变体是否全部完成
        一致性：跨页面颜色/字号/间距是否统一，组件是否复用而非重绘
        Spec 对照：回读功能需求，确认无遗漏 UI

        全部通过 → get_screenshot 总览，展示给用户确认
        用户确认 → 进入 Phase 2

---

[Phase 2：可交互 DEMO]

    [2.1 构建 Prompt]
        从 Design-Brief.md 提取：
        - 完整色彩值（所有变量的十六进制值）
        - 字体族（UI 字体 + 等宽字体）
        - 信息密度描述和参考基准
        - 动效风格（时长范围、缓动类型、明确禁止的效果）
        - 每个核心页面的视觉备注

        从 Product-Spec.md 提取：
        - 布局分区（几栏、各栏宽度固定值）
        - 所有交互行为（点击什么触发什么，具体说明触发条件和结果）
        - 页面之间的跳转关系
        - 真实样本数据（业务数据，非占位符）
        - 状态变化的完整流程

        Prompt 结构：
        1. 设计系统（色彩/字体/密度/动效规则）
        2. 逐页面：布局 + 内容 + 交互（每个交互写明"点击 X → Y"）
        3. 末尾必须加：
           ```
           Output: single index.html, all CSS and JS inlined.
           ZERO external dependencies — no CDN, no unpkg, no googleapis.
           Must work completely offline.
           ```

    [2.2 选择生成方式]
        询问用户：
        A. Open Design MCP（自动）—— 直接调用 OD Agent 生成，无需手动操作
        B. Google AI Studio（手动粘贴）—— 将 Prompt 输出给用户，用户去 AI Studio 生成后回传 HTML

    [2.3A Open Design MCP]
        1. create_project(name: "<项目名> Demo")
        2. start_run(prompt: <2.1 构建的完整 Prompt>)
        3. 每 30-60s 轮询 get_run(runId)
           - running → 继续等，告知用户进度
           - succeeded → 进验收
           - failed → 先 list_files 检查有无产出，有则进验收，无则重试一次
        4. 验收：get_artifact() 或 get_file("index.html")
           通过条件：> 20KB ✓  无 cdn./unpkg./googleapis 字样 ✓  包含主要页面结构 ✓
        5. 验收通过 → 写入项目 demo/index.html → 进 Phase 3
           验收失败 → write_file 修复，或切换 2.3B 方式

    [2.3B Google AI Studio]
        1. 将 2.1 构建的完整 Prompt 原文输出给用户
        2. 提示："打开 aistudio.google.com，粘贴 Prompt，生成完成后把完整 HTML 内容拷回来"
        3. 用户回传 HTML → 验收：> 5000 字符 ✓  无 cdn./unpkg./googleapis ✓
        4. 写入项目 demo/index.html → 进 Phase 3

---

[Phase 3：交付]

    [归档]
        在输出报告前，必须先完成以下两项归档：

        **1. 截图归档**
        用 export_nodes 将所有页面节点导出为 PNG，写入项目 design-prototype/ 目录：
        - 调用 export_nodes(filePath, nodeIds: [所有顶层页面帧的 ID], outputDir: "<项目根目录>/design-prototype", format: "png")
        - 每个页面/变体各导出一张，文件名用节点名称（export_nodes 默认用 nodeId 命名，可在导出后用 Bash mv 重命名为可读名称）
        - 导出完成后用 git add design-prototype/ 纳入版本管理

        **2. .pen 文件归档**
        把活跃的 .pen 文件复制到项目根目录，纳入 git 版本管理：
        - 调用 get_editor_state 获取当前 .pen 文件的完整路径
        - 用 Bash cp 将其复制到项目根目录，文件名统一为 design-prototype.pen
        - git add design-prototype.pen

        归档完成后提交：git commit -m "design: add Pencil prototype screenshots and .pen file"

    输出完成报告：

    "✅ 设计交付完成

     **Phase 1 原型图**
     文件：<.pen 文件名>
     画面：N 个页面 + N 个浮层/变体
     组件：N 个可复用组件

     **Phase 2 交互 DEMO**
     文件：demo/index.html（N KB）
     打开方式：浏览器直接打开（完全离线）

     ---

     编码参照优先级：
     demo/index.html（最高）→ Pencil 原型截图 → Design-Brief.md → Product-Spec.md

     调用 /dev-planner 制定开发计划，设计稿将作为 Phase 拆分和编码实现的核心参照。"
