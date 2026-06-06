# Development Plan — DataLink Automation Platform

> 本文件记录项目的开发阶段划分、当前进度和剩余工作。
> 新 session 启动时应首先阅读此文件，了解项目状态后再继续开发。
>
> **当前状态**：已有 Google AI Studio 生成的前端代码（frontend/），需迁移到 electron-vite 架构并集成真实后端。
> **AI 集成**：Google AI Studio（Gemini API），@google/generative-ai v2.4.0。

---

## 项目结构

```
datalink-automation/
├── src/
│   ├── main/                    # Electron 主进程（Node.js）
│   │   ├── index.ts             # 入口，创建 BrowserWindow
│   │   ├── browser-view.ts      # WebContentsView 管理
│   │   ├── gemini-agent.ts      # Gemini API 调用 + tool call 循环
│   │   ├── mcp-client.ts        # chrome-devtools-mcp 客户端（stdio）
│   │   ├── recorder.ts          # 录制拦截器
│   │   ├── player.ts            # 回放执行器
│   │   ├── login-manager.ts     # Cookie 管理
│   │   ├── logger.ts             # 日志写入
│   │   ├── config-store.ts       # electron-store 封装
│   │   └── ipc-handlers/         # IPC 处理器
│   │       ├── agent.ts         # agent:run, agent:step
│   │       ├── browser.ts        # browser:navigate, browser:back, etc.
│   │       ├── workflow.ts       # workflow:list, workflow:save, etc.
│   │       ├── login.ts          # login:status, login:clear
│   │       └── logs.ts           # logs:list, logs:read
│   ├── preload/                  # Preload scripts（contextBridge）
│   │   ├── index.ts              # 暴露 window.api
│   │   └── index.d.ts            # TypeScript 类型声明
│   └── renderer/                 # React 渲染进程（原 frontend/src/）
│       ├── index.html
│       ├── src/
│       │   ├── main.tsx
│       │   ├── App.tsx
│       │   ├── index.css
│       │   ├── types.ts
│       │   ├── components/       # 已有组件（Sidebar, BrowserMock, Modals）
│       │   ├── hooks/           # 新增：useAgent.ts, useWorkflow.ts
│       │   ├── services/         # 新增：ipc.ts（IPC 封装）
│       │   └── styles/           # 已有全局样式
│       └── (其他配置)
├── frontend/                    # 原始生成代码（保留，Phase 1 后可删除）
├── electron.vite.config.ts
├── package.json
└── tsconfig.json
```

---

## Phase 1: Electron 骨架迁移

**交付内容**：
- 将 `frontend/src/` 迁移到 `src/renderer/src/`
- 创建 `src/main/index.ts`（Electron 主进程入口）
- 创建 `src/preload/index.ts`（contextBridge IPC 桥接）
- 创建 `electron.vite.config.ts`（main/preload/renderer 三入口）
- 保留现有 UI 组件不动，验证 Electron 窗口能启动并显示 UI
- 安装必要依赖：electron@33、electron-vite@5、electron-store@10

**关键文件**：
- `src/main/index.ts` — BrowserWindow 1440x900 frameless，加载 renderer
- `src/preload/index.ts` — `window.api` 暴露（ping 测试接口）
- `src/preload/index.d.ts` — TypeScript 类型声明
- `electron.vite.config.ts` — electron-vite 配置
- `package.json` — 更新 dependencies，添加 electron、electron-vite、electron-store
- `tsconfig.json` + `tsconfig.node.json` + `tsconfig.web.json`
- `src/renderer/index.html` — 从 frontend/index.html 迁移

**验收标准**：
- `npm run dev` 启动 Electron 窗口
- 窗口内显示原有 UI（与 frontend/ 跑 Vite 时一致）
- TypeScript 编译零错误
- IPC ping handler 工作正常

---

## Phase 2: 内置浏览器 + IPC 基础

**交付内容**：
- `src/main/browser-view.ts` — WebContentsView 生命周期管理
  - 创建/销毁/bounds 同步
  - navigate/back/forward/reload
  - `--remote-debugging-port=9222` 启动参数
- `src/main/ipc-handlers/browser.ts` — IPC handlers
  - `browser:navigate` — 导航到指定 URL
  - `browser:back` / `browser:forward` / `browser:reload`
  - `browser:get-url` — 获取当前 URL
- `src/preload/index.ts` — 更新，暴露 browser 相关 IPC
- `src/renderer/src/components/BrowserPanel.tsx` — 新建（替代 BrowserMock）
  - 地址栏 + 前进/后退/刷新按钮
  - 通过 IPC 控制 WebContentsView
  - 右侧面板叠在 WebContentsView 上
- `src/main/config-store.ts` — electron-store 封装（API Key 加密存储）

**关键文件**：
- `src/main/browser-view.ts`
- `src/main/config-store.ts`
- `src/main/ipc-handlers/browser.ts`
- `src/preload/index.ts`（更新）
- `src/preload/index.d.ts`（更新）
- `src/renderer/src/components/BrowserPanel.tsx`（新建，替代 BrowserMock）

**验收标准**：
- 右侧面板加载真实网页（https://example.com 验证）
- 地址栏显示当前 URL，前进/后退/刷新可用
- 窗口 resize 时浏览器区域随之调整
- `http://localhost:9222/json` 可查看页面列表

---

## Phase 3: MCP Client + Gemini Agent

**交付内容**：
- `src/main/mcp-client.ts` — McpClient 类
  - spawn `npx chrome-devtools-mcp@latest` 子进程
  - MCP stdio JSON-RPC 协议（initialize / tools/list / tools/call）
  - 26 个工具列表可获取
  - 主进程退出时 kill 子进程
- `src/main/gemini-agent.ts` — GeminiAgent 类
  - 接收 prompt，调用 Gemini API
  - 将 MCP 工具注册为 Gemini function declarations
  - 实现 tool call 循环：function call → callTool → 追加结果 → 再次调用
  - 通过 `agent:step` IPC event 实时推送每步状态
  - 模型分工：gemini-2.5-flash（简单操作）、gemini-2.5-pro（复杂定位）
- `src/main/ipc-handlers/agent.ts` — IPC handler
  - `agent:run(prompt, history)` — 触发 GeminiAgent
  - `agent:step` — 实时推送步骤状态
- `src/preload/index.ts` — 更新，暴露 agent IPC
- `frontend/src/components/Sidebar.tsx` — 更新第 77 行（"Claude-Sonnet-4.6" → "Gemini 2.5 Pro"）
- `frontend/src/components/SettingsModal.tsx` — 更新（"Claude API Key" → "Google AI Studio API Key"，模型选项改为 Gemini）

**关键文件**：
- `src/main/mcp-client.ts`
- `src/main/gemini-agent.ts`
- `src/main/ipc-handlers/agent.ts`
- `src/preload/index.ts`（更新）
- `src/renderer/src/components/Sidebar.tsx`（更新标签）
- `src/renderer/src/components/SettingsModal.tsx`（更新表单）

**验收标准**：
- MCP 子进程启动成功，26 个工具可获取
- Gemini API 连接成功（配置 API Key 后）
- 用户输入 "截图当前页面" → Gemini 调用 `take_screenshot` → 截图 base64 返回
- `agent:step` 事件实时推送，控制台能看到每步工具调用

---

## Phase 4: UI 绑定真实逻辑

**交付内容**：
- `src/renderer/src/hooks/useAgent.ts` — 封装 IPC 调用
  - `useAgent()` hook：管理 agent:run 调用和 agent:step 监听
  - 步骤状态管理（waiting → running → success/error）
- `src/renderer/src/services/ipc.ts` — IPC 封装层
- `src/renderer/src/components/Sidebar.tsx` — 接入 useAgent
  - 发送消息 → `api.agent.run()`
  - 接收 `agent:step` → 更新消息状态
  - 执行中禁用输入框
- `src/renderer/src/components/ChatPanel.tsx` — 渲染真实步骤列表
  - 复用现有 Sidebar 的消息渲染逻辑
  - AI 消息内嵌步骤列表（状态点 + 工具名 + 参数）
- `src/renderer/src/components/ErrorOverlay.tsx` — 接入错误事件
  - 步骤失败时弹出，显示工具名、参数、错误信息

**关键文件**：
- `src/renderer/src/hooks/useAgent.ts`（新建）
- `src/renderer/src/services/ipc.ts`（新建）
- `src/renderer/src/components/Sidebar.tsx`（更新，接入 IPC）
- `src/renderer/src/components/ErrorModal.tsx`（更新，接入错误状态）

**验收标准**：
- 用户输入 "帮我点击页面上的新建按钮" → 浏览器中按钮被点击
- 步骤列表实时更新（等待→执行中→成功/失败）
- 错误时 ErrorModal 弹出，显示失败详情

---

## Phase 5: 录制功能

**交付内容**：
- `src/main/recorder.ts` — Recorder 类
  - `start()` — 开始拦截 McpClient.callTool
  - `stop()` — 返回步骤数组 `{ seq, tool, args, semanticInfo, screenshotRef, timestamp }`
  - `semanticInfo` 从 args 中提取（text/label/role）
- `src/main/workflow-store.ts` — 作业流文件管理
  - `saveWorkflow(name, description, steps)` → `{workflowDir}/{slug}.json`
  - `listWorkflows()` / `loadWorkflow(id)` / `deleteWorkflow(id)`
- `src/main/ipc-handlers/workflow.ts` — IPC handlers
  - `workflow:list` / `workflow:save` / `workflow:delete` / `workflow:rename`
- `src/renderer/src/components/Sidebar.tsx` — 录制按钮
  - 点击切换录制状态，录制中 amber 高亮脉冲
- `src/renderer/src/components/WorkflowModal.tsx` — 从 IPC 加载真实数据

**关键文件**：
- `src/main/recorder.ts`
- `src/main/workflow-store.ts`
- `src/main/ipc-handlers/workflow.ts`
- `src/renderer/src/components/Sidebar.tsx`（更新录制逻辑）

**验收标准**：
- 点击录制 → 操作浏览器 → 停止录制 → 填写名称 → WorkflowModal 出现新条目
- JSON 文件存在于 workflowDir，内容包含完整步骤和元数据

---

## Phase 6: 回放功能

**交付内容**：
- `src/main/player.ts` — Player 类
  - `run(workflowId)` — 加载 workflow，按 seq 顺序执行
  - 语义重定位：先用 semanticInfo 在当前 a11y snapshot 定位
  - AI fallback：定位失败则调用 Gemini 重定位
  - `ElementNotFoundError` 终止回放
- `src/main/ipc-handlers/player.ts` — IPC handlers
  - `player:run` / `player:stop`
- `src/renderer/src/components/WorkflowModal.tsx` — ▶ 按钮绑定 `api.player.run()`
- ChatPanel 实时展示回放进度（复用 Phase 4 步骤列表组件）

**关键文件**：
- `src/main/player.ts`
- `src/main/ipc-handlers/player.ts`
- `src/renderer/src/components/WorkflowModal.tsx`（更新 ▶ 按钮逻辑）

**验收标准**：
- 录制 3-5 步作业流 → 回放时浏览器重现操作
- 目标元素变化时，AI 重定位能找到并继续
- AI 重定位失败后 ErrorModal 展示 ElementNotFoundError

---

## Phase 7: 登录管理 + 错误日志

**登录管理**：
- `src/main/login-manager.ts` — LoginManager 类
  - `captureSession()` — WebContentsView 导航完成后检查 cookie，加密存入 electron-store
  - `restoreSession()` — 应用启动时解密注入 cookie，再导航 datalinkUrl
  - `clearSession()` — 清除 savedSession 和 cookies
- `src/main/ipc-handlers/login.ts` — IPC：`login:status` / `login:clear`
- `src/renderer/src/components/Sidebar.tsx` — 显示登录状态指示（底部输入框上方）

**错误日志**：
- `src/main/logger.ts` — Logger 类
  - 每次执行创建 `{workflowDir}/logs/YYYY-MM-DD_HH-mm-ss.log`
  - 每步追加：`[timestamp] [STEP N] [STATUS] tool=xxx args=yyy duration=Zms`
  - 失败时 `WebContentsView.capturePage()` 截图保存
- `src/main/ipc-handlers/logs.ts` — IPC：`logs:list` / `logs:read`
- `src/renderer/src/components/ErrorModal.tsx` — 新增截图缩略图显示
- Toolbar 新增"日志"图标 → 日志查看 overlay

**关键文件**：
- `src/main/login-manager.ts`
- `src/main/logger.ts`
- `src/main/ipc-handlers/login.ts`
- `src/main/ipc-handlers/logs.ts`
- `src/renderer/src/components/Sidebar.tsx`（更新登录状态）
- `src/renderer/src/components/ErrorModal.tsx`（更新截图显示）

**验收标准**：
- 手动登录后重启 Electron，自动注入 Cookie 无需重新登录
- 执行后 logs/ 目录出现 .log 文件
- 失败后 screenshots/ 目录出现截图，ErrorModal 显示缩略图
- 日志查看器能列出历史日志并查看内容

---

## 技术栈

| 层级 | 技术 | 版本 | 说明 |
|------|------|------|------|
| 桌面框架 | Electron | 33.x | 跨平台桌面壳，WebContentsView 嵌入浏览器 |
| 构建工具 | electron-vite | 5.x | Electron 专用 Vite，三入口（main/preload/renderer） |
| 前端框架 | React + TypeScript | 19.x / 5.8 | 渲染进程 UI（原 frontend/） |
| UI 样式 | Tailwind CSS | 4.x | 工具类 CSS（已有） |
| AI SDK | @google/generative-ai | 2.4.x | Gemini API function calling（main process） |
| 浏览器控制 | chrome-devtools-mcp | latest（npx） | MCP server，26 个浏览器操作工具 |
| 本地存储 | electron-store | 10.x | 加密配置（API Key / Cookie）持久化 |
| 打包 | electron-builder | 25.x | Windows 安装包输出 |
| 包管理 | npm | 10.x | 项目已有，保持一致 |

---

## 开发规则

- 每完成一个 Phase 执行四步走：Code Review → 测试完整性 → 编译验证 → 功能测试
- 四步走全部通过后才能 commit
- Commit message 格式：`phase-N: 简要描述`
- IPC 命名规范：`domain:action`（例：`agent:run`、`browser:navigate`、`workflow:list`）
- 主进程不直接操作 DOM，渲染进程不直接访问 Node.js / Electron API（全部通过 contextBridge）
- chrome-devtools-mcp 子进程随主进程启动，主进程退出时显式 kill 子进程
- 包管理器：npm
- 已有代码（frontend/src/）在 Phase 1 迁移后保持不变，只做必要更新（标签文字、API Key 字段名）