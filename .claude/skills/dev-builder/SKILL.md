---
name: dev-builder
description: 当 DEV-PLAN.md 就绪、用户说要开始写代码或继续开发下一个 Phase 时使用。
---

[任务]
    **初始化模式**：无代码 + 有 DEV-PLAN.md → 根据技术栈搭建项目骨架，安装依赖，配置开发环境，完成 Phase 1。

    **持续开发模式**：有代码 + 有 DEV-PLAN.md → 按 Phase 逐步开发。每个 Phase：Plan Mode 规划实现 → 读设计稿 → 编码 → per-Task review + commit → Phase 四步走验证 → 用户确认。

[依赖检测]
    Skill 启动时第一步自动执行。

    必需：
    - Product-Spec.md → 缺失则提示先调用 /product-spec-builder
    - DEV-PLAN.md → 缺失则提示先调用 /dev-planner
    - DEV-PLAN 技术栈表中列出的所有系统工具和运行时环境

    可选：
    - Design-Brief.md → 缺失则标记"无设计规范模式"
    - 设计工具 MCP → 缺失则标记"无设计稿模式"
    - gh CLI → 有则可自动创建 GitHub 仓库和 push
    - playwright → 有则可做 UI 自动化测试

    安装策略：
    - 必需依赖缺失或版本不满足时，Agent 自主判断安装方式并直接安装，不需要用户手动操作
    - 需要用户权限或需要用户交互时，提示用户操作
    - 可选依赖缺失时，标记降级模式继续工作，不阻塞流程

[第一性原则]
    **修改纪律**：每次改代码前必须评估影响范围。改之前想清楚，改之后回归验证。不急着动手，不改坏已有功能。
    **SDK-First**：框架和 SDK 已有的能力不重复造。用之前 WebSearch 确认 SDK 是否已支持。
    **联网优先**：不靠过期记忆，靠实时信息。用到外部库/API 前，WebSearch 确认当前版本的用法和兼容性。
    **验证即证据（硬性门禁）**：完成声明必须在同一条消息中包含刚刚执行的验证命令及其输出。"完成了"加上同一条消息内运行的编译输出是有效声明。"完成了"加上"之前编译过了"是无效声明，必须重新运行。"完成了"但没有任何验证命令也是无效声明。这不是建议，是门禁。没有当场验证，就没有完成。
    **文件精简**：单文件不超过 300 行。超了就按职责拆分。三行简单代码好过一个过度抽象。

[输出风格]
    **语态**：
    - 像资深工程师汇报进度：简洁、准确、有数据
    - 完成了就说完成了，有问题就说有问题，不含糊

    **原则**：
    - × 绝不说"应该没问题"——要么验证通过说"通过"，要么没验证说"未验证"
    - × 绝不跳过验证就声明完成
    - × 绝不用软性措辞替代验证："应该没问题"、"大概率通过"、"看起来正确"、"之前测过了"都不是证据
    - × 绝不引用上一条消息的验证结果，每次声明都需要当场运行的新鲜证据
    - × 绝不凭过期记忆用外部库（先搜索确认）
    - ✓ 每个 Phase 完成时输出验证证据（编译输出、测试结果）
    - ✓ 遇到阻塞时明确说明原因和需要什么帮助
    - ✓ 代码改动前先说影响范围，改完后说回归测试结果

    **典型表达**：
    - "Phase 3 交付清单 5 项已全部实现，tsc --noEmit 零错误，dev server 正常启动。"
    - "这个改动会影响 left-sidebar.tsx 和 app-layout.tsx，先评估一下再动手。"
    - "这个功能 SDK 已经内置了（WebSearch 确认），不需要自己实现。"
    - "编译通过但 API 返回 500，需要排查 db.ts 的 migration 逻辑。"

[文件结构]
    ```
    dev-builder/
    └── SKILL.md                           # 主 Skill 定义（本文件）
    ```

[开发规则清单]
    编码过程中必须遵守的所有规则，按类别组织。

    [代码规范（前端 / TypeScript）]
        适用于 TS/React/前端代码。后端 Python 见下一节。
        - 单文件不超过 300 行，超了按职责拆分
        - TypeScript strict mode，不用 any（用 unknown + 类型守卫）
        - 命名：组件 PascalCase，函数/变量 camelCase，文件 kebab-case，常量 UPPER_SNAKE_CASE
        - 每个文件单一职责，有明确的对外接口
        - 函数优先用纯函数，副作用隔离到专门的层（hooks、API route）
        - React 优先 function components + Hooks，不用 class
        - 样式优先 Tailwind，不写自定义 CSS 除非 Tailwind 做不到
        - 不做无关重构——改哪里只动哪里，不"顺手"改别的
        - 遵循已有代码库的风格——不强推自己的偏好
        - YAGNI：不为假想的未来需求写代码

    [代码规范（后端 / Python）]
        适用于 FastAPI/Flask 等 Python 后端代码。
        - 单文件不超过 300 行，超了按职责拆分（解析器、导出器、路由各自独立模块）
        - 命名：模块/函数/变量 snake_case，类 PascalCase，常量 UPPER_SNAKE_CASE
        - 类型注解优先：函数签名标注参数和返回类型，复杂结构用 TypedDict/dataclass/Pydantic model
        - 每个模块单一职责，有明确的对外接口；副作用（DB、文件、网络）隔离到专门的层
        - 路由层只做请求解析与响应组装，业务逻辑下沉到 service/lib，不在 handler 里堆逻辑
        - SQL 一律参数化查询，禁止字符串拼接（防注入）；DB 访问集中在 db 层
        - 不裸 except；按异常类型处理，向上抛或转成明确的 HTTP 错误
        - 遵循已有代码库风格，不强推个人偏好；不做无关重构；YAGNI
        - 编译/质量门禁：commit 前 pre-commit-check 按栈分发——装了 ruff 跑 ruff check，否则降级 python3 -m py_compile 语法检查（见 .claude/hooks/pre-commit-check.sh）

    [项目结构规范]
        项目代码放在以项目名命名的子文件夹里，不平铺在根目录。根目录只放规划文档、设计资源和 .claude/ 框架。

        ```
        project/
        ├── Product-Spec.md         # 根目录，不进 git
        ├── DEV-PLAN.md             # 根目录，不进 git
        ├── <project-name>/         # 项目代码文件夹
        │   ├── src/
        │   ├── package.json
        │   └── ...
        └── .claude/                # 框架定义
        ```

        项目文件夹内部结构，根据技术栈约定组织：

        **Next.js 全栈项目**：
        ```
        src/
        ├── app/              → 页面路由
        ├── app/api/          → API 路由
        ├── components/       → UI 组件（按功能分子目录）
        ├── hooks/            → 自定义 Hooks
        ├── lib/              → 工具函数、类型定义、业务逻辑
        └── styles/           → 全局样式（如有）
        ```

        **React + Vite 项目**：
        ```
        src/
        ├── components/       → UI 组件
        ├── hooks/            → 自定义 Hooks
        ├── lib/              → 工具函数
        ├── pages/            → 页面组件（如有路由）
        └── styles/           → 全局样式
        ```

        **CLI 工具项目**：
        ```
        src/
        ├── commands/         → 各子命令实现
        ├── lib/              → 工具函数、核心逻辑
        ├── utils/            → 底层共用能力
        └── index.ts          → 入口（Commander.js 解析）
        ```

        **CLI Agent 产品**（复杂度较高的 Agent 类 CLI，参考成熟 Coding Agent 架构）：
        ```
        src/
        ├── entrypoints/      → 入口层（CLI 解析、命令路由）
        ├── commands/         → slash command 实现
        ├── tools/            → 工具定义与执行逻辑
        ├── services/         → 运行时服务（MCP、analytics、LLM 调用）
        ├── coordinator/      → 多 Agent 协调器
        ├── hooks/            → Hook 系统（事件驱动的自动化）
        ├── plugins/          → 插件生态
        ├── tasks/            → 异步任务管理
        ├── constants/        → prompt 模板、系统常量、输出规范
        ├── bootstrap/        → 状态初始化
        ├── utils/            → 底层共用能力
        └── types/            → TypeScript 类型定义
        ```
        注意：此结构适用于大型 Agent 产品（如 Coding Agent、AI 助手），小型 CLI 工具不需要这么多层。根据实际规模取用。

        **Desktop（Electron）项目**：
        ```
        electron/
        ├── main.ts           → Electron 主进程
        └── preload.ts        → 预加载脚本
        src/                  → 同 Next.js 全栈项目结构
        ```

        **通用原则**：
        - 一起变的文件放一起（按功能聚合，不按技术分层）
        - 新项目按约定来，已有项目跟随现有风格
        - 每个文件有明确的单一职责

    [代码结构与设计原则]
        **模块设计**：
        - 每个模块有明确边界和对外接口
        - 别人不读内部实现也能知道这个模块做什么、怎么用
        - 能换掉内部实现而不影响调用方
        - 可以独立理解和测试

        **拆分信号**（什么时候该拆）：
        - 文件超过 300 行
        - 一个函数/组件做了 3 件以上不同的事
        - 改一个功能要同时动 5 个以上文件（耦合太紧）

        **不拆信号**（什么时候不该拆）：
        - 代码量小且逻辑内聚
        - 拆了反而要在多个文件间跳来跳去
        - 只是为了"看起来整洁"而拆（过度抽象）

    [数据库结构规范]
        - 表名 snake_case，字段名 snake_case
        - 每张表必须有 id（主键）、created_at、updated_at
        - 用 TEXT 存 JSON 时，在代码注释中注明 JSON 结构
        - 字段有默认值的必须在 schema 中声明 DEFAULT
        - migration 用 ALTER TABLE，执行前检查列/表是否已存在
        - 不在代码里写裸 SQL 字符串拼接（用参数化查询防注入）
        - 索引策略：频繁查询的字段加索引，但不滥加
        - 表之间的关系在 Phase 交付清单中说明

    [环境变量与安全]
        - Vite 的 VITE_ 前缀变量暴露到浏览器——不能放 API Key
        - Next.js 不带 NEXT_PUBLIC_ 前缀的变量只在服务端——安全
        - AI API 调用必须走服务端（Next.js API route 或 Express），不走浏览器
        - .env.example 作为模板提交到 Git，.env.local 放实际值（.gitignore）
        - 不在代码里硬编码任何密钥、路径、个人信息

    [扩展性与可维护性]
        - 配置优于硬编码：可能变化的值抽为常量或配置
        - 接口优于实现：依赖抽象（TypeScript interface），不依赖具体实现
        - 渐进增强：核心功能先跑通，增强功能后加
        - 错误处理分层：组件层 catch 显示 UI，服务层 catch 记录日志
        - 不为未来过度设计：当前需要什么就做什么

    [质量门槛]
        每个功能实现后必须满足：
        - ✅ Happy path 正常工作
        - ✅ Error path 有清晰的错误提示
        - ✅ Loading state（异步操作有加载指示）
        - ✅ Empty state（无数据时有引导）
        - ✅ 基本输入校验（必填、格式）
        - ✅ 无敏感信息硬编码

    [修改纪律]
        每次修改代码前必须执行：
        1. 评估影响范围：这个改动会影响哪些现有功能？列出来
        2. 检查副作用：特别是 CSS（overflow-hidden 裁切弹出层、z-index 层叠、flex-shrink 布局）
        3. 先想后改：确认方案不会破坏现有功能，再动手
        4. 回归验证：改完后不仅测新功能，还要验证相关的现有功能

    [Git 工作流]
        原子化提交：
        - 每完成一个独立功能就 commit，不要攒到 Phase 结束
        - 一个 commit 只包含一个逻辑变更（一个功能、一个修复、一个配置改动）
        - Phase 内可以有多次 commit，Phase 完成时不需要额外的汇总 commit

        Commit message 规范：
        - Phase 开发：`phase-N: 功能描述`
        - Bug 修复：`fix: 问题描述`
        - 功能新增：`feat: 功能描述`
        - 重构：`refactor: 描述`
        - 配置/依赖：`chore: 描述`

        Push 策略：
        - 每次 commit 后立刻 push 到远程仓库
        - push 前确认当前分支正确
        - 如远程仓库未设置 → 提醒用户先配置

        多 repo 隔离（工作目录含多个独立 git repo 时）：
        - 同一工作目录可能含多个互相独立的 git repo（如主仓=https + 配置库 .claude=ssh），归属/认证各不相同
        - 每个 repo 的 add/commit/push 必须分开、逐个独立执行，并各自验收远程同步状态
        - 禁止把多个独立 repo 的提交耦合进同一脚本/同一条命令——认证不同（ssh vs https）时耦合会掩盖单点失败，造成"半成功"烂局（一个推成、另一个卡 ahead）
        - 细则见 feedback/multi-repo-commit-isolation.md

        提交门槛：
        - 原子化 commit 的最低门槛：本次改动涉及的栈编译/语法检查通过（前端 tsc --noEmit 零错误；后端 ruff check 或 py_compile 通过）
        - 该门槛由 pre-commit-check hook 按栈自动卡，工具缺失时降级不阻塞
        - Phase 完成的门槛：四步走全部通过
        - 不通过编译/语法检查不允许 commit

    [进程管理]
        每次启动/重启 dev server 前：
        - 根据项目技术栈确定 dev server 的进程名和端口号
        - kill 占用该端口的进程，等待 2 秒确保端口释放
        - 确认只有 0 或 1 个 dev server 在运行，防止多实例冲突

[开发策略]
    编码过程中的方法论，按需运用。

    **Plan Mode 策略**
    每个 Phase 开始前必须进入 Plan Mode 并列出 TaskList。这是编码的前置条件，不可跳过。
    1. 读 DEV-PLAN.md 中该 Phase 的交付清单和关键文件
    2. 探索现有代码结构，理解当前状态
    3. 规划具体实现步骤，明确先改什么、后改什么、哪些文件需要新建或修改
    4. 用 TaskCreate 将实现步骤拆为具体 Task，每个页面、组件、功能一个 Task
    5. TaskList 列好后直接开始编码，不需要等用户确认
    
    禁止在没有 Plan 和 TaskList 的情况下直接写代码。
    Plan Mode 负责"这个 Phase 怎么实现"，DEV-PLAN.md 负责"做哪些 Phase"。

    **设计稿参照策略**
    
    如有设计工具 MCP 已连接（如 Pencil、Figma 等），以下步骤**不可跳过**：
    
    **每个功能开发前**：
    - 通过设计工具 API 读取涉及的所有页面和变体的精确数值（宽高、padding、gap、字号、字重、颜色、圆角、阴影）
    - 查看设计稿视觉效果
    - 不是 Phase 开头看一次就够——每个 Task 开始前都要重新读取，不凭记忆
    
    **编码过程中**：
    - 逐个组件对照提取的数值实现
    - 遇到设计稿与 Design Brief 冲突时，以设计稿为准
    
    **每个功能开发后**：
    - 读取代码中的实际值（Tailwind class / style），逐项与设计数值核对
    - 查看设计稿，确认布局结构一致
    - 有偏差先修正再提交
    - 让用户在浏览器中确认最终视觉效果
    
    如无设计工具（降级模式）：
    - 以 Design-Brief.md 为主要参照
    - 如无 Design-Brief → 以 Product-Spec.md 文字描述为参照

    **联网搜索策略**
    以下场景必须先 WebSearch 再动手：
    1. 用到外部库/API → 确认当前版本的用法和 API 签名
    2. SDK/框架有没有内置功能 → 确认后决定是自己实现还是直接用
    3. 遇到不确定的技术方案 → 搜索最佳实践
    4. 报错信息不熟悉 → 搜索别人的解决方案

    **技术栈选择策略**（初始化模式使用）
    根据 DEV-PLAN.md 的技术栈表配置项目。如 DEV-PLAN 未指定：
    - Web（纯前端）→ React + Vite + TypeScript + Tailwind
    - Web（全栈）→ Next.js + TypeScript + Tailwind
    - Desktop → Electron + Next.js + TypeScript + Tailwind
    - CLI → Node.js + TypeScript + Commander
    - CLI Agent → Node.js + TypeScript（参考 [CLI Agent 产品] 项目结构）
    - Mobile → React Native / Expo
    选定后 WebSearch 验证框架版本和兼容性。

[反合理化清单]
    Agent 容易用"合理"的理由跳过规则。以下是常见的合理化话术和正确应对。

    跳过 Plan Mode：
    - "这个很简单，直接写就行" → Plan Mode 不看复杂度，看纪律。简单的 Phase 也要 Plan + TaskList
    - "就改一个文件" → 一个文件也要先评估影响范围再动手
    - "用户在等，先写再说" → 5 分钟的 Plan 省 30 分钟的返工

    跳过验证：
    - "我刚测过这个" → 每次声明完成都需要当场运行的新鲜证据
    - "这个改动不可能出错" → 不可能出错的改动最容易出错，验证
    - "编译通过就说明没问题" → 编译通过不等于功能正常，四步走每步都要

    跳过 Code Review：
    - "改动很小，不用 review" → 每次代码变更都过 review，不看大小
    - "就修了个 typo" → typo 修复也 commit，commit 前也要编译验证

    写模糊计划：
    - "实现时再想细节" → Plan 阶段就要想清楚，不然实现时会走偏
    - "类似 Task 1 的做法" → 写出具体做法，不引用其他 Task
    - "添加必要的错误处理" → 指明处理哪些错误、用什么方式

    软性完成声明：
    - "应该没问题了" → "没问题"需要证据，运行验证命令
    - "看起来正确" → "正确"需要对比 Spec 原文和代码
    - "大概率通过" → 概率不是证据，运行测试拿结果

[Phase 完成度判断]
    每个 Phase 完成时，必须通过以下全部检查：

    **四步走**（必须全部通过才能确认 Phase 完成）：

    第一步：Code Review
    - 对照 DEV-PLAN.md 该 Phase 的交付清单，逐项确认是否实现
    - 检查代码质量：命名规范、类型安全、无 any、无循环依赖
    - 检查有没有超出 Phase 范围的改动（scope creep）
    - 输出证据：交付清单逐项对照结果

    第二步：测试完整性（由 test-builder skill 承担，真卡点）
    - 该 Phase 计划的所有功能都已实现，无遗漏、无半成品（功能清单打勾）
    - **调用 test-builder**：务实回归——探测/搭建测试基建，为本 Phase 涉及的高价值逻辑（契约、解析器、去重、关键边界）写可重跑回归测试并执行
    - 测试代码派 tester Sub-Agent 写（写测≠被测作者），主 Agent 验收；失败按代码错/测试错分流（bug-fixer 修代码 / tester 修测试）→ 重跑直到全绿
    - 输出证据：测试运行器真实输出（passed/failed 计数）+ 新增用例清单 + 未测项及理由

    第三步：编译验证（按栈）
    - 前端 TS：tsc --noEmit 零错误
    - 后端 Python：装了 ruff 跑 ruff check 零错误；否则 python3 -m py_compile 全部通过（语法级）
    - 混合栈项目两栈都要验，各自附证据
    - 无缺失依赖
    - 输出证据：各栈编译/检查命令的真实输出

    第四步：功能测试
    - 启动 dev server，确认无错误输出
    - 新功能可用
    - 现有功能未被破坏（回归）
    - 如有 Playwright → 用浏览器自动化测试核心交互流程
    - 如无 Playwright → API endpoint 用 curl 检查返回 200 + 提醒用户在浏览器手动确认 UI 渲染
    - 输出证据：启动日志 + API 响应 + 设计数值对比结果

    **冒烟测试**（四步走之外的额外检查）：
    - 安全扫描：npm audit 无 critical 漏洞
    - 无暴露密钥：grep 检查代码中无硬编码的 API Key、Token
    - 进程正常：只有 1 个 dev server 实例在运行

    **验证时效性规则**：
    四步走中的每一步验证命令必须在汇报的同一消息中执行。不接受"前面已经验证过了"。如果中间有任何代码修改，所有四步重新来。

    **全部通过后**：
    - 向用户汇报结果（附证据）
    - 用户确认 → Phase 完成
    - 不通过不允许确认 Phase 完成
    - 如验证过程中发现问题并修复，修复的 commit 用 `fix:` 前缀（per-Task commit 已在第二步完成）

[工作流程（初始化模式）]
    触发条件：有 DEV-PLAN.md，无项目代码

    [启动阶段]
        第一步：依赖检测
            执行 [依赖检测]

        第二步：加载文档
            读取 Product-Spec.md → 提取产品概述、核心功能
            读取 DEV-PLAN.md → 提取技术栈表、Phase 1 内容、数据库表（如有）
            如有 Design-Brief.md → 读取色彩方向、信息密度（配置 Tailwind 主题）
            如有设计工具 MCP → 读取 Phase 1 相关页面的设计数据

    [技术方案阶段]
        运用 [技术栈选择策略]
        根据 DEV-PLAN.md 的技术栈表确认方案
        WebSearch 验证框架版本和关键依赖兼容性
        如有多个合理选项 → 给用户 2-3 个方案选

    [项目搭建阶段]
        在 <project-name>/ 子文件夹中初始化项目，不在根目录。
        命名：小写字母 + 数字 + 连字符。
        配置 TypeScript strict mode、安装依赖、配置 Tailwind、配置环境变量。

        Git 准备：
        1. 根目录 git init + 创建 .gitignore（排除规划文档、设计资源、环境变量、构建产物）
        2. 确保 gh CLI 可用且已认证（未安装则安装，未认证则引导用户完成 `gh auth login`）
        3. 创建 GitHub **private** 仓库并关联远程
        4. 首次 commit + push

    [Phase 1 开发]
        进入 [持续开发模式] 的 Phase 执行流程，从 Phase 1 开始

[工作流程（持续开发模式）]
    触发条件：有 DEV-PLAN.md + 有项目代码

    [加载阶段]
        第一步：依赖检测
            执行 [依赖检测]

        第二步：加载文档和代码状态
            读取 DEV-PLAN.md → 识别所有 Phase 及完成状态
            读取 Product-Spec.md → 作为功能参照
            如有 Design-Brief.md → 读取视觉方向
            如有设计工具 MCP → 准备读取
            扫描已有代码结构 → 了解当前项目状态

        第三步：确定当前 Phase
            显示 Phase 列表和完成状态
            识别下一个待开发的 Phase
            如用户指定某个 Phase → 使用指定的

    [Phase 执行流程]
        第一步：Plan + TaskList
            这一步是编码的前置条件，不可跳过，不需要用户确认。没有 Plan 和 TaskList 不允许写任何代码。
            1. 读取该 Phase 的交付清单和关键文件
            2. 如有设计工具 MCP 已连接，查看该 Phase 涉及的页面，读取精确数值。如无设计工具，以 Design-Brief.md 或 Product-Spec.md 为参照
            3. 探索现有代码，理解当前结构
            4. 规划实现步骤，明确先做什么、后做什么
            5. 用 TaskCreate 列出具体任务清单，每个页面、组件、功能一个 Task
            6. TaskList 列好后直接进入第二步，不等用户确认

        第二步：逐个 Task 实现 + 单 Task Review 循环

            对每个 Task 执行以下循环：

            开发前——加载参照文档：
            1. 读取 DEV-PLAN.md 中该 Task 对应的交付清单和关键文件
            2. 读取 Product-Spec.md 中该 Task 涉及的功能描述
            3. 读取 Design-Brief.md 中该 Task 涉及的视觉方向和页面备注
            4. 如有设计工具 MCP 已连接，通过设计工具找到该 Task 对应的设计页面，读取该页面及其组件的精确数值。每个 Task 都重新读取，不凭记忆
            5. 明确该 Task 的交付目标：功能上实现什么、视觉上做成什么样

            编码：
            6. 严格按参照文档实现，逐个组件对照设计数值编码

            开发后——对照验证 + Review 循环：
            7. 读取代码实际值，逐项与设计数值核对，有偏差则修正
            8. 对照 Product-Spec.md 确认功能行为符合描述
            9. 派发 code-reviewer 执行两阶段审查。code-reviewer 同样对照 Product-Spec.md、Design-Brief.md、DEV-PLAN.md 和设计稿审查
            10. Stage 1 失败（功能缺失）→ 补实现 → 重新派发 code-reviewer
            11. Stage 2 失败（代码质量）→ 调用 bug-fixer 修复 → 重新派发 code-reviewer
            12. 两个 Stage 都通过 → TaskUpdate 标记完成 → 执行 Bash: echo clean > .claude/.needs-review 清除 review 状态 → commit
            13. 进入下一个 Task

            编码过程中始终遵循：
            - [开发规则清单] 中的所有规则
            - [修改纪律]：每次改动前评估影响
            - [联网搜索策略]：用外部库前确认 API
            - 遇到阻塞时明确说明，不强行继续

        第三步：Phase 完成验证
            所有 Task 完成后，执行 [Phase 完成度判断] 的四步走验证
            这是最终确认，确保所有 Task 的代码在一起能编译、能运行、功能完整
            每步附上证据
            不通过则修复后重新验证

        第四步：用户确认
            向用户汇报 Phase 完成情况，附证据
            用户确认 OK → Phase 完成
            用户有修改意见 → 修改后重新走第三步

        第五步：引导下一步
            "Phase N 已完成验证。下一个：Phase N+1。继续？"

[初始化]
    检测项目状态，路由到对应模式：
    - 无代码 + 有 DEV-PLAN.md → 初始化模式
    - 有代码 + 有 DEV-PLAN.md → 持续开发模式
    - 无 DEV-PLAN.md → 提示先调用 /dev-planner
    - 无 Product-Spec.md → 提示先调用 /product-spec-builder
