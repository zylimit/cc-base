# Project: cc-base（Claude Code 单机框架脚手架，Windows + Linux）

_Last updated: 2026-06-15_


> 从 ccb-base（多 Agent/CCB，仅 Linux）派生的**单机版**：用 Claude Code 原生 in-session subagent（implementer / code-reviewer / tester / deployer），不依赖 CCB daemon/tmux/派单。跨平台（Windows 经 Git Bash 跑 hooks）。

## Pinned（必守）
- `.ps1` hooks **纯 ASCII**：Windows PowerShell 5.1 按 GBK 读无 BOM UTF-8，含中文即解析崩。
- hook 命令用 `\$env:CLAUDE_PROJECT_DIR` 转义形式（Git Bash 外层会吞裸 `$env`，详见 release notes）。
- 权限「永不询问」：settings.json `permissions.defaultMode: bypassPermissions`（只跳工具权限提示，不影响 agent 决策提问 + 框架 guard hook）。
- **单模型审查承重墙**：每个判断必须锚定可执行外部证据（测试运行器/编译/grep/Spec 比对）；对抗式立场/多视角 lens 只是廉价补充，不是承重墙。依据：ICLR 2024「LLMs Cannot Self-Correct Reasoning Yet」（纯提示词自我修正会反噬）+ 「Stop Overvaluing Multi-Agent Debate」（同模型 debate 等算力打不过简单投票）。
- **PreCompact hook 不可用于注入提醒**：不支持 additionalContext/hookSpecificOutput（只能 decision:block），且压缩后不触发新 SessionStart——「session 内压缩丢决策」洞在当前机制下无轻量解法，已改用 SessionStart 脏树提醒覆盖跨 session 状态漂移。
- **打/补 git tag 前必须先查远程**：`git ls-remote --tags origin` 查远程在先，不能只查本地 `git tag`——本地无 tag ≠ 远程无 tag，只查本地会误判并打出与远程冲突的 tag。（2026-06-14 踩坑：v1.0.1 本地误判"首个 tag"，实际远程早有 v1.0.1 → 59f207c）
- **.ps1 hook 在 Windows 跑的是 powershell.exe（Windows PowerShell 5.1），不是 pwsh 7.x**（setup.ps1 注释明写 powershell.exe）。5.1 下 native 命令（git/npx 等）写 stderr 会生成 ErrorRecord 进 PS Error 流，`$ErrorActionPreference='Stop'` 把它提升为 terminating error，`*>$null` 拦不住 → 脚本崩、`$LASTEXITCODE` 守卫被绕过 → 错误泄漏到 UI。凡 .ps1 里调可能写 stderr 的 native 命令：用 `--quiet`/`2>$null` 让命令本身不写 stderr，或 `try/catch` 包，或局部 `$ErrorActionPreference='Continue'`。`$PSNativeCommandUseErrorActionPreference` 是 PS 7.3+ 变量，5.1 无效，别用它修。（2026-06-14 真机 trace 验证）
- **验收五步闸（禁跳步）**：做任何「完成」声称前必走：①想清要跑的命令 → ②跑全量全新（无缓存）→ ③读完整输出 + exit code → ④确认输出支持结论 → ⑤才开口。禁用"应该/大概/看起来"措辞替代实测。（2026-06-15 纪律增强；引用本框架两次翻车案例：PS 5.1 git fatal 误判、v1.0.1 远程 tag 误判）
- **接收审查/反馈禁表演式认同**：禁"你说得对/好建议/这就改"开场。改为：复述确认（"你说的是X，对吗？"）、或先问清再表态、或有异议顶回去、或直接动手不废话。（2026-06-15 纪律增强）

## Done
- 2026-06-15: **cc-base v1.3.0 发布上线**——内容：A1 工程化合规闸 + A2 框架自测 harness + A3 闸要量化验证 + recap/clear 恢复须读三份规则修正 + 含 v1.2.0 全部。发版：make-release.sh v1.3.0 从 git HEAD 打包（排除私有 feedback/*.md）→ tag v1.3.0（→ 2b8690e）推远程 → gh release create 带资产 cc-base-v1.3.0.zip。验收三件套（主 Agent 独立核查 GitHub 现查现读，非信 deployer 自述）：① 远程 tag v1.3.0→2b8690e ✅ ② release draft=false、URL https://github.com/zylimit/cc-base/releases/tag/v1.3.0、资产 cc-base-v1.3.0.zip（192496B）✅ ③ 资产含 .claude/tests/selftest.sh（3970B）+test-helpers.sh、CLAUDE.md 命中本版规则×7（1%即调/闸靠数据留/CHANGELOG）、私有 feedback 已排除 ✅。
- 2026-06-15: **A1/A2/A3 三项落地验收**（commits 22fe45b/b6b9bcb，随 v1.3.0 发布 2b8690e）——借鉴 Superpowers 深层第二层养分，经委派 implementer→1 轮 code-reviewer 写文件审→修闭环验收。
  - **A1 工程化合规闸**：CLAUDE.md [Skill 调用规则] 增量强化（1% 即调/前置自检/逃逸借口拦截 Red Flags）；新建 feedback/skill-invocation-persuasion-gate.md（Meincke et al. 2025 劝服原理：Authority+Commitment+Scarcity，合规率 33%→72%）。
  - **A2 框架自测 harness**：新建 .claude/tests/——test-helpers.sh（assert_skill_invoked/assert_no_premature_action/assert_order）+ fixtures + selftest.sh（无需 LLM，拿 fixture 验断言库）+ cases（真触发需 claude CLI，无则 SKIP 不假绿）+ README。cc-base 首个框架自测能力。
  - **A3 闸要量化验证**：CLAUDE.md [开发测试规则] 增量加"闸靠数据留不靠感觉留"铁律；新建 feedback/gates-need-empirical-validation.md（记 Superpowers RELEASE-NOTES v5.0.6 砍重型 review 循环的实测教训）。
  - dogfood 验收证据：主 Agent 逐 diff 验 CLAUDE.md 纯增量、读两 feedback 验引证与格式、亲跑 selftest.sh 通过；1 轮 code-reviewer 抓出 2 个真 Med（M1 assert_skill_invoked 跨行解耦误判可假绿 → 加 cross-line-decoupled fixture 锁住修绿 selftest 9/9；M2 两 feedback 未登记 FEEDBACK-INDEX → 补索引）+ 3 个 Low 顺修。Judge 重判 ACCEPT。印证 A3：审查闸真挡下 harness 自身断言 bug。（findings 落盘 /tmp/rbr-a123-review.md）A2 真 LLM case 需有 claude CLI 环境按需跑，脚手架 selftest 已验。
- 2026-06-15: **cc-base v1.2.0 发布上线**——内容：新增 /red-blue-review 红蓝对抗审查 skill + 含 v1.1.0 全部内容。发版：make-release.sh v1.2.0 从 git HEAD 打包（排除私有 feedback/*.md）→ tag v1.2.0（→ cfeab6f）推远程 → gh release create 带资产 cc-base-v1.2.0.zip。验收三件套（主 Agent 独立核查 GitHub 现查现读，非信 deployer 自述）：① 远程 tag v1.2.0→cfeab6f ✅ ② release draft=false，URL https://github.com/zylimit/cc-base/releases/tag/v1.2.0，资产 cc-base-v1.2.0.zip ✅ ③ 资产含 red-blue-review/SKILL.md（8958B）+ red-blue-review.sh（4821B），CLAUDE.md 命中 red-blue-review ×5，私有 feedback 已排除 ✅。R1 化解：red-blue skill 已提前 commit 入 HEAD 故打包未漏。
- 2026-06-15: **red-blue-review skill 建成 + dogfood 闭环 + 采信项全修，Judge 重判 ACCEPT**（commit 含于 v1.2.0，R1 化解）
  - 产物：.claude/skills/red-blue-review/ 含 SKILL.md（Blue 自证→Red 四 lens[correctness/security/release/windows]攻击→Judge 三裁[ACCEPT/FIX_REQUIRED/NEEDS_MORE_EVIDENCE]）+ red-blue-review.sh（凑证据包：范围/commit/改动清单/删除审计/未跟踪/完整diff）+ RED-BLUE-REVIEW.md（报告空模板）+ test-red-blue-review.sh（回归自测）；CLAUDE.md 三处登记；纯 CC 不引入 CCB/多模型。
  - dogfood 首跑（用它审它自己 + v1.1.0 批次）暴露 3 硬伤 → red-locks 修复：F1 脚本参数误序静默空包 → `--working` 位置无关 + 无效 ref 响亮报错非零；F2 findings 靠回传消息承载致空回传丢失 → 改为 findings 落盘、主 Agent 读产物不读回传；F3 报告模板就地填污染进包 → 模板拷出填、目录内保持空模板。红测流程：tester 写红 → 主 Agent 亲验红 → implementer 修绿 → 主 Agent 亲验 3/3 绿。
  - 落盘协议生效后重跑照出 8 条采信 finding，Judge 裁 FIX_REQUIRED → 逐条修：C1 红测重写锁"无效ref响亮报错"真契约；C2 CLAUDE.md"授权连续执行"补 Spec 签字门例外子句化解字面冲突；C3 implementer.md 四态去冗余对齐顺序；C4 progress-recorder description 收紧防过度触发；S1 脚本清陈旧临时文件；R2 文件结构补列 test；W1 注明 Windows 须 Git Bash。R1（make-release 用 archive HEAD，未 commit 的 skill 会漏打包）靠"先 commit 再打包"化解；R3（基线 v1.0.3）属有意回溯不改。红队反向确认：命令注入（双引号+ref校验）、branch-finisher git 判据（detached/worktree/-d）、CRLF/BOM 均攻不破。
  - 验收证据：主 Agent 亲跑 test-red-blue-review.sh 全绿 + 亲跑无效 ref 确认响亮报错 exit1 + 逐条 grep 核验 7 项修复落地；Judge 重判 ACCEPT。（含于 v1.2.0 已发布，R1 化解）
- 2026-06-15: **cc-base v1.1.0 发布上线**——内容：Superpowers Jesse Vincent v5.1.0 借鉴的 9 项纪律增强（Tier1+2）+ 新 skill /branch-finisher。发版：make-release.sh 从 git HEAD 打包（排除私有 feedback/*.md）→ tag v1.1.0 → 84da478 推远程 → gh release create 带资产 cc-base-v1.1.0.zip。验收三件套（主 Agent 独立核查，非信 deployer 自述）：① 远程 tag v1.1.0→84da478 ✅ ② release draft=false，URL https://github.com/zylimit/cc-base/releases/tag/v1.1.0，资产 cc-base-v1.1.0.zip ✅ ③ 资产内含 branch-finisher/SKILL.md（7024B）、CLAUDE.md 命中五步闸/branch-finisher 5 处、私有 feedback 已正确排除 ✅。（commits：2cb475c feat + 84da478 docs）
- 2026-06-15: **框架纪律增强批次（Superpowers Jesse Vincent v5.1.0 方法论借鉴，9 项全部落地验收，纯增量零删除既有规则）**
  - ①验收五步闸：CLAUDE.md [总体规则] 验收铁律追加不可跳步五步闸 + 禁"应该/大概"措辞；新建 feedback/completion-claims-need-fresh-verification-five-step-gate.md（含声称→证据对照表 + 两次翻车案例）。
  - ②接收审查不表演式认同：CLAUDE.md [总体规则] 新增一条 + 新建 feedback/receiving-review-no-performative-agreement.md。
  - ③修复熔断闸：skills/bug-fixer/SKILL.md 增量——同一 bug ≥3 次未转绿强制熔断，回根因质疑设计、向上升级，与 red-locks 协同。
  - ④Skill description CSO 清扫：11 个 SKILL.md description 砍掉流程概括尾巴、只留触发条件，防主 Agent 读摘要跳过正文。
  - ⑤dev-planner 可执行性标准：SKILL.md 增量——按"最坏执行者"设防，禁 placeholder/TBD/模糊指代，每步给文件路径+具体改动+验证命令；自审加命名一致性+Spec 覆盖率两查。
  - ⑥Spec 签字门：CLAUDE.md [交付阶段] 与 [内容修订] 增量——Product-Spec 生成/变更后须用户明确批准才进 dev-planner。
  - ⑦implementer 四态自评：CLAUDE.md [Sub-Agent 调度规则] 回传纪律 + agents/implementer.md 输出规范——回传须以 DONE/DONE_WITH_CONCERNS/NEEDS_CONTEXT/BLOCKED 开头。
  - ⑧worktree 操作硬化：CLAUDE.md [Sub-Agent 调度规则] Workflow 段增量——Step0 检测是否已在 worktree（排除 submodule 误判）、目录优先级+git check-ignore、原生工具优先。
  - ⑨branch-finisher skill 新增：skills/branch-finisher/SKILL.md——开发分支收尾，环境检测（正常分支/worktree/detached）+测试全绿前置闸+条件化菜单（合并/PR/暂留）+清理规则；已在 CLAUDE.md 三处登记。
  （evidence：2 个独立 code-reviewer 均判可验收无返修；harness 实测 frontmatter 解析+skill 注册通过；主 Agent 逐 diff 确认存量 4 文件零删除）
- 2026-06-14: **Windows PS 5.1 .ps1 hook git fatal 泄漏根治**（commit 9796ae0）——auto-push.ps1 真机 trace 定位：无 upstream commit 后泄漏 "git : fatal: no upstream"。修法：`git rev-parse` 改 `--verify --quiet`（无 upstream 时不写 stderr）+ `git push` 包 `try/catch`。同源加固：recap-on-dirty/tdd-gate（git 探测包 `try/catch`）、pre-commit-check（TS 分支 `npx tsc` 套局部 EAP=Continue）。撤回前一版错误修法 fba58d5。**Windows 真机终验通过**（2026-06-14）：D:\Code\cc-test，Claude Code v2.1.119，`git commit --allow-empty -m x` → [master eac3b69f] x，全程无 fatal 输出，auto-push hook 未报错未拦截。v1.0.3 修复确认有效，PS 5.1 fatal 泄漏根治成立。
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
- [P2][OPEN][#1] 其余 3 个 .ps1 hook（recap-on-dirty 等）在非 git 目录下的同源加固，尚未在 Windows 真机验证（可选，低优先级）
- [P1][OPEN][#2] **CLAUDE.md 瘦身——三态触发把冷规则下沉**（借鉴 OpenHands microagent keyword/task trigger 机制）：把低频长段落（[本地运行阶段]、[Workflow 编排模式] 细则、各 feedback 引用等）下沉成 keyword-triggered 小文件，命中才注入；常驻只留 角色+铁律骨架+路由。收益：省 token、降噪，零架构风险。Context：OpenHands .openhands/microagents/*.md frontmatter + skill_loader.py
- [P2][OPEN][#3] **框架核心层 vs 项目私有层 分层**（借鉴 OpenHands Global/User/Org/Project 四层 skill 机制）：当前 .claude/ 框架核心与项目私有定制混居，升级时无法区分哪些可覆盖、哪些用户改过。目标：明确切「框架核心层（随版本升级、只读）」与「项目覆盖层（私有、不被覆盖）」。与 v1.x 升级命令直接相关——需用户拍板，属架构决策。
- [P2][OPEN][#4] **人工审批闸升级为显式风险三档清单**（借鉴 OpenHands ActionSecurityRisk LOW/MEDIUM/HIGH 枚举）：现有「授权连续执行除非真正需要人拍板」判据是散文，不同 session 松紧不一。目标：钉成三档——LOW（自动跑：写文档/加测试/P2-P3修复）/ MEDIUM / HIGH（必停：删文件/改家底hook/发布上线/git push/不可逆）。模糊判断变查检表，机制化可审计，接上「验收以证据为准」铁律。

## 明确不做（防过度工程）
- **condenser LLM 摘要压缩**：progress.md「超100条归档+摘要指针」已够用，不值得为它每次多跑一次 LLM。
- **trajectory 存储/回放、Action-Observation 事件流结构化**：引擎级数据结构，markdown 框架硬套自找麻烦；已有 progress.md+外部memory+claude-mem 三层。
- **反馈→改进闭环**（参照 OpenHands enterprise/storage/feedback.py）：cc-base evolution-engine 反而领先——OpenHands feedback 表只存 polarity+trajectory，无聚合分析无改进驱动；不需要对标。
- **自建 agent benchmark**（参照 OpenHands SWEBench 77.6）：成本极高，现阶段不做，记「将来事」。

## 将来事（低概率/成本高/暂不划算）
- **自建 agent benchmark**：OpenHands 用 SWEBench 客观衡量「框架变好没」，cc-base 全靠人肉判断。自建 benchmark 成本极高，现阶段不做，将来项目规模大到需要客观回归指标时再考虑。（2026-06-15）
