# Project: cc-base（Claude Code 单机框架脚手架，Windows + Linux）

_Last updated: 2026-06-14（22:43）_

> 从 ccb-base（多 Agent/CCB，仅 Linux）派生的**单机版**：用 Claude Code 原生 in-session subagent（implementer / code-reviewer / tester / deployer），不依赖 CCB daemon/tmux/派单。跨平台（Windows 经 Git Bash 跑 hooks）。

## Pinned（必守）
- `.ps1` hooks **纯 ASCII**：Windows PowerShell 5.1 按 GBK 读无 BOM UTF-8，含中文即解析崩。
- hook 命令用 `\$env:CLAUDE_PROJECT_DIR` 转义形式（Git Bash 外层会吞裸 `$env`，详见 release notes）。
- 权限「永不询问」：settings.json `permissions.defaultMode: bypassPermissions`（只跳工具权限提示，不影响 agent 决策提问 + 框架 guard hook）。
- **单模型审查承重墙**：每个判断必须锚定可执行外部证据（测试运行器/编译/grep/Spec 比对）；对抗式立场/多视角 lens 只是廉价补充，不是承重墙。依据：ICLR 2024「LLMs Cannot Self-Correct Reasoning Yet」（纯提示词自我修正会反噬）+ 「Stop Overvaluing Multi-Agent Debate」（同模型 debate 等算力打不过简单投票）。
- **PreCompact hook 不可用于注入提醒**：不支持 additionalContext/hookSpecificOutput（只能 decision:block），且压缩后不触发新 SessionStart——「session 内压缩丢决策」洞在当前机制下无轻量解法，已改用 SessionStart 脏树提醒覆盖跨 session 状态漂移。
- **打/补 git tag 前必须先查远程**：`git ls-remote --tags origin` 查远程在先，不能只查本地 `git tag`——本地无 tag ≠ 远程无 tag，只查本地会误判并打出与远程冲突的 tag。（2026-06-14 踩坑：v1.0.1 本地误判"首个 tag"，实际远程早有 v1.0.1 → 59f207c）
- **.ps1 hook 在 Windows 跑的是 powershell.exe（Windows PowerShell 5.1），不是 pwsh 7.x**（setup.ps1 注释明写 powershell.exe）。5.1 下 native 命令（git/npx 等）写 stderr 会生成 ErrorRecord 进 PS Error 流，`$ErrorActionPreference='Stop'` 把它提升为 terminating error，`*>$null` 拦不住 → 脚本崩、`$LASTEXITCODE` 守卫被绕过 → 错误泄漏到 UI。凡 .ps1 里调可能写 stderr 的 native 命令：用 `--quiet`/`2>$null` 让命令本身不写 stderr，或 `try/catch` 包，或局部 `$ErrorActionPreference='Continue'`。`$PSNativeCommandUseErrorActionPreference` 是 PS 7.3+ 变量，5.1 无效，别用它修。（2026-06-14 真机 trace 验证）

## Done
- 2026-06-14: **Windows PS 5.1 .ps1 hook git fatal 泄漏根治**（commit 9796ae0）——auto-push.ps1 真机 trace 定位：无 upstream commit 后泄漏 "git : fatal: no upstream"。修法：`git rev-parse` 改 `--verify --quiet`（无 upstream 时不写 stderr）+ `git push` 包 `try/catch`。同源加固：recap-on-dirty/tdd-gate（git 探测包 `try/catch`）、pre-commit-check（TS 分支 `npx tsc` 套局部 EAP=Continue）。撤回前一版错误修法 fba58d5。
- 2026-06-12~13: Windows 真机踩坑全清——`.ps1` 中文崩 → 纯 ASCII；hook 命令 `$env` 被 Git Bash 吞 → `\$env` 转义；python3 商店桩 / pre-commit 健壮化；setup.ps1/sh 跨平台安装器。release v1.0.0。
- 2026-06-13: 权限 bypassPermissions 从配置层根治「老问我」（commit 09ac284）。
- 2026-06-14: **单模型质量补强**——① static-gate 补回（static-check.sh 识栈跑 shellcheck/ruff/tsc + code-review 加 Stage 0 静态闸，b3c1ed2）；③ code-reviewer 加对抗式红队立场（跨不了模型就跨立场，71b9ffa）。跨模型审查（②）按用户决定不做（Claude Code 只能 Claude，结构上不可能）。
- 2026-06-14: **文档漂移全面修复**——全局体检（3 只读 Explore agent 交叉扫）发现并修复 3 项漂移（commit 7246478）：① CLAUDE.md + ARCHITECTURE 共 5 处「两阶段」对齐为三阶段（Stage 0 静态闸 / Stage 1 规格 / Stage 2 质量）；② ARCHITECTURE §7 hook 表 6→11 条，补回 5 个 hook + 注脚显性化 static-check.sh 非注册 hook；③ CLAUDE.md 补回 progress-recorder 触发块。顺带排除 3 处 agent 误报（static-check.sh 非 hook、FEEDBACK-INDEX 最新、recap 不走 skill）。
- 2026-06-14: **release v1.0.1 打包发布**——make-release.sh 产物 /tmp/cc-base-v1.0.1.zip（static-gate 资产在包内 / 私人 feedback 已排除 / INDEX 重置干净 / 含最新三阶段 CLAUDE.md）。订正：远程 origin 早已有 `v1.0.1 → 59f207c`（更早发布点）；当时只查本地 `git tag`（为空）误判"无 tag/首个 tag"，补打的本地 v1.0.1 → 7246478 已删除（与远程冲突的多余 tag）。
- 2026-06-14: **release v1.0.2 发布 + GitHub Release 上线**——远程 tag `v1.0.2 → 1413fb9`（已 push），产物 /tmp/cc-base-v1.0.2.zip（152K）；GitHub Release https://github.com/zylimit/cc-base/releases/tag/v1.0.2 已上线（Latest release），附资产 cc-base-v1.0.2.zip（155KB），release notes 含安装方式（gh release download / curl 下载 → setup.sh / setup.ps1 注入安装）；客观核验：gh release download 实测可下载、解压含 setup.sh/setup.ps1/workflow；CoVe 进 code-review SKILL、2 个新 hook（SubagentStop + recap-on-dirty）、code-review-fanout.js 均在包内，私人 feedback 排除、INDEX 重置干净。含本轮 4 项前瞻改进，当前最新发布。
- 2026-06-14: **框架前瞻性改进（基于 3 个外部调研 agent）**——① CoVe 引入 code-review SKILL：每个风险点拆成可独立判定的验证问题、逐条挂外部证据核验，作为单模型审查承重墙（5d43bfa）；② SubagentStop hook 新增（subagent-acceptance-reminder .sh/.ps1，matcher 限 implementer|code-reviewer|tester|deployer），机制化「验收以客观证据为准」铁律（5d43bfa）；③ .claude/workflows/code-review-fanout.js 新增，多维 fan-out 审查 + 逐条 CoVe 多视角对抗 verify，schema 回传结论+证据句柄，可 opt-in 调用（5d43bfa）；④ SessionStart hook recap-on-dirty（.sh/.ps1）——工作树有未提交改动时注入提醒先 /recap 校准 progress.md，补「上下文流失致状态漂移」洞（0cf8ceb）。hook 总数 11→13。

## Decisions
- 2026-06-14: 框架定位确认——cc-base 为轻量框架，不碰多模型/CCB/复杂编排；改进只取「轻量且确定有效」方案。否决方案：Channels、多模型裁判、同模型 debate、完整 eval harness、graph memory、迁 Plugin。理由：轻量优先，CCB 运维脆弱成本过高。
- 2026-06-14: 跨平台/外部工具根因结论必须靠真机证据（trace/实测），不凭表层信息臆断。"查证后再结论"的关键不只是"去查"，是"读到位、读对、不被表层信息覆盖已查到的证据"。（本次连翻两次车：① 误判 hook 跑 pwsh 7.x，实为 5.1，setup.ps1 注释早写明却被用户报告"7.6.2"带偏；② 误判 PSNativeCommandUseErrorActionPreference 默认 $true，WebFetch 文档第 94 行写着 $false 却看走眼）

## 单模型 vs CCB（诚实定位）
- 客观轴（TDD/测试/静态闸/证据验收）：与 CCB 持平，模型无关。
- 审查轴：对抗式 QA + 三阶段（Stage 0 静态闸/Stage 1 规格/Stage 2 质量）+ CoVe 证据锚定，比温和 QA 强，但**同模型**——「第二个脑子挑盲区」补不了，是 CCB 唯一硬优势。
- 换来：轻、跨平台、无 CCB 运维脆弱（绑定/pkill/通知失效/daemon）。单用户 Windows 场景划算。

## TODO
（暂无待办）
