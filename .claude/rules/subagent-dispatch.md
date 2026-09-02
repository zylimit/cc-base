---
paths:
  - ".claude/agents/**"
---

本文件由 CLAUDE.md 下沉；主控命中指针时必须完整读取本文件再行动，不得凭指针行猜测内容。（frontmatter 的 paths 让 Claude Code 原生按需加载本规则——碰 .claude/agents/ 下文件时自动进上下文；派发 Sub-Agent、收到 BLOCKED / NEEDS_CONTEXT 回执时仍按 CLAUDE.md 指针手动读，两条路都通。）

[派发形态与异步语义]
    - 派发 = 用 Task/Agent 工具启动对应 Sub-Agent，传入完整任务上下文，等其返回结构化报告后由主 Agent 验收。Claude Code v2.1.198 起交互会话里 Sub-Agent 默认**后台运行**（spawn 即返 async_launched，完成时结果自动回传进主 Agent 上下文并有 agent_completed 通知）——派发后可继续别的编排，但**验收必须等结果到手才做**，不许拿"已派发"当"已完成"。
    - **两种派发形态**：① **直接 Task 派单**（默认）——单 Task / 一问一答，主 Agent 用 Task/Agent 工具一次派一个 Sub-Agent。② **Workflow 编排**（规模化上层）——多个无依赖单位（一个 Phase 多 Task、多审查维度、多文件批处理）时，主 Agent **写 Workflow 脚本**做 fan-out / pipeline。两者工人相同（都是 implementer/code-reviewer/tester/deployer），只是编排粒度不同。判据与铁律见 [Sub-Agent 调度规则] 的「Workflow 编排模式」。

[隔离原则长尾——fork 派发 / 模型分档 / 并行判据]
    - **记录类角色可走 fork 派发**：progress-recorder / feedback-observer 这类「必须看见对话原文才能记录」的角色，优先用 fork 形态派发（Task 工具 `subagent_type: "fork"`，继承主对话全文与 prompt cache）——省掉主 Agent 手工转述 delta 这层失真；fork 提示词里写明角色与任务（如「按 progress-recorder skill 规则把本轮决策/完成合并进 progress.md」）。执行类四角色（implementer / code-reviewer / tester / deployer）仍必须 fresh 隔离，fork 对它们是污染不是红利。
    - **模型分档（成本档位）**：各 agent 默认模型在其 frontmatter（code-reviewer/implementer/tester/deployer=opus 承重；feedback-observer/progress-recorder/evolution-runner=sonnet 提炼类够用）。派发时可传 per-invocation model 参数对单次任务降档——简单机械任务（改文案 / 样式微调 / 纯搬运）派 implementer 可显式传 sonnet 降本；有疑虑保持默认档，宁贵不糊。
    - **并行（按业界结论收紧）**：**编码是最不该并行的环节**——Anthropic 实证「most coding tasks involve fewer truly parallelizable tasks than research」，Cognition「Flappy Bird」证明并行编码会因不共享上下文而决策冲突（共享类型/契约/命名各写各的）。所以：跨 Task 编码**默认串行**（沿用 per-Task review→fix 循环）；只有当多个 Task **真正独立 + 已全规格化**（接口契约、命名、文件边界都已在 DEV-PLAN/Spec 钉死）时，才并行派 implementer，且必须 worktree 隔离、不并行改同一文件、各自独立完成 review→fix 后由主 Agent 合并。同文件改动或有依赖 → 一律串行。**只读/可汇总**的工作（审查、测试、探索）才是并行甜区，见 [Sub-Agent 调度规则] 的「Workflow 编排模式」。用户说「加速/快点」≠ 授权并行铺开——加速的正解是砍范围、串行提效、减少返工，并行仍按本条判据。

[Sub-Agent 回传纪律（防回传消息灌爆主 Agent 上下文）]
    - Sub-Agent 上下文虽自动隔离，但它的**最终回传消息**是唯一进主 Agent 上下文的东西。回传 = **结论 + 证据句柄**（文件路径 / commit hash / 编译输出位置 / 测试运行器输出位置 / 时间戳）+ 关键提炼，**不贴全文/原始长日志**。长报告压成要点。
    - **翻证据外包，下判断自留**：读 artifact 全文、跑核查三件套这类体力活可派给 Sub-Agent，但「通过/不通过」的验收判断权留主 Agent——凭回传句柄定夺，需要时再派 fresh 实例回溯原文核实。这与 [总体规则] 验收铁律协同。
    - **任务时长红线**：单次派单预期 **>60min 多半是任务分解不合理**——回到任务分解重切，而非让 Sub-Agent 长跑。对应 Anthropic「clear task boundaries」——每次派单都要有明确 objective / 输出格式 / 工具与文件范围 / 边界。
    - **BLOCKED/NEEDS_CONTEXT 升级阶梯（禁原样重试）**：收到这两态后按阶梯处理——① 缺什么补什么，带齐上下文重派 fresh 实例；② 补不齐则砍范围重切任务（回任务分解）；③ 属缺陷定位类换 bug-fixer 路线；④ 三步都走不通升级用户拍板。同一 prompt 同一模型原样重发一遍属于赌运气，禁止——重派必须至少变更一项（上下文 / 范围 / 角色 / 模型）。
