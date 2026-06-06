# cc-base

SiteMaster 全栈开发框架的**纯 Claude Code 基础设施脚手架**——零外部依赖，全部靠 Claude Code 原生的 **Sub-Agent（Task/Agent 工具）** 编排。

本仓库不是某个产品的代码，而是一套**可复用、可上库、可在新机器一键复现**的 Agent 工作环境配置：克隆下来直接 `claude`，就有一整套需求→设计→开发→测试→发布的技能体系 + 多 Sub-Agent 分权协作。

> 它是 [ccb-base](https://github.com/zylimit/ccb-base) 的**纯 Claude Code 版**：去掉了 CCB 多进程编排（codex/gemini 外部驱动、daemon、tmux），把所有委派改为 Claude Code 原生 Sub-Agent。框架技能体系、hook 闸门、feedback/进化引擎、项目记忆全部保留。

## 与 ccb-base 的区别

| 维度 | ccb-base（CCB 版） | cc-base（本仓，纯 CC 版） |
|------|-------------------|--------------------------|
| 编排 | CCB daemon + `ask` 跨进程派单 | Claude Code 原生 Sub-Agent（Task/Agent 工具） |
| 工人 | commander/coder(claude) + reviewer/tester/deployer(codex) 外部进程 | 主 Agent + implementer/code-reviewer/tester/deployer Sub-Agent |
| 运行依赖 | 需装 CCB、起 daemon、管 tmux | 无——只要 Claude Code 本身 |
| 跨 session 留痕 | CCB events/provider-state | 不留外部进程痕迹（靠 progress.md 项目记忆 + feedback） |
| 命令行工具 | ccb-ps / ccbcd / ccbk（管 daemon） | 无需（无 daemon 可管） |

## 角色映射

```
CCB 外部 Agent 进程            →   纯 CC Sub-Agent
─────────────────────────────────────────────────
commander (claude)            →   主 Agent（会话本身，编排者）
coder     (claude)            →   implementer    Sub-Agent（编码）
reviewer  (codex)             →   code-reviewer  Sub-Agent（两阶段审查）
tester    (codex)             →   tester         Sub-Agent（写测≠被测作者）
deployer  (codex)             →   deployer       Sub-Agent（打包/部署）
```

主 Agent 的**铁律不变**：编码/审查/测试/部署四个环节一律不亲自动手，只「写提示词 + 委派 fresh Sub-Agent + 验收」。

## 目录结构

```
.claude/
├── CLAUDE.md                 主控：角色、Skill 调用、Sub-Agent 调度、工作流
├── agents/                   7 个 Sub-Agent
│   ├── implementer.md        编码（dev-builder skill）
│   ├── code-reviewer.md      审查（code-review skill）
│   ├── tester.md             测试（test-builder skill，独立于实现者）
│   ├── deployer.md           部署（release-builder skill）
│   ├── feedback-observer.md  记录用户反馈（feedback-writer skill）
│   ├── evolution-runner.md   扫描 feedback 生成进化建议（evolution-engine skill）
│   └── progress-recorder.md  维护 progress.md 项目记忆
├── skills/                   13 个 Skill（需求→设计→开发→测试→发布 + 元技能）
├── hooks/                    6 个 hook（feedback 信号 / review 闸门 / commit 检查 / auto-push）
├── feedback/                 经验教训库 + 索引 + 模板（进化引擎扫描源）
├── EVOLUTION.md              进化引擎（四层：积累→毕业→优化→生成）
└── settings.json             hook 注册

progress.md                   项目外部工作记忆（决策/约束/TODO/Done，progress-recorder 维护）
.gitignore                    只版本化配置，排除运行时状态（.needs-review / settings.local.json）
README.md                     本文件
```

## 使用

```bash
cd cc-base-dryrun
claude            # 直接启动；CLAUDE.md 自动加载，SessionStart hook 自动检查 feedback
```

无安装步骤——纯 CC 方案没有 daemon、没有 tmux、没有命令行工具要装，Claude Code 原生读取 `.claude/`。

### 工作流一览

1. `/product-spec-builder` 需求 → Product-Spec.md
2. `/design-brief-builder` `/design-maker` 设计（可选）
3. `/dev-planner` → DEV-PLAN.md
4. `/dev-builder` 开发：主 Agent 派 implementer 编码 → 派 code-reviewer 两阶段审查 → bug-fixer 修 → 循环
5. Phase 验证四步走，第2步派 tester 跑/补回归测试（写测≠被测作者）
6. `/release-builder` 发布：先过测试卡点 → 派 deployer 打包/部署 → 主 Agent 独立核查三件套验收
7. `/record` `/recap` 维护项目记忆；用户给修正 → 自动派 feedback-observer 记录 → evolution-runner 归纳进化

## 设计要点

- **委派统一走原生 Sub-Agent**：每个 Task 一个 fresh 实例，主 Agent 提供完整上下文（Sub-Agent 不继承 session 历史），这是隔离保证，防止 Task A 的错误假设污染 Task B。
- **Workflow 编排是纯 CC 红利**：全 Claude worker 让 Dynamic Workflows 的 `agent()` 可原生 fan-out（ccb-base 因要驱动外部 codex worker 用不了）。判据 = 单元决策要不要自洽：**只读广度（审查/测试/研究）才并行，编码默认串行**（Anthropic 实证编码不适合多 Agent、Cognition「Flappy Bird」）。多 Agent 耗 ~15x token，必须用户显式 opt-in。详见 [ARCHITECTURE.md](./ARCHITECTURE.md) §4。
- **写测独立性**：tester 必须是与写该代码的 implementer 不同的 fresh 实例——自码自测会把作者的错误假设原样写进断言（confirmation bias）。
- **验收以客观证据为准**：子 Agent 自报"完成/通过"只反映它跑完了，不等于结果正确；主 Agent 一律核查客观证据（编译输出 / 测试运行器真实输出 / 部署三件套）。
- **配置入库、运行时不入库**：`.needs-review`、`settings.local.json` 等滚动/本机状态由 `.gitignore` 排除。
- **feedback ≠ memory**：用户修正 AI 行为 → feedback 流程（`.claude/feedback/`，喂进化引擎改进规则）；跨 session 偏好/上下文 → memory。两套系统不混用。
