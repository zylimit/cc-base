# cc-base

纯 Claude Code 框架底座：把一套经过血泪迭代的 hooks / skills / agents / feedback 经验，注入式安装到任意项目，让 Claude Code 在该项目里按既定职责边界、TDD 闸门、审查闭环、三文件同步等规则工作。无 CCB / 无 codex / 无 tmux 依赖。

## 装什么

注入式安装把以下框架资产复制进 target 项目的 `.claude/`，并把 hooks 合并进 `target/.claude/settings.json`（不覆盖你已有的其他配置）：

- `CLAUDE.md` —— 主控规则（职责边界、Skill 调用、四步走验证、记忆规则）
- `rules/` —— 主控下沉的细则（文件结构树 / Workflow 编排 / 工作流程各阶段详细步骤），主控留指针按需读取
- `hooks/` —— 闸门钩子（stop-gate 待审拦截、no-direct-code-guard、tdd-gate、pre-commit-check、dangerous-pkill-guard 等）
- `skills/` —— 15 个工作流 Skill（product-spec / dev-planner / dev-builder / code-review / test-builder / bug-fixer / release-builder / red-blue-review / branch-finisher …）
- `agents/` —— Sub-Agent 定义（implementer / code-reviewer / tester / deployer …）
- `feedback/` —— 经验教训库 + 索引

运行时产物（`.needs-review`、`.tdd-exempt` 等标记、`settings.local.json`）不随装。

## 一键安装

### Mac / Linux

```bash
./setup.sh ~/code/your-project     # 装到指定项目
./setup.sh                         # 不带参数 = 装到当前目录
```

需要 `jq`（用于 settings.json 合并）；**没有 jq 也能装**：target 尚无 `.claude/settings.json` 时直接复制框架的，已有时备份 `.bak` 并打印手工合并指引（不静默覆盖）。hooks 走 `.sh`，依赖 Git Bash / bash 环境展开 `$CLAUDE_PROJECT_DIR`。

### Windows（纯 PowerShell）

```powershell
pwsh -File setup.ps1 -Target C:\path\to\project    # 装到指定项目
pwsh -File setup.ps1                               # 不带参数 = 装到当前目录
pwsh -File setup.ps1 -Target C:\path -Force        # 覆盖已有 settings.json（先备份 .bak）
```

## 拷贝即用（快速路径）

不想跑安装器？直接把框架的 `.claude/` 整目录复制到目标项目根即可用——Claude Code 会从 `target/.claude/settings.json` 加载 hooks，从 `CLAUDE.md`、`skills/`、`agents/` 加载工作流，无需额外安装步骤或常驻服务。

```text
target/
└── .claude/        # 整目录复制过去
```

注意两点：

- 目标项目**已有** `.claude/settings.json` 时先人工合并，不要覆盖——要点是把框架 settings.json 里各 event 下的 hook command 追加进你已有的同名 event，已存在的条目不重复加，你项目自己的其他配置一律不动。
- 复制前清掉运行时产物（`.needs-review`、`.tdd-exempt`、`.fast-mode`、`settings.local.json`、feedback 顶层私人经验 *.md）——安装器会自动跳过这些，手工复制要自己留意。

安装器仍是推荐路径（自动排除运行时产物、合并 settings、重置 FEEDBACK-INDEX）；拷贝即用适合快速试用或无 bash/pwsh 安装环境的场合。

## .sh / .ps1 双写机制

每个 hook 同时提供 `.sh`（Mac/Linux）和 `.ps1`（Windows）两份等价实现，同名不同扩展放在 `.claude/hooks/`。两套逻辑严格行为等价：相同输入 → 相同 exit code（0=放行 / 2=拦截）。

**Windows 为何走 .ps1（不复用 .sh）**：Claude Code 只加载固定名 `.claude/settings.json` 这一个文件。`setup.ps1` 安装时直接把该文件里的 hook command 改写为 PowerShell 形式：

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& '$env:CLAUDE_PROJECT_DIR\.claude\hooks\<name>.ps1'"
```

`-Command + $env:` 让 powershell 自己展开环境变量，不依赖外层 shell。之所以不让 Windows 用户走 Git Bash 跑 `.sh`：Claude Code 的 Git Bash 自动检测有已知 bug（#22700），不可靠——直接走 `.ps1` 最稳。
