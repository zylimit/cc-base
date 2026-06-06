# Project: cc-base
_Last updated: 2026-06-06_

> **项目性质**：SiteMaster 全栈开发框架的**纯 Claude Code 基础设施脚手架**。本仓库不是产品代码，目标是把 `.claude`（CLAUDE.md / agents / skills / hooks / feedback）调稳、可复现、上库。是 ccb-base 的纯 CC 版——去掉 CCB 多进程编排，全部改 Claude Code 原生 Sub-Agent。

---

## Pinned（仅高置信"必须遵守"写入；受保护不可修订）

- 主 Agent 不得亲自编码/审查/测试/部署，只「写提示词 + 委派 + 验收」（铁律）。委派目标全部为 Claude Code Sub-Agent（Task/Agent 工具，fresh 实例）：编码=implementer、审查=code-reviewer、测试=tester、部署=deployer。
- 验收以客观证据为准（铁律），不轻信子 Agent 自报状态：编码→复核编译输出+对照 Spec；测试→复核运行器真实输出；部署→独立核查三件套（容器创建时间戳+镜像 tag / 健康检查 / live 冒烟，勿用 Up 时长）。
- 写测独立性（铁律）：tester 必须是与写该代码的 implementer 不同的 fresh 实例，自码自测会把作者错误假设写进断言（confirmation bias）。
- Sub-Agent 不继承 session 历史，派发前主 Agent 必须备齐完整任务上下文（Spec 条目/交付清单/涉及文件/项目结构/约束）。
- 配置入库、运行时不入库：`.claude/.needs-review`、`settings.local.json` 由 .gitignore 排除。
- feedback（.claude/feedback/，喂进化引擎）与 memory（跨 session 偏好）是两套系统，用户修正行为必须走 feedback。

---

## Decisions（按时间顺序追加，历史不可改）

- 2026-06-06: 立项——从 ccb-base 派生纯 Claude Code 版 cc-base。整树搬 `.claude`（skills/hooks/templates 本就 provider 无关，零改动）。
- 2026-06-06: 角色映射定稿——commander→主 Agent、coder→implementer、reviewer→code-reviewer、tester(codex)→tester Sub-Agent、deployer(codex)→deployer Sub-Agent。新增 tester.md / deployer.md 两个 agent。
- 2026-06-06: 删除 2 个纯 CCB 运维 feedback（ccb-dispatch / ccb-startup-tmux）——无 CCB 后失去意义；其余 5 个 feedback 把 CCB 渠道措辞（/ask、codex/gemini、commander）改写为 Sub-Agent。
- 2026-06-06: 丢弃 `.ccb/` 与 `tools/ccb-*`（纯 CC 无 daemon/tmux 可管，无需安装脚本）。
- 2026-06-06: 6 个 hook 全部保留——它们本就 provider 无关（review 闸门按文件登记、commit 编译门禁、auto-push、feedback 信号检测、进化检查），与 CCB 无耦合。
- 2026-06-06: 采纳 Dynamic Workflows 作为 Sub-Agent 之上的「规模化 fan-out 编排层」——纯 CC 全 Claude worker，workflow 的 agent() 可原生 spawn（ccb-base 因需驱动外部 codex worker 用不了，这是纯 CC 独有红利）。Workflow 不取代 Task 直派，只在多个无依赖单位时用。
- 2026-06-06: 确立 workflow 使用判据轴 = 「单元决策要不要自洽」而非"任务多少"。只读/可汇总（审查维度、测试目标、代码库探索、研究）= 并行甜区；共享上下文/契约（编码）= 默认串行。
- 2026-06-06: 并行 implementer 池（TODO #3）结论 = 大体上不做。编码是最不可并行环节（Anthropic《Building Effective Agents》"coding not a good fit for multi-agent"；Cognition《Don't Build Multi-Agents》并行编码决策冲突）。并行红利改用于审查/测试/研究，编码保持串行。
- 2026-06-06: 不照搬 ccb 的 coordinator 协调员模式——纯 CC Sub-Agent 本就上下文隔离，且 Sub-Agent 不能嵌套拉 Sub-Agent；保持「主 Agent 唯一编排者」扁平编排。借鉴的只是 coordinator 提炼出的规则层纪律（回传格式/翻证据下判断/时长红线）。
- 2026-06-06: workflow 集成方式——agent() 的 agentType 选项复用现有专职 Agent（code-reviewer/tester/implementer + 各自 skill），编排换脚本、工人不变。
- 2026-06-06: workflow 成本闸门——多 Agent 耗约 15x token，必须用户显式 opt-in、只对高价值任务用，不静默触发。

---

## TODO（权威待办清单）

- [P2][OPEN][#1] git 化：init + .gitignore 核对 + 推私有库（远端待定）
- [P3][OPEN][#2] 实跑一轮真实项目，验证纯 Sub-Agent 编排在 dev-builder per-Task review→fix 循环下的稳定性与并行表现
- [P3][RESOLVED][#3] 评估是否需要并行 implementer 池（无依赖 Task 并发）——结论：大体上不做，编码保持串行，并行红利用于审查/测试/研究（见 Decisions 2026-06-06）

---

## In Progress

（暂无）

---

## Done（最近完成的放前面）

- 2026-06-06: [#-] **借鉴 ccb-base 演进 + 业界实践，三处文档落地**：① CLAUDE.md 新增「Workflow 编排模式」整节 + 「Sub-Agent 回传纪律」（结论+证据句柄/翻证据外包下判断自留/任务时长>60min 红线）+ 收紧「并行」条（编码默认串行）+ [运行模型] 增「两种派发形态」与「扁平编排」铁律；② 新建 ARCHITECTURE.md（纯 CC 版全景架构，含 §4 Workflow 模式、§5 异构丢失风险、引用 3 篇业界文章）；③ README 设计要点加 Workflow 红利说明 + ARCHITECTURE.md 链接。
- 2026-06-06: [#-] **纯 CC 版骨架完成**：重写 CLAUDE.md（删 CCB 三条铁律、派单规则全改 Sub-Agent、运行模型章节声明纯 CC）；新增 tester/deployer 两个 agent；改写 dev-builder/test-builder/release-builder 的 CCB 引用；重写/精简 5 个 feedback + 索引；新 README / progress / .gitignore。全树终检无 CCB 残留。

---

## Risks & Assumptions

- Assumption：纯 Sub-Agent 同步派发够用，无需外部 daemon 留痕——跨 session 状态靠 progress.md + feedback 承载。（Confidence：Med）
- Assumption：写测独立性靠"派与实现者不同的 fresh tester 实例"即可保证，无需跨进程隔离。（Confidence：High——Sub-Agent 本就 fresh 不继承上下文）
- Risk：大规模项目下主 Agent 上下文增长，需靠 progress-recorder 自动归档（>100 条）兜底。
- Risk：异构互照丢失——ccb 用 codex reviewer 照出过 claude reviewer 漏判的真 bug，同源模型有共同盲区；纯 CC 全 Claude worker 失去这层交叉验证。缓解（非根除）：审查用多视角对抗 verify（correctness/security/repro 不同 lens）+ 写测独立 + 高风险多轮。根除需引入异构 worker（即回到 ccb 路线），是两版本质取舍。（Confidence：High——业界实证支撑）

---

## Notes（简要要点）

- 2026-06-06: 与 ccb-base 的核心差异 = 编排层（Sub-Agent vs CCB daemon）；技能体系/hook/feedback/进化引擎/项目记忆完全一致。
- 2026-06-06: 无安装步骤——Claude Code 原生读 `.claude/`，无 daemon/tmux/CLI 工具要装。
- 2026-06-06: TODO #2（实跑验证编排）仍 OPEN，现增一可验证项：实跑时验证 workflow fan-out（审查/测试场景）的实际表现。

---

## Context Index（轻量索引）

- 主入口：.claude/CLAUDE.md（SiteMaster 框架总控，纯 CC + Sub-Agent）
- 上游：ccb-base（CCB 版，https://github.com/zylimit/ccb-base）
- Archive：./progress.archive.md（尚未创建，条目 >100 时自动触发）
