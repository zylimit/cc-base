# Project: datalink-automation
_Last updated: 2026-06-07_

## Pinned（仅高置信"必须遵守"写入；受保护不可修订）
    - 浏览器自动化需要本地权限，必须使用桌面应用架构（非 Web 服务）
    - 写测独立性：测试代码须由独立于实现者的 fresh 实例编写
    - AI Provider：Google AI Studio（Gemini API），不使用 Claude API
    - 渲染进程不暴露 API Key，API 调用在主进程完成

## Decisions（按时间顺序追加，历史不可改）
    - 2026-06-07: 项目重置——清空旧代码，基于 frontend/ 目录重建
    - 2026-06-07: 技术栈：electron-vite 5 + React 19 + Tailwind 4 + @google/generative-ai 2.4 + chrome-devtools-mcp
    - 2026-06-07: AI 分工：gemini-2.5-flash（简单操作）、gemini-2.5-pro（复杂定位）
    - 2026-06-07: 作业流存储：本地 JSON 文件（用户可配置目录）
    - 2026-06-07: 前端代码来源：Google AI Studio 生成的 frontend/ 目录
    - 2026-06-07: 浏览器嵌入：Electron WebContentsView，remote-debugging-port=9222

## TODO（权威待办清单）
    - [P1][OPEN][#1] Phase 1：Electron 骨架迁移（frontend → electron-vite 结构）
    - [P2][OPEN][#2] Phase 2：内置浏览器 + IPC 基础（WebContentsView + config-store）
    - [P3][OPEN][#3] Phase 3：MCP Client + Gemini Agent（主进程）
    - [P4][OPEN][#4] Phase 4：UI 绑定真实逻辑（hooks + IPC 接入）
    - [P5][OPEN][#5] Phase 5：录制功能（Recorder + workflow-store）
    - [P6][OPEN][#6] Phase 6：回放功能（Player）
    - [P7][OPEN][#7] Phase 7：登录管理 + 错误日志

## In Progress

## Done（最近完成的放前面）
    - 2026-06-07: 新 DEV-PLAN.md 生成——7 个 Phase，基于 frontend/ 代码
    - 2026-06-07: frontend/ 目录首次提交（Google AI Studio 生成）

## Risks & Assumptions
    - Risk: chrome-devtools-mcp 要求 Node.js 22+，需确认开发环境版本（Mitigation：开发前检查 node --version）
    - Risk: WebContentsView bounds 同步在 Windows 高 DPI 屏幕可能有偏移（Mitigation：Phase 2 测试）

## Notes（简要要点）

## Context Index（轻量索引）
    - Archive：./progress.archive.md（若存在）