# Development Plan — DataLink Automation Platform

> 本文件记录项目的开发阶段划分、当前进度和剩余工作。
> 新 session 启动时应首先阅读此文件，了解项目状态后再继续开发。
>
> **当前状态**：现有 `src/` 为 Vite + React 纯前端 UI 原型（无 Electron、无真实后端、全部 mock 模拟），
> 需迁移至 `electron-vite` 架构并逐步替换为真实逻辑。

---

## Phase 1: Electron + Vite 骨架迁移

**交付内容**：
- 用 `electron-vite` 重建项目结构（react-ts 模板），目录分为 `src/main/`、`src/preload/`、`src/renderer/`
- 将现有 `src/` 下所有 React 组件和类型文件原样迁移到 `src/renderer/src/`，保持现有 UI 可运行（mock 数据不变）
- `src/preload/index.ts` 建立 contextBridge IPC 桥接，暴露 `window.api` 对象到渲染进程
- `src/main/index.ts` 创建主窗口（1440x900，frameless 标题栏），加载渲染器
- 删除 `express`、`@google/genai`、`server.js` 等非 Electron 依赖，清理 `package.json`
- 验证 Electron 窗口能启动并显示现有 UI

**关键文件**：
- `electron.vite.config.ts` — 替换原 `vite.config.ts`，配置 main/preload/renderer 三入口
- `src/main/index.ts` — Electron 主进程入口，创建 BrowserWindow
- `src/preload/index.ts` — contextBridge 定义，暴露 `window.api` IPC 接口
- `src/preload/index.d.ts` — `window.api` 的 TypeScript 类型声明
- `src/renderer/src/App.tsx` — 从原 `src/App.tsx` 迁移
- `src/renderer/src/components/` — 迁移所有组件
- `src/renderer/src/types.ts` — 迁移类型定义
- `src/renderer/index.html` — 渲染器入口 HTML
- `package.json` — 更新 dependencies：加 electron@33、electron-vite@2、electron-builder@25；移除 express、@google/genai

**验收标准**：
- `npm run dev` 能启动 Electron 窗口
- 窗口内显示原有 UI（即使数据全是 mock）
- TypeScript 编译无错误
- `src/` 根目录下原 Vite 文件已清理

---

## Phase 2: UI 界面重构（对照 Design Brief）

**交付内容**：
- 全局 CSS 变量建立设计令牌：底色 `#0B0B0C`、强调色 `#F97316`、成功色 `#4ADE80`（降饱和）、错误色 `#EF4444`、等待色 `#52525B`
- `ChatPanel` 重构：无气泡纯文本块，AI 消息左侧 2px amber 竖条，用户消息右对齐浅色背景条；步骤列表每行一个状态点（颜色变化，无动画）；输入框底部固定
- `WorkflowLibrary` 重构：行式列表（40px/行，1px 分隔线），每行含状态点 + 名称 + 步骤数 pill + 最后运行时间 + 播放/删除图标，hover 背景 `#1A1A1A`
- `Toolbar` 重构：34px 高，录制状态 amber 高亮，速度控制（1x/2x/4x），紧凑图标+标签风格
- `ErrorOverlay` 重构：0px 圆角，左侧 4px 红色竖条，monospace 错误详情，步骤时间线，截图占位
- 引入 `JetBrains Mono` 字体（CDN 或本地）用于步骤列表和错误详情

**关键文件**：
- `src/renderer/src/index.css` — 全局设计令牌变量 + Tailwind 配置
- `src/renderer/src/App.tsx` — 布局骨架（工具栏 + 分屏主体）
- `src/renderer/src/components/ChatPanel.tsx` — 对话面板完整重构
- `src/renderer/src/components/WorkflowLibrary.tsx` — 作业流列表完整重构
- `src/renderer/src/components/Toolbar.tsx` — 顶部工具栏重构
- `src/renderer/src/components/ErrorOverlay.tsx` — 错误覆盖层重构
- `src/renderer/src/types.ts` — 更新 Message / Workflow / Step 类型定义（移除 mock 特有字段）

**验收标准**：
- 视觉与 Design-Brief.md 的色彩、密度、字体方向一致
- 所有组件在 mock 数据下正常渲染，无 TypeScript 错误
- JetBrains Mono 在步骤列表中正确显示

---

## Phase 3: 本地配置存储 + 设置面板

**交付内容**：
- `electron-store` 初始化，存储路径为用户 appData 目录；字段：`apiKey`（加密）、`model`（string）、`workflowDir`（string）、`datalinkUrl`（string）
- `src/main/config-store.ts` 封装 get/set/clear 操作，IPC handler 暴露给渲染进程
- 设置面板 UI：在 Toolbar 右侧点击设置齿轮图标 → 弹出 overlay；包含 API Key 输入框（密码掩码）+ 模型下拉（haiku/sonnet）+ 作业流目录选择（调用 Electron dialog.showOpenDialog）+ Datalink URL 输入
- 应用启动时检查 `apiKey` 是否已配置，未配置则自动打开设置面板

**关键文件**：
- `src/main/config-store.ts` — electron-store 封装，get/set/clear，apiKey 使用 safeStorage 加密
- `src/main/ipc-handlers/config.ts` — IPC handlers：`config:get`、`config:set`、`config:open-dir-dialog`
- `src/renderer/src/components/Settings.tsx` — 设置面板 overlay
- `src/preload/index.ts` — 新增 config 相关 IPC 接口

**验收标准**：
- 设置面板可打开、填写 API Key 后关闭
- 重启 Electron 后 API Key 仍然存在（electron-store 持久化）
- 目录选择调用系统文件夹选择框
- 未配置 API Key 时启动自动弹出设置面板

---

## Phase 4: 内置浏览器（WebContentsView）

**交付内容**：
- 在主进程创建 `WebContentsView`，挂载到主窗口右侧区域（通过 bounds 定位）；渲染进程 BrowserPanel 区域对应的 DOM 元素作为占位，主进程监听窗口 resize 事件同步更新 WebContentsView bounds
- 浏览器 chrome UI（地址栏、前进/后退/刷新）在渲染进程实现，操作通过 IPC 发送给主进程控制 WebContentsView
- 启动时自动加载 `config.datalinkUrl`（未配置则显示 about:blank）
- 开启 remote debugging：WebContentsView 通过 `--remote-debugging-port=9222` 参数启动，供后续 chrome-devtools-mcp 连接

**关键文件**：
- `src/main/browser-view.ts` — WebContentsView 生命周期管理（创建/销毁/bounds 同步/navigate/back/forward/reload）
- `src/main/ipc-handlers/browser.ts` — IPC handlers：`browser:navigate`、`browser:back`、`browser:forward`、`browser:reload`、`browser:get-url`
- `src/renderer/src/components/BrowserPanel.tsx` — 重构为：顶部浏览器 chrome（地址栏 + 导航按钮）+ 底部占位 div（WebContentsView 叠在其上）
- `src/preload/index.ts` — 新增 browser 相关 IPC 接口

**验收标准**：
- 右侧面板加载真实网页（可先用 `https://example.com` 验证）
- 地址栏显示当前 URL，前进/后退/刷新可用
- 窗口 resize 时浏览器区域随之调整，不错位
- remote-debugging-port=9222 已开启（通过 `http://localhost:9222/json` 可查看页面列表）

---

## Phase 5: chrome-devtools-mcp + Claude API 集成

**交付内容**：
- 主进程以 child_process.spawn 启动 `npx chrome-devtools-mcp@latest`，通过 stdio 建立 MCP 协议连接；实现 `McpClient` 类：`initialize()`、`listTools()`、`callTool(name, args)`
- 创建 `ClaudeAgent` 类：接收用户 prompt，构建初始 messages，以 `tool_use` 模式调用 Claude API（`claude-haiku-4-5-20251001` 用于简单操作，`claude-sonnet-4-6` 用于复杂定位），将 chrome-devtools-mcp 的 26 个工具注册为 Claude tools
- 实现 tool use 循环：Claude 返回 `tool_use` block → 调用 McpClient.callTool → 将 `tool_result` 追加到 messages → 再次调用 Claude → 直到 Claude 返回 `end_turn`
- IPC handler `agent:run` 接收用户 prompt 和会话历史，触发 ClaudeAgent 执行，通过 `agent:step` IPC event 实时推送每步状态到渲染进程

**关键文件**：
- `src/main/mcp-client.ts` — McpClient 类：spawn chrome-devtools-mcp 子进程，实现 MCP stdio JSON-RPC 协议（initialize / tools/list / tools/call）
- `src/main/claude-agent.ts` — ClaudeAgent 类：Claude API tool_use 循环，消费 McpClient，推送步骤事件
- `src/main/ipc-handlers/agent.ts` — IPC handler `agent:run`，订阅 ClaudeAgent 事件并转发到渲染进程
- `src/preload/index.ts` — 新增 `api.agent.run(prompt, history)`、`api.agent.onStep(callback)` 接口

**验收标准**：
- chrome-devtools-mcp 子进程随 Electron 启动，工具列表可获取（26 个工具）
- 用户在 ChatPanel 输入 "截图当前页面" → Claude 调用 `take_screenshot` → 截图 base64 返回并在 ChatPanel 显示
- `agent:step` 事件在渲染进程可接收，控制台能看到每步工具调用名称和结果

---

## Phase 6: 对话驱动自动化（完整执行循环）

**交付内容**：
- ChatPanel 接入真实 IPC：用户发送消息 → `api.agent.run()` → 实时接收 `agent:step` 事件 → 在 AI 消息内渲染动态步骤列表（状态点颜色实时变化：等待→执行中→成功/失败）
- 每个步骤展示：步骤序号、工具名称（`click` / `fill` / `navigate_page` 等）、关键参数摘要（最多 60 字符）、执行耗时（成功后显示）
- 步骤失败时：当前步骤标红 + 停止后续步骤 + 触发渲染进程显示 ErrorOverlay，ErrorOverlay 展示工具名、参数、错误信息
- 执行中状态下 ChatPanel 输入框禁用，Toolbar 显示 "执行中..." 状态

**关键文件**：
- `src/renderer/src/hooks/useAgent.ts` — 封装 IPC 调用 + 步骤状态管理（step list state machine）
- `src/renderer/src/components/ChatPanel.tsx` — 接入 useAgent，渲染真实步骤列表
- `src/renderer/src/components/StepList.tsx` — 独立步骤列表组件（状态点 + 工具名 + 参数摘要 + 耗时）
- `src/main/claude-agent.ts` — 补充步骤耗时统计、失败事件 payload（错误消息 + 工具参数）

**验收标准**：
- 用户输入 "帮我点击页面上的新建按钮" → ChatPanel 出现 AI 消息 + 步骤列表 → 浏览器中按钮被点击 → 步骤变绿
- 故意输入错误指令时，步骤变红 + ErrorOverlay 弹出，显示失败工具名和错误信息
- 执行期间输入框不可用

---

## Phase 7: 录制功能（作业流捕获）

**交付内容**：
- 主进程 `Recorder` 类：`start()` 开始拦截 McpClient.callTool 调用，`stop()` 返回步骤数组；每条录制记录包含 `{ seq, tool, args, semanticInfo, screenshotRef, timestamp }`（`semanticInfo` 从 args 中提取语义字段：text/label/role）
- Toolbar "● 录制" 按钮：点击切换录制状态，录制中显示 amber 脉冲动画 + 已录制步骤数角标；同时 AI 自动执行的 tool call 也被录制
- 录制停止后弹出命名对话框：输入名称 + 描述 → 生成 UUID + 补全元数据 → 保存为 `{workflowDir}/{slug}.json`（格式符合 Product Spec 七节 JSON 示意）
- WorkflowLibrary 列表从 `workflowDir` 读取 JSON 文件并展示（通过 IPC `workflow:list` 获取）

**关键文件**：
- `src/main/recorder.ts` — Recorder 类，拦截 McpClient 并构建步骤记录
- `src/main/workflow-store.ts` — save / load / list / delete / rename workflow JSON 文件
- `src/main/ipc-handlers/workflow.ts` — IPC handlers：`workflow:list`、`workflow:save`、`workflow:delete`、`workflow:rename`、`workflow:export`、`workflow:import`
- `src/renderer/src/components/WorkflowLibrary.tsx` — 从真实 IPC 加载列表，展示保存的 JSON 文件
- `src/renderer/src/components/SaveWorkflowDialog.tsx` — 命名对话框（名称 + 描述输入）
- `src/preload/index.ts` — 新增 recorder 和 workflow IPC 接口

**验收标准**：
- 点击录制 → 操作浏览器（手动点击或 AI 执行）→ 步骤被捕获 → 停止录制 → 填写名称 → WorkflowLibrary 出现新条目
- 新条目对应的 JSON 文件存在于 workflowDir，内容包含完整步骤和元数据
- 重启 Electron 后 WorkflowLibrary 仍然显示保存的作业流

---

## Phase 8: 作业流回放

**交付内容**：
- `Player` 类：加载 workflow JSON，按 seq 顺序调用 McpClient.callTool；元素定位策略：先用步骤中的 semanticInfo（text/label/role）在当前 a11y snapshot 中重新定位，成功则执行；失败则触发 AI 重定位（Claude 看当前 snapshot 找对应元素，模型使用 sonnet）；AI 重定位失败则抛出 `ElementNotFoundError` 终止回放
- WorkflowLibrary 行的 "▶" 按钮触发回放，回放状态通过 `player:step` IPC event 推送，在 ChatPanel 中新增一条 AI 消息并实时更新步骤列表（与 Phase 6 的 StepList 组件复用）
- 回放中 Toolbar 显示 "▶ 回放中 X/N" 进度文字，不可同时启动新任务
- 回放完成在 ChatPanel 显示成功 summary；失败触发 ErrorOverlay（与 Phase 6 复用）

**关键文件**：
- `src/main/player.ts` — Player 类：加载 workflow、顺序执行、语义重定位、AI fallback 重定位、事件推送
- `src/main/ipc-handlers/player.ts` — IPC handlers：`player:run`、`player:stop`
- `src/renderer/src/components/WorkflowLibrary.tsx` — ▶ 按钮绑定 `api.player.run(workflowId)`
- `src/preload/index.ts` — 新增 player IPC 接口

**验收标准**：
- 录制一个"点击页面按钮并填写表单"的 3-5 步作业流 → 回放时浏览器重现操作 → ChatPanel 显示步骤进度
- 若目标元素位置变化，AI 重定位能找到并继续执行
- 故意删除目标元素，AI 重定位失败后 ErrorOverlay 展示 `ElementNotFoundError`

---

## Phase 9: 登录管理（Cookie 持久化）

**交付内容**：
- `LoginManager` 类：`captureSession()` 在 WebContentsView 导航完成后检查 cookie，若检测到 Datalink session cookie（通过 `datalinkUrl` 域名下有效 cookie 判断），则通过 `session.cookies.get` 提取全部 cookie，JSON 序列化后用 `safeStorage.encryptString` 加密存入 electron-store 的 `savedSession` 字段
- 应用启动时 `LoginManager.restoreSession()`：读取 `savedSession`，解密后通过 `session.cookies.set` 注入到 WebContentsView 的 session，再导航到 datalinkUrl（若无 savedSession 则直接导航让用户手动登录）
- ChatPanel 增加登录状态指示：底部输入框上方显示 "● 已登录 Datalink" (绿色) 或 "○ 未登录，请在右侧浏览器完成登录" (灰色)
- Toolbar 增加"重新登录"菜单项：清除 savedSession + 清除 WebContentsView cookies + 重新导航到 datalinkUrl

**关键文件**：
- `src/main/login-manager.ts` — LoginManager 类：captureSession / restoreSession / clearSession
- `src/main/browser-view.ts` — 在 did-navigate 事件中调用 LoginManager.captureSession()
- `src/main/ipc-handlers/login.ts` — IPC handlers：`login:status`、`login:clear`
- `src/renderer/src/components/ChatPanel.tsx` — 显示登录状态指示
- `src/preload/index.ts` — 新增 login IPC 接口

**验收标准**：
- 手动在右侧浏览器完成 Datalink 登录（包含短信验证码）后，ChatPanel 显示"已登录"
- 关闭并重启 Electron → 自动注入 Cookie → 右侧浏览器直接进入登录后状态（无需重新登录）
- 点击"重新登录"清除状态后，右侧浏览器返回登录页

---

## Phase 10: 错误日志 + 截图 + 日志查看器

**交付内容**：
- `Logger` 类：每次执行（AI 对话/回放）开始时创建 `{workflowDir}/logs/YYYY-MM-DD_HH-mm-ss.log` 文件；每步追加一行：`[timestamp] [STEP N] [STATUS] tool=xxx args=yyy duration=Zms`；执行结束追加 SUMMARY 行
- 步骤失败时调用 `WebContentsView.capturePage()` 截取当前浏览器画面，保存到 `{workflowDir}/screenshots/error_YYYY-MM-DD_HH-mm-ss.png`；ErrorOverlay 展示截图缩略图
- 日志查看器：Toolbar 新增"日志"图标 → 打开日志列表 overlay，列出历史日志文件（文件名 + 大小 + 最后修改时间）；点击一条打开详情 overlay（滚动显示日志内容）

**关键文件**：
- `src/main/logger.ts` — Logger 类：createSession / appendStep / appendSummary / list / read
- `src/main/browser-view.ts` — 截图方法封装 `captureErrorScreenshot()`
- `src/main/ipc-handlers/logs.ts` — IPC handlers：`logs:list`、`logs:read`
- `src/renderer/src/components/LogViewer.tsx` — 日志列表 + 详情 overlay
- `src/renderer/src/components/ErrorOverlay.tsx` — 新增截图缩略图（通过 IPC 读取截图 base64）
- `src/preload/index.ts` — 新增 logs IPC 接口

**验收标准**：
- 执行一次 AI 对话后，`logs/` 目录下出现对应 `.log` 文件，内容包含每步记录
- 故意触发失败，`screenshots/` 目录下出现截图文件，ErrorOverlay 显示截图缩略图
- 日志查看器能列出历史日志并查看内容

---

## 技术栈

| 层级 | 技术 | 版本 | 说明 |
|------|------|------|------|
| 桌面框架 | Electron | 33.x | 跨平台桌面壳，WebContentsView 嵌入浏览器 |
| 构建工具 | electron-vite | 2.x | Electron 专用 Vite，三入口（main/preload/renderer） |
| 前端框架 | React + TypeScript | 19.x / 5.8 | 渲染进程 UI |
| UI 样式 | Tailwind CSS | 4.x | 工具类 CSS |
| AI SDK | @anthropic-ai/sdk | 0.100.x | Claude API tool_use，haiku/sonnet 分工 |
| 浏览器控制 | chrome-devtools-mcp | latest（npx） | MCP server，26 个浏览器操作工具，基于 Puppeteer |
| 本地存储 | electron-store | 10.x | 加密配置（API Key / Cookie）持久化 |
| 打包 | electron-builder | 25.x | Windows 安装包输出 |
| 包管理 | npm | 10.x | 项目已有，保持一致 |

## 开发规则

- 每完成一个 Phase 执行四步走：Code Review → 测试完整性 → 编译验证 → 功能测试
- 四步走全部通过后才能 commit
- Commit message 格式：`phase-N: 简要描述`（例：`phase-1: electron-vite 骨架迁移完成`）
- IPC 命名规范：`domain:action`（例：`agent:run`、`browser:navigate`、`workflow:list`）
- 主进程不直接操作 DOM，渲染进程不直接访问 Node.js / Electron API（全部通过 contextBridge）
- chrome-devtools-mcp 子进程随主进程启动，主进程退出时显式 kill 子进程
- 包管理器：npm
