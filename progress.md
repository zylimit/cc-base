# Project: datalink-automation
_Last updated: 2026-06-07_

## Pinned（仅高置信"必须遵守"写入；受保护不可修订）
    - 浏览器自动化需要本地权限，必须使用桌面应用架构（非 Web 服务）
    - 写测独立性：测试代码须由独立于实现者的 fresh 实例编写
    - AI Provider：Google AI Studio（Gemini API），不使用 Claude API

## Decisions（按时间顺序追加，历史不可改）
    - 2026-06-07: 重新规划——清空旧代码和 DEV-PLAN.md，基于 Product-Spec + Design-Brief 重建
    - 2026-06-07: AI Provider：改用 Google AI Studio（Gemini API），SDK 为 @google/generative-ai v0.8.x
    - 2026-06-07: 技术栈：Electron 33 + electron-vite 5 + React 19 + TypeScript 5.8 + Tailwind 4 + chrome-devtools-mcp (npx latest) + electron-store 10
    - 2026-06-07: 浏览器嵌入方案：Electron WebContentsView（替代 webview tag），开启 remote-debugging-port=9222 供 chrome-devtools-mcp 连接
    - 2026-06-07: LLM 分工：gemini-2.5-flash 用于简单操作，gemini-2.5-pro 用于复杂元素定位
    - 2026-06-07: 作业流存储：本地 JSON 文件（用户可配置目录），不使用数据库

## TODO（权威待办清单）
    - [P1][OPEN][#1] Phase 1：项目骨架搭建（electron-vite + React + Tailwind）
    - [P2][OPEN][#2] Phase 2：UI 界面（暗夜工程台风格）
    - [P3][OPEN][#3] Phase 3：内置浏览器（WebContentsView）
    - [P4][OPEN][#4] Phase 4：chrome-devtools-mcp 集成
    - [P5][OPEN][#5] Phase 5：Gemini API 集成
    - [P6][OPEN][#6] Phase 6：对话驱动自动化（完整执行循环）
    - [P7][OPEN][#7] Phase 7：录制功能（作业流捕获）
    - [P8][OPEN][#8] Phase 8：作业流回放
    - [P9][OPEN][#9] Phase 9：登录管理（Cookie 持久化）
    - [P10][OPEN][#10] Phase 10：错误日志 + 截图 + 日志查看器

## In Progress

## Done（最近完成的放前面）
    - 2026-06-07: 项目重置——清空旧代码和 DEV-PLAN.md，commit a154bf7
    - 2026-06-07: 新 DEV-PLAN.md 生成——10 个 Phase，Gemini API 方案

## Risks & Assumptions
    - Risk: chrome-devtools-mcp 要求 Node.js 22+，需确认开发环境版本（Mitigation：开发前检查 node --version，不满足则升级）
    - Risk: WebContentsView bounds 同步在 Windows 高 DPI 屏幕可能有偏移问题（Mitigation：Phase 3 内置浏览器阶段重点测试高 DPI 场景）

## Notes（简要要点）

## Context Index（轻量索引）
    - Archive：./progress.archive.md（若存在）