本文件由 CLAUDE.md 下沉；主控命中指针时必须完整读取本文件再行动，不得凭指针行猜测内容。

[启用条件（铁律：唯一开关）]
    唯一开关 = `.claude/harness/module-catalog.json` 存在。存在即启用全部大仓能力；不存在即默认关闭、所有 hook 静默走原逻辑（零行为变化）。
    - node 不可用同样静默降级（hook 通过 `lib-harness.sh|.ps1` 的 `harness_node_ok` 守卫跳过，非假绿、非 crash）。
    - doctor 判启用态：`node harness.mjs doctor` 输出 JSON 看 `catalogPresent` 字段（false=未启用）；`bash doctor.sh` 的人读输出报「module-catalog.json 未配置（大仓治理默认关闭，接线走原逻辑）」同义（前者机器读、后者人读，同一事实两副面孔）。
    - 启用 = 放一份合规 catalog 文件；关闭 = 删该文件。不动 settings.json、不动任何 hook。
    - 小项目 / 框架本体零负担——未启用时对项目完全透明。
    - fitness / adapters 两个子命令允许无 catalog 直接跑（fitness 无 catalog 时只失去模块分级，规则本身照扫；adapters list 只是查表）；其余定向能力（impact / verify / arch-check / attributes）无 catalog 一律 rc 3 降级。

[规模目标（60 万行级）]
    面向 60 万行以上代码规模的仓库：分类热路径走编译后 glob 正则缓存（同一 glob 只编译一次）；git 路径清单一律 NUL 分隔 + quotePath=false（中文/非 ASCII 文件名不被转义破坏）；tracked 清单有 `maxTrackedPaths` 上限（默认 10 万，catalog 可覆盖），**截断按坏测量处理**——catalog-lint 显式 warning、impact 保守全 fanout + degraded，绝不静默少测。selftest 内置规模冒烟（120 模块 × 3 万路径分类 <2.5s）。

[module-catalog.json schema]
    Catalog 顶层：`version`（必填）/ `modules`（必填，数组）/ `global[]`（变更即全模块 fanout 的路径，如 package.json / tsconfig.json）/ `ignored[]`（impact 排除路径，如 README / docs）/ `riskChecks{low,medium,high:[checkId]}` / `checks{id:{command,class?,allowFastSkip?,attributes?}}` / `contextPack`（预算覆盖）/ `layers[]`（架构分层名，最外层在前，依赖只许指向同层或更靠后的内层）/ `maxTrackedPaths`（tracked 清单上限）。
    Module：`id`（必填唯一）/ `paths[]`（必填 glob）/ `dependsOn[]` / `owners[]` / `riskTier`（low|medium|high）/ `verification[]`（声明即覆盖 riskChecks 默认）/ `attributes{属性:档位}`（五性证据要求，见 .claude/rules/quality-attributes.md）/ `forbiddenDependencies[]`（永远不许 import 的模块——隐私/安全边界可执行化）/ `layer`（本模块所在分层）/ `provides[]`（裸 import 说明符前缀，如 `@acme/db`，arch-check 用它归属包名 import）。
    路径分类优先级：**module > ignored > global > unmapped**；多模块命中按 specificity（glob 字面字符数）最高者赢。

    catalog-lint 全量归类要求（每条 tracked path 必须有归处）：
    - `CATCH_ALL`（错）：模块 paths 含 `''` `'.'` `'*'` `'**'` `'**/*'`——吞整树、掩盖漏项
    - `UNMAPPED`（错）：tracked path 未被任何 module/global/ignored 声明
    - `OVERLAP`（错）：同一路径被 >1 个 module 声明
    - `DANGLING_DEP`（错）：dependsOn / forbiddenDependencies 指向不存在的 module id
    - `UNKNOWN_ATTRIBUTE` / `UNKNOWN_TIER`（错）：attributes 声明了未知属性或未知档位
    - `UNJUSTIFIED_TIER`（错）：档位设 none|minimal 却不给 reason——退出治理必须是留痕决策，不是零成本默认
    - `SELF_FORBIDDEN`（错）：forbiddenDependencies 指向自己
    - `FORBIDDEN_DECLARED`（错）：同一条边既 dependsOn 又 forbidden——矛盾声明，禁令是更强陈述
    - `UNKNOWN_LAYER`（错）：module.layer 不在 catalog.layers 里
    - `CYCLE`（warning，不阻断）：dependsOn 图含环
    - `TRUNCATED`（warning）：tracked 清单触顶截断，覆盖面不完整

    **保守扩张铁律**：unmapped 命中 / global 命中 / 非 git / truncated → 全模块 fanout + `degraded:true`（宁可全跑，不可漏测）。

[十五能力清单]
    载体 `node .claude/harness/harness.mjs <subcommand>`，stdout 单行 JSON、stderr 人读诊断。
    - **doctor**：环境自检（node 版本 / catalogPresent / gitRepo / headCommit / subcommands / waivers / attributesDeclared / modulesWithLayer / forbiddenEdges / adaptersPresent）。**始终 rc 0**。注意：harness 子命令 `doctor`（JSON 输出）与框架脚本 `.claude/scripts/doctor.sh`（人读结论）两物同名——后者独立做文件存在性判断、**不调用本子命令**（见启用条件段）。
    - **diff-hash**：当前工作树 canonical diff 的 SHA256（含 untracked 内容 hash；排除 .needs-review / .fast-mode / evidence / receipts / waivers 等运行态）。
    - **selftest**：内置回归断言（glob / catalog 分类 / impact 闭包 / context-pack 预算 / receipt 防篡改 / 四态门 / waiver 规则 / 五性判定 / arch 纯函数 / fitness 规则 / 规模冒烟）。失败 rc 1。
    - **catalog-lint**：按 schema 校验 catalog。无参 = 对当前仓 `git ls-files` 全量归类（NUL 分隔 + 截断警告）。
    - **impact**：反向依赖闭包——传变更路径，返 `affected`（直接 + 反向闭包）/ `direct` / `expansionReasons` / `verification`（每模块绑的 check）/ `degraded`。
    - **context-pack**：预算化打包——P1 任务信封 + Spec/Plan 指针 → P2 canonical diff（截断 maxDiffChars）→ P3 变更文件（每个截断 maxFileChars）→ P4-6 受影响模块 verification 路径串。DENY 路径永不入包（.git / node_modules / dist / build / .next / .venv / .env / *.pem|key|p12|pfx / id_rsa / .ssh|.aws|.azure|.gnupg|.kube / .claude/evidence|receipts|waivers 等；白名单 `.env.example|.sample|.template` 可入包）。产出 `packHash`（仅含 path+bytes 清单 + budgets + diffHash，对空白变动稳定）。
    - **receipt write|verify**：diff-bound 审查回执。`write` 从 stdin 读 JSON 写 `.claude/harness/receipts/<taskId>.json`；`verify` 比对当前 diff 与回执绑定 diffHash。
    - **verify**：质量门——对受影响模块跑各自 verification、四态聚合、应用 waiver，**并对受影响模块做五性覆盖判定**（`attributes` + `attributeGaps` + `gate` 字段；critical/high 属性缺证据 = 门不过，见 quality-attributes.md）。
    - **waiver list|check|create**：结构化豁免管理。
    - **attributes**：五性静态接线审计（不执行命令）——每模块声明的属性 × 档位 × 已接线的 claiming checks；blocking 档位（critical/high）声明了却无 check 认领 = 可见缺口 rc 1。
    - **arch-check**：真实 import 边 vs 声明依赖图——多语言 import 提取（JS/TS/Python/Go/Java/Kotlin/C#/Rust/Ruby/PHP/Swift/Scala），报 `forbiddenDependencies`（越禁边，含 layer 违规）/ `undeclaredDependencies`（漂移：代码有边、catalog 没声明——会让 impact 少算漏测）/ `unusedDeclarations`（虚边：声明了没人 import，过度扩测且边界已不真实）/ `cycles` / 未行使图诚实说明。声明与禁令冲突时**禁令赢**。`--record` 把漂移指标快照进趋势台账（失败也照记——存量债先立基线）。
    - **fitness**：内置零依赖五性规则扫描（凭 `.claude/rules/quality-attributes.md` 细则）——密钥字面量(security) / 日志含个人数据(privacy) / 静默吞错(reliability) / 无界重试(resilience) / 高危模块未挂单的 TODO(safety，minimumTier=high)。默认扫变更文件，`--all` 扫全 tracked，`--paths a,b` 显式指定；`harness-fitness:ignore` 行内压制单条；`.claude/harness/fitness-rules.json` 可增补/替换规则集。error 级命中 rc 1。
    - **adapters list|add**：外部工具表（semgrep / osv-scanner / trivy / gitleaks / syft / presidio / stryker / schemathesis / k6 / checkov / oslo，各自映射到五性属性）。`list` 报 available（PATH 上有没有）+ wired（catalog.checks 接没接）；`add <id>` 把 check 写进 catalog.checks——接线只是半步，模块 verification 列表引用它才会被选中。
    - **adr-check**：ADR 执法校验——没人盯的架构决策必然漂移。扫 `Architecture-Design.md` 的 `### ADR-xxx` 内联块 + `docs/adr/*.md` 独立文件（均可选，`--file`/`--dir` 可改），每条**活跃** ADR 的「执法方式/Enforced-by」必须能解析出至少一个真实存在的执法点：catalog check id / fitness 规则 id / harness 能力名（arch-check / layers / forbiddenDependencies / fitness / verify / receipt…）/ 或显式人工标记（评审/人工/manual/review——诚实的"人守"放行但单列 `manualOnly`）。**幽灵引用比没有更糟**（读起来像被执法实际没有）：零可识别 token = fail；已废弃（superseded/deprecated/rejected/已废弃…）豁免；认识的 token 旁边搭车的未知词只上报 `unrecognized` 不拦。
    - **arch-trend**：架构漂移棘轮——arch-check 对任何 undeclared 边都 rc 1，存量带债的老仓根本用不成闸。台账给出接入路径：`arch-check --record` 快照漂移指标（undeclared / forbidden / cycles + 上下文量），`arch-trend` 看趋势报告（基线/历史最优/最新/较上次 delta），`arch-trend --gate` 只在**最新值超过历史最优**时 rc 1——棘轮只朝一个方向转：旧债可以慢慢还，新债一分不许添。unresolved/unused 是上下文量不进棘轮。首条记录只立基线不比较。

    预算默认值（catalog.contextPack 可覆盖）：maxTotalChars=120000 / maxFiles=40 / maxFileChars=6000 / maxDiffChars=40000。

[退出码契约（源码确认）]
    | 子命令 | 0 | 1 | 2 | 3 | 4 |
    |---|---|---|---|---|---|
    | doctor / diff-hash | 总是 | — | — | — | — |
    | selftest | 全过 | 有失败 | — | — | — |
    | catalog-lint | 无错 | 有错 | — | catalog 缺失 | — |
    | impact | 正常 | — | — | 无 catalog / 非 git | — |
    | context-pack | 正常 | — | — | 非 git | — |
    | receipt write | 写入成功 | — | — | 参数错 / 子命令错 | — |
    | receipt verify | PASS | — | — | 非 git | STALE |
    | verify | PASS / 全 SKIPPED 且无属性缺口 | — | FAIL / BLOCKED / 属性缺口 | 无 catalog / 非 git | — |
    | waiver list | 总是 | — | — | — | — |
    | waiver check | valid | invalid | — | — | — |
    | waiver create | 写入成功 | 校验失败 | — | 子命令错 | — |
    | attributes | 无未接线 blocking 属性 | 有 blocking 属性未接线 | — | 无 catalog | — |
    | arch-check | 图干净 | 越禁边 / 未声明边 / 环 | — | 无 catalog / 非 git | — |
    | fitness | 无 error 级命中 | 有 error 级命中 | — | --all 且非 git | — |
    | adapters | list / add 成功 | add 未知 id | — | add 无 catalog / 子命令错 | — |
    | adr-check | 全部活跃 ADR 有真实执法（或无 ADR） | 有 ADR 缺执法 / 纯幽灵引用 | — | — | — |
    | arch-trend | 报告态总是；--gate 无回退 | --gate 有指标超历史最优 | — | — | — |
    | unknown / missing | — | — | — | 总是 | — |

    要点：
    - `verify` FAIL/BLOCKED **或 critical/high 属性缺证据** = rc 2（commit 闸阻断）；无 catalog 或非 git = rc 3（降级，不阻断也不假绿）。输出里 `gate` 字段三态：PASS / FAIL|BLOCKED（check 层）/ BLOCKED_BY_ATTRIBUTES（属性层）。
    - `receipt verify` STALE = rc 4（stop-gate 拦停强制重审）；非 git = rc 3（降级）。
    - 缺命令 / 二进制找不到 = `verify` 内部 BLOCKED（reason: `command-missing:<exe>`），**绝不假绿**。

[接线点（hook 侧，catalog + node 双满足才启用，否则静默走原逻辑）]
    守卫库 `.claude/hooks/lib-harness.sh|.ps1` 提供 `harness_enabled`（catalog 存在）/ `harness_node_ok`（node 可用）/ `harness_run`（跑子命令）。两处接线，**不新增 hook 事件**：
    - **stop-gate ↔ receipt verify**：`.needs-review` 清单清空（口头释放）后再校验当前 diff 是否有已通过回执绑定。rc=4（STALE）= 代码越过所有已审回执 → 拦停强制重审、保留 `.needs-review` 让下轮仍拦；rc=0/3 照原逻辑清理放行。位置：`stop-gate.sh:32-50` / `stop-gate.ps1` 对应段。
    - **pre-commit-check ↔ verify**：staged 就绪后、commit 之前跑定向质量门。rc=2（受影响模块 FAIL/BLOCKED **或属性缺证据**）= 阻断 commit；rc=3（无 catalog / 非 git）静默跳过；rc=0 放行。位置：`pre-commit-check.sh:61-74` / `.ps1` 对应段。
    - arch-check / fitness / attributes 不走 hook 自动触发（成本考量），推荐进 catalog checks 由 verify 定向带跑（如 `"arch": {"command": "node .claude/harness/harness.mjs arch-check", "class": "static"}`），或 code-review Stage 0 / 发版前手动跑。

[与 per-Task review→fix 闭环的关系]
    diff-bound 回执把「`.needs-review` 空 marker + `echo clean`」从口头承诺升级为机器可验证事实：当前工作树 diff 的 SHA256 必须等于某条已通过回执绑定的 diffHash。
    - 任何 diff 字节变动（哪怕一个换行）→ 旧回执自动 stale → stop-gate 拦停、强制重审重写回执。
    - `contentHash` 防 JSON 字段被改（reviewer / verdict / scope / timestamp 等任一字段变动 → hash 不匹配 → 回执作废）。
    - `taskId` 限定 `[A-Za-z0-9._-]`，路径穿越 / 分隔符被替换（safeTaskId）。
    - 回执落 `.claude/harness/receipts/`（git 忽略的运行态）。

[四态质量门（verify 细则）]
    verification 解析优先级：`module.verification` > `catalog.riskChecks[module.riskTier]`。
    单 check 四态：
    - `PASS`：命令 exit 0
    - `FAIL`：命令 exit ≠ 0
    - `BLOCKED`：缺 command 定义 / 二进制找不到（**不假绿**）
    - `SKIPPED`：Fast Mode + 非 security/safety + check 声明 `allowFastSkip:true`
    聚合：任一 FAIL → FAIL；任一 BLOCKED → BLOCKED；否则 PASS（SKIPPED 不阻断）。
    check 聚合之上再叠五性覆盖门：受影响模块声明的 critical/high 属性若无 PASS 的 claiming check（或有 claiming check FAIL/BLOCKED 反证），`gate=BLOCKED_BY_ATTRIBUTES`、rc 2——「check 全绿但没有任何检查证明过 security」不再能读作完成。细则见 .claude/rules/quality-attributes.md。

[waiver——结构化 per-check 豁免]
    schema（`.claude/harness/waivers/*.json`，git 忽略）：`version:1` / `owner` / `reason` / `scope`（= 被豁免 check id，或 `attribute:<module>/<属性>` 豁免一条 high 档属性缺口）/ `expiry`（ISO，必须未来）/ `compensation` / `created_at` / `contentHash`（create 时写入防篡改）。
    命中规则：FAIL 或 BLOCKED + **非 security/safety 类** + scope == check id → 降级 SKIPPED（reason: `waiver:<scope>`）。
    **security / safety 类永不可豁免**——class:security|safety 的 check 即使有匹配 waiver 仍保留 FAIL/BLOCKED。
    属性豁免：scope 写 `attribute:<module>/<属性>` 只能推迟 **high** 档缺口（critical 永不可豁免）；且禁词校验天然使 `attribute:x/security`、`attribute:x/safety` 不可表示——安全与功能安全的属性缺口没有豁免通道。
    禁词（reason + scope 联合正则，命中即 create/validate 拒绝）：`safety|security|secret|credential|destructive|push|deploy|production`。
    与 Fast Mode 关系：**Fast Mode = 非 security/safety + allowFastSkip 的提前 SKIP 路径；waiver = FAIL/BLOCKED 事后降级**。两者正交，不互相替代。

[运行态文件]
    - `.claude/harness/module-catalog.json`：唯一开关，**本体照常分发**（catalog 仓库可选择性提交共享配置；不提交即每工作树独立）。
    - `.claude/harness/adapters.json`：外部工具表，本体照常分发（项目可自行增删条目）。
    - `.claude/harness/fitness-rules.json`：可选项目自定义 fitness 规则（`{"replace":false,"rules":[...]}`），有则并入内置规则。
    - `.claude/harness/receipts/*.json`：审查回执，**git 忽略**（永不入库）。
    - `.claude/harness/waivers/*.json`：结构化豁免，**git 忽略**（永不入库）。
    - `.claude/harness/trend/arch-trend.jsonl`：漂移趋势台账（`arch-check --record` 追加，超 1000 行自动保留最近 500），**默认 git 忽略**（每机各持；团队要共享趋势可自行取消忽略）；不进 diff 指纹、不进 context-pack。
    - `.claude/.runtime/supervisor/`：supervisor 进程守护运行态（state/pid/service 日志），**git 忽略**（见 dev-workflow-details 的本地运行阶段与 README「进程守护」）。
    - `.claude/.needs-review` / `.fast-mode` / `.stop-gate-strikes`：原框架运行态（harness 复用，git 忽略）。

[典型工作流]
    1. 启用：在 `.claude/harness/` 写一份合规 `module-catalog.json`（参照 `.claude/tests/fixtures/harness/catalog-good.json`；五性声明参照 quality-attributes.md 示例）→ `node .claude/harness/harness.mjs catalog-lint` 验过。
    2. 接线五性：给关键模块声明 `attributes`（如支付模块 security:critical）→ `attributes` 子命令看接线缺口 → `adapters list --attribute security` 挑工具 → `adapters add <id>` 接线 → 模块 verification 引用该 check。
    3. 开发：正常 per-Task 编码 → review → fix 闭环（hook 自动接线，无需手工调用）。
    4. 诊断：`doctor` 看启用态、`impact` 看变更影响面、`context-pack` 看 LLM 上下文预算分配、`arch-check` 看依赖漂移与越禁边、`fitness` 扫变更文件的五性反模式。
    5. 审查：code-reviewer 通过后用 `receipt write` 写回执（stdin JSON：taskId / reviewer / verdict / scope 四字段，命令签名见能力清单 receipt 条）。
    6. 验收：`receipt verify` 确认 diff 绑定、`verify` 确认定向质量门 + 五性覆盖通过。
    7. 防漂移日常：arch-designer 产出的 ADR 用 `adr-check` 盯执法引用（Architecture-Design.md 改动后、发版前跑）；接入老仓先 `arch-check --record` 立债务基线，此后周期性（Phase 收尾 / 发版前）`--record` + `arch-trend --gate`——旧债不挡路，新债零容忍。
