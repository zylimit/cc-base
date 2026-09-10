---
paths:
  - ".claude/agents/**"
---

本文件由 CLAUDE.md 下沉；主控命中指针时必须完整读取本文件再行动，不得凭指针行猜测内容。

[派发形态]
    - **Task 直派（默认）**：用 Task/Agent 工具启动一个 Sub-Agent，传完整任务上下文，等结构化报告回来由主 Agent 验收。Sub-Agent 默认后台跑（spawn 即返回，完成时结果自动回传进主 Agent 上下文并通知），派发后可继续别的编排，但**验收必须等结果到手才做**，不许拿"已派发"当"已完成"。
    - **Workflow 编排**：多个无依赖单位（一个 Phase 多 Task、多审查维度、多文件批处理）的 fan-out 上层，须用户显式 opt-in（多 Agent 耗 token ~15x）。写或提议任何 workflow 之前必须先读 .claude/rules/workflow-orchestration.md。
    - **记录类角色走 fork**：progress-recorder / feedback-observer 这类必须看见对话原文的角色，用 Task 工具 `subagent_type: "fork"` 继承主对话全文，省掉主 Agent 手工转述这层失真；执行类四角色 fork 是污染不是红利，一律 fresh。
    - **模型分档**：默认模型写在各 agent frontmatter（执行类 opus 承重，提炼类 sonnet 够用）；纯机械任务（改文案 / 样式微调 / 搬运）派发时可传 sonnet 降本，有疑虑就保持默认，宁贵不糊。

[隔离原则]
    - 每个 Task 用 **fresh 实例**，不复用之前的 Sub-Agent——防 Task A 的错误假设污染 Task B。这不是可选最佳实践，是隔离保证。
    - Sub-Agent 不继承 session 历史，需要的上下文主 Agent 必须**显式给**；给的是**文件路径不是历史**——brief 与 diff 落盘传路径，不把前序 Task 的总结粘进派单（贴历史的派单里 99% 是废话）。
    - **写测 ≠ 被测作者**：tester 必须是与写该代码的 implementer 不同的 fresh 实例，自码自测会把作者的错误假设原样写进断言。详见 feedback/test-independence-author-not-tester.md；大仓启用后 `record-authorship.mjs` 记谁写了哪些文件，`review` 的 verdict 据此拒绝自审 ACCEPT。
    - **并行**：跨 Task 编码**默认串行**，同文件改动或有依赖一律串行；只读 / 可汇总的工作（审查、测试、探索）才是并行甜区。用户说"加速 / 快点"≠ 授权并行铺开——正解是砍范围、串行提效、减少返工。

[派单包七字段]
    **Goal**（完成后必须成立的具体结果）/ **Scope**（允许读改的文件、模块、行为）/ **Out of Scope**（明确不得顺手处理的内容）/ **Existing Pattern**（应遵循的现有实现、类型、命名、文档）/ **Business Context**（这个 Task 为什么做、谁受益、Spec「规则与例外」里相关的条目、progress.md Pinned / Decisions 里适用于本 Task 的规则（引日期）、用户教过的相关纠正（feedback 文件名）——从 Spec 与 progress.md 抄，不让 fresh 实例猜；编码 / 审查 / 测试类派单**不许写 N/A**）/ **Verification**（本任务允许且需要的最小客观核查，用户明确豁免时写明）/ **Escalation**（哪些情况必须返回主 Agent，不得自行扩大范围或权限）。其余不适用的字段写 N/A；大仓启用后由 `task` 子命令机器校验，缺哪个点哪个。
    每单 ≤ 6 次工具调用，只给「文件:行 + 改成什么 + 一条验证命令」（2026-09-06 用户纠正）；单次派单预期 >60min 说明任务分解不合理，回任务分解重切，而不是让 Sub-Agent 长跑。

[回传与验收]
    - Sub-Agent 的**最终回传消息**是唯一进主 Agent 上下文的东西：回传 = **结论 + 证据句柄**（文件路径 / commit hash / 编译与测试输出位置 / 时间戳）+ 关键提炼，不贴全文与原始长日志，长报告压成要点。
    - **统一回执信封**，各 Sub-Agent 一律以四态自评开头：**Status**（DONE / DONE_WITH_CONCERNS / NEEDS_CONTEXT / BLOCKED；tester 可用 PASS / FAIL 表示运行器结果）/ **Changed**（实际改动的文件或产物，只读角色写 None）/ **Verified**（实际跑过且拿到结果的核查）/ **Not verified**（没执行或无法证明的，必须列）/ **Business assumptions**（Spec 没写、自己补的判断，没有写 None）/ **Counter-examples**（代码对得上 Spec、Spec 对不上业务的反例，有就报「需求存疑」，主 Agent 回流 product-spec-builder 迭代模式，没有写 None）/ **Needs review by** / **Evidence**。
    - **对着 diff 与运行器输出判，不对着实现者的报告判**；翻证据（读 artifact 全文、跑核查三件套）这类体力活可外包，「通过 / 不通过」的判断权留主 Agent，需要时再派 fresh 实例回溯原文核实。
    - **BLOCKED / NEEDS_CONTEXT 升级阶梯（禁原样重试）**：① 缺什么补什么、带齐上下文重派 fresh；② 补不齐就砍范围重切任务；③ 属缺陷定位类换 bug-fixer 路线；④ 三步都不通升级用户拍板。重派必须至少变更一项（上下文 / 范围 / 角色 / 模型），同 prompt 同模型原样重发属于赌运气。

[边界]
    evolution-runner 返回的进化建议需展示给用户逐条确认 / 跳过后再执行。feedback（用户修正 AI 行为，走 feedback-observer 写进 .claude/feedback/）、用户 memory、agent memory 三套的各自边界见 .claude/rules/memory-systems.md——写 feedback、动 agent memory、判断某条该记哪儿之前必须先读该文件；决策 / 约束 / 完成事项只认 progress.md，不因任何 memory 存了什么而豁免。
