本文件由 CLAUDE.md 下沉；主控命中指针时必须完整读取本文件再行动，不得凭指针行猜测内容。

[文件结构]
    project/
    ├── Product-Spec.md                    # 产品需求文档
    ├── Product-Spec-CHANGELOG.md          # 需求变更记录
    ├── Architecture-Design.md             # 架构设计文档（可选，M/L 档项目）
    ├── DFX-Spec.md                        # DFX 质量属性设计（可选，与架构设计配套）
    ├── Design-Brief.md                    # 设计规范文档（可选）
    ├── DEV-PLAN.md                        # 分阶段开发计划
    ├── <project-name>/                    # 项目代码（以项目名命名的子文件夹）
    │   ├── src/
    │   ├── package.json
    │   └── ...
    ├── .gitignore
    └── .claude/
        ├── CLAUDE.md                      # 主控
        ├── settings.json                  # hooks 等 Claude Code 配置
        ├── rules/                         # 主控下沉的细则（file-structure / workflow-orchestration / dev-workflow-details / subagent-dispatch / memory-systems / harness-large-repo / quality-attributes）
        ├── hooks/                         # 闸门钩子（stop-gate / no-direct-code-guard / tdd-gate / pre-commit-check / three-file-sync-gate / dangerous-pkill-guard / secret-exfil-guard / precompact-gate / release-gate / harness-async-verify / notify / session-rules-banner 等，全部 .mjs，node 单运行时，共用逻辑在 hooks/lib/）
        ├── harness/                       # 大仓治理（harness.mjs + adapters.json；module-catalog.json 放置即启用）
        ├── workflows/                     # Workflow 编排脚本（code-review-fanout.js）
        ├── agents/
        │   ├── implementer.md             # 实现者 Sub-Agent（编码）
        │   ├── code-reviewer.md           # 审查者 Sub-Agent（审查）
        │   ├── tester.md                  # 测试者 Sub-Agent（写测/跑测，独立于实现者）
        │   ├── deployer.md                # 部署者 Sub-Agent（打包/部署）
        │   ├── feedback-observer.md       # 反馈观察 Sub-Agent
        │   ├── evolution-runner.md        # 进化引擎 Sub-Agent
        │   └── progress-recorder.md       # 项目记忆 Sub-Agent
        ├── EVOLUTION.md                   # 进化引擎
        ├── feedback/                      # 经验教训
        ├── scripts/                       # 质量脚本（doctor 自检 / plan-lint / skill-description-lint / fast-mode 开关 / gate-audit / statusline 状态行 / supervisor 进程守护）
        ├── tests/                         # 框架自测（selftest / test-setup / test-routing / test-fast-mode / test-gate-audit / test-three-file-sync-gate，cases/run-all.sh 统一跑）
        └── skills/
            ├── product-spec-builder/      # 需求收集
            ├── arch-designer/             # 架构设计（七大原则 + 模块划分 + ADR）
            ├── dfx-designer/              # DFX 设计（12 维质量属性定档）
            ├── design-brief-builder/      # 设计规范
            ├── design-maker/              # 设计图制作
            ├── dev-planner/               # 开发计划
            ├── dev-builder/               # 项目开发
            ├── bug-fixer/                 # Bug 修复
            ├── code-review/               # 代码审查
            ├── test-builder/              # 系统测试
            ├── release-builder/           # 构建发布
            ├── red-blue-review/           # 红蓝对抗审查
            ├── branch-finisher/           # 开发分支收尾
            ├── skill-builder/             # 创建新 Skill
            ├── feedback-writer/           # 记录用户反馈
            ├── evolution-engine/          # 进化引擎扫描
            └── progress-recorder/         # 项目记忆维护
