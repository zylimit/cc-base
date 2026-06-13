# cc-base

纯 Claude Code 框架底座：把一套经过血泪迭代的 hooks / skills / agents / feedback 经验，注入式安装到任意项目，让 Claude Code 在该项目里按既定职责边界、TDD 闸门、审查闭环、三文件同步等规则工作。无 CCB / 无 codex / 无 tmux 依赖。

## 装什么

注入式安装把以下框架资产复制进 target 项目的 `.claude/`，并把 hooks 合并进 `target/.claude/settings.json`（不覆盖你已有的其他配置）：

- `CLAUDE.md` —— 主控规则（职责边界、Skill 调用、四步走验证、记忆规则）
- `hooks/` —— 闸门钩子（stop-gate 待审拦截、no-direct-code-guard、tdd-gate、pre-commit-check、dangerous-pkill-guard 等）
- `skills/` —— 9 个工作流 Skill（product-spec / dev-planner / dev-builder / code-review / test-builder / bug-fixer / release-builder …）
- `agents/` —— Sub-Agent 定义（implementer / code-reviewer / tester / deployer …）
- `feedback/` —— 经验教训库 + 索引

运行时产物（`.needs-review`、`.tdd-exempt` 等标记、`settings.local.json`）不随装。

## 一键安装

### Mac / Linux

```bash
./setup.sh ~/code/your-project     # 装到指定项目
./setup.sh                         # 不带参数 = 装到当前目录
```

需要 `jq`（用于 settings.json 合并）。hooks 走 `.sh`，依赖 Git Bash / bash 环境展开 `$CLAUDE_PROJECT_DIR`。

### Windows（纯 PowerShell）

```powershell
pwsh -File setup.ps1 -Target C:\path\to\project    # 装到指定项目
pwsh -File setup.ps1                               # 不带参数 = 装到当前目录
pwsh -File setup.ps1 -Target C:\path -Force        # 覆盖已有 settings.json（先备份 .bak）
```

## .sh / .ps1 双写机制

每个 hook 同时提供 `.sh`（Mac/Linux）和 `.ps1`（Windows）两份等价实现，同名不同扩展放在 `.claude/hooks/`。两套逻辑严格行为等价：相同输入 → 相同 exit code（0=放行 / 2=拦截）。

**Windows 为何走 .ps1（不复用 .sh）**：Claude Code 只加载固定名 `.claude/settings.json` 这一个文件。`setup.ps1` 安装时直接把该文件里的 hook command 改写为 PowerShell 形式：

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& '$env:CLAUDE_PROJECT_DIR\.claude\hooks\<name>.ps1'"
```

`-Command + $env:` 让 powershell 自己展开环境变量，不依赖外层 shell。之所以不让 Windows 用户走 Git Bash 跑 `.sh`：Claude Code 的 Git Bash 自动检测有已知 bug（#22700），不可靠——直接走 `.ps1` 最稳。
