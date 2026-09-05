本文件由 CLAUDE.md 下沉；主控命中指针时必须完整读取本文件再行动，不得凭指针行猜测内容。

[工作流程]
    [需求收集阶段]
        触发：用户表达产品想法（自动）或调用 /product-spec-builder（手动）
        
        执行：调用 product-spec-builder skill
        
        完成后：输出交付指南，引导下一步

    [交付阶段]
        触发：Product Spec 生成完成后自动执行

        用户签字闸：先让用户审查已写入的 Product-Spec.md，明确批准后才进入 dev-planner 规划阶段。用户没点头不往下走——有改动回 product-spec-builder 改完再请批。

        输出：
            "✅ **Product Spec 已生成！**
            
            文件：Product-Spec.md
            
            ---
            
            先过一遍 Product-Spec.md，确认写的就是你要的。**批准了我再往下规划开发计划。**
            
            ## 📘 接下来
            
            - 调用 /arch-designer 做架构设计（多模块 / 中大型项目推荐）
            - 调用 /dfx-designer 做 DFX 设计（把可靠性/安全性这些质量属性定成可验收指标）
            - 调用 /design-brief-builder 确定视觉方向（可选）
            - 调用 /design-maker 生成完整设计稿（可选，需先完成 Design Brief）
            - 调用 /dev-planner 制定开发计划（需先批准 Spec）
            - 直接对话可以改 UI、加功能"

    [架构设计阶段]
        触发：用户调用 /arch-designer，或 Spec 批准后主 Agent 判为 M/L 档（多模块 / 有边界诉求 / 大规模）时建议

        执行：调用 arch-designer skill（文档类，主 Agent 直接执行）——规模判档 → 模块划分推演 → 七大原则自检 + 关键场景走查 → 产出 Architecture-Design.md；L 档同步产出 .claude/harness/module-catalog.json 骨架并跑 catalog-lint

        完成后：
            "✅ **架构设计已生成！**

            文件：Architecture-Design.md[ + module-catalog.json 骨架]

            接下来：
            - 调用 /dfx-designer 做 DFX 设计（推荐）
            - 调用 /design-brief-builder 确定视觉方向（可选）
            - 调用 /dev-planner 制定开发计划（Phase 将按模块边界拆）"

    [DFX 设计阶段]
        触发：用户调用 /dfx-designer，或 arch-designer 完成后顺路建议

        执行：调用 dfx-designer skill（文档类，主 Agent 直接执行）——12 维过堂（场景六要素 + 度量 + 对策 + 验证落点）→ 按模块定档 → 优先级栈排序 → 产出 DFX-Spec.md；有 catalog 则写 modules[].attributes + adapters 接线建议 + 跑 attributes 子命令确认缺口。用户说"DFX 评审"则走评审模式只出评分卡

        完成后：
            "✅ **DFX-Spec 已生成！**

            文件：DFX-Spec.md[ + module-catalog attributes 已定档]

            接下来：
            - 调用 /design-brief-builder 确定视觉方向（可选）
            - 调用 /dev-planner 制定开发计划（DFX 验证手段会进各 Phase 验收）"

    [设计规范阶段]
        触发：用户调用 /design-brief-builder
        
        执行：调用 design-brief-builder skill
        
        完成后：
            "✅ **Design Brief 已生成！**
            
            文件：Design-Brief.md
            
            接下来：
            - 调用 /design-maker 生成完整设计稿（可选）
            - 调用 /dev-planner 制定开发计划
            - 跳过设计稿也可以，后续按文字描述开发"

    [设计图制作阶段]
        触发：用户调用 /design-maker
        
        执行：调用 design-maker skill
        
        完成后：
            "✅ **设计稿已完成！**
            
            设计文件已通过设计工具生成，覆盖所有页面和状态变体。
            
            调用 /dev-planner 制定开发计划。设计稿会作为 Phase 拆分和编码实现的核心参照。"

    [开发计划阶段]
        触发：用户调用 /dev-planner
        
        执行：调用 dev-planner skill
        
        生成后跑 `.claude/scripts/plan-lint.sh` 静态校验（禁 placeholder / Phase 结构 / Task 粒度），不过先修再往下走
        
        完成后：
            "✅ **DEV-PLAN 已生成！**
            
            文件：DEV-PLAN.md
            共 N 个 Phase。
            
            调用 /dev-builder 开始开发。"

    [项目开发阶段]
        触发：用户调用 /dev-builder
    
        第一步：询问设计稿
            询问用户："有设计稿吗？有的话发给我参考。"
            用户发送图片 → 记录，开发时参考
            用户说没有 → 继续
    
        第二步：进入开发
            调用 dev-builder skill，进入 Plan Mode，列出当前 Phase 的 TaskList
            编码一律委派（[总体规则] 职责边界铁律，无"主 Agent 直接开发"分支）：
                → 派发 implementer Sub-Agent：每个 Task 一个 fresh 实例，有依赖顺序执行，无依赖可并行，不并行修改同一文件，并行 Task 各自独立完成 review → fix 循环后再 commit，如有文件冲突由主 Agent 合并解决
                → 主 Agent 只写提示词（任务上下文：Spec 条目、交付清单、涉及文件、项目结构）+ 验收，不亲手写代码
    
        第三步：per-Task 开发 → review → fix 循环

            对 Phase 中的每个 Task，执行以下循环：

            派发 implementer 编码（执行规则见 dev-builder SKILL.md）
                ↓
            派发 code-reviewer 三阶段审查
                ↓
            Stage 0 静态闸（static-check.mjs 识栈跑 linter）结果：
                → 全绿 → 进入 Stage 1
                → 有静态错 → 停在 Stage 0，派发 bug-fixer 修绿 → 从 Stage 0 重审
                ↓
            Stage 1 Spec Compliance 结果：
                → 通过 → 进入 Stage 2
                → 失败 → 派发 implementer 补实现 → 重新派发 code-reviewer
                ↓
            Stage 2 Code Quality 结果：
                → 通过 → 执行 echo clean > .claude/.needs-review → commit → Task 完成 → 进入下一个 Task
                → 失败 → 派发 bug-fixer（或 implementer）修复 → 重新派发 code-reviewer（从 Stage 0 开始）

            循环直到三个 Stage 都通过。

            所有 Task 完成 → 进入第四步

            用户可随时介入切换为手动模式

        第四步：Phase 级别最终验证
            执行 dev-builder SKILL.md [Phase 完成度判断] 的四步走验证。
            其中第2步「测试完整性」派 tester Sub-Agent 跑/补回归测试（写测≠被测作者）。
            重点关注跨 Task 的集成问题——导入关系、文件依赖、命名一致性。
            如发现问题 → 派发 bug-fixer 修复 → 用 fix: commit message 提交 → 重新验证

        第五步：用户确认 Phase 完成

        第六步：引导进入下一个 Phase，或提示可调用 /release-builder 发布

        补充——手动触发入口：
        - 用户调用 /code-review → 派发 code-reviewer 三阶段审查（Stage 0 静态闸 → Stage 1/2）→ 展示报告给用户 → 用户决定修复范围和下一步
        - 用户调用 /bug-fixer 或报告 bug → 调用 bug-fixer skill 修复 → 修完后建议 /code-review 验证

    [发布阶段]
        触发：用户调用 /release-builder

        执行：调用 release-builder skill（打包前先过测试卡点；部署派发 deployer Sub-Agent，主 Agent 独立验收）

        完成后：展示发布结果

    [本地运行阶段]
        触发：用户说"帮我跑起来"、"启动项目"、"运行一下"等
        执行：自动检测项目类型，安装依赖，启动项目
        输出："🚀 **项目已启动！** **访问地址**：http://localhost:[端口号] [根据 Product Spec 生成简要使用说明]"

    [内容修订]
        当用户提出修改意见时：

        第一步：明确变更内容
            调用 product-spec-builder（迭代模式）
                ↓
            通过追问明确变更内容 → 更新 Product-Spec.md → 更新 Product-Spec-CHANGELOG.md
                ↓
            用户签字闸：让用户审查更新后的 Product-Spec.md，明确批准变更后才进入第二步。没点头不更新开发计划。

        第二步：更新开发计划
            调用 dev-planner（迭代模式）
                ↓
            更新 DEV-PLAN.md（如不存在则创建）→ 明确变更影响哪些 Phase / Task

        第三步：执行代码变更
            编码一律委派（[总体规则] 职责边界铁律）：
                → 派发 implementer Sub-Agent，主 Agent 写提示词 + 验收，不亲手写代码

        第四步：review → fix 循环
            执行 [项目开发阶段] 第三步同样的 review → fix 循环。

        第五步：验证 → 用户确认
            执行 dev-builder SKILL.md [Phase 完成度判断] 的四步走验证。
            如验证中发现问题并修复，修复的 commit 已在修复时提交。
            用户确认 → 完成

        完成后引导：如有更多修改继续对话。如之前已打包发布过，提醒用户输入 /release-builder 重新打包。
