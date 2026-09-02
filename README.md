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
- `rules/` —— 主控下沉的细则（文件结构树 / Workflow 编排 / 工作流程各阶段 / **大仓能力 harness-large-repo**），主控留指针按需读取；harness/workflow 相关细则带 `paths:` frontmatter，Claude Code 原生按需加载（碰到匹配文件才进上下文）
- `hooks/` —— 闸门钩子（stop-gate 待审拦截 + diff-bound 回执网关、no-direct-code-guard、tdd-gate、pre-commit-check + 四态质量门、dangerous-pkill-guard、**secret-exfil-guard 密钥读/拷/外传闸**、three-file-sync-gate、**precompact-gate 压缩前守门**、**release-gate 发布前置闸**、**harness-async-verify 编辑期后台早警**、**notify 桌面通知**等；harness 接线经 `lib-harness`，有 catalog 才启用）
- `harness/` —— 大仓治理 harness（`harness.mjs`，**默认关闭**，放 `module-catalog.json` 才启用——见下方「大仓能力」）
- `skills/` —— 17 个工作流 Skill（product-spec / **arch-designer 架构设计** / **dfx-designer DFX 设计** / dev-planner / dev-builder / code-review / test-builder / bug-fixer / release-builder / red-blue-review / branch-finisher …）
- `agents/` —— Sub-Agent 定义（implementer / code-reviewer / tester / deployer …）
- `scripts/` —— 质量脚本（doctor 自检 / plan-lint / skill-lint / fast-mode 开关 / fix-platform / gen-manifest / gate-audit / statusline 状态行）
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

## 原生安全层与状态行（settings.json 自带）

框架 settings.json 在 hooks 之外带三层 Claude Code 原生配置：

- **permissions deny/ask（密钥红线 + HIGH 档机器化）**：`Read(**/.env)`、`Read(**/id_rsa*)`、`Read(secrets/**)` 等 deny 规则让密钥文件对任何工具不可读（同路径 Edit/Write 连带被挡，Bash 里的 cat/head/sed 也认；任意子进程绕读由 secret-exfil-guard hook 补拦）；`Bash(git push*)`、`Bash(gh release *)`、`Bash(npm publish*)`、`Bash(docker push*)` ask 规则把「发布/push 必停等审批」做成机器强制——**bypassPermissions 模式下 ask 规则照样弹审批**（官方语义），与审批三档的 HIGH 档一致。
- **statusLine（治理状态常驻可见）**：`.claude/scripts/statusline.sh|.ps1` 显示 `[模型] | ctx N% | $成本 | FAST-MODE 剩余h | 待审 N | harness ON`——fast-mode 忘关、待审欠账、大仓开关全程在眼前，不再只靠开场 banner。
- **env**：`CLAUDE_CODE_STOP_HOOK_BLOCK_CAP=25`——Claude Code 对 Stop 闸有「连拦 8 次强制放行」的原生上限，提额到 25 作兜底（stop-gate 自身三振熔断先触发）。

可选进阶（默认不开，按需自取）：`/sandbox` 开原生 OS 级沙箱（文件系统/网络域名白名单/凭据 mask；Linux/WSL2 需 `apt install bubblewrap socat`，原生 Windows 不支持）；`CLAUDE_CODE_TOOL_MEMORY_LIMIT` 给 Bash 命令加 cgroup 内存上限防跑飞 build 拖死会话（Linux，取值格式见官方 env 文档）；权限模式想要「不打扰 + 分类器兜底」可把 `defaultMode` 改 `"auto"`。五性视角的定位见 `.claude/rules/quality-attributes.md`「Claude Code 原生安全层」节。

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

`fix-platform` 独立工作——不依赖 cc-base 仓库在场、不依赖 jq（`.sh` 用 python3，`.ps1` 用 pwsh 内置），保守只清框架 hook command 残留、不动你的自定义 hook，幂等可重复跑。statusLine 的 command 同样被归一（框架 statusline 路径才动，用户自定义状态行不碰）。

也可直接重跑对应平台的 `setup.sh` / `setup.ps1`：setup 的 settings 合并会先清异平台残留再追加本平台 command（需 jq；无 jq 时 setup 走降级不清，用 `fix-platform` 兜底）。

## Claude Code 之外的强制层（git hooks + CI）

`.claude/hooks/` 那 19 个闸**只在 Claude Code 会话内生效**。用户自己手敲 `git commit`、用别的编辑器提交、脚本或别的 Agent 提交——全都绕得过去。补这个缺口的是另外两层：

| 层 | 位置 | 管到哪 |
|---|---|---|
| Claude Code hook | `.claude/hooks/` | 会话内的每一次工具调用 |
| git hook | `.claude/githooks/` | 凡是走 git 的提交与推送路径，不管谁发起 |
| CI | `.github/workflows/gate.yml` | 所有人、所有分支、所有机器 |

**git hook 层默认不开**——setup 一律不碰 `core.hooksPath`，悄悄改它会把你自己的 `.git/hooks` 整个顶掉。要开显式开（只写本仓库的 `.git/config`）：

```bash
bash .claude/scripts/install-githooks.sh on|off|status
```
```powershell
pwsh .claude/scripts/install-githooks.ps1 on|off|status
```

开了之后：`pre-commit` 跑快的静态检查（三只审计脚本 `--staged` + catalog 在场时的 `catalog-lint`/`fitness`），`commit-msg` 卡 subject 门槛（宽度按显示列算，不按字节也不按字符个数——`fix: 修好登录崩溃` 按字符数会被误拒），`pre-push` 跑全量回归（`CCBASE_PREPUSH_FULL=0` 可降到只跑静态段）。

退出码分档处理，**降级和没跑成一律出声不假绿**：`1`/`2` 阻断，`3` 降级只告警（`check-syntax` 在没装 pwsh 的机器上恒 rc 3，拿它拦住每次 commit 只会让人第一天就 `--no-verify`），工具跑不起来打 SKIPPED 并写明「未执行 != 通过」。`--no-verify` 绕过是 HIGH 档行为，要向人交代。

CI 那格是唯一能真验 26 个 `.ps1` 的地方（Windows runner 自带 pwsh），矩阵 ubuntu + windows × node 22/24，并断言 run-all 第三段的真触发 case 是**显式 SKIPPED** 而非静默跳过。

分工、每个 hook 跑什么、退出码怎么读、为什么降级不阻断，全在 `.claude/githooks/README.md`。

## 大仓能力（可选——按需开启）

面向 **60 万行级**代码规模项目的影响面分析、diff-bound 审查回执、四态质量门、架构防腐、五性证据门。**默认关闭**——小项目零负担，所有 hook 走原逻辑。

**启用 = 在 `.claude/harness/` 放一份合规 `module-catalog.json`**（模块 id / paths globs / dependsOn / verification / owners / riskTier / attributes 五性档位 / forbiddenDependencies / layer）。文件存在即启用全部大仓能力；删掉即关闭。不动 settings.json、不动任何 hook。

启用后：

- **影响面分析**：`node .claude/harness/harness.mjs impact` 算变更的反向依赖闭包——改一个模块，自动列出所有受影响模块 + 各自该跑的 verification。60 万行规模由 glob 编译缓存 + NUL 分隔路径（中文文件名不被转义破坏）+ tracked 截断保守降级撑住。
- **diff-bound 审查回执**：code-reviewer 通过后写回执绑定当前 diff 的 SHA256，diff 变一个字节旧回执自动 stale，stop-gate 拦停强制重审（把「reviewer 自报通过」升级为机器可验证）。
- **四态质量门**：commit 前对受影响模块跑定向检查，PASS / SKIPPED / FAIL / BLOCKED 四态（缺命令 = BLOCKED 不假绿），pre-commit-check 阻断 FAIL。
- **架构防腐**：`arch-check` 拿**真实 import 边**（JS/TS/Python/Go/Java/C#/Rust 等 12 语言）对照 catalog 声明图——越禁边（forbiddenDependencies：隐私/安全边界可执行化，如 analytics 永不许碰 pii-store）、分层违规（layers 只许向内依赖）、未声明边（依赖漂移 = impact 漏测）、虚边、依赖环全部机器可见。
- **ADR 执法校验**：`adr-check` 要求 Architecture-Design.md / docs/adr/ 里每条活跃架构决策的「执法方式」指向真实存在的 check / fitness 规则 / harness 能力（或显式声明人工评审）——幽灵引用比没有更糟，读起来像被执法实际没有。
- **漂移棘轮**：`arch-check --record` 快照漂移指标，`arch-trend --gate` 只在新值超过历史最优时拦——存量老仓带债接入：先立基线，旧债慢慢还、新债一分不许添（可修改性的硬度量）。
- **五性证据门**：模块声明质量属性档位（security / safety / privacy / resilience / reliability…，critical/high 阻断），check 声明它认领哪些属性，`verify` 判覆盖——「检查全绿但没人证明过 security」不再能读作完成。critical 与 security/safety 属性永无豁免通道。
- **fitness 内置规则**：零外部依赖的五性反模式扫描（密钥字面量 / 日志 PII / 静默吞错 / 无界重试 / 高危模块未挂单 TODO），第一天就能跑。
- **adapters 工具表**：semgrep / osv-scanner / trivy / gitleaks / syft / presidio / stryker / schemathesis / k6 / checkov / oslo 按属性一键接进质量门（`adapters add <id>`），工具缺失报 BLOCKED 不假绿。
- **结构化 waiver**：per-check 豁免（owner / reason / scope / expiry），security / safety 永不可豁免；high 档属性缺口可留痕推迟，critical 不行。
- **规格可判定性**：`spec-lint` 按本仓 Product-Spec 实际的形状扫——四段必填段缺失或空、模板 `<...>` 未填、功能需求条目缺「用户做什么 → 系统做什么 → 得到什么」的箭头、适当/快速这类不可判定措辞。**不照搬 EARS**：那套语法在本生态零命中，做出来的是一个永远全绿、却让人以为规格被检查过的闸。
- **需求追溯**：`trace` 把 `[REQ-<模块>-<三位数>]` 编号和测试引用对上，报未追溯需求与悬空编号；**编号是可选的，没写就明说追溯不可用（rc 3）而不硬造锚点**——小项目零负担，要上追溯再加。`spec` 按变更取相关需求的预算化视图，只把该看的那几条塞进 delegate 的上下文。
- **一键 DoD**：`dod` 把十四步静态治理跑完给一个结论（阻断步 FAIL → rc 2；全降级 = 什么都没建立 → rc 3，不是绿）。只管静态治理，代码能不能跑仍归 `gate`。
- **结构化分歧评审**：`review start|blue|lens|verdict|backlog` 把评审做成引擎的闸而不是习惯——九个 lens 分三阶段（code → functional → trust），早阶段没**过**晚阶段的 lens 直接拒收（贵评审不花在没过便宜评审的代码上）；每条 finding 必须带 `file:line` 或复现路径，否则整份拒收；裁决由引擎算不由人断言，**一个 lens 报 error 不会被四个干净 lens 投票稀释**；连续 FIX_REQUIRED 到 `maxRounds` 就 `escalate` 交人（再来一轮也分不出是改动错还是标准错）。ACCEPT 且到最终阶段自动写 diff-bound 回执。**这一层不用开 catalog**——它是本领域唯一有实测效果的杠杆，锁在大仓开关后面等于在最需要它的仓里废掉它。
- **作者 ≠ 评审（机器强制）**：姊妹仓把这条明确标为 prompt-only，自陈「引擎只会数 lens，看不出谁写的代码」。cc-base 有它没有的东西——Claude Code 的 hook 事件带 `agent_id` / `agent_type`。`authorship record` 记谁改了哪些文件，`review verdict` 校验 lens 的 agentId ∈ 当前 diff 的作者集就**拒绝出 ACCEPT** 并点名。没有账本时不阻断，但输出 `authorshipEnforced:false` 并说明缺的是哪一半——没数据时假装验过了比散文规则更糟。
- **评审证据包**：`review-pack` 把 commits / diffstat / untracked / diff（超阈值溢出到 `.patch`）凑齐，**删除与重命名单独成节**——评审者系统性地漏看「删掉了什么」，让它成为必须走过的一小节。

完整启用条件、catalog schema、三十六能力清单、退出码契约、接线点见 `.claude/rules/harness-large-repo.md`；五性声明与判定细则见 `.claude/rules/quality-attributes.md`（CLAUDE.md「大仓能力」「五性治理」小节指针指向它们）。`node .claude/harness/harness.mjs doctor` 看启用态。

## 进程守护（开发态韧性）

长驻开发服务（dev server / worker）交给 supervisor 守护——**宕机自动拉起**（指数退避封顶 30s）、健康探针连败 3 次杀掉重拉（治「活着但不服务」）、重启风暴熔断（窗口内超限即置 crashed 并停手，失败可见不空转）：

```bash
node .claude/scripts/supervisor.mjs start --id web --health-url http://127.0.0.1:3000/health -- npm run dev
node .claude/scripts/supervisor.mjs status          # 以 pid 实活性为准
node .claude/scripts/supervisor.mjs logs --id web
node .claude/scripts/supervisor.mjs stop --id web
```

状态与日志落 `.claude/.runtime/supervisor/<id>/`（git 忽略）。这是开发态护栏，不是生产 init——生产仍归 systemd / k8s。
