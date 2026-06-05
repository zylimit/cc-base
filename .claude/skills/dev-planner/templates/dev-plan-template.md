---
name: dev-plan-template
description: DEV-PLAN.md 输出模板。分析 Product Spec 后，按此模板结构填充内容，输出为 DEV-PLAN.md，供 dev-builder 按 Phase 逐步开发。
---

# DEV-PLAN 输出模板

本模板用于生成分阶段开发计划。dev-builder 读取此文档按 Phase 逐步实现代码。

---

## 模板结构

**文件命名**：DEV-PLAN.md

---

```markdown
# Development Plan — [项目名称]

> 本文件记录项目的开发阶段划分、当前进度和剩余工作。
> 新 session 启动时应首先阅读此文件，了解项目状态后再继续开发。

---

## Phase 1: [功能名称]

**交付内容**：
- [用动词开头，描述交付物1——用户能做什么 / 系统做什么]
- [交付物2]
- [交付物3]

**关键文件**：
- `src/path/to/file1.tsx` — [用途说明]
- `src/path/to/file2.ts` — [用途说明]
- `src/path/to/file3.ts` — [用途说明]

**验收标准**：
- [能编译、能启动、能看到XX效果]

---

## Phase 2: [功能名称]

**交付内容**：
- [交付物列表]

**关键文件**：
- [文件路径 + 用途]

**验收标准**：
- [验证标准]

---

<根据实际功能数量动态增减 Phase>

---

## 技术栈

| 层级 | 技术 | 版本 | 说明 |
|------|------|------|------|
| [层级名] | [技术名] | [版本号] | [选择理由或用途] |

## 数据库表（如有）

| 表名 | 所属 Phase | 用途 |
|------|-----------|------|
| `table_name` | Phase N | [用途说明] |

## 开发规则

- 每完成一个 Phase 执行四步走：Code Review → 测试完整性 → 编译验证 → 功能测试
- 四步走全部通过后才能 commit
- Commit message 格式：`phase-N: 简要描述`
- 包管理器：[pnpm/npm/yarn]
```

---

## 完整示例

以下是「Forge — 本地 AI 桌面代理」项目的 DEV-PLAN 片段，供参考：

```markdown
# Development Plan — Forge

> 本文件记录 Forge 项目的开发阶段划分、当前进度和剩余工作。
> 新 session 启动时应首先阅读此文件，了解项目状态后再继续开发。

---

## Phase 1: Electron + Next.js 骨架

**交付内容**：
- Electron 主进程 + Next.js 渲染器基础框架
- 三区布局：左侧栏（可折叠）+ 主内容区 + 右侧栏（可折叠）
- 标题栏组件（窗口控制按钮）
- 导航图标栏（聊天 / 管理 / IM / 定时 / 设置）
- 深色/浅色/跟随系统主题切换（ThemeProvider）
- Tailwind CSS 语义色彩系统

**关键文件**：
- `src/components/layout/app-layout.tsx` — 主布局
- `src/components/layout/left-sidebar.tsx` — 左侧栏
- `src/components/layout/right-sidebar.tsx` — 右侧栏
- `src/components/layout/title-bar.tsx` — 标题栏
- `src/components/providers/theme-provider.tsx` — 主题
- `src/app/globals.css` — 色彩变量定义

**验收标准**：
- TypeScript 编译无错误
- Electron 窗口可启动，显示三区布局
- 主题切换正常工作

---

## Phase 2: 聊天核心 + SQLite 持久化

**交付内容**：
- SQLite 数据库初始化（better-sqlite3，WAL 模式）
- sessions 和 messages 表
- settings 表（key-value 全局设置）
- 会话 CRUD API（/api/sessions）
- 聊天 API（/api/chat）— Claude API 流式调用 + SSE 输出
- 前端聊天界面：用户消息 + Agent 消息 + 流式渲染
- 会话列表 + 新建会话 + 切换会话

**关键文件**：
- `src/lib/db.ts` — 数据库初始化 + 表创建
- `src/app/api/chat/route.ts` — 聊天 API
- `src/hooks/use-chat.ts` — 聊天状态管理
- `src/hooks/use-sessions.ts` — 会话管理
- `src/components/views/chat-view.tsx` — 聊天视图

**验收标准**：
- 能创建会话、发送消息、收到 Claude 流式回复
- 刷新后会话和消息不丢失

---

## 技术栈

| 层级 | 技术 | 版本 | 说明 |
|------|------|------|------|
| 桌面框架 | Electron | 40.x | 跨平台桌面壳 |
| 前端 | Next.js + React | 15.x | 全栈框架 |
| UI | Tailwind CSS | 4.x | 工具类 CSS |
| AI 引擎 | Claude API (@anthropic-ai/sdk) | latest | 核心 AI 能力 |
| 数据库 | SQLite (better-sqlite3) | latest | 本地持久化，WAL 模式 |
| 包管理 | pnpm | 10.x | 快速、磁盘高效 |

## 数据库表

| 表名 | 所属 Phase | 用途 |
|------|-----------|------|
| `sessions` | Phase 2 | 会话元数据 |
| `messages` | Phase 2 | 消息内容（JSON content blocks） |
| `settings` | Phase 2 | 全局 key-value 设置 |
| `skills` | Phase 3 | Skill 定义 |
| `agents` | Phase 3 | Agent 配置 |
| `mcp_servers` | Phase 3 | MCP 服务器配置 |
| `im_channels` | Phase 4 | IM 通道配置 |
| `cron_tasks` | Phase 4 | 定时任务定义 |
| `api_providers` | Phase 5 | 多模型 API 提供商 |
| `workspaces` | Phase 6 | Workspace 定义 |

## 开发规则

- 每完成一个 Phase 执行四步走：Code Review → 测试完整性 → 编译验证 → 功能测试
- 四步走全部通过后才能 commit
- Commit message 格式：`phase-N: 简要描述`
- 包管理器：pnpm
```

---

## 写作要点

1. **Phase 命名**：用功能名称命名，不用编号序列。"聊天核心 + SQLite 持久化"比"Phase 2"更容易理解
2. **交付内容**：
   - 用动词开头（搭建、实现、创建、配置）
   - 每条描述一个可感知的交付物
   - 基础设施 Phase 可以写"XX 表 + CRUD API"
   - 业务功能 Phase 要写用户能做什么
3. **关键文件**：
   - 使用完整的项目内相对路径
   - 每个文件附用途说明
   - 不列测试文件和配置文件（除非是 Phase 的核心交付物）
4. **验收标准**：
   - 最低要求：能编译 + 能启动 + 新功能可用
   - 推荐加上：现有功能未破坏
5. **技术栈表**：
   - 标注版本号（经 WebSearch 验证的最新稳定版）
   - 说明列写选择理由或用途
6. **数据库表**：
   - 标注在哪个 Phase 创建
   - 后续 Phase 如果新增列（migration），在该 Phase 的交付内容中说明
7. **Phase 顺序**：
   - 基础设施（骨架/数据库/路由）→ 核心功能 → 辅助功能 → 收尾（i18n/打包/部署）
   - 不违反依赖关系
