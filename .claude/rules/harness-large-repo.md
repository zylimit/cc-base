本文件由 CLAUDE.md 下沉；主控命中指针时必须完整读取本文件再行动，不得凭指针行猜测内容。

[启用条件（铁律：唯一开关）]
    唯一开关 = `.claude/harness/module-catalog.json` 存在。存在即启用全部大仓能力；不存在即默认关闭、所有 hook 静默走原逻辑（零行为变化）。
    - node 不可用同样静默降级（hook 通过 `lib-harness.sh|.ps1` 的 `harness_node_ok` 守卫跳过，非假绿、非 crash）。
    - doctor 判启用态：`node harness.mjs doctor` 输出 JSON 看 `catalogPresent` 字段（false=未启用）；`bash doctor.sh` 的人读输出报「module-catalog.json 未配置（大仓治理默认关闭，接线走原逻辑）」同义（前者机器读、后者人读，同一事实两副面孔）。
    - 启用 = 放一份合规 catalog 文件；关闭 = 删该文件。不动 settings.json、不动任何 hook。
    - 小项目 / 框架本体零负担——未启用时对项目完全透明。

[module-catalog.json schema]
    Catalog 顶层：`version`（必填）/ `modules`（必填，数组）/ `global[]`（变更即全模块 fanout 的路径，如 package.json / tsconfig.json）/ `ignored[]`（impact 排除路径，如 README / docs）/ `riskChecks{low,medium,high:[checkId]}` / `checks{id:{command,class?,allowFastSkip?}}` / `contextPack`（预算覆盖）。
    Module：`id`（必填唯一）/ `paths[]`（必填 glob）/ `dependsOn[]` / `owners[]` / `riskTier`（low|medium|high）/ `verification[]`（声明即覆盖 riskChecks 默认）。
    路径分类优先级：**module > ignored > global > unmapped**；多模块命中按 specificity（glob 字面字符数）最高者赢。

    catalog-lint 全量归类要求（每条 tracked path 必须有归处）：
    - `CATCH_ALL`（错）：模块 paths 含 `''` `'.'` `'*'` `'**'` `'**/*'`——吞整树、掩盖漏项
    - `UNMAPPED`（错）：tracked path 未被任何 module/global/ignored 声明
    - `OVERLAP`（错）：同一路径被 >1 个 module 声明
    - `DANGLING_DEP`（错）：dependsOn 指向不存在的 module id
    - `CYCLE`（warning，不阻断）：dependsOn 图含环

    **保守扩张铁律**：unmapped 命中 / global 命中 / 非 git / truncated → 全模块 fanout + `degraded:true`（宁可全跑，不可漏测）。

[九能力清单]
    载体 `node .claude/harness/harness.mjs <subcommand>`，stdout 单行 JSON、stderr 人读诊断。
    - **doctor**：环境自检（node 版本 / catalogPresent / gitRepo / headCommit / subcommands / waivers）。**始终 rc 0**；框架 `.claude/scripts/doctor.sh` 调用本子命令做抽检（两物同名易混，harness 子命令输出 JSON、框架脚本输出人读）。
    - **diff-hash**：当前工作树 canonical diff 的 SHA256（含 untracked 内容 hash；排除 .needs-review / .fast-mode / evidence / receipts / waivers 等运行态）。
    - **selftest**：内置回归断言（glob / catalog 分类 / impact 闭包 / context-pack 预算 / receipt 防篡改 / 四态门 / waiver 规则）。失败 rc 1。
    - **catalog-lint**：按 schema 校验 catalog。无参 = 对当前仓 `git ls-files` 全量归类。
    - **impact**：反向依赖闭包——传变更路径，返 `affected`（直接 + 反向闭包）/ `direct` / `expansionReasons` / `verification`（每模块绑的 check）/ `degraded`。
    - **context-pack**：预算化打包——P1 任务信封 + Spec/Plan 指针 → P2 canonical diff（截断 maxDiffChars）→ P3 变更文件（每个截断 maxFileChars）→ P4-6 受影响模块 verification 路径串。DENY 路径永不入包（.git / node_modules / dist / build / .next / .venv / .env / *.pem|key|p12|pfx / id_rsa / .ssh|.aws|.azure|.gnupg|.kube / .claude/evidence|receipts|waivers 等；白名单 `.env.example|.sample|.template` 可入包）。产出 `packHash`（仅含 path+bytes 清单 + budgets + diffHash，对空白变动稳定）。
    - **receipt write|verify**：diff-bound 审查回执。`write` 从 stdin 读 JSON 写 `.claude/harness/receipts/<taskId>.json`；`verify` 比对当前 diff 与回执绑定 diffHash。
    - **verify**：质量门——对受影响模块跑各自 verification、四态聚合、应用 waiver。
    - **waiver list|check|create**：结构化豁免管理。

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
    | verify | PASS / 全 SKIPPED | — | FAIL / BLOCKED | 无 catalog / 非 git | — |
    | waiver list | 总是 | — | — | — | — |
    | waiver check | valid | invalid | — | — | — |
    | waiver create | 写入成功 | 校验失败 | — | 子命令错 | — |
    | unknown / missing | — | — | — | 总是 | — |

    要点：
    - `verify` FAIL/BLOCKED = rc 2（commit 闸阻断）；无 catalog 或非 git = rc 3（降级，不阻断也不假绿）。
    - `receipt verify` STALE = rc 4（stop-gate 拦停强制重审）；非 git = rc 3（降级）。
    - 缺命令 / 二进制找不到 = `verify` 内部 BLOCKED（reason: `command-missing:<exe>`），**绝不假绿**。

[接线点（hook 侧，catalog + node 双满足才启用，否则静默走原逻辑）]
    守卫库 `.claude/hooks/lib-harness.sh|.ps1` 提供 `harness_enabled`（catalog 存在）/ `harness_node_ok`（node 可用）/ `harness_run`（跑子命令）。两处接线，**不新增 hook 事件**：
    - **stop-gate ↔ receipt verify**：`.needs-review` 清单清空（口头释放）后再校验当前 diff 是否有已通过回执绑定。rc=4（STALE）= 代码越过所有已审回执 → 拦停强制重审、保留 `.needs-review` 让下轮仍拦；rc=0/3 照原逻辑清理放行。位置：`stop-gate.sh:32-50` / `stop-gate.ps1` 对应段。
    - **pre-commit-check ↔ verify**：staged 就绪后、commit 之前跑定向质量门。rc=2（受影响模块 FAIL/BLOCKED）= 阻断 commit；rc=3（无 catalog / 非 git）静默跳过；rc=0 放行。位置：`pre-commit-check.sh:61-74` / `.ps1` 对应段。

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
    - `SKIPPED`：Fast Mode + 非 security + check 声明 `allowFastSkip:true`
    聚合：任一 FAIL → FAIL；任一 BLOCKED → BLOCKED；否则 PASS（SKIPPED 不阻断）。

[waiver——结构化 per-check 豁免]
    schema（`.claude/harness/waivers/*.json`，git 忽略）：`version:1` / `owner` / `reason` / `scope`（= 被豁免 check id）/ `expiry`（ISO，必须未来）/ `compensation` / `created_at` / `contentHash`（create 时写入防篡改）。
    命中规则：FAIL 或 BLOCKED + **非 security 类** + scope == check id → 降级 SKIPPED（reason: `waiver:<scope>`）。
    **security 类永不可豁免**——class:security 的 check 即使有匹配 waiver 仍保留 FAIL/BLOCKED。
    禁词（reason + scope 联合正则，命中即 create/validate 拒绝）：`safety|security|secret|credential|destructive|push|deploy|production`。
    与 Fast Mode 关系：**Fast Mode = 非 security + allowFastSkip 的提前 SKIP 路径；waiver = FAIL/BLOCKED 事后降级**。两者正交，不互相替代。

[运行态文件]
    - `.claude/harness/module-catalog.json`：唯一开关，**本体照常分发**（catalog 仓库可选择性提交共享配置；不提交即每工作树独立）。
    - `.claude/harness/receipts/*.json`：审查回执，**git 忽略**（永不入库）。
    - `.claude/harness/waivers/*.json`：结构化豁免，**git 忽略**（永不入库）。
    - `.claude/.needs-review` / `.fast-mode` / `.stop-gate-strikes`：原框架运行态（harness 复用，git 忽略）。

[典型工作流]
    1. 启用：在 `.claude/harness/` 写一份合规 `module-catalog.json`（参照 `.claude/tests/fixtures/harness/catalog-good.json`）→ `node .claude/harness/harness.mjs catalog-lint` 验过。
    2. 开发：正常 per-Task 编码 → review → fix 闭环（hook 自动接线，无需手工调用）。
    3. 诊断：`doctor` 看启用态、`impact` 看变更影响面、`context-pack` 看 LLM 上下文预算分配。
    4. 审查：code-reviewer 通过后用 `receipt write` 写回执（stdin JSON：taskId / reviewer / verdict / scope 四字段，命令签名见九能力 receipt 条）。
    5. 验收：`receipt verify` 确认 diff 绑定、`verify` 确认定向质量门通过。
