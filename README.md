# cc-base

纯 Claude Code 框架底座：把一套经过血泪迭代的 hooks / skills / agents / feedback 经验，注入式安装到任意项目，让 Claude Code 在该项目里按既定职责边界、TDD 闸门、审查闭环、三文件同步等规则工作。无 CCB / 无 codex / 无 tmux 依赖。

## 快速部署（3 步）

```bash
# 1. 下载（或到 GitHub Release 页手动下 zip）
gh release download v1.9.4 -R zylimit/cc-base -p '*.zip'

# 2. 解压到任意目录
unzip cc-base-v1.9.4.zip      # Windows: 解压到 cc-base/

# 3. 装到你的项目
bash cc-base/setup.sh /path/to/your-project        # Mac / Linux
pwsh cc-base/setup.ps1 -Target C:\path\to\project  # Windows
```

装完**在该项目目录启动 Claude Code 即生效**。验证：启动后看到 SessionStart 框架横幅 + `/recap` 能恢复项目状态。

- 不带参数 = 装到当前目录。没有 `jq` 也能装（自动降级）。
- 不想跑安装器？直接把 `cc-base/.claude/` 整目录复制到目标项目根即可（见「拷贝即用」）。
- 升级 = 重跑 setup（靠 FRAMEWORK-MANIFEST 安全覆盖，你改过的框架文件不覆盖）。

## 装什么

注入式安装把以下框架资产复制进 target 项目的 `.claude/`，并把 hooks 合并进 `target/.claude/settings.json`（不覆盖你已有的其他配置）：

- `CLAUDE.md` —— 主控规则（职责边界、Skill 调用、四步走验证、记忆规则）
- `rules/` —— 主控下沉的细则（文件结构树 / Workflow 编排 / 工作流程各阶段 / **大仓能力 harness-large-repo**），主控留指针按需读取
- `hooks/` —— 闸门钩子（stop-gate 待审拦截 + diff-bound 回执网关、no-direct-code-guard、tdd-gate、pre-commit-check + 四态质量门、dangerous-pkill-guard、three-file-sync-gate 等；harness 接线经 `lib-harness`，有 catalog 才启用）
- `harness/` —— 大仓治理 harness（`harness.mjs`，**默认关闭**，放 `module-catalog.json` 才启用——见下方「大仓能力」）
- `skills/` —— 15 个工作流 Skill（product-spec / dev-planner / dev-builder / code-review / test-builder / bug-fixer / release-builder / red-blue-review / branch-finisher …）
- `agents/` —— Sub-Agent 定义（implementer / code-reviewer / tester / deployer …）
- `scripts/` —— 质量脚本（doctor 自检 / plan-lint / skill-lint / fast-mode 开关 / fix-platform / gen-manifest / gate-audit）
- `tests/` —— 框架自测（selftest / test-setup / test-routing / 闸回归 / cases，`run-all.sh` 统一跑）
- `workflows/` —— Workflow 编排脚本（code-review-fanout.js，opt-in 多维审查）
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

### 升级

重跑一遍 setup 即升级。安装器靠 `.claude/FRAMEWORK-MANIFEST.txt` 区分框架核心层和项目私有层：你没改过的框架文件安全覆盖升级；**你在项目里改过的框架文件不会被覆盖**，新版本落在旁边的 `<文件>.framework-new`，安装结束会汇总提示，手工合并即可。项目里自己新增的文件（私有 skill / feedback 等）一律不动。框架源侧改动后用 `bash .claude/scripts/gen-manifest.sh` 重新生成清单。

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
"C:/Program Files/PowerShell/7/pwsh.exe" -NoProfile -ExecutionPolicy Bypass -Command "& '$env:CLAUDE_PROJECT_DIR\.claude\hooks\<name>.ps1'"
```

`-Command + $env:` 让 pwsh 自己展开环境变量，不依赖外层 shell。解释器优先探测 pwsh 7（powershell.exe 5.1 会继承被 Git Bash 污染的 PATH，部分机器上 hook 卡死），探测不到才回退 powershell.exe。之所以不让 Windows 用户走 Git Bash 跑 `.sh`：Claude Code 的 Git Bash 自动检测有已知 bug（#22700），不可靠——直接走 `.ps1` 最稳。

## 跨平台搬迁

`.claude/settings.json` 里的 hook command 是**平台绑定**的：Mac/Linux 装出 `.sh` 形态，Windows 装出 `.ps1` 形态。把项目整目录从一平台搬到另一平台时，旧平台 command 会残留——新平台跑不了（`.ps1` 形态搬到 Linux 报 `powershell.exe: not found`；`.sh` 形态搬到纯 PowerShell 的 Windows 跑不了）。

**搬到目标平台后跑一次 `fix-platform` 把 settings.json 归一为本平台形态**（删异平台 hook command、补本平台 command、Linux/Mac 侧补 `chmod 0755 hooks/*.sh` 执行位）：

```bash
# Mac / Linux（搬到 Linux/Mac 后；用 python3，不依赖 jq）
bash .claude/scripts/fix-platform.sh
```
```powershell
# Windows（搬到 Windows 后）
pwsh -File .claude/scripts/fix-platform.ps1
```

`fix-platform` 独立工作——不依赖 cc-base 仓库在场、不依赖 jq（`.sh` 用 python3，`.ps1` 用 pwsh 内置），保守只清框架 hook command 残留、不动你的自定义 hook，幂等可重复跑。

也可直接重跑对应平台的 `setup.sh` / `setup.ps1`：setup 的 settings 合并会先清异平台残留再追加本平台 command（需 jq；无 jq 时 setup 走降级不清，用 `fix-platform` 兜底）。

## 大仓能力（可选——按需开启）

面向 20-30 万行代码规模项目的影响面分析、diff-bound 审查回执、四态质量门。**默认关闭**——小项目零负担，所有 hook 走原逻辑。

**启用 = 在 `.claude/harness/` 放一份合规 `module-catalog.json`**（模块 id / paths globs / dependsOn / verification / owners / riskTier）。文件存在即启用全部大仓能力；删掉即关闭。不动 settings.json、不动任何 hook。

启用后：

- **影响面分析**：`node .claude/harness/harness.mjs impact` 算变更的反向依赖闭包——改一个模块，自动列出所有受影响模块 + 各自该跑的 verification。
- **diff-bound 审查回执**：code-reviewer 通过后写回执绑定当前 diff 的 SHA256，diff 变一个字节旧回执自动 stale，stop-gate 拦停强制重审（把「reviewer 自报通过」升级为机器可验证）。
- **四态质量门**：commit 前对受影响模块跑定向检查，PASS / SKIPPED / FAIL / BLOCKED 四态（缺命令 = BLOCKED 不假绿），pre-commit-check 阻断 FAIL。
- **结构化 waiver**：per-check 豁免（owner / reason / scope / expiry），security 永不可豁免。

完整启用条件、catalog schema、九能力清单、退出码契约、接线点见 `.claude/rules/harness-large-repo.md`（CLAUDE.md「大仓能力」小节指针指向它）。`node .claude/harness/harness.mjs doctor` 看启用态。
