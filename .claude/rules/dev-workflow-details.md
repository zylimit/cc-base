---
paths:
  - "Product-Spec.md"
  - "Product-Spec-CHANGELOG.md"
  - "DEV-PLAN.md"
  - "Architecture-Design.md"
  - "DFX-Spec.md"
  - "Design-Brief.md"
---

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

[各 Skill 执行方式]
    由 CLAUDE.md [Skill 调用规则] 下沉：触发条件在主控一行一个，这里是每个 Skill 的自动 / 手动入口、前置条件与执行方式原文。

    [product-spec-builder]
        **自动调用**：
        - 用户表达想要开发产品、应用、工具时
        - 用户描述产品想法、功能需求时
        - 用户要修改 UI、改界面、调整布局时（迭代模式）
        - 用户要增加功能、新增功能时（迭代模式）
        - 用户要改需求、调整功能、修改逻辑时（迭代模式）
        **手动调用**：/product-spec-builder

    [arch-designer]
        **自动调用**：
        - Product-Spec 批准后判为 M/L 档（多模块 / 有边界诉求 / 大规模）时建议调用
        - 用户说"架构设计"、"模块划分"、"技术架构"、"分层"、"架构评审"时
        **手动调用**：/arch-designer
        前置条件：Product-Spec.md 必须存在
        执行方式：文档类 skill，主 Agent 直接执行（同 product-spec-builder）；产出 Architecture-Design.md，L 档同步产出 `.claude/harness/module-catalog.json` 骨架接通 arch-check 架构防腐闸

    [dfx-designer]
        **自动调用**：
        - arch-designer 完成后建议顺路做 DFX 定档
        - 用户说"DFX"、"非功能需求"、"可靠性/可测试性/可服务性设计"、"DFX 评审"时
        **手动调用**：/dfx-designer
        前置条件：Product-Spec.md 必须存在（Architecture-Design.md 可选，有则按模块定档）
        执行方式：文档类 skill，主 Agent 直接执行；设计模式产出 DFX-Spec.md 并把档位落进 catalog attributes + adapters 接线；评审模式只出评分卡不改文件

    [design-brief-builder]
        **手动调用**：/design-brief-builder
        前置条件：Product-Spec.md 必须存在

    [design-maker]
        **手动调用**：/design-maker
        前置条件：Product-Spec.md 和 Design-Brief.md 必须存在

    [dev-planner]
        **手动调用**：/dev-planner
        前置条件：Product-Spec.md 必须存在

    [dev-builder]
        **手动调用**：/dev-builder
        前置条件：Product-Spec.md 和 DEV-PLAN.md 必须存在

    [bug-fixer]
        **自动调用**：
        - code-review 发现问题后，自动调用修复（review → fix 闭环的一部分）
        - 用户报告 bug、功能异常、编译错误、运行时错误时
        - 用户说"这个功能坏了"、"报错了"、"不正常"时
        **手动调用**：/bug-fixer
        前置条件：项目代码已创建

    [code-review]
        **自动调用**：
        - 每个功能开发完成后，自动进入 review → fix 闭环
        - 用户要求代码审查、检查代码质量时
        **手动调用**：/code-review
        前置条件：Product-Spec.md 必须存在，项目代码已创建
        执行方式：派发 code-reviewer Sub-Agent 执行三阶段审查（Stage 0 静态闸 → Stage 1 规格合规 → Stage 2 代码质量），主 Agent 不自己审查（见 [Sub-Agent 调度规则]）

    [test-builder]
        **自动调用**：
        - dev-builder 四步走验证第2步「测试完整性」时，调用 test-builder 跑/补回归测试（真卡点）
        - per-Task review → fix 闭环中，Stage 1 规格通过后补关键逻辑测试（可选，按价值取舍）
        **手动调用**：/test-builder
        前置条件：项目代码已创建
        执行方式：务实回归——主 Agent 写测试提示词，**测试代码交独立方编写（写测≠被测作者：派 tester Sub-Agent，或非该功能作者的另一 implementer fresh 实例）**，主 Agent 独立复核运行输出后验收；测试失败按代码错/测试错分流（bug-fixer 修代码 / tester 修测试）

    [release-builder]
        **手动调用**：/release-builder（skill 设 disable-model-invocation——发布是副作用工作流，主 Agent 不能代触发；用户口头说"发布/打包/上线"时，主 Agent 回指该命令请用户亲自敲，这是 HIGH 档显式人触发的机器化）
        前置条件：项目代码已创建
        执行方式：用户敲命令时 release-gate hook 先查待审清单（未清直接拦、干净则注入卡点提醒）；打包前先过测试卡点（复用 test-builder 作前置闸门，证据=运行器真实输出，卡点未过不许打包交付）；部署派发 deployer Sub-Agent 执行，主 Agent 不亲自执行、只验收（独立核查三件套，见 [总体规则] 验收铁律）

    [red-blue-review]
        **自动调用**：
        - 发版 / 合并分支前，对高风险或家底（hooks / skills / CLAUDE.md / agents）改动建议过一遍
        - 用户说"红蓝审查"、"对抗审查"、"检视改动"时
        **手动调用**：/red-blue-review
        前置条件：有一批已成型的改动（已 commit 或工作树未提交）
        执行方式：主 Agent 编排 Blue → Red → Judge 三遍——跑 red-blue-review.sh 凑证据包 → 派 implementer 做 Blue 自证（仅作靶子）→ 派 code-reviewer（fresh，独立于 Blue）做 Red 四 lens 攻击（correctness / security / release / windows，每 finding 须附复现路径或 file:line）→ 主 Agent 自己 Judge 裁定（只看证据），出 ACCEPT / FIX_REQUIRED / NEEDS_MORE_EVIDENCE 填进 RED-BLUE-REVIEW.md

    [branch-finisher]
        **自动建议**（skill 设 disable-model-invocation，主 Agent 只建议不能代触发——合并/清分支是副作用工作流，须用户亲自敲命令）：
        - Phase / 功能完成后，建议用户敲 /branch-finisher 收尾当前开发分支
        - 用户说"收尾"、"合并分支"、"这个分支弄完了"时，回指 /branch-finisher 请用户确认触发
        **手动调用**：/branch-finisher
        前置条件：项目代码已创建
        执行方式：先检测环境状态，测试全绿为前置闸门；据状态给出条件化菜单（合并 / 提 PR / 清理分支），按用户选择执行

    [skill-builder]
        **自动调用**：
        - EVOLUTION.md 第四层提议创建新 Skill，用户确认后
        **手动调用**：/skill-builder
        前置条件：无
        新建或改 skill 后跑 `node .claude/harness/harness.mjs skills-lint` 校验 description（CSO，触发式开头、≤180 字），不过先修

    [feedback-writer]
        由 feedback-observer sub-agent 调用，不由用户直接触发
        执行方式：永远通过 feedback-observer sub-agent 执行

    [evolution-engine]
        **自动调用**：session 初始化时自动派发 evolution-runner sub-agent
        **手动调用**：/evolution-engine
        执行方式：永远通过 evolution-runner sub-agent 执行（skill 已声明 `context: fork` + `agent: evolution-runner`——直接调 skill 也会自动落到该 sub-agent 后台运行，不阻塞开场；建议返回后仍逐条展示给用户确认）

    [progress-recorder]
        **自动调用**：出现决策/约束/完成/新任务语言时立即触发（条件见 [项目记忆规则]）
        **手动调用**：/record /archive /recap
        执行方式：record/archive 派 progress-recorder sub-agent 执行，recap 主 Agent 直接读 progress.md + Product-Spec.md + Product-Spec-CHANGELOG.md（只读 progress.md 不算恢复完成；三份存在即读，不存在的跳过不报错）

[项目进度检测显示格式]
    显示格式：
        "📊 **项目进度检测**
        
        - Product Spec：[已完成/未完成]
        - Design Brief：[已生成/未生成/未创建]
        - DEV-PLAN：[已生成/未生成]
        - 项目代码：[已创建/未创建]
        
        **当前阶段**：[阶段名称]
        **下一步**：[具体指令或操作]"

