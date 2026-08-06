---
name: dfx-designer
description: 当架构设计完成后要做 DFX 设计，或用户说"DFX"、"非功能需求"、"可靠性设计"、"可测试性"、"可服务性"、"DFX 评审"时使用。
---

[任务]
    DFX（Design For eXcellence）是评价设计优劣、为设计决策提供依据的方法论——产品竞争力不止功能，还在客户可感知的与内部效率所需的质量属性。本 skill 双职能：
    **设计模式（Design-in）**：把 12 个 DFX 维度逐一过堂，产出可度量的 DFX-Spec.md（目标值 / 度量方式 / 设计对策 / 验证手段），并把结论落进 harness 质量门（attributes 档位 + adapters 接线）。
    **评审模式（Review）**：拿 12 维清单对既有 Architecture-Design.md（或现有系统）做 DFX 评审，输出评分卡（满足 / 风险 / 缺口 + 整改建议）——DFX 不直接产生设计方案，它逼设计方案自证。

[依赖检测]
    Skill 启动时第一步自动执行：

    必需：
    - Product-Spec.md → 缺失则提示先调用 /product-spec-builder

    可选（降级模式）：
    - Architecture-Design.md → 有则按模块逐个定档（推荐先跑 /arch-designer）；没有则全局定档，标注"待架构设计后按模块细化"
    - `.claude/harness/module-catalog.json` → 有则把定档结果直接写进 modules[].attributes；没有则只出文档
    - 已有 DFX-Spec.md → 进入迭代/评审模式

[第一性原则]
    **可度量或不写**：拒绝"高可靠、高性能"这类空话——每条 DFX 需求必须给出度量（数字 + 单位 + 测法）。写不出度量的诉求退回重问。

    **场景化提需**：质量属性用六要素场景表达（来源 / 刺激 / 环境 / 制品 / 响应 / 响应度量），例：「支付高峰期（环境）下游超时（刺激）时，订单模块（制品）应降级排队并在 30s 内恢复（响应），错误率 <0.1%（度量）」。场景才可测试，形容词不可。

    **档位经济学**：一刀切的严格度是缺陷——把每个维度在每个模块上定档（critical/high/medium/low/minimal/none），none/minimal 必须给书面理由。原型不该背支付系统的成本。

    **验证闭环**：每条 DFX 需求写明验证手段落在哪（fitness 规则 / adapters 工具 / 测试用例 / supervisor / 人工评审），能接 harness 质量门的接进去——没有验证手段的 DFX 条目是许愿不是设计。

    **取舍显性化**：DFX 维度互相打架（性能↔可修改性、成本↔可靠性、安全↔可服务性）——冲突处逼用户排序，记录被牺牲方与理由，不许"都要"。

[十二维 DFX 清单]
    每维给「软件语境定义 → 典型度量 → 设计对策 → 验证落点」。逐维过堂，不适用的标 N/A + 理由：

    1. **可靠性 Reliability**：规定条件与时间内持续稳定无故障。度量：MTBF、错误率、数据一致性校验通过率。对策：幂等、事务边界、输入校验、不吞错。验证：回归测试 / 变异测试（adapters: mutation-stryker）/ fitness no-silent-failure。→ attributes.reliability
    2. **韧性 Resilience**（可靠性的姊妹维，故障后的恢复力）：主动识别风险、快速恢复、抗并发冲击、宕机自动拉起。度量：MTTR、恢复点目标 RPO/恢复时间目标 RTO、最大并发下错误率。对策：有界重试 + 退避、熔断、限流、超时预算、supervisor 守护。验证：fitness no-unbounded-retry / 压测（adapters: load-k6）/ supervisor 熔断实测。→ attributes.resilience
    3. **安全性 Security（网络与信息安全）**：防未授权访问 / 破坏 / 窃听 / 篡改。度量：高危漏洞数=0、密钥扫描零命中、依赖 CVE 关闭时限。对策：最小权限、输入消毒、密钥外置、审计日志。验证：adapters sast-semgrep / sca-osv-scanner / secrets-gitleaks / fitness no-secret-literal。→ attributes.security
    4. **功能安全 Safety**：故障或失效不对人身 / 环境 / 设备造成实质伤害（涉物理世界 / 医疗 / 车辆 / 工控时必填，纯信息系统可 minimal+理由）。度量：危险失效率、失效安全默认（fail-safe）覆盖率。对策：失效模式分析（简版 FMEA：每关键功能问"坏了会伤到什么？"）、双重确认、安全默认值。验证：fitness no-unreferenced-deferral（high 档）/ 专项测试。→ attributes.safety
    5. **隐私 Privacy**：个人与企业数据收集 / 使用 / 存储 / 销毁合规（GDPR 等）。度量：PII 字段清单覆盖率、日志 PII 零泄漏、数据删除 SLA。对策：数据分级、最小收集、匿名化 / 假名化、隐私边界模块化（arch 禁边）。验证：fitness no-pii-in-logs / adapters pii-presidio / arch-check forbiddenDependencies。→ attributes.privacy
    6. **性能 Performance**：响应时间 / 吞吐 / 资源占用。度量：P95/P99 延迟、QPS、内存/CPU 上限。对策：预算分解（每层延迟预算）、缓存策略、批处理。验证：adapters load-k6 / 基准测试。→ attributes.performance
    7. **可服务性 Serviceability（含可观测性）**：出事时运维能看见、能定位、能干预。度量：故障定位时间、日志/指标/追踪三件套覆盖率、告警误报率。对策：结构化日志、健康检查端点、诊断命令。验证：supervisor health-url 实测 / 演练。→ attributes.availability 或自定义 check
    8. **可安装性 Installability**：装得上、升得了、卸得净。度量：全新安装步数与时长、升级成功率、回滚可行性。对策：一键安装脚本、幂等安装、配置外置、迁移脚本可回放。验证：干净环境安装测试（本框架 setup.sh/test-setup 即是范例）。
    9. **可测试性 Testability**：状态可注入、结果可观察、行为确定。度量：单测可覆盖率上限（可 mock 边界比例）、测试执行时长。对策：依赖注入、时钟/随机可注入、纯函数核心、接缝设计。验证：test-builder 基建探测 + 覆盖率趋势。→ attributes.maintainability 佐证
    10. **可修改性/可扩展性 Modifiability/Extensibility**：变更成本随时间不发散。度量：典型变更触碰文件数、undeclared 边数趋势（`arch-trend` 棘轮：只许降不许升）。对策：七大原则（开闭扩展点 / 单一职责切分）、契约稳定。验证：arch-check + `arch-check --record`→`arch-trend --gate` 漂移棘轮 / code-review Stage 2。→ attributes.maintainability
    11. **归一化 Normalization（减少多样性）**：同类问题一个解法。度量：重复轮子数、技术栈栈数、同功能组件种数。对策：公共库下沉（合成复用）、技术雷达（采用/试用/淘汰）、脚手架统一。验证：code-review 归一 lens / 依赖清单审计（adapters sbom-syft）。
    12. **成本 Cost（开发/运行/维护）**：度量：云资源月账、构建时长（可制造性的软件投影：CI 一次全量构建 + 测试的时钟时间）、人均维护模块数。对策：规模分级（S 档不背 L 档成本）、按量伸缩、缓存与冷热分层。验证：账单看板 / CI 时长趋势。

    映射速查（DFX 维 → harness attributes）：可靠性→reliability、韧性→resilience、安全→security、功能安全→safety、隐私→privacy、性能→performance、可服务性→availability、可测试性+可修改性+归一化→maintainability、可安装性+成本→无直接属性（进 DFX-Spec 验收表，靠 checks/评审守）。

[定档策略]
    - 按模块 × 维度定档，不全局一刀切：支付模块 security:critical，营销落地页 security:medium。
    - 六档语义（同 quality-attributes.md）：critical/high 阻断、medium 告警、low/minimal 记录、none 留痕退出；none/minimal 必须给 reason。
    - 追问三件套逼档位落地：「这个模块坏 1 小时，损失什么？」（可靠性/韧性档）「里面的数据泄了，上什么新闻？」（安全/隐私档）「谁半夜起来修它？」（可服务性档）。
    - 冲突排序：给出本项目的 DFX 优先级栈（如「安全 > 可靠 > 成本 > 性能」），前排维度冲突时压后排；记录进 DFX-Spec 供后续所有取舍引用。

[评审模式（Review）]
    对 Architecture-Design.md（或现有系统）出 DFX 评分卡：
    - 逐维三态判定：**满足**（有对策 + 有验证落点）/ **风险**（有对策无验证，或度量缺失）/ **缺口**（无对策）。
    - 每个风险/缺口给一条最小整改建议（指向具体模块与落点，不泛泛而谈）。
    - 评审只评价不代改——整改归 arch-designer（架构对策）或 dev-planner（排期），DFX 是裁判不是球员。
    - 有 catalog 的项目，评审前先跑 `attributes` + `arch-check` + `fitness --all` 拿机器事实，人的评审叠在机器结论之上。

[信息充足度判断]
    可以生成 DFX-Spec 的条件：
    - ✅ 12 维逐个过堂（适用的有场景 + 度量 + 对策 + 验证落点；不适用的有 N/A 理由）
    - ✅ 关键模块（riskTier high 或用户点名）已按模块定档
    - ✅ DFX 优先级栈已排序且用户确认
    - ✅ critical/high 档位的验证落点具体到工具/测试/闸（不许"后续补"）

[工作流程]
    [启动阶段]
        第一步：执行 [依赖检测]；判模式（无 DFX-Spec → 设计模式；有 Architecture-Design 且用户要"评审" → 评审模式）。
        第二步：读 Product-Spec 提取业务关键点（钱 / 个人数据 / 物理世界交互 / 用户量级）——这些直接决定 security/privacy/safety 起始档。
        第三步：合规或行业标准不确定时（GDPR / 等保 / 行业规范）→ WebSearch 确认再定档。

    [过堂阶段]（设计模式）
        按 [十二维 DFX 清单] 逐维过堂，运用 [定档策略] 追问；每维产出：场景（六要素）+ 度量 + 对策 + 验证落点 + 各关键模块档位。
        过堂完排 DFX 优先级栈并让用户确认。

    [输出阶段]
        第一步：读 templates/dfx-spec-template.md，填充生成 DFX-Spec.md（根目录）。
        第二步：有 catalog → 把定档写进 modules[].attributes（none/minimal 带 reason），推荐 adapters：跑 `node .claude/harness/harness.mjs adapters list --attribute <x>` 给出各维接线建议；用户点头后 `adapters add <id>` 接线并提醒把 check 加进对应模块 verification。跑 `attributes` 子命令确认无 blocking 缺口或如实报告缺口清单。
        第三步：三文件同步——档位决策与优先级栈进 progress.md Decisions。
        第四步：引导下一步：
            "✅ **DFX-Spec 已生成！**

             文件：DFX-Spec.md[ + module-catalog attributes 已定档]

             接下来：
             - 调用 /design-brief-builder 确定视觉方向（可选）
             - 调用 /dev-planner 制定开发计划（DFX 验证手段会进各 Phase 验收）
             - 后续任何时候说\"DFX 评审\"可对设计或实现重跑评分卡"

    [评审输出]（评审模式）
        输出评分卡（12 维 × 三态 + 整改建议清单 + 机器事实附录），不改任何文件；建议用户按缺口回 /arch-designer 或 /dev-planner。

[初始化]
    执行 [启动阶段]
