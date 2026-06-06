# Project: datalink-automation
_Last updated: 2026-06-07_

## Pinned（仅高置信"必须遵守"写入；受保护不可修订）
    - 浏览器自动化需要本地权限，必须使用桌面应用架构（非 Web 服务）
    - 写测独立性：测试代码须由独立于实现者的 fresh 实例编写

## Decisions（按时间顺序追加，历史不可改）
    - 2026-06-07: 放弃前后端分离架构——浏览器自动化需要本地权限，改为纯 Electron 桌面应用架构
    - 2026-06-07: 技术栈确认：Electron 33 + electron-vite 2 + React 19 + TypeScript 5.8 + Tailwind 4 + @anthropic-ai/sdk 0.100 + chrome-devtools-mcp (npx latest) + electron-store 10
    - 2026-06-07: 浏览器嵌入方案：Electron WebContentsView（替代 webview tag），开启 remote-debugging-port=9222 供 chrome-devtools-mcp 连接
    - 2026-06-07: LLM 分工：claude-haiku-4-5-20251001 用于简单操作，claude-sonnet-4-6 用于复杂元素定位
    - 2026-06-07: 作业流存储：本地 JSON 文件（用户可配置目录），不使用数据库

## TODO（权威待办清单）
    - [P1][OPEN][#1] 开始 Phase 1：Electron + Vite 骨架迁移（现有代码为纯 Vite React 原型，需迁移至 electron-vite 结构）

## In Progress

## Done（最近完成的放前面）
    - 2026-06-07: Design Brief 已生成（Design-Brief.md）——暗夜工程台风格，#0B0B0C 底色 + #F97316 琥珀橙强调色，紧凑密度，参考 Cursor IDE × Grafana
    - 2026-06-07: DEV-PLAN.md 已生成——10 个 Phase，覆盖 Spec 全部功能（骨架迁移 → UI重构 → 配置存储 → 内置浏览器 → MCP+Claude集成 → 对话执行 → 录制 → 回放 → 登录管理 → 错误日志）

## Risks & Assumptions
    - Risk: chrome-devtools-mcp 要求 Node.js 22+，需确认开发环境版本（Mitigation：开发前检查 node --version，不满足则升级）
    - Risk: WebContentsView bounds 同步在 Windows 高 DPI 屏幕可能有偏移问题（Mitigation：Phase 4 内置浏览器阶段重点测试高 DPI 场景）

## Notes（简要要点）

## Context Index（轻量索引）
    - Archive：./progress.archive.md（若存在）
