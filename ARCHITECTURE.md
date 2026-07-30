# cc-base 架构文档

> SiteMaster 全栈开发框架的**纯 Claude Code 基础设施**。本仓库不是产品代码，交付物是 `.claude/`（CLAUDE.md / agents / skills / hooks / feedback）这套可复现的编排配置。它是 [ccb-base](https://github.com/zylimit/ccb-base) 的纯 CC 派生版——去掉 CCB 多进程编排与外部 codex/gemini worker，全部改用 Claude Code 原生能力。

---

## 1. 这是什么

一套让单个 Claude Code 主 Agent 扮演「资深产品经理 + 全栈开发教练」（角色名 SiteMaster），带用户从模糊想法走到可发布产品的框架。编排不依赖任何外部进程：无 daemon、无 tmux、无 codex/gemini 外驱。所有委派走 Claude Code 原生的 **Sub-Agent（Task/Agent 工具）** 与 **Dynamic Workflows**。

与 ccb-base 的唯一本质差异 = **编排层**：

| | ccb-base | cc-base |
|---|---|---|
| 编排 | CCB daemon + tmux 多进程 | Claude Code 原生 Sub-Agent / Workflow |
| worker | 异构（claude / codex / gemini） | 同构（全 Claude） |
| 派单 | `ccb ask` 异步 + 轮询 | Task 工具同步返回 / Workflow 引擎 |
| 上下文保护 | coordinator 协调员中间层 | Sub-Agent 本就隔离，无需中间层 |
| fan-out | coordinator 串外部 agent | **Dynamic Workflows（纯 CC 红利）** |

技能体系 / hook / feedback / 进化引擎 / 项目记忆与 ccb-base **完全一致**。

---

## 2. 两类角色 —— 谁干什么

### 2.1 主 Agent = 唯一编排者

负责 **需求分析 / 任务分解 / 排序 / 派发 / 验收**。四个执行环节（编码 / 审查 / 测试 / 部署）**一律不亲自动手**，只「写提示词 + 委派 + 验收」。仅文档类（Product-Spec / CHANGELOG / DEV-PLAN / 本架构文档）可直接写。

### 2.2 专职 Sub-Agent = 工人（`.claude/agents/`）

每次派发都是 **fresh 实例**，不继承 session 历史，互不串扰。

| Agent | Skill | 职责 |
|-------|-------|------|
| `implementer` | dev-builder | 编码实现 + 编译验证 + 自检 |
| `code-reviewer` | code-review | 三阶段审查（静态闸 / 规格符合性 / 代码质量）+ 报告 |
| `tester` | test-builder | 写/跑测试（独立于实现者）+ 运行证据 |
| `deployer` | release-builder | 打包/部署执行 + 结果 |
| `feedback-observer` | feedback-writer | 记录用户反馈到 `.claude/feedback/` |
| `evolution-runner` | evolution-engine | 扫描 feedback + 生成进化建议 |
| `progress-recorder` | progress-recorder | 增量维护 `progress.md` 项目记忆 + 归档 |

### 2.3 扁平编排（铁律）

主 Agent 是唯一编排者：**Sub-Agent 不再拉 Sub-Agent**；Workflow 由主 Agent 编写、其内 `workflow()` 嵌套仅一层。纯 CC 的 Sub-Agent 本就上下文隔离（只回传最终结论进主 Agent），**不需要 ccb-base 那种 coordinator 协调员中间层**——那是 CCB 为驱动外部 codex worker 才有的，纯 CC 不照搬。

---

## 3. 两种派发形态

| 形态 | 何时用 | 工人 |
|------|--------|------|
| **直接 Task 派单**（默认） | 单 Task / 一问一答 | 一次一个专职 Sub-Agent |
| **Workflow 编排**（规模化上层） | 多个无依赖单位的 fan-out / pipeline | 同一批专职 Sub-Agent，由脚本编排 |

两者工人相同，只是编排粒度不同。Task 工具**同步返回**，不存在"提交后轮询"。

---

## 4. Workflow 编排模式 —— 纯 CC 的核心红利

> 本节结论基于业界实践（见 §10 引用），不是凭空设计。

### 4.1 为什么 cc-base 能用、ccb-base 不能

Dynamic Workflows 的 `agent()` **只能 spawn Claude subagent**。ccb-base 要驱动外部 codex worker，被这条挡在门外（其架构文档 §3.7 的结论是"用 coordinator 不用 workflow"）。**cc-base 全是 Claude worker，这道门是开的**——这是纯 CC 相对 CCB 最该吃下的红利。

### 4.2 判据轴 = 单元的决策要不要自洽（不是"任务多少"）

| 工作类型 | 决策需自洽? | 业界结论 | cc-base 处理 |
|---------|:---:|---------|------------|
| **只读广度**（审查维度 / 代码库探索 / 测试目标普查 / 研究） | 否，结果汇总 | ✅ 多 Agent 甜区 | **Workflow fan-out** |
| **逐条验证/评判** | 否，独立投票 | ✅ voting / evaluator | **Workflow** 多视角 verify |
| **单 Task review→fix** | 串行 | ✅ evaluator-optimizer | 现有循环，workflow 只形式化 |
| **跨 Task 编码** | **是，共享契约** | ⚠️「not a good fit」 | **默认串行**，并行是窄例外 |

**关键修正**：编码是**最不该并行**的环节。Anthropic 实证「most coding tasks involve fewer truly parallelizable tasks than research」；Cognition 的「Flappy Bird」证明并行编码会因不共享上下文而决策冲突（共享类型/契约/命名各写各的）。所以把 workflow 并行红利用在**审查 / 测试 / 研究**这些只读广度上，**编码保持串行**。

### 4.3 三个推荐场景

1. **code-review 多维 + 对抗验证**：`pipeline(维度, 审查, 逐条 verify)`，verify 用**多视角 lens**（correctness / security / repro）。以视角多样性**补回纯 CC 失去的「codex/claude 异构互照」**——这是纯 CC 对同源盲区的正面解法。**已落地脚本** `.claude/workflows/code-review-fanout.js`（主 Agent 显式 opt-in 调用，schema 回传「结论 + 证据句柄」由主 Agent 定夺）。
2. **test-builder 批量写测**：`parallel` 多个高价值逻辑（契约 / 解析器 / 边界）各派 tester。`agent()` 每次 fresh，天然独立于 implementer 作者，写测独立性免费保住。
3. **代码库探索 / 研究**：breadth-first 普查，多 agent 各搜一个角度。

### 4.4 集成点：`agentType`

```js
agent(prompt, { agentType: 'code-reviewer', schema })
agent(prompt, { agentType: 'tester', schema })
agent(prompt, { agentType: 'implementer', isolation: 'worktree', schema })  // 仅并行写文件时
```

`agentType` 从与 Task 工具同一个注册表解析，直接复用框架现有专职 Agent（带各自 skill + system prompt）。**编排换成脚本，工人不变**——隔离 / 职责边界 / 写测独立全保住。

### 4.5 三铁律 + 成本闸门

- **主 Agent 仍是唯一编排者**：workflow 是主 Agent 写的脚本，不是 Sub-Agent 自拉 Sub-Agent；`workflow()` 嵌套仅一层（压死扁平原则）。
- **验收判断权留主 Agent**：workflow 用 `schema` 回传「结论 + 证据句柄」，主 Agent 凭证据定夺（= 翻证据外包 / 下判断自留，与验收铁律协同）。
- **写测独立性**：`agent()` fresh + 不同 agentType 保证。
- **成本闸门（硬约束）**：多 Agent 耗 token **~15x**（Anthropic 实证），只对高价值任务划算。**必须用户显式 opt-in**，不静默触发——达到 fan-out 规模时主 Agent 先提议、用户确认再跑。worktree 隔离有 ~200-500ms+磁盘/agent 成本，只在并行写文件时用；单 Phase 仅 1-2 个单位时不划算，直接 Task 直派。

---

## 5. 行为铁律（已固化 feedback）

带血教训固化的硬规则。完整细则各见 `.claude/feedback/<name>.md`，索引见 `FEEDBACK-INDEX.md`。

| 铁律 | 一句话 |
|------|--------|
| **主 Agent 职责边界** | 编码/审查/测试/部署一律委派专职 Sub-Agent，主 Agent 只「写提示词 + 委派 + 验收」 |
| **验收以客观证据为准** | 子 Agent 自报状态 ≠ 任务结果；验收核查客观证据（部署三件套 / 测试运行器真实输出 / 编译输出） |
| **测试独立性** | 写测者 ≠ 被测代码作者，避免自码自测的 confirmation bias |
| **测试卡点** | 测试通过是打包/交付前的强制前置闸门，「部署/打包」指令不豁免测试 |
| **多 repo 提交隔离** | 多个独立 repo 各自分开提交，禁止耦合进同一脚本（认证不同会掩盖单点失败） |

### 异构互照的丢失（cc-base 固有风险）

ccb-base 实证：codex reviewer 照出过会话内 claude reviewer 漏判的真 bug——**同源模型有共同盲区**。纯 CC 全是 Claude worker，**失去这层异构交叉验证**。缓解（非根除）：① 审查用 §4.3 的**多视角对抗 verify** 补回部分交叉性；② 写测独立 + fresh 实例减少作者偏见；③ 高风险改动多轮审查。根除需引入异构 worker——那就回到 ccb-base 的路线了，是两版的本质取舍。

---

## 6. SiteMaster 开发工作流

需求 → 交付全流程（详见 `.claude/CLAUDE.md` [工作流程]）：

```
需求收集 → 设计规范 → 设计图 → 开发计划 → 项目开发 → Bug修复 → 代码审查 → 系统测试 → 构建发布
  product-spec  design-brief  design-maker  dev-planner  dev-builder  bug-fixer  code-review  test-builder  release-builder
```

**per-Task 闭环**（dev-builder 核心，evaluator-optimizer 模式）：编码 → code-reviewer 三阶段审查（Stage0 静态闸 / Stage1 规格符合性 / Stage2 代码质量）→ 通过则 `echo clean > .claude/.needs-review` + commit → 下一个 Task；失败则 bug-fixer 修复后重审。

**Phase 完成四步走验证**：Code Review → 测试完整性（test-builder 真卡点）→ 编译验证 → 功能测试。全过才算 Phase 完成。

15 个 Skill 全清单见 README / CLAUDE.md [可用技能]。

---

## 7. Hook 闸门（`.claude/hooks/`）

settings.json 实际注册 14 个 hook（每个均 `.sh` + `.ps1` 双平台）：

| Hook | 触发 | 作用 |
|------|------|------|
| `detect-feedback-signal.sh` | UserPromptSubmit | 检测用户修正信号 → 提示派 feedback-observer |
| `check-evolution.sh` | SessionStart | 报告待处理 feedback 数 |
| `session-rules-banner.sh` | SessionStart | 会话开始打印框架核心铁律横幅 |
| `recap-on-dirty.sh` | SessionStart | 工作树有未提交改动时注入提醒：先 /recap 校准 progress.md 再继续（防上个 session 中断/压缩致状态漂移） |
| `pre-commit-check.sh` | PreToolUse(Bash) | git commit 前按技术栈编译/语法门禁（tsc / ruff / py_compile） |
| `kill-dev-ports.sh` | PreToolUse(Bash) | 启动开发服务器前清理占用端口 |
| `dangerous-pkill-guard.sh` | PreToolUse(Bash) | 拦截 `pkill -f` 等粗暴杀进程命令 |
| `tdd-gate.sh` | PreToolUse(Bash) | 测试相关命令前提示 TDD 工作流（red-locks-the-bug） |
| `no-direct-code-guard.sh` | PreToolUse(Edit\|Write) | 拦主 Agent 直接改业务代码，强制委派 implementer |
| `mark-review-needed.sh` | PostToolUse(Edit/Write) | 业务代码改动登记进待审清单（豁免 .claude/ 框架自身、文档类） |
| `auto-push.sh` | PostToolUse(Bash) | git commit 后本地领先上游则自动 push |
| `stop-gate.sh` | Stop | 有未审业务代码则阻止停止，列出待审文件 |
| `three-file-sync-gate.sh` | Stop | 家底/代码改动但 progress.md 未同步、或 Spec 与 CHANGELOG 未成对更新则阻止停止（三文件同步铁律） |
| `subagent-acceptance-reminder.sh` | SubagentStop(implementer\|code-reviewer\|tester\|deployer) | 执行类 Sub-Agent 返回时，注入提醒主 Agent 按客观证据验收、勿信自报（机制化「验收以客观证据为准」铁律） |

> `hooks/static-check.sh` **不是注册 hook**，是 code-review Stage 0 静态闸主动调用的工具（识栈跑 shellcheck / ruff / tsc），同放此目录仅为聚拢。

**设计要点**：所有 hook 在 jq 缺失时优雅降级；review 闸门按文件登记（非全局布尔）+ flock 防并发 + 优先级反转（clean 与待审混存时正确 block）。hook 本就 provider 无关，与 ccb-base 逐字节相同。

---

## 8. 项目记忆 + 反馈进化（两套独立系统）

- **项目记忆**：`progress-recorder` agent 维护项目根目录的 `progress.md`（决策/约束/完成/待办/风险），>100 条自动归档到 `progress.archive.md`。指令 `/record` `/archive` `/recap`。
- **反馈进化**：用户修正 AI 行为 → `feedback-observer` 写 `.claude/feedback/` → `evolution-runner`（session 初始化自动派发）扫描并生成进化建议 → 用户逐条确认后改进 Skill/规则。

> ⚠️ feedback（改进框架）与 memory（跨 session 记住用户偏好）是两套不同系统，用户修正行为必须走 feedback。

---

## 9. 目录结构

```
project/
├── Product-Spec.md / -CHANGELOG.md      # 需求文档 + 变更记录
├── Design-Brief.md                       # 设计规范（可选）
├── DEV-PLAN.md                           # 分阶段开发计划
├── progress.md / progress.archive.md     # 项目记忆（根目录）
├── <project-name>/                       # 项目代码子文件夹
└── .claude/
    ├── CLAUDE.md                         # 主控
    ├── rules/                            # 主控下沉细则（file-structure / workflow-orchestration / dev-workflow-details / harness-large-repo）
    ├── agents/                           # 7 个专职 Sub-Agent
    ├── skills/                           # 15 个 Skill
    ├── hooks/                            # 14 个注册闸门 + static-check 工具
    ├── harness/                          # 大仓治理 harness（harness.mjs，默认关闭，放 module-catalog.json 才启用）
    ├── workflows/                        # Workflow 脚本（code-review-fanout.js）
    ├── scripts/                          # 质量脚本（doctor / plan-lint / skill-lint / fast-mode / fix-platform / gen-manifest / gate-audit）
    ├── tests/                            # 框架自测（selftest / test-setup / test-routing / 闸回归 / cases）
    ├── feedback/                         # 已固化铁律 + 索引 + templates
    └── EVOLUTION.md                      # 进化引擎
```

运行时文件（`.claude/.needs-review`、`settings.local.json`）由 `.gitignore` 排除，不入库。**无安装步骤**——Claude Code 原生读 `.claude/`，无 daemon/tmux/CLI 工具要装。

---

## 10. 设计原则速览

1. **最简优先**：默认直接 Task 派单；只在 fan-out 规模 + 高价值 + 用户 opt-in 时才上 Workflow。（Anthropic：「find the simplest solution possible, only increasing complexity when needed」）
2. **扁平编排**：主 Agent 唯一编排者，Sub-Agent 不自拉 Sub-Agent，workflow 嵌套仅一层。
3. **决策自洽轴定并行**：只读广度才并行；编码这类共享契约的串行。（Anthropic：coding「not a good fit」for multi-agent；Cognition「Flappy Bird」）
4. **验收以客观证据为准**：翻证据可外包，下判断留主 Agent。
5. **隔离即正确性**：fresh 实例 + 完整任务上下文（objective / 输出格式 / 工具与文件范围 / 边界）防错误假设跨 Task 传染。

**引用**：
- Anthropic《Building Effective Agents》——5 工作流模式 + 最简优先 — https://www.anthropic.com/research/building-effective-agents
- Anthropic《How we built our multi-agent research system》——15x token / 编码不适合多 Agent / orchestrator-worker — https://www.anthropic.com/engineering/multi-agent-research-system
- Cognition《Don't Build Multi-Agents》——并行 subagent 上下文割裂致决策冲突（Flappy Bird）
