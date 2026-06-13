# Feedback Index

> 经验教训索引。新建或更新 feedback 文件后，同步更新此索引。
> 格式：每条一行，`- [标题](文件名.md) — 一句话描述`
> 模板：templates/feedback-topic-template.md

- ✅[已毕业] [主 Agent 职责边界：编码/审查/测试/部署一律委派专职 Sub-Agent](main-agent-no-direct-coding.md) — 主 Agent 只「写提示词 + 验收」，不亲自写代码/审查/测试/部署；环节→派发目标（Claude Code Sub-Agent）：编码=implementer、审查=code-reviewer、测试=tester（写测≠被测作者）、部署=deployer；文档类工作不在此约束内
- ✅[已毕业] [部署验收：独立核查三件套，不轻信子 Agent 回复状态](deploy-acceptance-independent-verification.md) — 子 Agent incomplete/空回复/自报通过 ≠ 部署结果；验收以宿主真实状态为准：容器创建时间戳+镜像tag（勿用 Up 时长）/ 健康检查端点 / live 冒烟验证新功能产物；收尾清理临时产物+确认版本文件已提交
- ✅[已毕业] [测试独立性：写测者 ≠ 被测代码作者](test-independence-author-not-tester.md) — 自码自测易"作弊"（confirmation bias），把作者错误假设原样写进断言；测试派独立方：tester Sub-Agent 或非作者的另一 implementer fresh 实例；主 Agent 不写测试且独立复核运行输出
- ✅[已毕业] [测试卡点：测试通过是打包/交付前的强制前置闸门](test-gate-before-packaging-delivery.md) — "部署/打包"指令不豁免测试；打包前必须有相关功能回归测试已运行且通过的证据（含重跑已有套件），带后端逻辑变更的版本新功能须补回归测试或手动功能验证证据，卡点未过不许进入打包→交付；可让 release-builder 复用 test-builder（派 tester）作前置闸门
- ✅[已毕业] [多 repo 提交隔离：独立 repo 各自提交，禁止耦合进同一脚本](multi-repo-commit-isolation.md) — 多个独立 git repo 的 add/commit/push 必须分开、逐个独立执行并各自验收远程同步状态，不得为省事耦合进同一脚本；归属/认证不同（ssh vs https）时耦合会掩盖单点失败造成"半成功"烂局
- 🔒[铁律]✅[已毕业] [存量框架资产保留复用，删/停/重写现有 hook/skill/tool 须用户拍板](preserve-existing-framework-assets-human-approval-to-remove-hook.md) — 现有 hooks/skills/CLAUDE.md/agents/tools 是用户血泪迭代的家底，一律「保留复用 + 增量补缺」；删/停/重写任何现有 hook/skill/tool 须先和用户商量给理由、由用户拍板（人工审批闸），不擅自删/推倒重写
- 🔒[铁律]✅[已毕业] [改家底/写规则文档时新增内容须无缝贴合家底风格](edit-family-assets-style-must-match-handwritten-not-ai-generated.md) — 往 skill/规则/CLAUDE.md/feedback 新增内容时风格须无缝贴合存量，缩进/标记/语气/密度同原文，改完读不出哪句后加；禁英文缩写堆砌/元叙事/花哨标记/过度解释 why；改前先 grep 核查家底本来用不用某词
- 🔒[铁律]✅[已毕业] [red-locks-the-bug：缺陷修复前先补红测锁定](red-locks-the-bug-add-red-test-before-fix.md) — review/测试/验收发现的缺陷，修复前必须先派 tester 补锁定该缺陷的失败测试（红）→ 主 Agent 验红 → implementer 修绿 → code-reviewer 复审；缺陷固化为永久回归测试防再犯、修复有客观靶子（红转绿）、机制化不靠自觉
- 🔒[铁律]✅[已毕业] [三文件同步：随时可 Clear 上下文，靠 recap 完整恢复](three-file-sync-clearable-context-recap-recovery.md) — Product-Spec.md/Product-Spec-CHANGELOG.md/progress.md 即时同步，确保任何时候可 Clear 上下文、靠 recap 完整恢复；决策/约束/完成/新任务即时写 progress.md，需求变更写 Product-Spec + CHANGELOG，不积压等批量
- ✅[已毕业] [记录/配置文件要简洁结论导向，不记过程](record-config-files-concise-conclusions-not-process.md) — progress.md/各类记录配置文件保留决策结论/约束/可 recap 恢复状态/最终方案（含一句话关键原因），删除不写调试来龙去脉/失败试错过程/源码追踪细节；与三文件同步正交（那条管该记别漏，本条管记的别啰嗦）
- ✅[已毕业] [主 Agent 行为：静默 subagent 须预先告知；中断≠否决方案；禁止甩锅](subagent-silence-preannounce-interrupt-not-rejection-no-blameshift.md) — 派静默 Sub-Agent/长后台任务前必先一句话告知（静默运行/预计耗时/会通知）；工具被用户消息中断（rejected/interrupted）≠用户否决方案，不擅自切换、禁甩锅「你打断了我」，复盘根因对己不对人
- ✅[已毕业] [TDD 测试先行优于事后补测](tdd-test-first-over-after-the-fact-regression.md) — 高价值逻辑（契约/解析器/状态机/去重/schema/驱动适配层）走 red-green-refactor：先写失败测试定义契约 → 验红（亲见 fail、失败因功能缺失非笔误）→ 实现到绿 → 重构；事后补测=拿覆盖率却失「测试有效」证明，不接受
- ✅[已毕业] [TDD per-Task 循环：测试侧缺陷派回 tester，implementer 全程不碰断言](tdd-per-task-test-side-defect-routing.md) — implementer GREEN 阶段被禁改测试文件保 TDD 纯度，若静态检查撞到 tester 写的测试文件自身纯类型/lint 缺陷，implementer 因被禁改测试合理停手（非死锁）；先隔离判断错在 impl 还是 test，test 侧缺陷派回 tester 做断言不变的最小修复
