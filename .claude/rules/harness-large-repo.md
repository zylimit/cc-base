---
paths:
  - ".claude/harness/**"
---

本文件由 CLAUDE.md 下沉；主控命中指针时必须完整读取本文件再行动，不得凭指针行猜测内容。（frontmatter 的 paths 让 Claude Code 原生按需加载本规则——碰 .claude/harness/ 下文件时自动进上下文；未碰时靠 CLAUDE.md 指针手动读，两条路都通。）

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

[三十九能力清单]
    载体 `node .claude/harness/harness.mjs <subcommand>`，stdout 单行 JSON、stderr 人读诊断。入口仍是这一个文件，实现已按分节拆进 `.claude/harness/lib/`（core 底层 / catalog / graph=impact+arch-check+arch-trend / quality=receipt+verify+waiver+attributes / scan=fitness+adapters+adr-check / context / evidence=gate+ledger+gate-audit+retention+risk / task=task+budget / spec=spec-lint+trace+spec+dod / review=review+review-pack+authorship / memory=invariants+recap+archive+sync-check / rules=rules-audit+skills-lint+claude-md-lint / init / release / selftest），**harness.mjs 不再能单文件搬走**——只拷它不拷 lib/ 会 ERR_MODULE_NOT_FOUND 起不来。子命令名、JSON 字段、退出码不受拆库影响。**输出里的仓库路径一律正斜杠、一律仓库相对**（Windows 上也一样，平台分隔符与机器目录都不外泄）——stdout 是给 hook / git hook / CI 读的机器契约，同一个仓在两个平台给出两种路径形态，等于让每个消费者各自兜一遍；绝对路径更是把开发者的目录结构写进了输出，下游拿它做不了稳定比对。唯一的例外是调用方自己用 `--file` 传进来的绝对路径被原样回显，那是入参不是引擎拼的路径。
    - **doctor**：环境自检（node 版本 / catalogPresent / gitRepo / headCommit / subcommands / waivers / attributesDeclared / modulesWithLayer / forbiddenEdges / adaptersPresent）。**始终 rc 0**。注意：harness 子命令 `doctor`（JSON 输出）与框架脚本 `.claude/scripts/doctor.sh`（人读结论）两物同名——后者独立做文件存在性判断、**不调用本子命令**（见启用条件段）。
    - **diff-hash**：当前工作树 canonical diff 的 SHA256（含 untracked 内容 hash；排除 .needs-review / .fast-mode / evidence / receipts / waivers 等运行态）。
    - **selftest**：内置回归断言（glob / catalog 分类 / impact 闭包 / context-pack 预算 / receipt 防篡改 / 四态门 / waiver 规则 / 五性判定 / arch 纯函数 / fitness 规则 / 评审分阶段与裁决 / 作者集判定 / 规模冒烟）。失败 rc 1。
    - **catalog-lint**：按 schema 校验 catalog。无参 = 对当前仓 `git ls-files` 全量归类（NUL 分隔 + 截断警告）。
    - **impact**：反向依赖闭包——传变更路径，返 `affected`（直接 + 反向闭包）/ `direct` / `expansionReasons` / `verification`（每模块绑的 check）/ `degraded`。
    - **context-pack**：预算化打包——P1 任务信封 + Spec/Plan 指针 → P2 canonical diff（截断 maxDiffChars）→ P3 变更文件（每个截断 maxFileChars）→ P4-6 受影响模块 verification 路径串。DENY 路径永不入包（.git / node_modules / dist / build / .next / .venv / .env / *.pem|key|p12|pfx / id_rsa / .ssh|.aws|.azure|.gnupg|.kube / .claude/evidence|receipts|waivers 等；白名单 `.env.example|.sample|.template` 可入包）。产出 `packHash`（仅含 path+bytes 清单 + budgets + diffHash，对空白变动稳定）。
    - **receipt write|verify**：diff-bound 审查回执。`write` 从 stdin 读 JSON 写 `.claude/harness/receipts/<taskId>.json`；`verify` 比对当前 diff 与回执绑定 diffHash。
    - **verify**：质量门——对受影响模块跑各自 verification、四态聚合、应用 waiver，**并对受影响模块做五性覆盖判定**（`attributes` + `attributeGaps` + `gate` 字段；critical/high 属性缺证据 = 门不过，见 quality-attributes.md）。
    - **waiver list|check|create**：结构化豁免管理。
    - **attributes**：五性静态接线审计（不执行命令）——每模块声明的属性 × 档位 × 已接线的 claiming checks；blocking 档位（critical/high）声明了却无 check 认领 = 可见缺口 rc 1。
    - **arch-check**：真实 import 边 vs 声明依赖图——多语言 import 提取（JS/TS/Python/Go/Java/Kotlin/C#/Rust/Ruby/PHP/Swift/Scala），报 `forbiddenDependencies`（越禁边，含 layer 违规）/ `undeclaredDependencies`（漂移：代码有边、catalog 没声明——会让 impact 少算漏测）/ `unusedDeclarations`（虚边：声明了没人 import，过度扩测且边界已不真实）/ `cycles` / 未行使图诚实说明。声明与禁令冲突时**禁令赢**。`--record` 把漂移指标**连同每条边的身份**快照进趋势台账（`undeclaredEdges` / `forbiddenEdges` / `cycleKeys`，失败也照记——存量债先立基线）。
    - **fitness**：内置零依赖五性规则扫描（凭 `.claude/rules/quality-attributes.md` 细则）——密钥字面量(security) / 日志含个人数据(privacy) / 静默吞错(reliability) / 无界重试(resilience) / 高危模块未挂单的 TODO(safety，minimumTier=high)。默认扫变更文件，`--all` 扫全 tracked，`--paths a,b` 显式指定；`harness-fitness:ignore` 行内压制单条；`.claude/harness/fitness-rules.json` 可增补/替换规则集。error 级命中 rc 1。
    - **adapters list|add**：外部工具表（semgrep / osv-scanner / trivy / gitleaks / syft / presidio / stryker / schemathesis / k6 / checkov / oslo，各自映射到五性属性）。`list` 报 available（PATH 上有没有）+ wired（catalog.checks 接没接）；`add <id>` 把 check 写进 catalog.checks——接线只是半步，模块 verification 列表引用它才会被选中。
    - **adr-check**：ADR 执法校验——没人盯的架构决策必然漂移。扫 `Architecture-Design.md` 的 `### ADR-xxx` 内联块 + `docs/adr/*.md` 独立文件（均可选，`--file`/`--dir` 可改），每条**活跃** ADR 的「执法方式/Enforced-by」必须能解析出至少一个真实存在的执法点：catalog check id / fitness 规则 id / harness 能力名（arch-check / layers / forbiddenDependencies / fitness / verify / receipt…）/ 或显式人工标记（评审/人工/manual/review——诚实的"人守"放行但单列 `manualOnly`）。**幽灵引用比没有更糟**（读起来像被执法实际没有）：零可识别 token = fail；已废弃（superseded/deprecated/rejected/已废弃…）豁免；认识的 token 旁边搭车的未知词只上报 `unrecognized` 不拦。
    - **arch-trend**：架构漂移棘轮——arch-check 对任何 undeclared 边都 rc 1，存量带债的老仓根本用不成闸。台账给出接入路径：`arch-check --record` 快照漂移指标与边身份，`arch-trend` 看趋势报告（基线/历史最优/最新/较上次 delta），`arch-trend --gate` 判回退时 rc 1——棘轮只朝一个方向转：旧债可以慢慢还，新债一分不许添。unresolved/unused 是上下文量不进棘轮。首条记录只立基线不比较。
      · **per-edge 基线**：棘轮比的是**边的身份集合**，不是计数——计数制有个真漏洞，还掉一条旧债同时添一条新债计数不变即过，新债借旧债的额度混进来。历史最优的 per-edge 形态是各先验快照的**交集**：某条边在任一历史快照里缺席过，就是还清过，再回来和从没见过的新边一样算新债。回退时 `regressed[].newEdges` **点名是哪条边**，`basis` 记这条判决出自 `count` 还是 `edges`。旧债减少照样记 improved。
      · **count 棘轮保留作兜底**：老台账记录只有 count 没有边身份（本能力上线前写的），这类先验**不当成空集**——当空集会让当前所有边都算新债，一次误报就够让人把闸关掉。做法是该记录标 count-only、不参与交集，per-edge 对该指标降级为计数比较并在 `notes` / `edgeBasis` 里写明降级；两套判据同时跑，取更严的那个。
      · **forbidden 不进棘轮，零容忍**：任何快照 `forbidden > 0` → `--gate` rc 1，不比历史、不看基线，`forbiddenViolation` 点名边与理由。forbiddenDependencies 是 catalog 里**显式声明**的安全/隐私边界（analytics 永不许 import pii-store），不存在「第一天记基线时已有 2 条、此后 ≤2 就过闸」这种旧债慢慢还——那与「声明与禁令冲突时禁令赢」自相矛盾。undeclared / cycles 才是真能慢慢还的漂移债。报告态（无 `--gate`）照旧只报不判。
    - **cochange**：共同变更频率反查边界——`arch-check` 看的是 import 边，可**耦合不必经 import 存在**（共享一份隐式契约、同一个数据格式、同一份配置），那一半它照不到。本命令扫 git 历史统计**模块对**的共变次数：两个模块总是一起改、而 catalog 里双向都没有 `dependsOn` 解释这件事 → 进 `undeclaredCoupling`——代码用行为说它们是一体的，边界图说它们无关，两者必有一个错。**默认只报不判，`--gate` 才 rc 1**（同 arch-trend 的取法）：共变高常有正当理由（一个 API 和它唯一的客户端、一份 schema 和它的迁移），启发式判据默认做成硬闸，第一周就被整条关掉，此后没人再看。三个旋钮各有理由：`--max-commits`（默认 500）限扫描深度，触顶报 `truncated` 当坏测量说明覆盖不全；`--max-files-per-commit`（默认 30，与 `budget` 的 `maxChangedFiles` 同一个数同一个理由）以上的 commit **跳过并计数**——批量格式化、大重命名、初始导入会让所有模块对一次全变成「共变」，是这里最大的单一噪声源；`--min-support`（默认 5）以下不报，五次独立 commit 才算习惯，低于此一次重构分散成两三个 commit 就足以点名任何一对，而满是巧合的报告没人读得完。每对同时给 `cochangeCount` 与 `commitsScanned` 让人自己判断显著性，**不给合成的「耦合度」分数**——不可复核的单一指标会被当成真理。模块粒度：文件对是几千行没人判断得了的东西，所以无 catalog 一律 rc 3。
    - **gate**：`verify` 的带证据版——同一套 verifyPlan（四态聚合 + waiver + 五性属性门，不是另写一份），额外把每条执行过的 check 的 stdout+stderr 落 `.claude/harness/evidence/<check>-<epoch>.log` 并记 `evidence` 路径 + `evidenceSha256`（LF 归一后算），算 `planHash`（已解析的 check-id/模块计划的 sha256），整条 gate 记录追加进账本，并记 `scopeSource`（`computed`=引擎自己算的变更面 / `caller`=调用方用 `--changed` 指定）+ `scopeRequested`，每条 check 记 `suppressed`（waiver 压下来的记原判决 `from`，Fast Mode 跳过的没有原判决可记）。退出码与 `verify` 同契约，多一条：PASS 但账本追加失败 = rc 3（没记下来的验证不是证据，不许读成绿），FAIL 仍 rc 2。**没跑的 check 不写证据文件**（BLOCKED/SKIPPED 写空日志会和「跑了但没输出」混成一回事）。`verify` 本身一字不动——三对 hook 在消费它。**`--changed` 仍可用**（只想验某个子集是正当用法），但这种记录关不掉任务——见 task complete。
    - **ledger**：哈希链账本，防证据被静默改写。`contentHash=sha256(LF(JSON.stringify(record)))` / `chain=sha256(prev+NUL+contentHash)` / `prev`=上一行 chain（首行 64 个 0），落 `.claude/harness/state/ledger.jsonl`，append-only。子命令重算整条链，逐条报断裂：`unparseable-line` / `content-hash-mismatch` / `chain-predecessor-mismatch` / `chain-hash-mismatch`（行号 1 起），任一断裂 rc 1。**同时重算证据摘要**：账本引用的每个 `evidence` 日志重读一遍比对 `evidenceSha256`，对不上 = `evidence-tampered`、文件没了 = `evidence-missing`，一样 rc 1（写了不读的哈希等于没写）；账本大到重读嫌慢用 `--no-verify-evidence` 关掉——默认开，默认关掉的校验等于没有。**两个方向都 fail-closed**：链断 = 此前全部验证按未证明处理（`task complete` 阻断、`risk` 报 LEDGER_BROKEN）；文件在但读不出来 = rc 3 降级（读不出 ≠ 空账本，更不是链完好）。**没有也不会有「修复账本」的命令**——链本身就是证据，能改成自洽的工具就是伪造工具。链断也不是重跑门能解的（新记录只往断裂后面追加），诊断因此不推荐任何命令：要么人来决定把 `ledger.jsonl` 退役（同时作废它记过的全部证明）再重建，要么去查是谁改的。
    - **gate-audit**：扫账本，列出 catalog 里定义了但**从未 FAIL/BLOCKED 过**的 check（`neverIntervened`）与从未真正跑过的 check（`neverExecuted`）——没拦过任何东西的闸是成本 + 假安全。**被压制的单列 `suppressed[]`**（check / 次数 / 压制方 / 被压掉的原判决）：waiver 洗成 SKIPPED 的失败按原判决记账（算跑过、算拦过），不许和「从没接线」混进同一个数再一起配文案「genuinely stable」。报告态 rc 0（无 catalog / 账本读不出来 rc 3——没有历史就没有可审的东西，拿空清单去答会答成「每条 check 都没跑过」）。**与 `.claude/scripts/gate-audit.sh` 是两物**：那个审的是 **hook 闸**、读 `.claude/evidence/gate-block.log`；这个审的是 **catalog check**、读 harness 账本。两者不合并、不互相覆盖，合了「哪个闸没响过」就只剩一半答案。
    - **retention**：按龄（`--max-age-days` 默认 30）+ 数量（evidence `--max-evidence` 默认 400、context pack `--max-packs` 默认 60）修剪运行态。**账本引用到的 evidence 文件永不删**——删了新鲜回执就没法验证了。默认 dry-run 只报告，`--apply` 才真删；`--apply` 删不掉时 rc 1（删除失败是失败，不静默）。**先验链再决定删不删**：账本读不出来或链已断裂时两种模式都拒绝清扫（rc 3 + `refused:{reason,detail}`，`protectedByLedger:null`）——保护集算不出来 ≠ 保护集为空，把前者当后者正是这类命令最典型的丢数据方式；dry-run 也拦，因为算错的清单就是下一次 `--apply` 照着删的清单。五性把隐私定义成含「销毁合规」，自家运行态只积不销是自我不一致。
    - **risk**：状态衰变扫描——`LEDGER_BROKEN`（链断）/ `LEDGER_UNREADABLE`（账本在但读不出来）/ `EVIDENCE_TAMPERED` / `EVIDENCE_MISSING`（证据日志被改写 / 没了）/ `EXPIRED_WAIVER`（过期 waiver 仍在）/ `UNWIRED_ATTRIBUTE`（blocking 档属性无 check 认领）/ `FAIL_STREAK`（同一 check 连败 ≥3 → 停止重跑转根因；被 waiver 压成 SKIPPED 的失败照样计数，否则连败一豁免就没人听得见）/ `SUPPRESSED_FAILURE`（waiver 压下去的失败次数，warning——签了字带过期带补偿的决定不该改退出码，但压制是一种状态、不是没事）/ `FAST_MODE_DEBT`（最新一次 gate 在 Fast Mode 下 SKIP 掉的证据尚未由完整 gate 偿还）/ `FAST_MODE_OPEN` / `STALE_TASK`（活跃 task 超 72h）。error 级 finding rc 1，warning 不改退出码。catalog 可无（无则只少 UNWIRED_ATTRIBUTE 一项）。
    - **task start|status|complete**：六字段信封机器校验。`start` 从 stdin 读 JSON——`id` + `goal`/`scope`/`outOfScope`/`existingPattern`/`verification`/`escalation`，缺任一 rc 3 并**点名缺哪个**（不含糊成一句「信封不全」）；`id` 消毒为 `[A-Za-z0-9._-]` 并截到 120 字符；引擎补 `state:"active"`/`baseCommit`/`startedAt` 写 `.claude/harness/state/task.json`，一个工作树一个活跃 task。`status` 返回记录 + 当前 diffHash（始终 rc 0）。**`complete` 是硬闸**：全成立才 rc 0——① 有绑当前 diffHash 的 PASS gate 记录，且这条记录 ①a `scopeSource=computed`（调用方指定范围的 PASS 关不掉任务：`gate --changed <catalog 映射不到的路径>` 能拿到 PASS + `modules:[]`，而旁边的 diffHash 是真工作树指纹——签名是真的，被签的东西是假的）①b `planHash` 等于当前变更面重算出的计划 ①c 至少有一条 check 真跑过（全 SKIPPED 的 PASS 什么都没建立，证据是延后了不是拿到了）② 有绑同一 diffHash 的**新鲜且完整**的 accept 回执（verdict 认 `ACCEPT`/`pass`，被篡改的回执不算）③ 账本链完好 ④ 账本引用的证据日志仍与摘要相符 ⑤ 验证计划非空；否则 rc 2 + `blockers[]` 逐条列出缺哪项。**`complete` 自己也不收 `--changed`**（rc 3）——完成的范围永远不是调用方说了算，否则 ①a 从另一头又被绕开。非 git（rc 3 降级，同 `gate`/`verify`/`receipt verify`：`gitFingerprint()` 在任何非 git 树都是同一个常量，「绑定到这个 diff」对哪棵树都成立）、账本读不出来（rc 3）同样不给结论。
    - **budget**：爆炸半径信号——`maxChangedFiles`/`maxChangedLines`/`maxModulesTouched`/`maxNewFiles`，从 `catalog.budget` 读，缺省 30/1000/5/15（限额写 null 即只报数不判定）。超限 rc 1。**这是「拆分或升级」的信号，不是禁令**：广泛改动有时是对的，这个数只是让人停下想一秒；把它当禁令用，结果一定是整条关掉。
    - **spec-lint**：规格文档可判定性检查，**扫的是本仓 product-spec-builder 实际产出的形状，不是 EARS**。默认读仓根 `Product-Spec.md`，`--file` 可改。error：`MISSING_SECTION`/`EMPTY_SECTION`（产品概述 / 应用场景 / 功能需求 / 技术方向 四段缺失或只有标题没内容）、`PLACEHOLDER`（模板 `<...>` 未填 / TBD / TODO / 待定 / 待补，代码围栏与行内 code 不扫，`<br>` 这类真标签按白名单放行）、`NO_FLOW`（功能需求条目没有箭头，即说不清「用户做什么 → 系统做什么 → 得到什么」；一个箭头就够，模板自己的示例大多只有一个）、`DUPLICATE_ID`。warning：`AMBIGUOUS`（适当 / 合理 / 快速 / 友好 / 尽量 / 等等 / 若干 / 优化体验——**只扫功能需求条目**，产品概述和应用场景是宣传散文，在那儿抓「快速」只会训练所有人忽略整条检查）、`PARTIAL_ID`。error rc 1，无规格文档 rc 3。**照搬姊妹仓那套 `REQ-XXX-001`+`SHALL`+`WHEN` 会做出一个在本生态零命中、永远全绿的检查器——那比没有更糟，因为它读起来像规格被检查过了。**
    - **trace**：需求编号 ↔ 测试引用覆盖。**编号是可选的，没有编号就明说追溯不可用**（rc 3 + 一句「本规格未声明需求编号；要启用请在功能需求条目前加 `[REQ-<模块>-<三位数>]`」），**不硬造锚点**——行号 / 标题 / 散文哈希做出来的链接下次编辑就断，却读起来像覆盖率。有编号则扫全仓 tracked 文件：测试文件（`**/test(s)/**`、`*.test.*`、`*.spec.*` 等，`--tests` 可覆盖）引用 = `verified`，其余代码引用 = `implemented`。未被任何测试引用 → `unverified` rc 1；**代码/测试里引用了规格没声明的编号 = `dangling` rc 1**（指向一条已经不存在的需求），**.md 散文里的同类引用只报 `danglingInDocs` 不判失败**（CHANGELOG 引用历史编号是正当的）。`--min-coverage` 默认 1。非 git rc 3。
    - **spec**：按变更取相关需求的**预算化视图**——需求只增不减，唯一让它读得起的办法是不再整份读。`--paths a,b` 指定变更面、`--all` 全量、`--budget N` 字符预算（默认 6000，超预算**整条丢弃不截半句**）。收窄走的是质量门同一条路：impact 选模块 → trace 把编号映到模块 → 只渲染交集，并给每条标 `_verified by:`。**收窄需要编号 + catalog 同时具备**；缺任一则渲染整个功能需求段并把 `narrowed:false` 与原因同时写进 JSON 和渲染出的标题——**降级可以，闭口不谈不行**。始终 rc 0（无规格文档 rc 3）。
    - **dod**：Definition of Done——十四步静态治理一次跑完（catalog-lint / spec-lint / trace / attributes / arch-check / adr-check / fitness --all / ledger / arch-trend --gate / rules-audit / skills-lint / claude-md-lint 十二步阻断，risk / budget 两步只报信号不阻断）。宪法三步同其余阻断步一样只认退出码：rules-audit 只在有幽灵引用时 FAIL（U 多少不改退出码，那是给人的工作清单不是闸），skills-lint / claude-md-lint 各按自己的 finding 判，源不在（无规则文档 / 无 catalog）一律降级不阻断。每步以**子进程**跑，判据就是各子命令自己的退出码（0=PASS / 3=DEGRADED / 其余=FAIL），所以 dod 断言的是 hook 消费的同一份契约，不是另一套私有返回值。**降级不阻断**（没有 catalog 的仓不等于架构检查失败）；任一阻断步 FAIL → rc 2；**阻断步全部降级 = 什么都没建立 → rc 3 而不是 0**（同「空验证计划=不算绿」）。**只管静态治理**：过了不代表代码能跑，那半边归 `gate`，输出里的 `note` 就写着这句。
    - **review start|blue|lens <name>|verdict|backlog|status|team**：结构化分歧评审引擎。这一层不靠 catalog——评审是本领域唯一有实测效果的杠杆（一个 agentic review loop 把某模型在 SWE-bench Verified 上从 27.5% 拉到 56.9%，token 效率是重采样的 6.5 倍；另有研究报告三个结构化分歧的 agent 打得过五个共识型 agent），把它锁在大仓开关后面等于在最需要它的仓里废掉它，所以无 catalog 时按默认 profile 跑并在会话里记 `catalogPresent:false`。
      · **lens 团队**：九个 lens 各占一种失效模式，分三阶段——stage 1 `code`（correctness / architecture / maintainability）、stage 2 `functional`（testing / performance）、stage 3 `trust`（security / privacy / reliability / resilience）。召集顺序：`catalog.review.lenses` 显式清单最大，否则按 `catalog.review.profile`（personal / team / production / regulated，默认 team）定队，再**减去**受影响模块没声明到 low 以上的属性对应的 lens——属性只能减不能加（都声明成 high 就等于全员到齐，正是要防的那种噪声）；correctness 永不被减（stage 1 空掉会让阶段模型失效）。显式清单里的陌生 lens 名按 stage 1 处理，项目可以自带 lens。
      · **分阶段闸就是预算**：晚阶段 lens 在早阶段**通过**之前一律拒收（rc 1 + `stageGated`）。**报了 ≠ 过了**：某阶段有 error 级 finding 或有 lens 报 `unable`，该阶段就一直卡住，后面的贵 lens 根本不会被召集——这比姊妹仓更硬（那边阶段一报完就放行，只靠裁决短路挡）。
      · **blue**：被审方自证，stdin `{claims:[{statement,evidence}]}`，**每条主张必须带证据**（命令+退出码 / file:line），任一条没有整份拒收 rc 1。靶子也不能是空气。
      · **lens**：stdin `{findings:[{severity,location|reproduction,summary}],unable?,unableReason?}`，`--agent <id>` 记这份报告是谁出的。`severity` 限 `error|warning|info`；**每条 finding 必须能被定位**（`file:line` 形态的 location，或可复现的 reproduction），有一条不合格整份拒收 rc 1——定位不了的印象没法行动，而没法行动的 finding 会让整套评审变成表演。
      · **verdict**：裁决**由引擎算，不由人断言**。blue 没报 / 当前阶段有必召 lens 没报 → 拒绝出裁决（rc 1，列 blockers）；任一 error → `FIX_REQUIRED`；任一 `unable` → `NEEDS_MORE_EVIDENCE`；否则 `ACCEPT`（rc 0，其余裁决 rc 2）。**一个 lens 报 error 不会被投票稀释**——四个干净的 lens 抵不掉一个有定位的错误，这条是本设计与「共识型评审」的分界线，函数里没有任何投票。轮次上限 `catalog.review.maxRounds`（默认 3）：同一份改动连续 FIX_REQUIRED 到上限，裁决带 `escalate:true` 并明说停——要么改动错、要么标准错，再来一轮也分不出是哪个，交人。`ACCEPT` 且是最终阶段时**自动写一条 receipt**（复用 receipt write，scope 里记哪些 lens 覆盖了这个 diff），stop-gate 由此放行。
      · **树一动就 stale**：评审绑的是它判过的那份 diff、不是一个意图，blue / lens / verdict / backlog add 一律 rc 4，重开评审。`status`、`backlog list` 是只读报告，始终 rc 0。
      · **backlog add|list**：finding 可以被背，不可以被删。`add` 需 `owner` / `expiry`（必须未来）/ `summary` / `lens`；`list` 报过期项。**security / safety / privacy 的 finding 永不可入 backlog**——backlog 会变成这套设计在别处拒绝提供的那种豁免（禁词与 waiver 同源）。
    - **review-pack**：给评审者的证据包（commits / diffstat / **删除与重命名单独成节** / untracked 清单 / diff，超 `--max-diff-lines`（默认 800）溢出到 `.patch`）。`--base` 默认 `HEAD`。落 `.claude/harness/state/context/`，文件名由 base + diffHash 前 12 位决定而不是时钟——同一份改动重打就覆盖同一个文件，不给 retention 攒一堆同样的包。**删除单独成节**是因为评审者系统性地漏看「删掉了什么」；重命名的旧路径也算「走了」，一并列在这节而不是只埋在 diff 里。非 git rc 3。
    - **authorship record|show**：作者账本，把姊妹仓在宪法里标 **prompt-only** 的那条规则（「评审者永远不是作者」，它自陈「引擎只会数 lens，看不出谁写的代码」）变成引擎能判的事——Claude Code 的 hook 事件带 `agent_id` / `agent_type`，这是 cc-base 有而它没有的东西。`record` 从 stdin 读 `{agentId,agentType?,files:[...]}` 追加进 `.claude/harness/state/authorship.jsonl`（跨进程锁，坏行保留计数不静默丢弃）；`show` 报当前 diff 涉及文件的作者集与未归属文件。`review verdict` 消费它：某 lens 的 `agentId` ∈ 当前 diff 的作者集 → **拒绝出 ACCEPT** 并点名（自审不算独立评审）。**诚实边界**：没有账本、账本里没有一条命中本次 diff、或没有任何 lens 带 `--agent` 时，verdict **不阻断**，但输出 `authorshipEnforced:false` 并写明缺的是哪一半——没数据时假装验过了比原来的散文规则更糟。**本批只建引擎侧能力**，把 `SubagentStart` / `SubagentStop` 接进 `authorship record` 是下一批的事。
    - **invariants**：把「不可交易集 + 当前活跃状态」从 `.claude/CLAUDE.md`（铁律标记的粗体条目）、`progress.md` 的 Pinned 段和运行态**重新派生**出来，约 1200 字符预算（`--budget` 可调，`--rules` / `--file` 可指别的源）。要点是「什么不能被交易掉 + 现在处在什么状态」，不是把宪法复读一遍——所以只取粗体标签、正文里引用某条铁律的段落不算。活跃状态含：有无活跃 task（含超 72h 的 stale 标记）/ Fast Mode 窗口开着没开着还剩多久 / 最近一次 gate 的判决**以及它绑不绑当前 diff** / 账本链完好与否 / 待审清单几个。**状态块排在最前**，预算从尾巴吃——被压缩最先毁掉的就是它。两个源都读不出条目 → rc 3 并写明缺哪个（状态块照给）。**为什么需要它**：压缩不是把治理约束稀释了，是把它们删了，而摘要不修正漂移、只把漂移原样带过去；`PostCompact` 钩子（`.claude/hooks/postcompact-reinject.sh|.ps1`）在压缩边界后自动跑它、把结果经 `additionalContext` 回注；那个钩子不看 catalog 开关，小项目也一样生效，node 不在或引擎报错时打可见降级说明而不静默。
    - **recap**：从 artifact 派生当前处境，预算化（默认 4000 字符，`--budget` 可调）。读 `progress.md` 的当前断点 / Pinned / TODO 的 P0-P1（已 DONE|完成 的不算）/ 近期 Decisions / 近期 Done / 近期 Notes，加 `Product-Spec.md` 与 `Product-Spec-CHANGELOG.md`（**存在才读，不存在跳过不报错**，并在输出头上写明没读哪些）。渲染顺序就是优先级——预算从尾巴吃，「工作停在哪」先出。**关键性质**：跑了一周还是两年，恢复成本恒定，靠预算而不是靠全读。**它读的是 artifact 不是压缩摘要**——摘要是一种主张，不是事实。三份都不存在 rc 3。
    - **archive**：`progress.md` 超预算时把最老的 Done / Notes 条目移进 `progress.archive.md`，原地留一行指针。**默认 dry-run 只报计划，`--apply` 才动**（`--max-entries` 每段上限默认 100，`--file` / `--archive` 可指路径）。**只搬不改写**：条目连同它的续行整块搬走、字节不动，更正是在正文写新条目而不是回去改旧的。哪一端算「老」由日期读出来而不是拍脑袋（newest-first 搬尾巴、oldest-first 搬头，读不出来按尾巴并写明），猜反了会把最新的工作归掉档。写盘顺序是先 archive 后 progress——中间崩了条目在两边都在，读得见也修得回；反过来就丢了。Pinned 与 TODO 永不归档（还在生效的东西藏起来是反的）。以前归档留下的指针行不计入条目数、也不再被搬第二次。无 `progress.md` rc 3。
    - **sync-check**：三文件同步铁律的机器判定。`MEMORY_BEHIND_CODE`（有代码/家底改动但 `progress.md` 不在同一改动集里）/ `SPEC_WITHOUT_CHANGELOG`（`Product-Spec.md` 变了而 `Product-Spec-CHANGELOG.md` 没变）。`--staged` 判索引（供 git hook 用），无参判工作树。运行态（`.claude/evidence|harness/state|...`）、`node_modules`、纯文档不算「该被记住的改动」——那种误报会让人把闸关掉。仓里没有 `progress.md` 就不报 MEMORY_BEHIND_CODE（不存在的不强造）。**它只能判「文件动没动在一起」，判不了写下来的是不是真的**，findings 说到这儿为止。同步 rc 0 / 不同步 rc 1 / 非 git 或索引读不出来 rc 3。
    - **rules-audit**：宪法审计——扫 `.claude/CLAUDE.md` 与 `.claude/rules/*.md`，每条规则行（列表 / 编号 / 表格行）按能不能落到执法点分四类：**M** 机器强制（行内反引号 token，或规则行行首的粗体 token，解析出真实存在的 harness 子命令 / hook / script / test；粗体只加不减——解析不到就留在 U，绝不判 phantom，因为粗体在这些文档里绝大多数是普通强调而非引用语法） / **P** 承认靠自觉（行内写明 prompt-only、靠自觉、(P)、[P]——被「不」否定的不算，那是相反的陈述，把机制化过的规则记成没人管的那一类是最糟的读法） / **phantom** 幽灵引用（token 长得就是执法点却不存在：`harness.mjs` 后面跟一个没有的子命令名、引一个不存在的 hook 文件） / **U** 未分类（以上都不是——要最小化的正是这一类）。**只有 phantom 判失败**（rc 1 并点名到 `file:line`）；U 多少不改退出码——那是要人判断的指标不是自动闸，但 stdout 与 stderr 都显著给出（含逐条 file:line 与规则文本前若干字、per-file 分项）。判据**故意保守**：glob / 占位符 / JSON 字段名 / 配置键 / 数据文件一律解析成「什么都不是」，宁可落进 U 也不猜——**误判成 M 就是自动化的幽灵引用，误判成 phantom 会让人去修一条本来没坏的规则**。围栏里的代码块不算规则行（例子不是条款，不然贴一段命令就能刷高自己的比例）。为什么要这个数：2026 有研究报告规则不只是效果差、还会把行为**扭曲**到没人写下来的方向，且指令遵从有数量天花板（条数上升遵从率下降）——所以要压的从来不是字节数，是「指不到任何执法点、又不承认自己指不到」的条数：每条都指向命令的长宪法是健康的，满是劝诫的短宪法不是。
    - **skills-lint**：SKILL.md frontmatter 闸——frontmatter 一畸形，Claude Code 直接**静默丢弃**这个 skill，坏掉的和从没写过长得一模一样，而丢掉的往往正是那条去执法的 skill，所以这是本仓最贵的静默失败。扫 `.claude/skills/*/SKILL.md` 五件事：① frontmatter 可解析（`---` 围栏成对；键值形态在 CC 实际使用的子集内）② `name` 存在、kebab-case、与所在目录同名 ③ `description` 存在非空且 ≤180 字（与 `.claude/scripts/skill-description-lint.sh` 同一个数——那边管措辞、这边管形状，两半凑一条规则）④ 全体 skill 不重名 ⑤ `disable-model-invocation` / `user-invocable` 这类布尔字段必须是裸 true/false（引号包起来的 "false" 是非空字符串、恒真，读出来的意思和写的正好相反）。**不手搓 YAML 解析器**：子集照 `.claude/harness/audit/check-syntax.mjs` 划（判得最狠的一条是裸值里不许有 `": "`——loader 会连整份文档一起拒），超出子集的形态（缩进续行 / 块标量 / 流式集合 / 锚点）报「无法判定」走 rc 3，不静默接受也不误判为错。三档分得清：干净 rc 0；有 finding rc 1（点名到 `file:line` + 判据代号）；该扫没扫成 rc 3（目录在却读不了 / 文件读不了 / 形态判不了）。**没有 skills 目录 rc 0**——本框架装进不带 skill 的项目是常态不是故障；**目录在但一个 SKILL.md 都没有也是 rc 0**，归 note 不归降级，输出里 `listed` / `inScope` 两个数都在（「没东西可扫」和「扫了没扫成」不共用一个退出码）。
    - **claude-md-lint**：高风险模块的**目录级宪法**闸——Claude Code 对子目录里的 `CLAUDE.md` 是**按需加载**的（改到那个目录下的文件，它的规则才进上下文），所以嵌套 CLAUDE.md 是唯一能把模块边界写在「干活的地方」而不占主控预算的位置；高危模块没有它，边界就只存在于 agent 记不记得，正是本框架要机器化掉的那类自觉。catalog 里 `riskTier` 为 high（或 critical——该字段无取值校验，写了 critical 按不低于 high 读）的模块，其目录必须有 `CLAUDE.md` 且四节齐全：Purpose / Boundaries / Invariants / Verification，**中英双语标题都认**（目的 / 边界 / 不变量 / 验证）。判定：标题行（#..####）文本含关键词即算该节，**一个标题只认一节**（第一个命中的，「Boundaries and Verification」不许一段正文顶两节）；**有壳没肉不算有**——标题到同级或更高级的下一个标题之间没有一行正文即判空节（写成子小节仍有正文的照算有）；围栏里的标题是例子不是章节。模块目录 = 该模块 path globs 的**最长公共字面目录前缀**（`core/**`→`core`，`db/schema.ts`→`db`）；跨两个根或只到仓根的模块**派生不出目录**，报「无法判定」走 rc 3，不硬判也不静默跳过。**只查 high/critical**：medium 及以下不欠目录宪法，一刀切要求每模块一份的规则活不过一周。三档：齐 rc 0；缺文件 / 缺节 / 空节 rc 1（点名模块 id + 期望路径 + 缺哪节，finding 与降级同时出现 finding 赢）；无 catalog / 非 git / 模块根派生不出 rc 3。**catalog 存在但没有一个 high/critical 模块也是 rc 0**，归 note 不归降级，`listed` / `inScope` 两个数都在（同 skills-lint：「没东西可扫」和「扫了没扫成」不共用一个退出码）。

    - **init**：从仓库现状推一份 catalog 草案，把启用门槛从「手写一份合规 catalog」降到「跑一条命令再人工审一遍」——手写第一份正是接入停在的那一步。扫 tracked 清单按顶层/次顶层目录推候选模块（`packages`/`apps`/`src` 这类容器名、或子目录 ≥3 且文件 >24 的大目录拆一层，只拆一层，所以候选永远是兄弟、没有一个 glob 能吞掉另一个），单文件目录 / docs / 构建产物 / 缓存目录进 `ignored`，manifest 与 lockfile 与顶层散落脚本进 `global`。**默认 dry-run 打到 stdout，`--apply` 才写**；`--apply` 遇已有 catalog **rc 1 不覆盖也没有 --force**（手写的档位、attributes、禁边没有任何推断能重建，要换请自己先删）。候选超 `--max-modules`（默认 50）退回顶层粒度并说明——三百个模块的草案没人会审。
      · **不猜的比猜的重要**：`riskTier` 一律 `low` 占位，`attributes` / `dependsOn` / `layer` / `forbiddenDependencies` **一概不生成**。机器读目录名猜出的 high 会被下游当成有人定过档，比不写更糟。
      · **`dependsOn` 尤其不写**：真实 import 边照跑（复用 arch-check 那套提取），但只报在 `referenceEdges` 和 stderr 里**供人过目**。写进 `dependsOn` 等于让 arch-check 对着自己的倒影做检查，`undeclaredDependencies` 从此恒空、防腐闸当场失效。
      · **草案必须自洽**：产出前用真 `lintCatalog` 自检一遍，UNMAPPED / OVERLAP / CATCH_ALL 任一不过就 rc 1 拒绝给出（连 `--apply` 也一个字节都不写）——把人第一步就送进红灯的草案比没有草案更糟。推断没放下的路径按字面补进 `ignored` 并计数上报，落进 ignored 的手写文件数单独报 `sourceIgnored`，该提拔成模块的自己提。
    - **release**：发版判据的**证据装配**——把「这个 commit 能不能发」的七条判据一次跑齐、摆成可核查清单。**它自己什么都不做**：不打 tag、不 push、不建 GitHub release、不写任何文件，每个子进程都是读（`git ls-remote` / `gh run list` / `dod`）。发版是 HIGH 档人工决定，一个会自己发版的命令第一次误触之后就再没人敢跑它。**不替代**仓里已有三件——`release-gate.sh`（hook，skill 展开前查待审清单）/ 仓根 make-release.sh（打包 zip + 排私有 feedback + 泄漏扫描）/ release-builder skill（人的工作流）；缺的正是它们中间那步装配。七条**全部阻断、全部可降级**：`worktree`（有未提交改动 = 要发的不是测过的；运行态按 `isStateExcluded` 排除，Fast Mode 标记不算「未提交的活」）/ `remote`（本地 HEAD 对 `git ls-remote origin <当前分支>`）/ `dod`（子进程跑，判据是它自己的退出码）/ `manifest`（对 `FRAMEWORK-MANIFEST.txt`）/ `review-queue`（`.claude/.needs-review` 非 clean）/ `fast-mode`（开着 = 这批跳过了 review/test 闸）/ `ci`（当前 HEAD 的 CI 结论）。
      · **降级不是通过、也不是失败**：问不出答案就报 UNKNOWN，两个通道都明写，且**不动退出码**。
      · **`remote` 实查远端，不读 `git status` 的 ahead/behind**：那个数来自 `.git` 里的远端跟踪引用，是上次 fetch 的缓存、可以任意陈旧；本仓已经吃过一次这个亏。差异方向也当场判出来给命令（本地领先 → push / 分叉 → fetch 后看 `HEAD..origin/<branch>` / 远端提交本地没有 → 先 fetch）。
      · **`ci` 是本轮最大教训的机器化**：本仓 CI 连红一个多月没人看，而每批都在本地跑 run-all 报「全绿」——两句都真，本地跑的和 CI 跑的不是同一件事。所以结论从 CI 自己读；**读不到时诚实降级并写明「CI 状态未知，不等于通过」，绝不因查不到就当绿**。查到 failure/timed_out/startup_failure/action_required → 阻断；HEAD 从没跑过 CI（刚 commit 没 push）/ 还在跑 / cancelled 这类没结论的 → 降级说明。守卫顺序是设计的一部分：**无 origin 先答，再去找 `gh`**——装了 gh 的机器和没装的机器给同一个答案，golden 才录得住。
      · **`manifest` 问的是「这份清单是不是 gen-manifest.sh 现在会写出来的那份」**，不是「列进去的文件哈希还对不对」——因为装机器依赖的正是前者：仓根 setup.sh 用同一套排除逻辑拷同一批文件，**没有清单行的框架文件会被当成用户改过、升级时不覆盖**（静默跳过，不报错）。所以三类发现都算：漏列 / 列了但树上没有 / 哈希对不上。判据复刻 gen-manifest.sh 的 `case` 分支及其两条语义（`*` 跨 `/`、首个命中的分支赢），**行序不比**（生成侧的 `sort` 吃 locale，字节序不是内容的性质）。下一步命令 `bash .claude/scripts/gen-manifest.sh`。
      · **没有豁免 flag，一个都不给**：`--skip-ci` / `--allow-dirty` / `--force` 每一个都是 waiver 的翻版——没有 owner、没有到期、没有补偿，由当下最赶时间的人签发。`release` 的 flag 白名单表空着，且要一直空着（`--任何东西` 一律 rc 2）。
      · **每条阻断项都带「下一步该敲什么命令」**，JSON 的 `blockers[].nextStep` 与 stderr 末尾那几行是同一份——空手的诊断没人会用第二次。

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
    | arch-trend | 报告态总是；--gate 无回退且无禁边 | --gate 有新边/指标超历史最优，或最新快照 forbidden > 0 | — | — | — |
    | cochange | 报告态总是；--gate 无未声明共变 | --gate 有 undeclaredCoupling | — | 无 catalog / 非 git / 取不到历史 | — |
    | gate | PASS | — | FAIL / BLOCKED / 属性缺口 | 无 catalog / 非 git / PASS 但账本追加失败 | — |
    | ledger | 链完好且证据摘要相符 | 有断裂（链或证据） | — | 账本在但读不出来 | — |
    | gate-audit | 总是 | — | — | 无 catalog / 账本读不出来 | — |
    | retention | 报告或修剪完成 | --apply 有文件删不掉 | — | 链读不出或已断裂（拒绝清扫） | — |
    | risk | 无 error 级 finding | 有 error 级 finding | — | — | — |
    | task start | 写入成功 | — | — | stdin 非 JSON / 信封缺字段 | — |
    | task status | 总是 | — | — | — | — |
    | task complete | 全部条件成立 | — | 有 blockers / 无活跃 task | 无 catalog / 非 git / 账本读不出来 / 传了 --changed | — |
    | budget | 未超限 | 有指标超限 | — | 无 catalog / 非 git | — |
    | spec-lint | 无 error | 有 error | — | 无规格文档 / 读不出来 | — |
    | trace | 覆盖达标且无悬空编号 | 有未追溯需求 / 悬空编号 | — | 无规格文档 / 未声明编号 / 非 git | — |
    | spec | 渲染完成（`narrowed` 字段说明收窄与否） | — | — | 无规格文档 | — |
    | dod | 阻断步无 FAIL 且至少一步有结论 | — | 有阻断步 FAIL | 阻断步全降级（什么都没建立） | — |
    | review start | 开成功 | — | — | 非 git / 无变更 | — |
    | review blue | 记下 | 主张缺证据 | — | stdin 非 JSON / 无会话 | 树已移动 |
    | review lens | 记下 | finding 无定位 / severity 非法 / 未召集 / 阶段未过 | — | stdin 非 JSON / 无会话 / 缺 lens 名 | 树已移动 |
    | review verdict | ACCEPT | 有 blockers（blue 未报 / 当前阶段缺报 / 作者自审挡 ACCEPT） | FIX_REQUIRED / NEEDS_MORE_EVIDENCE | 无会话 | 树已移动 |
    | review backlog add | 记下 | 保护属性 / 缺字段 / 过期 | — | stdin 非 JSON / 无会话 | 树已移动 |
    | review backlog list / status / team | 总是 | — | — | — | — |
    | review-pack | 写出 | — | — | 非 git | — |
    | authorship record | 追加成功 | — | — | stdin 非 JSON / 缺 agentId 或 files / 追加失败 | — |
    | authorship show | 总是 | — | — | 非 git / 账本读不出来 | — |
    | invariants | 派生到条目 | — | — | 两个源都读不出条目（状态块照给） | — |
    | recap | 至少读到一份 | — | — | 三份 artifact 都不存在 | — |
    | archive | 报告或归档完成 | --apply 写盘失败 | — | 无 progress.md | — |
    | sync-check | 同步 | 不同步（点名 findings） | — | 非 git / 索引读不出来 | — |
    | rules-audit | 无幽灵引用 | 有幽灵引用 | — | 无规则文档 | — |
    | skills-lint | 干净 / 无 skills 目录 / 无 SKILL.md | 有 finding | — | 目录或文件读不了 / 形态无法判定 | — |
    | claude-md-lint | 四节齐 / 无 high-critical 模块 | 缺文件 / 缺节 / 空节 | — | 无 catalog / 非 git / 模块根派生不出 | — |
    | init | 草案产出（dry-run 或 --apply 写成功） | --apply 时 catalog 已存在 / 草案自检不过 catalog-lint / 写盘失败 | — | 非 git / tracked 清单空或截断 | — |
    | release | 阻断项全过（降级项照列，不改退出码） | 有阻断项（`blockers[]` 逐条带下一步命令） | — | 非 git / 七条全降级（什么都没建立） | — |
    | unknown / missing | — | — | — | 总是 | — |
    | 未知 flag（任一子命令） | — | — | 总是 | — | — |

    要点：
    - **未知 flag = rc 2 用法错，不是降级**：每个子命令有一张白名单表（`harness.mjs` 的 `SUBCOMMAND_FLAGS`，与 dispatch 挨着），它不读的 `--flag` 一律 rc 2、stderr 点名是哪个 flag 并列出该子命令认识哪些。此前是无条件收进 flags 后静默忽略——`impact --paths ...`（`--paths` 是 fitness 的，impact 认 `--changed`）照跑照出 JSON 照 rc 0，录基线时会录出一份看着正常实则什么都没测的假基线。加子命令须同步加表项（表项缺失 = 该子命令不收任何 flag），两个方向都由 selftest 钉住。`--flag=value` 从来不是这个 parser 认的拼法（会解析成 `changed=x` 这个键），现在整个 token 被原样点名，不再吞掉。
    - `verify` FAIL/BLOCKED **或 critical/high 属性缺证据** = rc 2（commit 闸阻断）；无 catalog 或非 git = rc 3（降级，不阻断也不假绿）。输出里 `gate` 字段三态：PASS / FAIL|BLOCKED（check 层）/ BLOCKED_BY_ATTRIBUTES（属性层）。
    - `receipt verify` STALE = rc 4（stop-gate 拦停强制重审）；非 git = rc 3（降级）。
    - 缺命令 / 二进制找不到 = `verify` 内部 BLOCKED（reason: `command-missing:<exe>`），**绝不假绿**。

[接线点（hook 侧，catalog + node 双满足才启用，否则静默走原逻辑）]
    守卫库 `.claude/hooks/lib-harness.sh|.ps1` 提供 `harness_enabled`（catalog 存在）/ `harness_node_ok`（node 可用）/ `harness_run`（跑子命令）/ `harness_rc_in_contract`（退出码是否在契约内）/ `harness_err_head`（引擎 stderr 头几行）。三处接线，**不新增 hook 事件**：
    - **stop-gate ↔ receipt verify**：`.needs-review` 清单清空（口头释放）后再校验当前 diff 是否有已通过回执绑定。rc=4（STALE）= 代码越过所有已审回执 → 拦停强制重审、保留 `.needs-review` 让下轮仍拦；rc=0/3 照原逻辑清理放行。位置：`stop-gate.sh:32-50` / `stop-gate.ps1` 对应段。
    - **pre-commit-check ↔ verify**：staged 就绪后、commit 之前跑定向质量门。rc=2（受影响模块 FAIL/BLOCKED **或属性缺证据**）= 阻断 commit；rc=3（无 catalog / 非 git）静默跳过；rc=0 放行。位置：`pre-commit-check.sh:61-74` / `.ps1` 对应段。
    - **harness-async-verify ↔ verify（编辑期后台早警）**：PostToolUse(Edit|Write) 挂 `harness-async-verify.sh|.ps1`（settings 里 `asyncRewake:true` 后台形态）——两次 commit 之间的编辑期后台跑同一套 verify，rc=2 时唤醒主 Agent 读 stderr 摘要（gate + 失败 check 前 5 条 + 属性缺口数）。**早警不硬拦**（commit 硬门仍是 pre-commit-check）；180 秒防抖（`.claude/.async-verify-last`）；catalog/node 缺任一静默跳过；Fast Mode 放行。
    - **契约外退出码 = 引擎崩了，不是闸的结论**（三处一律不静默放行）：契约表之外的码（引擎异常、缺 `lib/`、node 出岔给的 rc 1 之类）不许落进「其余一律放行」。stop-gate 出 `decision:"block"`、pre-commit-check exit 2、harness-async-verify 照唤醒形态发诊断（早警仍不硬拦）；三处诊断都**点名实际退出码**并带上引擎 stderr 头几行——「引擎崩了」和「回执不匹配 / 门真没过」要采取的行动完全不同，混成一句话等于没说。stop-gate 这条**不清 `.needs-review`**（清了等于销毁下轮该拦的状态），并走同一套 `.stop-gate-strikes` 三振熔断（sig 按退出码记）：引擎长期崩是「拦三次 + 每次说清为什么 → 放行」，不是无限拦。回归锁：`.claude/tests/test-hook-failopen.sh`。
    - arch-check / fitness / attributes 不走 hook 自动触发（成本考量），推荐进 catalog checks 由 verify 定向带跑（如 `"arch": {"command": "node .claude/harness/harness.mjs arch-check", "class": "static"}`），或 code-review Stage 0 / 发版前手动跑。
    - **闸的原生边界（防跑飞视角必须知道）**：Claude Code 对 Stop hook 有「同 turn 连拦 8 次强制放行」的原生上限（防 hook 死循环），框架 settings.json 已把 `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` 提到 25——stop-gate 自身的三振熔断（3 次）会先触发，正常永远碰不到原生上限；但要知道这层「泄闸」边界存在，闸不是无限次的。

[与 per-Task review→fix 闭环的关系]
    diff-bound 回执把「`.needs-review` 空 marker + `echo clean`」从口头承诺升级为机器可验证事实：当前工作树 diff 的 SHA256 必须等于某条已通过回执绑定的 diffHash。
    - 任何 diff 字节变动（哪怕一个换行）→ 旧回执自动 stale → stop-gate 拦停、强制重审重写回执。
    - `contentHash` 防 JSON 字段被改（reviewer / verdict / scope / timestamp 等任一字段变动 → hash 不匹配 → 回执作废）。
    - `taskId` 限定 `[A-Za-z0-9._-]`，路径穿越 / 分隔符被替换（safeTaskId）。
    - 回执落 `.claude/harness/receipts/`（git 忽略的运行态）。
    - 回执谁来写：手写 `receipt write` 是轻量路子；走评审引擎时不用手写——`review verdict` 判出 ACCEPT 且已到最终阶段才自动写，写不出来就说明评审没走完，闸自然不放行。两条路产出同一份 diff-bound 回执，stop-gate 只认这一件事。

[四态质量门（verify 细则）]
    verification 解析优先级：`module.verification` > `catalog.riskChecks[module.riskTier]`。
    单 check 四态：
    - `PASS`：命令 exit 0
    - `FAIL`：命令 exit ≠ 0
    - `BLOCKED`：缺 command 定义 / 二进制找不到（**不假绿**）
    - `SKIPPED`：Fast Mode + 非 security/safety/privacy + check 声明 `allowFastSkip:true`
    聚合：任一 FAIL → FAIL；任一 BLOCKED → BLOCKED；否则 PASS（SKIPPED 不阻断）。
    **空验证计划 = BLOCKED（不算绿）**：受影响模块存在但一条 check 都没解析出来（模块没配 verification 且 riskChecks 无该档默认）→ 整体 BLOCKED、输出 `emptyPlan:true`——什么都没跑就什么都没建立，配置缺口必须可见（借鉴 codex-base v3「空计划=配置失败」）。无受影响模块（无变更）仍 PASS。
    check 聚合之上再叠五性覆盖门：受影响模块声明的 critical/high 属性若无 PASS 的 claiming check（或有 claiming check FAIL/BLOCKED 反证），`gate=BLOCKED_BY_ATTRIBUTES`、rc 2——「check 全绿但没有任何检查证明过 security」不再能读作完成。细则见 .claude/rules/quality-attributes.md。

[waiver——结构化 per-check 豁免]
    schema（`.claude/harness/waivers/*.json`，git 忽略）：`version:1` / `owner` / `reason` / `scope`（= 被豁免 check id，或 `attribute:<module>/<属性>` 豁免一条 high 档属性缺口）/ `expiry`（ISO，必须未来）/ `compensation` / `created_at` / `contentHash`（create 时写入防篡改）。
    命中规则：FAIL 或 BLOCKED + **非 security/safety/privacy 类** + scope == check id → 降级 SKIPPED（reason: `waiver:<scope>`）。
    **security / safety / privacy 类永不可豁免**——这三类 check 即使有匹配 waiver 仍保留 FAIL/BLOCKED（隐私与安全同为不可协商项，借鉴 codex-base v3 保护属性集）。
    属性豁免：scope 写 `attribute:<module>/<属性>` 只能推迟 **high** 档缺口（critical 永不可豁免）；且禁词校验天然使 `attribute:x/security`、`attribute:x/safety`、`attribute:x/privacy` 不可表示——安全、功能安全与隐私的属性缺口没有豁免通道。
    禁词（reason + scope 联合正则，命中即 create/validate 拒绝）：`safety|security|privacy|pii|secret|credential|destructive|push|deploy|production`。
    与 Fast Mode 关系：**Fast Mode = 非 security/safety + allowFastSkip 的提前 SKIP 路径；waiver = FAIL/BLOCKED 事后降级**。两者正交，不互相替代。

[运行态文件]
    - `.claude/harness/module-catalog.json`：唯一开关，**本体照常分发**（catalog 仓库可选择性提交共享配置；不提交即每工作树独立）。
    - `.claude/harness/lib/*.mjs`：引擎实现本体，与 harness.mjs 同批分发、同批升级（安装器按整棵树 find 复制，天然带上；手工搬运须整目录一起搬）。不是运行态，列在此处只为提醒它与入口不可拆散。
    - `.claude/harness/adapters.json`：外部工具表，本体照常分发（项目可自行增删条目）。
    - `.claude/harness/fitness-rules.json`：可选项目自定义 fitness 规则（`{"replace":false,"rules":[...]}`），有则并入内置规则。
    - `.claude/harness/receipts/*.json`：审查回执，**git 忽略**（永不入库）。
    - `.claude/harness/waivers/*.json`：结构化豁免，**git 忽略**（永不入库）。
    - `.claude/harness/trend/arch-trend.jsonl`：漂移趋势台账（`arch-check --record` 追加，超 1000 行自动保留最近 500），**默认 git 忽略**（每机各持；团队要共享趋势可自行取消忽略）；不进 diff 指纹、不进 context-pack。
    - `.claude/harness/state/review.json`：当前评审会话（绑 diffHash、召集的 lens、blue、各 lens 报告、backlog、lineage），**git 忽略**；一个工作树一份，`review start` 覆盖前会把上一次 FIX_REQUIRED 记进 lineage 供轮次上限用。
    - `.claude/harness/state/authorship.jsonl`：作者账本（append-only，跨进程锁），**git 忽略**。
    - `.claude/harness/state/context/`：`review-pack` 的证据包与 diff 溢出文件，**git 忽略**；与 context-pack 共用一个可回收目录，`retention --max-packs` 一起修剪——隐私含销毁合规，只积不销是自我不一致。
    - `.claude/harness/state/`：证据层运行态，**git 忽略**——`ledger.jsonl`（`gate` 追加的哈希链账本，append-only，**不许手工编辑**：改了 `ledger` 就报断裂，而断裂 = 此前全部验证按未证明处理）+ `ledger.lock`（追加期间的跨进程互斥目录，超 60s 视为陈旧锁回收；并发 gate 靠它才不会各写各的 prev 把链写死）+ `task.json`（当前活跃 task 信封，一个工作树一份）。
    - `.claude/harness/evidence/*.log`：每条执行过的 check 的原始 stdout+stderr（`gate` 落盘，文件名 `<check>-<epoch>.log`），**git 忽略**；`retention` 按龄和数修剪，但**账本引用到的永不删**。
    - 上面两条与 receipts / waivers / trend 一样**排除出 diff 指纹**（跑引擎不会 stale 掉自己刚写的证据）、**排除出 context-pack**（运行态永不进交给 delegate 的包）。
    - `.claude/.runtime/supervisor/`：supervisor 进程守护运行态（state/pid/service 日志），**git 忽略**（见 dev-workflow-details 的本地运行阶段与 README「进程守护」）。
    - `.claude/.needs-review` / `.fast-mode` / `.stop-gate-strikes`：原框架运行态（harness 复用，git 忽略）。

[典型工作流]
    1. 启用：`node .claude/harness/harness.mjs init` 出草案 → **人审**（模块划得对不对、哪些被塞进 ignored 该提拔回来、riskTier 与 attributes 该定成什么、referenceEdges 里哪些边是真要声明的 dependsOn）→ `init --apply` 落盘或照草案手改 → `catalog-lint` 验过。空手写也行（参照 `.claude/tests/fixtures/harness/catalog-good.json`；五性声明参照 quality-attributes.md 示例），但 init 那一步省下的是把每条 tracked path 都找到归处的功夫。
    2. 接线五性：给关键模块声明 `attributes`（如支付模块 security:critical）→ `attributes` 子命令看接线缺口 → `adapters list --attribute security` 挑工具 → `adapters add <id>` 接线 → 模块 verification 引用该 check。
    3. 开发：正常 per-Task 编码 → review → fix 闭环（hook 自动接线，无需手工调用）。
    4. 诊断：`doctor` 看启用态、`impact` 看变更影响面、`context-pack` 看 LLM 上下文预算分配、`arch-check` 看依赖漂移与越禁边、`fitness` 扫变更文件的五性反模式。
    5. 审查（两条路，二选一）：轻量走 `receipt write` 手写回执（stdin JSON：taskId / reviewer / verdict / scope 四字段，命令签名见能力清单 receipt 条）；要结构化分歧就走评审引擎——`review-pack` 凑证据 → `review start` 开会（看它召集了谁）→ 被审方 `review blue` 自证 → 每个 lens **派不同的 fresh 实例**报 `review lens <name> --agent <id>`（写这段代码的那个 agent 先 `authorship record` 记账，verdict 才拦得住自审）→ `review verdict` 让引擎算裁决，ACCEPT 且到最终阶段时 receipt 自动写出。
    6. 验收：`receipt verify` 确认 diff 绑定、`verify` 确认定向质量门 + 五性覆盖通过。
    7. 防漂移日常：arch-designer 产出的 ADR 用 `adr-check` 盯执法引用（Architecture-Design.md 改动后、发版前跑）；接入老仓先 `arch-check --record` 立债务基线，此后周期性（Phase 收尾 / 发版前）`--record` + `arch-trend --gate`——旧债不挡路，新债零容忍。
    8. 漂移哨兵（长 session 可选）：Claude Code 原生定时任务（CronCreate 工具 / `/loop`）可在长会话里周期性跑 `node .claude/harness/harness.mjs arch-trend --gate` 与 `fitness`——让漂移在会话内就被点名，不等发版前才发现。用法：让主 Agent 建一条 30-60 分钟间隔的 cron 提示（内容即上述命令 + 解读要求）；`CLAUDE_CODE_DISABLE_CRON=1` 可全局关停。成本极低（命令本地跑，只有解读吃 token），长会话才值得开。
