# Feedback Index

> 经验教训索引。新建或更新 feedback 文件后，同步更新此索引。
> 格式：每条一行，`- [标题](文件名.md) — 一句话描述`
> 模板：templates/feedback-topic-template.md

- ✅[已毕业] [主 Agent 职责边界：编码/审查/测试/部署一律委派专职 Sub-Agent](main-agent-no-direct-coding.md) — 主 Agent 只「写提示词 + 验收」，不亲自写代码/审查/测试/部署；环节→派发目标（Claude Code Sub-Agent）：编码=implementer、审查=code-reviewer、测试=tester（写测≠被测作者）、部署=deployer；文档类工作不在此约束内
- ✅[已毕业] [部署验收：独立核查三件套，不轻信子 Agent 回复状态](deploy-acceptance-independent-verification.md) — 子 Agent incomplete/空回复/自报通过 ≠ 部署结果；验收以宿主真实状态为准：容器创建时间戳+镜像tag（勿用 Up 时长）/ 健康检查端点 / live 冒烟验证新功能产物；收尾清理临时产物+确认版本文件已提交
- ✅[已毕业] [测试独立性：写测者 ≠ 被测代码作者](test-independence-author-not-tester.md) — 自码自测易"作弊"（confirmation bias），把作者错误假设原样写进断言；测试派独立方：tester Sub-Agent 或非作者的另一 implementer fresh 实例；主 Agent 不写测试且独立复核运行输出
- ✅[已毕业] [测试卡点：测试通过是打包/交付前的强制前置闸门](test-gate-before-packaging-delivery.md) — "部署/打包"指令不豁免测试；打包前必须有相关功能回归测试已运行且通过的证据（含重跑已有套件），带后端逻辑变更的版本新功能须补回归测试或手动功能验证证据，卡点未过不许进入打包→交付；可让 release-builder 复用 test-builder（派 tester）作前置闸门
- ✅[已毕业] [多 repo 提交隔离：独立 repo 各自提交，禁止耦合进同一脚本](multi-repo-commit-isolation.md) — 多个独立 git repo 的 add/commit/push 必须分开、逐个独立执行并各自验收远程同步状态，不得为省事耦合进同一脚本；归属/认证不同（ssh vs https）时耦合会掩盖单点失败造成"半成功"烂局
