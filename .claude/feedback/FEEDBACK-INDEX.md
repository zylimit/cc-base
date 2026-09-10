# Feedback Index

> 经验教训索引。新建或更新 feedback 文件后，同步更新此索引。
> 格式：每条一行，`- [标题](文件名.md) — 一句话描述`
> 模板：templates/feedback-topic-template.md

- [大批量重构收口、发版前须主动扫重复代码并给出裁定](batch-refactor-closeout-scan-duplication-before-release.md) — 多 Phase/跨目录重构或新增改造收口、发版前，主 Agent 主动做一次重复代码/可提炼逻辑扫描，不等用户提醒；扫描量化留痕（工具/窗口/克隆数），裁定「做/不做」都写理由，防止为了抽象而抽象
- [脚手架交付应复制即用且保持项目根目录清爽](copy-ready-clean-scaffold-layout.md) — 「复制即用」为默认交付契约（`.claude/` 复制过去即工作），安装器只是可选便利；目标项目根目录暴露文件压到最少，维护资产收进隐藏配置目录
- [地基未稳不助推看盘类锦上添花，重计算签字前须成本预估](foundation-first-no-premature-dashboards-cost-preflight-serial-dev.md) — 数据未准、基本功能未稳时看盘/报表/指标卡类需求默认泼冷水降级挂账；含重计算的规格签字前附真库量级成本预估或抽样实测；DEV-PLAN 排期默认一次一个功能串行收口
- [hook 解释器选 pwsh 7，不用 Windows PowerShell 5.1](hook-interpreter-use-pwsh7-not-powershell51.md) — 本机配置 hook / 脚本解释器时 PowerShell 一律用 pwsh 7 绝对路径（含空格加引号、bash 命令串用正斜杠），其余裸 powershell.exe hook 超时时按同法逐个替换
- ✅[已毕业] [本地全量回归绿不等于 CI 绿，收官前须独读 CI 真实输出](local-green-is-not-ci-green-check-before-closeout.md) — 本地 run-all 与 CI 跑的集合不同，前者绿不能反推后者绿；收官/发版前 `gh run list` 是独立核查步骤；CI 失败邮件早已送达用户，缺的不是通知是验收方（主 Agent）从不核对——通知到人≠验收到位；跨环境修复未经真实环境判决前只记「已修未验」；行号绑定的豁免机制每批改动宿主文件都要重查
- [长跑批处理必须有看门狗与输入预检，挂死立即止损不观望](long-batch-needs-watchdog-input-precheck-and-prompt-stop-loss.md) — 批处理流水设计期就带看门狗超时 + 病态输入廉价预检直接跳过隔离；确认挂死迹象立即报告止损，不许"进程还活着"式观望，观望是最贵的选项
- [元测试不进发版链，脚手架保持轻量](meta-tests-not-in-release-chain-scaffold-stay-lean.md) — 加"验证验证者"的机制前先问省了谁的什么时间；发版链只放直接证明代码正确的检查，元测试（测尺子的尺子）挪出高频路径；现有机制按「与代码直接相关」+「拦过什么」定期清理；长耗时步骤开跑前先报预计时长和证明什么
- [调研使用 Claude Code 原生 Sub-Agent，主 Agent 保留独立判断](native-subagent-research-main-agent-judgment.md) — 长目录/复杂材料学习派原生 Task/Agent fresh Sub-Agent，不擅自调本地 ask gemini 桥；主 Agent 亲读关键材料独立判断，翻证据可委派、下判断不外包
- [permissions.ask 列表与用户「全部放行」指令冲突](settings-ask-list-conflicts-with-user-authorize-continuous-execution.md) — 用户抱怨反复被要求确认时先查 `.claude/settings.json` 的 `permissions.ask` 列表和 hook 的 `permissionDecision`，别只辩解"我没问"；用户明确全部放行后记进 progress.md 决策并清理冲突的 ask 规则，安全护栏条目不在放行范围
- [仓库清爽不等于去品牌化，清理时默认保留品牌识别资产](preserve-brand-assets-during-cleanup.md) — 清理/精简/重写入口文档前先盘点 Logo、ASCII Banner、初始化话术、项目名视觉，默认保留；删除替换须用户明确同意
- [研究下钻按指定递归深度执行，不能用平级数量冒充深度](recursive-research-depth-not-fanout.md) — 用户要求「向下多打 N 层/加强吸收」= 委派树递归下钻（主 Agent 分轮驱动、逐层收窄边界），不是同层加并行研究者；验收核实际层数与每层新增分析价值
- [Sub-Agent 派单要给最小上下文，不让它自己推导/复核/写长回执](subagent-dispatch-minimal-context-not-self-derivation.md) — 派单只给「文件:行+改成什么+一条验证命令」且 ≤8 次工具调用；复核收拢主 Agent 一次做；≤5 行机械改动主 Agent 直接改不起实例；reviewer 一次一个问题——4 行夹具修正滚到 60 轮的教训
- [review 循环收敛于核心行为，避免过度防御边角输入](review-loop-converge-on-core-behavior-avoid-over-defense.md) — review → fix 闭环收敛判据是核心行为无 HIGH/Medium，非真实调用路径的边角输入参数花样记残留、不再开新一轮红锁；防御代码只为真实调用路径写，安全类缺陷不受此限
- ✅[已毕业] [完成声明需当场新鲜证据：不可跳步五步闸](completion-claims-need-fresh-verification-five-step-gate.md) — 任何"完成/通过/修好"结论前必须有当场跑出的新鲜证据，走不可跳步五步闸；子 Agent 自述/空回复≠结果正确，禁凭表层信息断言再事后追认
- ✅[已毕业] [押后事项非点名批准不得重启；长耗时计算先报耗时拿批准；数据呈现≠数据重算](deferred-work-restart-needs-explicit-approval-long-db-compute-is-red-zone.md) — 用户押后/否决过的事项只有点名批准才能重启，含糊指令先复述问清；超过几分钟的长耗时计算启动前报预计耗时拿批准；用户要"看数"用现成数据答，数据呈现≠数据重算
- ✅[已毕业] [部署验收：以宿主真实状态为准做独立核查，不轻信子 Agent 回复状态](deploy-acceptance-independent-verification.md) — 部署验收以宿主真实状态为准，独立核查三件套（容器时间戳+镜像tag / 健康检查 / live冒烟），不以子 Agent 回复状态为唯一依据
- ✅[已毕业] [生产删除前重查目标当前状态，归因须有直接证据](destructive-ops-recheck-live-state-and-require-direct-evidence.md) — 生产/共享环境的删除・停用・覆盖类写操作，执行前当场重查目标最新状态、归因要直接证据（旧快照 + 时间推断不作数）；误删用户在跑的导入 Session 的实害教训
- ✅[已毕业] [改家底/写规则文档时的风格一致性铁律](edit-family-assets-style-must-match-handwritten-not-ai-generated.md) — 改/加家底（skill、规则文档、CLAUDE.md/AGENTS.md、feedback）时新增内容必须无缝贴合原有家底风格，看上去像用户手搓的、不是 AI 生成的；改前先 grep 核查家底是否本就用某词，保留有机制意义的功能性标识
- ✅[已毕业] [审查/验收闸要量化验证，无效就砍](gates-need-empirical-validation.md) — 审查/验收/测试闸要靠数据验证有效性——记录它判过几次 FIX_REQUIRED/红，长期全过/全绿就是纯成本，简化或删掉；加新闸先想清怎么知道它有用
- ✅[已毕业] [主 Agent 职责边界：编码/审查/测试/部署一律委派专职 Sub-Agent，主 Agent 只写提示词 + 验收](main-agent-no-direct-coding.md) — 主 Agent 只写提示词 + 委派 + 验收，不亲自写代码/审查/测试/部署；编码=implementer、审查=code-reviewer、测试=tester、部署=deployer（全部 Claude Code Sub-Agent）
- ✅[已毕业] [多 repo 提交隔离：独立 repo 各自提交，禁止耦合进同一脚本](multi-repo-commit-isolation.md) — 多个独立 git repo 的提交必须分开、各自独立处理，不能为图省事耦合进同一个脚本——尤其归属不同、远程协议/认证方式不同（ssh vs https）时，耦合会掩盖单点失败，造成"半成功"烂局
- ✅[已毕业] [性能根因先实测再给方案，代码推测不配当推荐依据](perf-root-cause-needs-measured-evidence-before-recommending-options.md) — 性能类根因判断给方案选项前必须先 EXPLAIN ANALYZE / 采样实测；被质疑才补证据 = 流程倒置，本例实测直接推翻代码推测（真凶是 lateral 重复扫描 + work_mem 溢出，非猜的 ANY(path)）
- ✅[已毕业] [存量框架资产保留 · 删 hook 须人工审批](preserve-existing-framework-assets-human-approval-to-remove-hook.md) — 自举/重构现有框架时，存量资产（hooks/skills/CLAUDE.md/AGENTS.md/tools）一律「保留复用 + 增量补缺」，绝不一股脑删/推倒重写；删除/停用/重写现有 hook 须先商量给理由、由用户拍板
- ✅[已毕业] [recap 恢复：必须读齐 Spec + CHANGELOG，不止 progress.md](recap-recovery-must-read-spec-and-changelog-not-just-progress.md) — recap / Clear 之后的上下文恢复必须读齐 progress.md + Product-Spec.md + Product-Spec-CHANGELOG.md 三份——只读 progress.md 漏掉需求基线与需求变更，不算恢复完成
- ✅[已毕业] [接收审查意见/反馈不表演式认同](receiving-review-no-performative-agreement.md) — 接收 code-review 结论或用户反馈时不表演式认同——禁"你说得对/好建议/这就改"空话，改为复述确认/先问清/有理由顶回去/直接动手；反馈含糊先停下问清不凭猜分批
- ✅[已毕业] [记录/配置文件要简洁结论导向，不记过程](record-config-files-concise-conclusions-not-process.md) — 记录/配置类文件（progress.md / ccb.config 注释 / 各类记录文件）要简洁、结论导向——只记决策结论/约束/可 recap 恢复状态的精炼信息/最终方案，不写调试来龙去脉/多次失败试错过程/源码追踪逐步细节/长篇推导
- ✅[已毕业] [red-locks-the-bug：缺陷修复前先补红测锁定](red-locks-the-bug-add-red-test-before-fix.md) — review 交叉审 / 系统测试 / 抽查发现的缺陷，修复前必须先由 tester 补一条锁定该缺陷的失败测试（红）→ 验红（亲见 fail）→ coder 修到绿（禁碰测试断言）→ 异模型 reviewer 复审
- ✅[已毕业] [客户端拒绝工具调用 ≠ 远端命令未执行](rejected-tool-call-remote-side-effect-may-have-executed.md) — SSH/docker exec/数据库写入等远端副作用调用被中断或拒绝后，恢复第一步先实查远端状态（进程列表 / pg_stat_activity）确认上次到底执行没执行；假设"被拒=没发生"造成双进程 + 孤儿查询的实害教训
- ✅[已毕业] [仓库刷新应遵循用户明确授权，避免擅自加重流程](repository-refresh-follow-explicit-scope.md) — 用户已授权清理并要求直接拉最新时走最短安全路径（只读确认后直接 clone），不擅自加临时克隆/比对/备份交换，明确不要的旧资产不「保险起见」保留
- ✅[已毕业] [脚手架开发遵循用户明确的质量门禁豁免](scaffold-development-skip-quality-gates.md) — 开发脚手架内核 ≠ 用脚手架开发业务项目；用户明确豁免本轮测试/检视/用例时照办，但豁免不得删减最终脚手架的审查测试能力、不外推成永久约束
- ✅[已毕业] [Skill 调用合规靠劝服工程，不靠"写清楚"](skill-invocation-persuasion-gate.md) — agent 合规靠劝服工程不靠"写清楚"——规则用绝对命令语言（必须/禁止/失败）、抹掉理性化空间、逐条拦截逃逸借口，高频被跳的配前置清单 + Red Flags 黑名单
- ✅[已毕业] [主 Agent 行为：静默 subagent 须预先告知；中断≠否决方案；禁止甩锅](subagent-silence-preannounce-interrupt-not-rejection-no-blameshift.md) — 派静默 subagent 前必先告知用户(预计耗时/会通知)；工具被用户消息中断(interrupted/rejected)≠用户否决方案，不得擅自切换；禁止甩锅"你打断了我"
- ✅[已毕业] [TDD per-Task 循环：测试侧缺陷的归属分流——派回 tester，不让 coder 碰测试](tdd-per-task-test-side-defect-routing.md) — coder 被硬约束「禁改测试文件」，但 GREEN 后 lint:static 撞到的是 tester 写的测试文件自身的 typecheck/eslint 缺陷时，coder 合理停手非死锁；按「测试错→tester 修，代码错→coder 修」分流
- ✅[已毕业] [测试方法论升级：从事后补回归测试转向 TDD（测试先行，学习 obra/superpowers）](tdd-test-first-over-after-the-fact-regression.md) — 事后补回归测试价值有限（为打勾、覆盖低），引入 TDD red-green-refactor：高价值逻辑测试先行、先写失败测试再写实现，UI 保持渲染/视觉对照
- ✅[已毕业] [测试代码规模按风险分层，卡在有效代码三分之一到二分之一区间](test-code-capped-at-one-third-of-effective-code.md) — 测试量整体落在有效代码 1/3–1/2（按行数），低了补高了删；预算按风险分档：密钥/危险命令/安装器/发布类可到上限二分之一，引擎子命令守退出码契约+一条真实场景，提醒类 hook/工具脚本各留一两条；不做全量覆盖
- ✅[已毕业] [测试卡点：测试通过是打包/交付前的强制前置闸门，部署 ≠ 可跳过测试](test-gate-before-packaging-delivery.md) — 测试通过必须是打包/交付前的强制前置卡点；"部署"指令不等于可跳过测试，带后端逻辑变更的版本打包前须有回归测试或手动功能验证证据
- ✅[已毕业] [测试独立性：写测者 ≠ 被测代码作者（自码自测易作弊）](test-independence-author-not-tester.md) — 写测者不得是被测代码作者；自码自测会把作者的错误假设原样写进断言（confirmation bias），测试派独立方（tester Sub-Agent 或非作者的另一 implementer fresh 实例）
- ✅[已毕业] [三文件同步：随时可 Clear 上下文，靠 recap 完整恢复](three-file-sync-clearable-context-recap-recovery.md) — Product-Spec.md / Product-Spec-CHANGELOG.md / progress.md 最大程度维护、即时同步，确保用户任何时候可 Clear 上下文、靠 recap 完整恢复；决策/约束/完成事项/新任务即时同步到对应文件，doc 类由主 Agent 直接维护
