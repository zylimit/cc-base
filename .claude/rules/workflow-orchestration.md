本文件由 CLAUDE.md 下沉；主控命中指针时必须完整读取本文件再行动，不得凭指针行猜测内容。

    **Workflow 编排模式（规模化 fan-out 的上层；纯 CC 专属红利）**：
    Claude Code 的 Dynamic Workflows 用 `agent()` 原生 spawn Claude subagent。纯 CC 全是 Claude worker，这条路是开的（ccb-base 因要驱动外部 codex worker 用不了）。**Workflow 不取代 Task 直派，是它在「多个无依赖单位」时的规模化上层。**
    - **判据轴 = 这些单元的决策要不要自洽**（不是"任务多少"）：
      - **要自洽（共享上下文/契约）** → 编码这类 → **别用 workflow 并行**，串行直派。
      - **不要自洽（只读/可独立汇总）** → 审查维度、测试目标、代码库探索、研究广度 → **Workflow fan-out 甜区**。
    - **三个推荐场景**：① **code-review 多维 + 对抗验证**——`pipeline(维度, 审查, 逐条 verify)`，verify 用**多视角 lens**（correctness/security/repro），以视角多样性补回纯 CC 失去的「codex/claude 异构互照」。已落地脚本 `.claude/workflows/code-review-fanout.js`，opt-in 直接调。② **test-builder 批量写测**——`parallel` 多个高价值逻辑各派 tester（fresh 实例天然独立于 implementer 作者）。③ **代码库探索/研究**——breadth-first 普查。
    - **集成点 `agentType`**：workflow 的 `agent(prompt, {agentType:'code-reviewer'|'tester'|'implementer', schema, isolation:'worktree'})` 从同一注册表复用框架现有专职 Agent（带其 skill+system prompt）。**编排换脚本，工人不变**，隔离/职责边界/写测独立全保住。
    - **三铁律不动**：① **主 Agent 仍是唯一编排者**——workflow 是主 Agent 写的脚本，不是 Sub-Agent 自拉 Sub-Agent；其内 `workflow()` 嵌套仅一层。② **验收判断权留主 Agent**——workflow 用 `schema` 回传「结论 + 证据句柄」，主 Agent 凭证据定夺（= 翻证据外包/下判断自留）。③ 写测独立性靠 `agent()` 每次 fresh + 不同 agentType。
    - **成本闸门（硬约束）**：多 Agent 耗 token **~15x**（Anthropic 实证），只对高价值任务划算。Workflow **必须用户显式 opt-in**，不静默触发——达到 fan-out 规模时主 Agent 先提议、用户确认再跑。worktree 隔离有 ~200-500ms+磁盘/agent 成本，只在并行写文件时用；单 Phase 仅 1-2 个单位时不划算，直接 Task 直派。
    - **worktree 操作纪律**：① Step0 先检测当前是否已在 worktree 中，已在则不再嵌套创建（注意排除 submodule 误判，别把 submodule 当成 worktree）；② 目录优先级——已声明目录 > 现存 .worktrees > 配置指定目录 > 默认，选定后须 `git check-ignore` 确认该 worktree 路径不入版本控制（防把 worktree 提交进仓库）；③ 优先用 harness 原生 worktree 工具（如 EnterWorktree），没有再退回 git 命令。
