# Feedback Index

> 经验教训索引。新建或更新 feedback 文件后，同步更新此索引。
> 格式：每条一行，`- [标题](文件名.md) — 一句话描述`
> 模板：templates/feedback-topic-template.md

- [hook 解释器选 pwsh 7，不用 Windows PowerShell 5.1](hook-interpreter-use-pwsh7-not-powershell51.md) — 本机配置 hook / 脚本解释器时 PowerShell 一律用 pwsh 7 绝对路径（含空格加引号、bash 命令串用正斜杠），其余裸 powershell.exe hook 超时时按同法逐个替换
- [生产删除前重查目标当前状态，归因须有直接证据](destructive-ops-recheck-live-state-and-require-direct-evidence.md) — 生产/共享环境的删除・停用・覆盖类写操作，执行前当场重查目标最新状态、归因要直接证据（旧快照 + 时间推断不作数）；误删用户在跑的导入 Session 的实害教训
- [性能根因先实测再给方案，代码推测不配当推荐依据](perf-root-cause-needs-measured-evidence-before-recommending-options.md) — 性能类根因判断给方案选项前必须先 EXPLAIN ANALYZE / 采样实测；被质疑才补证据 = 流程倒置，本例实测直接推翻代码推测（真凶是 lateral 重复扫描 + work_mem 溢出，非猜的 ANY(path)）
- [客户端拒绝工具调用 ≠ 远端命令未执行](rejected-tool-call-remote-side-effect-may-have-executed.md) — SSH/docker exec/数据库写入等远端副作用调用被中断或拒绝后，恢复第一步先实查远端状态（进程列表 / pg_stat_activity）确认上次到底执行没执行；假设"被拒=没发生"造成双进程 + 孤儿查询的实害教训
- [脚手架交付应复制即用且保持项目根目录清爽](copy-ready-clean-scaffold-layout.md) — 「复制即用」为默认交付契约（`.claude/` 复制过去即工作），安装器只是可选便利；目标项目根目录暴露文件压到最少，维护资产收进隐藏配置目录
- [脚手架开发遵循用户明确的质量门禁豁免](scaffold-development-skip-quality-gates.md) — 开发脚手架内核 ≠ 用脚手架开发业务项目；用户明确豁免本轮测试/检视/用例时照办，但豁免不得删减最终脚手架的审查测试能力、不外推成永久约束
- [研究下钻按指定递归深度执行，不能用平级数量冒充深度](recursive-research-depth-not-fanout.md) — 用户要求「向下多打 N 层/加强吸收」= 委派树递归下钻（主 Agent 分轮驱动、逐层收窄边界），不是同层加并行研究者；验收核实际层数与每层新增分析价值
- [调研使用 Claude Code 原生 Sub-Agent，主 Agent 保留独立判断](native-subagent-research-main-agent-judgment.md) — 长目录/复杂材料学习派原生 Task/Agent fresh Sub-Agent，不擅自调本地 ask gemini 桥；主 Agent 亲读关键材料独立判断，翻证据可委派、下判断不外包
- [仓库刷新应遵循用户明确授权，避免擅自加重流程](repository-refresh-follow-explicit-scope.md) — 用户已授权清理并要求直接拉最新时走最短安全路径（只读确认后直接 clone），不擅自加临时克隆/比对/备份交换，明确不要的旧资产不「保险起见」保留
- [仓库清爽不等于去品牌化，清理时默认保留品牌识别资产](preserve-brand-assets-during-cleanup.md) — 清理/精简/重写入口文档前先盘点 Logo、ASCII Banner、初始化话术、项目名视觉，默认保留；删除替换须用户明确同意
- [押后事项非点名批准不得重启，长耗时计算是红区](deferred-work-restart-needs-explicit-approval-long-db-compute-is-red-zone.md) — 用户押后/否决过的事项只有点名批准才能重启，含糊指令先复述问清；超过几分钟的长耗时计算启动前报预计耗时拿批准；用户要"看数"用现成数据答，数据呈现≠数据重算
- [地基未稳不助推看盘类锦上添花，重计算签字前须成本预估](foundation-first-no-premature-dashboards-cost-preflight-serial-dev.md) — 数据未准、基本功能未稳时看盘/报表/指标卡类需求默认泼冷水降级挂账；含重计算的规格签字前附真库量级成本预估或抽样实测；DEV-PLAN 排期默认一次一个功能串行收口
- [长跑批处理必须有看门狗与输入预检，挂死立即止损不观望](long-batch-needs-watchdog-input-precheck-and-prompt-stop-loss.md) — 批处理流水设计期就带看门狗超时 + 病态输入廉价预检直接跳过隔离；确认挂死迹象立即报告止损，不许"进程还活着"式观望，观望是最贵的选项
- [本地全量回归绿不等于 CI 绿，收官前须独读 CI 真实输出](local-green-is-not-ci-green-check-before-closeout.md) — 本地 run-all 与 CI 跑的集合不同，前者绿不能反推后者绿；收官/发版前 `gh run list` 是独立核查步骤；CI 失败邮件早已送达用户，缺的不是通知是验收方（主 Agent）从不核对——通知到人≠验收到位；跨环境修复未经真实环境判决前只记「已修未验」；行号绑定的豁免机制每批改动宿主文件都要重查
