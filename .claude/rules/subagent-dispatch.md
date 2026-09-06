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

[隔离原则 / 派单包 / 回传纪律（由 CLAUDE.md [Sub-Agent 调度规则] 下沉，原文）]
    evolution-runner 返回的进化建议需展示给用户逐条确认/跳过后再执行。

    **编码/审查/测试/部署——一律走 Sub-Agent，不存在"主 Agent 自己上"的分支**：
    四个环节都通过 Task/Agent 工具派发对应 Sub-Agent，主 Agent 只「写提示词 + 验收」。这是隔离保证，不是可选最佳实践。

    **Sub-Agent 隔离原则（适用于所有 Sub-Agent 派发）**：
    - 每个 Task 必须用 fresh 实例，不复用之前的 Sub-Agent
    - 主 Agent 提供完整任务上下文（Spec 条目、交付清单、涉及文件、项目结构），Sub-Agent 不继承 session 历史
    - Sub-Agent 不知道之前的 Task 做了什么。如果需要上下文，主 Agent 必须显式提供
    - 这不是可选的最佳实践，是隔离保证：防止 Task A 的错误假设污染 Task B
    - **统一派单包**：每次派发明确六字段——**Goal**（完成后必须成立的具体结果）/ **Scope**（允许读改的文件、模块、行为）/ **Out of Scope**（明确不得顺手处理的内容）/ **Existing Pattern**（应遵循的现有实现、类型、命名、文档）/ **Verification**（本任务允许且需要的最小客观核查；用户明确豁免时写明豁免）/ **Escalation**（哪些情况必须返回主 Agent，不得自行扩大范围或权限）。不适用的字段写 N/A，不让 fresh 实例靠猜；大仓启用后这六字段由 `task` 子命令机器校验，缺哪个点哪个。
    - **写测独立性**：tester 必须是与写该代码的 implementer **不同**的 fresh 实例——自码自测会把作者的错误假设原样写进断言（confirmation bias）。详见 feedback/test-independence-author-not-tester.md；大仓启用后 `record-authorship.mjs` 每次编辑自动记谁写了哪些文件，`review` 的 verdict 据此拒绝出自审 ACCEPT
    - **并行**：跨 Task 编码**默认串行**（沿用 per-Task review→fix 循环），同文件改动或有依赖一律串行；**只读/可汇总**的工作（审查、测试、探索）才是并行甜区，见下「Workflow 编排模式」。用户说「加速/快点」≠ 授权并行铺开——加速的正解是砍范围、串行提效、减少返工。

    **Workflow 编排模式**：多个无依赖单位的规模化 fan-out 上层（判据轴 = 单元决策要不要自洽；须用户显式 opt-in，多 Agent 耗 token ~15x）。**写或提议任何 workflow 之前必须先读 .claude/rules/workflow-orchestration.md**（判据轴 / 三个推荐场景 / agentType 集成点 / 三铁律 / 成本闸门 / worktree 操作纪律全在该文件）。

    **Sub-Agent 回传纪律（防回传消息灌爆主 Agent 上下文）**：
    - Sub-Agent 的**最终回传消息**是唯一进主 Agent 上下文的东西。回传 = **结论 + 证据句柄**（文件路径 / commit hash / 编译输出位置 / 测试运行器输出位置 / 时间戳）+ 关键提炼，**不贴全文/原始长日志**。长报告压成要点。
    - **统一回执信封**：所有 Sub-Agent 回传先给通用信封，再追加角色专属内容——**Status**（四态，见下；tester 可用 PASS/FAIL 表示运行器结果）/ **Changed**（实际修改的文件或产物；只读角色写 None）/ **Verified**（实际执行并得到结果的核查）/ **Not verified**（没执行或无法证明的事项，必须列出）/ **Needs review by**（需主 Agent、用户或其他专职角色接管的事项）/ **Evidence**（路径 / commit / 输出位置 / 时间戳等句柄，不贴长日志）。
    - **implementer 四态自评开头**：implementer 回传消息须以自评状态四选一开头——**DONE**（完成、无遗留疑虑）/ **DONE_WITH_CONCERNS**（完成但有疑虑，逐条列出疑虑点）/ **NEEDS_CONTEXT**（缺上下文做不下去，列明缺什么）/ **BLOCKED**（受阻，说明阻塞在哪、需要什么）。主 Agent 据此前置决策（补上下文 / 先解阻塞 / 直接进 review），不必等 code-reviewer 才把疑虑暴露出来。四态即信封的 Status 字段，各 Sub-Agent 同样以之开头。
    - **禁原样重试**：收到 BLOCKED / NEEDS_CONTEXT 后，重派必须至少变更一项（上下文 / 范围 / 角色 / 模型）——同一 prompt 同一模型原样重发一遍属于赌运气。
    翻证据外包下判断自留、单次派单 >60min 的分解红线、四级升级阶梯的完整细则见 .claude/rules/subagent-dispatch.md——派发前、收到 BLOCKED / NEEDS_CONTEXT 时必须先读该文件。

    **⚠️ feedback 和 memory 是两套不同的系统，不能混淆：**
    - 用户修正 AI 行为时，必须走 feedback 流程（派发 feedback-observer 写进 .claude/feedback/），不能只写 memory
    - **决策 / 约束 / 完成事项只认 progress.md**——三文件同步铁律不因任何 memory 存了什么而豁免，`three-file-sync-gate.mjs` 在 Stop 阶段照拦
    feedback / 用户 memory / agent memory 三套的各自边界见 .claude/rules/memory-systems.md——写 feedback、动 agent memory、判断某条该记哪儿之前必须先读该文件。

