# Project: cc-base（Claude Code 单机框架脚手架，Windows + Linux）

_Last updated: 2026-06-14_

> 从 ccb-base（多 Agent/CCB，仅 Linux）派生的**单机版**：用 Claude Code 原生 in-session subagent（implementer / code-reviewer / tester / deployer），不依赖 CCB daemon/tmux/派单。跨平台（Windows 经 Git Bash 跑 hooks）。

## Pinned（必守）
- `.ps1` hooks **纯 ASCII**：Windows PowerShell 5.1 按 GBK 读无 BOM UTF-8，含中文即解析崩。
- hook 命令用 `\$env:CLAUDE_PROJECT_DIR` 转义形式（Git Bash 外层会吞裸 `$env`，详见 release notes）。
- 权限「永不询问」：settings.json `permissions.defaultMode: bypassPermissions`（只跳工具权限提示，不影响 agent 决策提问 + 框架 guard hook）。

## Done
- 2026-06-12~13: Windows 真机踩坑全清——`.ps1` 中文崩 → 纯 ASCII；hook 命令 `$env` 被 Git Bash 吞 → `\$env` 转义；python3 商店桩 / pre-commit 健壮化；setup.ps1/sh 跨平台安装器。release v1.0.0。
- 2026-06-13: 权限 bypassPermissions 从配置层根治「老问我」（commit 09ac284）。
- 2026-06-14: **单模型质量补强**——① static-gate 补回（static-check.sh 识栈跑 shellcheck/ruff/tsc + code-review 加 Stage 0 静态闸，b3c1ed2）；③ code-reviewer 加对抗式红队立场（跨不了模型就跨立场，71b9ffa）。跨模型审查（②）按用户决定不做（Claude Code 只能 Claude，结构上不可能）。

## 单模型 vs CCB（诚实定位）
- 客观轴（TDD/测试/静态闸/证据验收）：与 CCB 持平，模型无关。
- 审查轴：对抗式 QA + 两阶段，比温和 QA 强，但**同模型**——「第二个脑子挑盲区」补不了，是 CCB 唯一硬优势。
- 换来：轻、跨平台、无 CCB 运维脆弱（绑定/pkill/通知失效/daemon）。单用户 Windows 场景划算。

## TODO
- 重切 release（v1.0.1）纳入 static-gate + 对抗式审查（v1.0.0 落后）。
