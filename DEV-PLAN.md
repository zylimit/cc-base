# Development Plan — DataLink Automation Platform

> 本文件记录项目的开发阶段划分、当前进度和剩余工作。
> 新 session 启动时应首先阅读此文件，了解项目状态后再继续开发。
>
> **当前状态**：全新项目，无代码。基于 Product-Spec.md + Design-Brief.md 重新规划。
> **AI 集成**：Google AI Studio（Gemini API），不使用 Claude API。

---

## Phase 1: 项目骨架搭建

**交付内容**：
- electron-vite 5.x 项目初始化（react-ts 模板），目录分为 `src/main/`、`src/preload/`、`src/renderer/`
- TypeScript strict mode 配置
- Tailwind CSS 4 配置（Design Brief 色彩系统）
- electron-store 初始化（appData 目录）
- Git 初始化 + .gitignore + 首次 commit

**关键文件**：
- `electron.vite.config.ts` — main/preload/renderer 三入口配置
- `src/main/index.ts` — Electron 主进程入口，BrowserWindow 1440x900 frameless
- `src/preload/index.ts` — contextBridge IPC 桥接，暴露 `window.api`
- `src/preload/index.d.ts` — `window.api` TypeScript 类型声明
- `src/renderer/index.html` — 渲染器入口 HTML
- `src/renderer/src/main.tsx` — React 入口
- `src/renderer/src/App.tsx` — 根组件（空白，待 Phase 2 填充）
- `src/renderer/src/index.css` — Tailwind 4 + 设计令牌变量（#0B0B0C 底色 / #F97316 琥珀橙 / #4ADE80 成功 / #EF4444 错误）
- `package.json` — 依赖：electron@33、electron-vite@5、react@19、typescript@5.8、tailwindcss@4、@google/generative-ai、electron-store@10
- `tsconfig.json` + `tsconfig.node.json` + `tsconfig.web.json`
- `.gitignore`

**验收标准**：
- `npm run dev` 启动 Electron 窗口（空白窗口即可）
- TypeScript 编译零错误
- 无 network 请求，所有资源本地加载

---

## Phase 2: UI 界面（暗夜工程台风格）

**交付内容**：
- 主界面布局：Toolbar（36px）+ MainContent（左右分屏 576:864）
- ChatPanel 组件：无气泡纯文本块，AI 消息左侧 2px amber 竖条，用户消息右对齐浅色背景
- StepList 组件：竖排步骤行，每行状态点（⬜等待→🟠执行中→✅成功→❌失败）+ 工具名 + 参数摘要
- Toolbar 组件：应用标题 + 录制按钮 + 作业流库按钮 + 设置按钮，hover 状态
- BrowserPanel 组件：地址栏 + 前进/后退/刷新按钮 + 内容区占位
- InputArea 组件：底部固定输入框 + 发送按钮

**关键文件**：
- `src/renderer/src/App.tsx` — 布局骨架（Toolbar + MainContent）
- `src/renderer/src/components/ChatPanel.tsx` — 对话面板
- `src/renderer/src/components/StepList.tsx` — 步骤列表
- `src/renderer/src/components/Toolbar.tsx` — 工具栏
- `src/renderer/src/components/BrowserPanel.tsx` — 浏览器面板（含地址栏 chrome）
- `src/renderer/src/components/InputArea.tsx` — 输入区域
- `src/renderer/src/index.css` — 全局设计令牌变量

**验收标准**：
- 所有组件在 mock 数据下正常渲染
- 视觉与 Design-Brief.md 一致（#0B0B0C 底色 / #F97316 强调 / JetBrains Mono 等宽字体）
- TypeScript 零错误

---

## Phase 3: 内置浏览器（WebContentsView）

**交付内容**：
- 主进程 `BrowserViewManager` 类：创建/销毁/bounds 同步/navigate/back/forward/reload
- WebContentsView 挂载到右侧面板，通过 bounds 定位
- 渲染进程 BrowserPanel 重构：地址栏 + 导航按钮 → IPC 调用主进程控制 WebContentsView
- 启动时加载 `config.datalinkUrl`（默认 https://datalink.huawei.com）
- remote-debugging-port=9222 供 chrome-devtools-mcp 连接

**关键文件**：
- `src/main/browser-view.ts` — WebContentsView 生命周期管理
- `src/main/ipc-handlers/browser.ts` — IPC handlers：`browser:navigate`、`browser:back`、`browser:forward`、`browser:reload`、`browser:get-url`
- `src/renderer/src/components/BrowserPanel.tsx` — 重构为受控组件
- `src/preload/index.ts` — 新增 browser 相关 IPC 接口
- `src/preload/index.d.ts` — 更新类型声明

**验收标准**：
- 右侧面板加载真实网页（https://example.com 验证）
- 地址栏显示当前 URL，前进/后退/刷新功能可用
- 窗口 resize 时浏览器区域随之调整
- `http://localhost:9222/json` 可查看页面列表

---

## Phase 4: chrome-devtools-mcp 集成

**交付内容**：
- 主进程 `McpClient` 类：spawn `npx chrome-devtools-mcp@latest`，通过 stdio 建立 MCP 协议连接
- 实现 `initialize()`、`listTools()`、`callTool(name, args)` 方法
- 26 个工具列表可获取（take_screenshot、click、fill、navigate_page 等）
- 主进程启动时 MCP Client 初始化，主进程退出时显式 kill

**关键文件**：
- `src/main/mcp-client.ts` — McpClient 类：child_process spawn + MCP stdio JSON-RPC 协议
- `src/main/index.ts` — 应用启动时初始化 McpClient
- `src/main/ipc-handlers/mcp.ts` — IPC handlers：`mcp:list-tools`、`mcp:call-tool`

**验收标准**：
- MCP 子进程启动成功，工具列表可获取（26 个工具）
- `api.mcp.callTool('take_screenshot', {})` 返回截图数据

---

## Phase 5: Gemini API 集成

**交付内容**：
- `GeminiAgent` 类：接收用户 prompt，构建 messages，以 function calling 模式调用 Gemini API
- 将 chrome-devtools-mcp 的 26 个工具注册为 Gemini function declarations
- 实现 tool call 循环：Gemini 返回 function call → 调用 McpClient.callTool → 追加结果到 messages → 再次调用 Gemini → 直到 end
- `config.model` 支持 gemini-2.5-flash（简单操作）和 gemini-2.5-pro（复杂定位）
- IPC handler `agent:run` 接收用户 prompt，触发 GeminiAgent 执行，通过 `agent:step` IPC event 实时推送每步状态

**关键文件**：
- `src/main/gemini-agent.ts` — GeminiAgent 类：API 调用、tool call 循环、事件推送
- `src/main/ipc-handlers/agent.ts` — IPC handler `agent:run` + `agent:step` event

**验收标准**：
- Gemini API 连接成功（配置 API Key 后）
- 用户输入 "截图当前页面" → Gemini 调用 `take_screenshot` → 截图在 ChatPanel 显示
- `agent:step` 事件实时推送，控制台能看到每步工具调用

---

## Phase 6: 对话驱动自动化（完整执行循环）

**交付内容**：
- ChatPanel 接入真实 IPC：用户发送消息 → `api.agent.run()` → 实时接收 `agent:step` 事件 → AI 消息内渲染动态步骤列表
- 执行中状态下 ChatPanel 输入框禁用，Toolbar 显示 "执行中..." 状态
- 步骤失败时：当前步骤标红 + 停止后续步骤 + 触发 ErrorOverlay
- ErrorOverlay 展示：工具名、参数、错误信息

**关键文件**：
- `src/renderer/src/hooks/useAgent.ts` — 封装 IPC 调用 + 步骤状态管理
- `src/renderer/src/components/ChatPanel.tsx` — 接入 useAgent，渲染真实步骤列表
- `src/renderer/src/components/StepList.tsx` — 复用，状态点颜色实时变化
- `src/renderer/src/components/ErrorOverlay.tsx` — 错误覆盖层（Phase 2 已创建 UI，Phase 6 接入逻辑）
- `src/main/gemini-agent.ts` — 补充步骤耗时统计、失败事件 payload

**验收标准**：
- 用户输入 "帮我点击页面上的新建按钮" → ChatPanel 出现 AI 消息 + 步骤列表 → 浏览器中按钮被点击 → 步骤变绿
- 故意输入错误指令时，步骤变红 + ErrorOverlay 弹出

---

## Phase 7: 录制功能（作业流捕获）

**交付内容**：
- `Recorder` 类：`start()` 开始拦截 McpClient.callTool 调用，`stop()` 返回步骤数组
- 每条录制记录：`{ seq, tool, args, semanticInfo, screenshotRef, timestamp }`
- `semanticInfo` 从 args 中提取（text/label/role 等语义字段）
- Toolbar "● 录制" 按钮：点击切换录制状态，录制中 amber 高亮
- 录制停止后弹出命名对话框（名称 + 描述输入）
- 保存为 `{workflowDir}/{slug}.json`（Product Spec 七节 JSON 格式）

**关键文件**：
- `src/main/recorder.ts` — Recorder 类：拦截 McpClient + 构建步骤记录
- `src/main/workflow-store.ts` — save / load / list / delete / rename workflow JSON
- `src/main/ipc-handlers/workflow.ts` — IPC：`workflow:list`、`workflow:save`、`workflow:delete`、`workflow:rename`
- `src/renderer/src/components/Toolbar.tsx` — 录制按钮逻辑
- `src/renderer/src/components/SaveWorkflowDialog.tsx` — 命名对话框
- `src/renderer/src/components/WorkflowLibrary.tsx` — 从 IPC 加载列表，展示保存的 JSON 文件

**验收标准**：
- 点击录制 → 操作浏览器 → 停止录制 → 填写名称 → WorkflowLibrary 出现新条目
- JSON 文件存在于 workflowDir，内容包含完整步骤和元数据

---

## Phase 8: 作业流回放

**交付内容**：
- `Player` 类：加载 workflow JSON，按 seq 顺序调用 McpClient.callTool
- 元素定位策略：先用 semanticInfo（text/label/role）在当前 a11y snapshot 重新定位，成功则执行
- 失败则触发 AI 重定位（Gemini 看当前 snapshot 找对应元素）
- AI 重定位失败则抛出 `ElementNotFoundError` 终止回放
- WorkflowLibrary 行的 "▶" 按钮触发回放，ChatPanel 实时展示步骤进度

**关键文件**：
- `src/main/player.ts` — Player 类：加载 workflow、顺序执行、语义重定位、AI fallback
- `src/main/ipc-handlers/player.ts` — IPC：`player:run`、`player:stop`
- `src/renderer/src/components/WorkflowLibrary.tsx` — ▶ 按钮绑定 `api.player.run(workflowId)`

**验收标准**：
- 录制 3-5 步作业流 → 回放时浏览器重现操作 → ChatPanel 显示步骤进度
- 目标元素位置变化时，AI 重定位能找到并继续执行
- AI 重定位失败后 ErrorOverlay 展示 `ElementNotFoundError`

---

## Phase 9: 登录管理（Cookie 持久化）

**交付内容**：
- `LoginManager` 类：`captureSession()` 在 WebContentsView 导航完成后检查 cookie
- 检测到 Datalink session cookie 则加密存入 electron-store 的 `savedSession`
- 应用启动时 `restoreSession()`：解密后注入 cookies，再导航到 datalinkUrl
- ChatPanel 增加登录状态指示（底部输入框上方）
- Toolbar 增加"重新登录"菜单项

**关键文件**：
- `src/main/login-manager.ts` — LoginManager 类：captureSession / restoreSession / clearSession
- `src/main/browser-view.ts` — did-navigate 事件中调用 captureSession
- `src/main/ipc-handlers/login.ts` — IPC：`login:status`、`login:clear`
- `src/renderer/src/components/ChatPanel.tsx` — 显示登录状态指示

**验收标准**：
- 手动在右侧浏览器完成 Datalink 登录后，ChatPanel 显示"已登录"
- 关闭并重启 Electron → 自动注入 Cookie → 无需重新登录
- 点击"重新登录"清除状态后，右侧浏览器返回登录页

---

## Phase 10: 错误日志 + 截图 + 日志查看器

**交付内容**：
- `Logger` 类：每次执行开始时创建 `{workflowDir}/logs/YYYY-MM-DD_HH-mm-ss.log`
- 每步追加：`[timestamp] [STEP N] [STATUS] tool=xxx args=yyy duration=Zms`
- 步骤失败时调用 `WebContentsView.capturePage()` 截图保存
- 日志查看器：Toolbar "日志" 图标 → 打开日志列表 overlay
- ErrorOverlay 新增截图缩略图（通过 IPC 读取截图 base64）

**关键文件**：
- `src/main/logger.ts` — Logger 类：createSession / appendStep / appendSummary / list / read
- `src/main/browser-view.ts` — 截图方法封装
- `src/main/ipc-handlers/logs.ts` — IPC：`logs:list`、`logs:read`
- `src/renderer/src/components/LogViewer.tsx` — 日志列表 + 详情 overlay

**验收标准**：
- 执行一次 AI 对话后，`logs/` 目录下出现对应 `.log` 文件
- 故意触发失败，`screenshots/` 目录下出现截图文件，ErrorOverlay 显示缩略图
- 日志查看器能列出历史日志并查看内容

---

## 技术栈

| 层级 | 技术 | 版本 | 说明 |
|------|------|------|------|
| 桌面框架 | Electron | 33.x | 跨平台桌面壳，WebContentsView 嵌入浏览器 |
| 构建工具 | electron-vite | 5.x | Electron 专用 Vite，三入口（main/preload/renderer） |
| 前端框架 | React + TypeScript | 19.x / 5.8 | 渲染进程 UI |
| UI 样式 | Tailwind CSS | 4.x | 工具类 CSS |
| AI SDK | @google/generative-ai | 0.8.x | Gemini API function calling |
| 浏览器控制 | chrome-devtools-mcp | latest（npx） | MCP server，26 个浏览器操作工具，基于 Puppeteer |
| 本地存储 | electron-store | 10.x | 加密配置（API Key / Cookie）持久化 |
| 打包 | electron-builder | 25.x | Windows 安装包输出 |
| 包管理 | npm | 10.x | 项目已有，保持一致 |

---

## 开发规则

- 每完成一个 Phase 执行四步走：Code Review → 测试完整性 → 编译验证 → 功能测试
- 四步走全部通过后才能 commit
- Commit message 格式：`phase-N: 简要描述`（例：`phase-1: electron-vite 骨架迁移完成`）
- IPC 命名规范：`domain:action`（例：`agent:run`、`browser:navigate`、`workflow:list`）
- 主进程不直接操作 DOM，渲染进程不直接访问 Node.js / Electron API（全部通过 contextBridge）
- chrome-devtools-mcp 子进程随主进程启动，主进程退出时显式 kill 子进程
- 包管理器：npm