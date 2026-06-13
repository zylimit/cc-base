---
type: feedback
description: 三文件（Product-Spec.md / Product-Spec-CHANGELOG.md / progress.md）最大程度维护、即时同步，确保用户任何时候可 Clear 上下文、靠 recap 完整恢复项目状态；每次出现决策/约束/完成事项/新任务即时同步到对应文件，doc 类由主 Agent 直接维护（符合去中转精神）
created: 2026-06-10
updated: 2026-06-10
occurrences: 1
graduated: true  # 2026-06-10 毕业→CLAUDE.md [项目记忆规则] 三文件同步铁律（并调和 record 一律派 progress-recorder 的旧表述）；本文件留作细则参照
source_skill: N/A  # 项目记忆维护机制，跨 Skill 通用约束
priority: 铁律（用户连说三遍 + 强制进化，最高置信）
---

# 三文件同步：随时可 Clear 上下文，靠 recap 完整恢复

**问题描述**：
用户下达铁律——三个关键文件必须最大程度维护、即时同步：
- **Product-Spec.md**（产品需求）
- **Product-Spec-CHANGELOG.md**（需求变更记录）
- **progress.md**（项目状态 / 决策 / 约束 / 进度）

目的：用户要能在**任何时候**清空（Clear）上下文重来，恢复项目状态**完全靠这三个文件**（辅以 DEV-PLAN.md / Design-Brief.md / demo 作恢复点）。任何决策、约束、完成事项、新任务一旦产生，就要即时落到对应文件，不能积压在上下文里——上下文一清就丢。

**触发场景**：
开发全流程任意时刻。只要对话中出现以下任一信号，即时同步对应文件：
- 产品需求变更 → Product-Spec.md + Product-Spec-CHANGELOG.md
- 项目状态 / 决策（决定用 X / 最终选择 / 将采用）/ 约束（必须 / 不能 / 要求）/ 进度（完成了 / 实现了 / 修复了）/ 新任务（需要 / 应该 / 计划）→ progress.md

**Why（为什么三文件即时同步）**：
用户的工作方式是「随用随清」——上下文窗口有限，长跑项目里会频繁 Clear 重来。如果关键信息只活在上下文里，Clear 即丢、recap 即残。唯有把决策/约束/完成/任务即时沉淀进这三份磁盘文件，才能保证「Clear → recap → 完整恢复」这条恢复链不断。这是用户敢于随时清空上下文的前提。

**How to apply（怎么做）**：
1. **即时同步，不积压**：每次出现决策/约束/完成事项/新任务，**当场**写入对应文件，不攒着等批量。
2. **分流落点**：
   - 产品需求变更 → 更新 Product-Spec.md，并在 Product-Spec-CHANGELOG.md 追加变更条目。
   - 项目状态/决策/约束/进度 → 更新 progress.md（项目根目录）。
3. **doc 类由主 Agent 直接维护**：这三个文件属文档类，主 Agent 可直接写（符合「主 Agent 职责边界」铁律对文档类的豁免，也符合「去中转」精神——**不必每次都派 progress-recorder subagent**）。
   - 注：progress-recorder subagent 仍可用于较重的 record/archive 批处理（如阈值触发的归档），但日常即时小同步主 Agent 直接落盘即可，别为每条小更新起一个 subagent。
4. **恢复演练心智**：写任何一处时自问「如果用户现在 Clear，recap 这三份文件能不能复原这条信息？」答否就补。

**关联**：
- 与 CLAUDE.md [项目记忆规则] 直接相关：该节已要求 progress-recorder 维护 progress.md 并定义 record/archive/recap 与自动归档阈值；本条**强化为铁律**并补两点——① 三文件（不止 progress.md）即时同步以服务「随时可 Clear + recap 恢复」；② doc 类小同步主 Agent 可直接维护，不必每次派 subagent。
- 与 CLAUDE.md [内容修订] 相关：需求变更流程已要求更新 Product-Spec.md + CHANGELOG，本条把「即时性」与「恢复目的」明确为硬约束。
- 呼应 feedback/ccb-cross-role-dispatch-no-relay-compact-at-source.md 的「去中转」精神：能主 Agent 直接做的轻量文档维护，不绕 subagent。

**evolution-engine 信号**：
CLAUDE.md [项目记忆规则] 当前只点名 progress.md 由 progress-recorder 维护，未把「三文件即时同步以支撑随时 Clear + recap 完整恢复」上升为铁律，也未说明「doc 类即时小同步主 Agent 可直接落盘、不必每次派 progress-recorder」。建议进化时：① 在 [总体规则] 或 [项目记忆规则] 新增「三文件同步铁律」，明确三文件清单、即时同步触发信号、Clear/recap 恢复目的；② 注明 doc 类轻量同步主 Agent 直接维护、重批处理（归档）才派 progress-recorder，避免与「去中转」相悖的过度派单。
