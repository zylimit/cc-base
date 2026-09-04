# 跨仓借鉴台账

> 兄弟仓（deepseek-base / codex-base 等）每轮摸底的机制清单与判定。一条机制一个判定，判定要带证据句柄。
> 规则：**拒绝**的条目在出现新证据前保持拒绝，不反复重评；**吸收**的条目在回归证明它错之前保持吸收；**观察**是未决，要写清缺什么证据才能定。
> 与 progress.md 的分工：这里只记「机制 → 判定 → 落点」，取舍理由与过程进 progress.md 的 Decisions。
> 本文件不进分发包（make-release.sh 只打 `.claude/` 与安装器），是框架自己的维护记录。

## 摸底记录

| 日期 | 仓 | 基准 | 方式 |
|---|---|---|---|
| 2026-09-04 | deepseek-base（`/mnt/d/code/deepseek-base`） | HEAD `ea0d815`，2026-07-31 后 57 个 commit | Explore 只读 + 主 Agent 对每条指控在 cc-base 源码逐一核实 |
| 2026-09-04 | codex-base（`~/code/codex-base`） | HEAD `f4e8790`，v3→v4→v5 共 12 个 commit | 同上 |

## 他们对 cc-base 的判定，以及核实结果

deepseek-base 的 `docs/CROSS-POLLINATION.md:40-58` 把 cc-base 定性为「a deliberate dsh fork」，给了六条拒绝/指控；codex-base 的 `docs/CROSS-POLLINATION.md:13,20-32,94` 另给了五条。逐条在本仓核过，属实的记属实，不属实的写出反证。

| 指控 | 核实 | 处置 |
|---|---|---|
| 全 SKIPPED 聚合成 PASS（dsh :58；codex :26「skip 假绿」） | **属实**。`quality.mjs:340` 注释明写 `PASS or all-SKIPPED -> 0`；`evidence.mjs:444` 只把它当 reason 字符串 `every-check-skipped`，退出码照 0。本仓 `dod` / `release` 早就是「什么都没建立 = rc 3 不是 0」（`release.mjs:550`），只有 `verify` / `gate` 没对齐 | 吸收（本轮）：all-SKIPPED → rc 3 降级，与 dod / release 口径一致；不照 dsh 做成 BLOCK，本仓退出码契约里 3 就是「没建立」 |
| waiver 把跑过的 FAIL 改写成 SKIPPED（dsh :57） | **属实**，且 progress.md 早记为 `[P1][OPEN][#20b]`，推迟原因是它改既有 `verify` 行为、会让 golden 重录差异不可解释 | 吸收（排期）：dsh 的 `waivePlan` 形态（跑之前解析 waiver、跑过的结果不可变）可直接参照，独立成批 |
| 作者≠评审「只建了一半，真实 session 里 authorshipEnforced 恒 false」（dsh :54） | **属实**。`review.mjs:18` 写明台账为空就 `enforced:false`；全仓 hooks / scripts / agents / skills **没有任何一处调用 `authorship record`**，台账永远是空的 | 观察：要么给 SubagentStop 接线自动记作者（先查官方 hook 输入里有没有 agent 身份字段），要么在 rules 里如实写「大仓启用后由主 Agent 派单时手动 record」。缺的证据：hook 输入 schema |
| `bypassPermissions` 默认 + 密钥守卫 fail-open（dsh :56） | 前半是用户明确决定（progress Pinned「权限永不询问」，只跳工具权限提示，框架 guard hook 照跑）；后半**部分属实**：`secret-exfil-guard.sh` 用 `set -euo pipefail`，脚本内部出错会以 rc 1 退出，PreToolUse 的 rc 1 是「非阻断错误、工具照跑」 | 前半拒绝（用户决策）。后半观察：改成任何内部错误都 exit 2 会把「hook 自己有 bug」变成「所有 Bash 被拦」，可能砖机，需要用户拍板；stop-gate 的三振熔断是可参照的缓冲 |
| auto-push / kill-dev-ports 违反最小副作用（dsh :55；codex :94） | 两个 hook 都挂着（`settings.json:88,125`）。auto-push 只在 `git commit` 后、本地领先上游时静默 push，fast-mode 下停用 | 拒绝：这是用户有意设计的「提交即推送」，本仓 CI 靠它每批必跑；代价是每次 commit 都是对外动作，主 Agent 只在验证齐全后 commit |
| `.needs-review` 登记簿已被 diff-bound receipt 取代；三文件同步 Stop 硬闸误报多（codex :94） | 本仓两者并存：登记簿是无 catalog 时的轻量闸，receipt 是大仓启用后的闸；三文件闸按工作树实际未提交改动拦 | 拒绝：轻量项目没有 catalog，登记簿是唯一闸；误报率由 `gate-audit` 数据说话，不凭感觉删 |
| TDD 软提醒 hook 是提示噪音（codex :94） | 属实是软提醒（`tdd-gate.sh` 只出提醒不拦） | 拒绝：red-locks 铁律的机器提醒，删了就只剩自觉；同样交给 gate-audit 数据 |
| live-tree manifest 漂移——清单从工作树生成、工作树脏时清单带脏（codex :13,31） | **部分属实**。`gen-manifest.sh` 确从工作树生成；但 `release` 的 manifest 项会比对，脏了会 FAIL 而不是静默过 | 观察：codex 的对策是安装事务启动前重建分发面并与 source manifest 逐字比对，随安装器事务化一起看 |
| spec trace「截断仍可成功」（codex :27） | **属实**。`spec.mjs:482` 的退出码只看 `r.ok`，`truncated` 只是回显字段 | 吸收（本轮）：truncated → rc 3，坏测量不许读成通过 |
| shell-string gate（用 `sh -c` 跑未结构化的验证串）不得复制（codex :13,41） | 本仓 check 的 `cmd` 确实是字符串交 shell 执行 | 观察：改成 argv 数组是 catalog schema 变更，影响所有已有 catalog；先记着 |

## deepseek-base 机制表

| 机制 | 它在哪 | cc-base 现状 | 判定 | 落点 |
|---|---|---|---|---|
| 不可读 receipt fail-closed + 隔离（改名 `*.corrupt-<ts>` + `state/quarantine.jsonl`，verdict 判红，返回体列 `unreadable`） | `.dsh/base/lib/quality.mjs:514`、`core.mjs:390` | `quality.mjs:108` `catch { /* skip bad file */ }`——手改一个回执成非法 JSON 它就凭空消失 | **吸收（本轮）** | `core.mjs` 新增 `quarantine()`，`loadReceipts` 返回 `unreadable[]`，`receipt verify` 有 unreadable 即 STALE |
| `quarantine()` 通用原语：受损运行态（task / fast-mode / review session / waiver）不静默重建也不静默保留 | `core.mjs:390-406`，接线四处 | 全仓无 quarantine 概念；ledger 层有 `{corrupt:true,raw}` 保留，运行态 state 仍 `catch → null` | **吸收（本轮）** | 同上，`risk` 加 `QUARANTINED_STATE` |
| supervisor 受损 state fail-visible（读成 `{corrupt:true}`、status 报 corrupt 且 exit 1，防第二个 supervisor 接管同一子进程） | `.dsh/base/supervisor.mjs:53-63` | `scripts/supervisor.mjs:61-62` `catch → null`，`:247` 的「already running」判定建在这个 null 上 | **吸收（本轮）** | `supervisor.mjs` 单文件 |
| arch-trend 坏行不丢：`corruptLines>0` 时 `--gate` 直接红（「有洞的历史分不清新债和忘掉的债」） | `graph.mjs:462-506` | gate-log 侧已有 `corruptLines`（`review.mjs:1129`）；`graph.mjs:407` 的 trend 仍 `skip bad line` | **吸收（本轮）** | `graph.mjs` 单点 |
| golden 突变尺子自动化：`MUTANTS.json` 声明式突变 + `--mutate` 报 killRate，exit 时全量还原、目标文件脏则拒跑 | `tests/golden/MUTANTS.json`、`tests/golden-baseline.mjs:321-369` | `harness-golden.mjs` 只有 `--record/--check/--probe`，「尺子能咬住」靠人工突变（2026-09-02 那次 29 条是手跑的） | **吸收（本轮）** | `harness-golden.mjs` 加 `--mutate` + 清单文件 |
| release 两条阻断：`gate-fresh`（存在一次绑定当前 diffHash 的完整 PASS gate，fast-mode 跑的不算）+ `review-depth`（lens 覆盖达发版底线） | `context.mjs:706-736` | `release.mjs:545` 七项里没有 gate；`dod` 十四步里也没有 gate / verify | **吸收（本轮）gate-fresh；review-depth 观察**（本仓 lens 模型是 backlog 保护集，不是覆盖底线，先不硬套） | `release.mjs` 加一项 |
| Windows 包管理器 shim 发现（`where` 找不到时扫 WinGet / scoop / chocolatey，命中则前置注入 PATH 而非判 BLOCKED） | `quality.mjs:43-120` | 无 | **吸收（本轮）** | `quality.mjs` 的 `whichCmd` 侧 |
| doctor 分发完整性全量比对、spawn 独立审计脚本 | `context.mjs:156-183` | `doctor.sh:104` 只从清单**前 20 行随机抽 3 个** | **吸收（本轮）** | `doctor.sh` 改全量 |
| waiver 前置声明 `waivePlan`（跑之前解析，命中即 SKIPPED 不执行；受保护 check 照跑并计 `waiversBlocked`） | `quality.mjs:221-240` | 即 #20b | **吸收（排期）** | 独立批，含 golden 重录 |
| 跨仓借鉴台账（absorbed / adapted / rejected / watching 四态，拒绝也留痕） | `docs/CROSS-POLLINATION.md` | 无，结论散在 progress.md | **吸收（本轮）** | 本文件 |
| 运行时表跨表契约测试（指纹排除表 ↔ pack 拒绝表穷举双向迭代） | `tests/table-consistency.test.mjs` | 四份排除表已有 `test-setup.sh ⑥` 表范围比对 + 行为锁 | 拒绝：等价物已有，形态不同 | — |
| `url-userinfo` 密钥模式（`http(s)://user:pass@host`） | `audit/scan-secrets.mjs:30` | 15 条模式里没这条 | **吸收（本轮）** | `scan-secrets.mjs` 加一条 + 一对正反用例 |
| `run-tests.mjs` 版本安全启动器、零文件 exit 3 | `audit/run-tests.mjs` | CI 矩阵 22/24 无 Node 20 | 拒绝：不需要；「零文件 = 什么都没证明」语义本仓 run-all 已有 | — |
| 强制 PowerShell 7（`#requires -Version 7.0`） | `setup.ps1:1-16` | Pinned 明写兼容 5.1，28 条 ps1 行为断言锁 5.1 语义 | 拒绝：与 Pinned 冲突；#30 记着 5.1 无机器可验，是承认缺口不是放弃兼容 | — |
| macOS CI 格 / actions v7 / gitleaks+semgrep 独立 job / 覆盖率 advisory 格 | `.github/workflows/gate.yml` | Decisions 2026-09-03 明确不做 macOS 格与 SHA pin | 拒绝 macOS 与 pin；gitleaks / semgrep 观察（本仓 adapters 表已能按属性接外部扫描器，CI 侧加不加看 gate-audit 数据） | — |
| 窗口绑定豁免 / rules-audit 分类 / per-edge 棘轮 / review-pack 删除段 / 突变尺子 / supervisor | 它的 :46-52 自认从 cc-base 吸收 | 本仓原创 | 不回收 | — |

## codex-base 机制表

| 机制 | 它在哪 | cc-base 现状 | 判定 | 落点 |
|---|---|---|---|---|
| 事务式安装器：零写 dry-run → 独占锁 + maintenance marker → 全量 staging + backup 各自 post-hash → `link()` 不覆盖落地 → 依赖序 apply、manifest 最后写 → 逆序回滚且回滚自身 CAS → 失败留证不留残、后续命令 fail-closed；`*_FAIL_AFTER=N` 故障注入让回滚路径可测 | `scripts/lib/installer.mjs`（1068 行）、`files.mjs` | `setup.sh:26-90` 逐文件顺序 `cp`，中途失败留一半新一半旧；无 dry-run、无锁、无 marker、无回滚 | **吸收（排期）最小切片**：`--dry-run` 零写 + 锁 + marker + doctor/hook 见 marker 即拒；完整 staging/回滚是大改，等切片跑稳 | `setup.sh` / `setup.ps1` 成对 + `doctor.sh` |
| `readiness check` 只读聚合 + **信任边界四个硬 false 字段**（`producerIdentityAuthenticated / ciProvenanceVerified / externalSignatureVerified / releaseAuthorized` 必须为 false，否则候选证明非法）+ 每个 blocked gate 带 `nextAction` + release 强制 clean worktree 与显式 `base..HEAD` | `.codex/runtime/lib/readiness.mjs:81-89,120-122,150` | `release` 已是只读聚合、blocker 已带下一步命令；缺信任边界字段 | **吸收（本轮）信任边界字段**；range 绑定观察 | `release.mjs` 输出加 `trustBoundary` 块 |
| Assurance profile 四档 + 15 控制轴 + floors 只抬不降 + 单调性静态校验 + `floors.paths` 治理面自动升 strict | `.codex/harness/assurance-policy.json`、`assurance.mjs` | 五性档位是「模块属性多重要」，fast-mode 是布尔；没有统一工作流档位 | 完整档位拒绝（本仓刻意轻量，见 Decisions 2026-06-14 / 07-30）；**吸收（本轮）治理面自动升档**：改 `.claude/hooks|harness|skills|agents/**`、`.github/**` 时 `risk` 抬到 high 并点名 | `evidence.mjs` 的 risk |
| Rapid evidence loan + 持久 evidence debt（关窗不清债；只有债务产生**之后**的 fresh PASS 才算偿还；DEFERRED ≠ PASS ≠ SKIPPED） | `rapid.mjs`、`debt.mjs` | 有 `FAST_MODE_DEBT` / `FAST_MODE_OPEN` 两个 risk finding | 观察：要核本仓关窗后债务是否还在、偿还是否要求债后 fresh PASS；缺的证据是一次实跑 | — |
| 显式 requirement-trace 文件（REQ → paths + checks → fresh PASS），spec lint 只认 fence 外 heading | `.codex/harness/requirement-trace.json`、`spec.mjs:355-442` | `trace` 是启发式推断；截断仍报成功 | 截断 → rc 3 **吸收（本轮）**；显式 trace 文件观察（多一份要手工维护的映射表，轻量项目未必划算） | `spec.mjs` |
| Review v2：三阶段固定序、UNABLE 必须结构化、前序失败阻断后续 APPROVE、范围不可自缩、`reviewer.claim` 只是自报 | `reviews.mjs:168-207` | `review` 有 lens / backlog / 轮次上限 | 观察：值得抄的是「UNABLE 必须结构化」与「范围不可自缩」两条约束，等 review 引擎下次动时一起 | — |
| Rule registry：闸门声明 `enforcement / bindings / gateKinds`，静态可达 + 运行时命中双向审计，死闸机器可见 | `rule-registry.json`、`guard-registry.mjs`、`audit.mjs` | `rules-audit` + `gate-audit` 各管一半 | 观察：本仓「闸靠数据留」已有 gate-audit；把二十余个 hook 登记进表再和 gate log 对上是中等改动，先看 gate-audit 能否直接扩 | — |
| runtime 树哈希进证据身份（harness 自己改了 → 旧 receipt 自动失效） | `identity.mjs:63-89` | receipt 绑 diffHash / contentHash，不绑引擎版本 | **吸收（本轮）** | `quality.mjs` receipt 加 `engineHash`，verify 时不等即 STALE |
| 受管路径安全边界：逐段拒 symlink / `..` / NFC 不定形 / Windows 保留名 / 尾点尾空格，NFC+lowercase 碰撞检测 | `files.mjs:86-142` | `setup.sh:19-23` `validate_target` 只查 `..` | **吸收（本轮）** | `setup.sh` / `setup.ps1` 的 `validate_target` |
| `pack-check` 分发面双向闭包（missing / unexpected / forbidden / duplicates） | `scripts/codex-base.mjs:138-181` | `release` 的 manifest 项 + `test-release-manifest.sh` 已是双向 | 拒绝：等价物已有 | — |
| hook 引导 fail-closed + 崩溃进 gate log + Stop 事件查 `stop_hook_active` 防死循环 | `bootstrap.mjs:26-63,195-243` | 契约外退出码已 block 并点名；三振熔断已有 | 拒绝：等价物已有；`stop_hook_active` 本仓 stop-gate 用 strikes 文件承担同一职责 | — |
| `never` 模式下 `prompt` 即死锁 → 无应答通道的闸不是保护是死锁 | `b547f30`、ADR-0005 | 本仓 headless / CI 下 hook 的 block 路径没专门审过 | 观察：#10 headless 烟囱测试做了才有证据 | — |
| PermissionRequest 精确 argv 放行 | `config.toml:55-63` | 本仓 `bypassPermissions`，不走 PermissionRequest | 拒绝：前提不成立 | — |
| Codex 原生面（execpolicy Starlark / `[auto_review]` / `codex exec --output-schema` / `/hooks` 信任哈希） | — | — | 拒绝：平台特有 | — |

## 本轮吸收批次

按落地顺序，每批 tester 造红 → implementer 修绿 → code-reviewer 复审 → commit（本仓 commit 即 push、即触发 CI）。commit 落定后回填。

| 批 | 内容 | commit |
|---|---|---|
| 0 | 审查清单挂账 #31 `.runtime` pathspec 裸奔 / #32 软链路径 / #33 DENY 注释（连同本台账首版、feedback 索引重建） | `f3cd449` |
| 1 | 「读不出来 ≠ 不存在」：留痕原语、receipt 不可读 fail-closed、supervisor 坏 state fail-visible、arch-trend 坏行判红、verify all-SKIPPED → rc 3、trace 截断 → rc 3；第二轮把目录级 / 权限级 I/O 失败也收进来（只有 ENOENT 算不存在） | `66f7725` |
| 2 | golden `--mutate` + `MUTANTS.json`（13 条，本仓 13/13 killed） | `c60ea14` |
| 3 | 发版与证据绑定：release `gate-fresh` 项 + 信任边界字段、receipt 绑 `engineHash`、治理面改动 risk 告警、shim 发现 | `c60ea14` |
| 4 | 小修：doctor 清单全量比对、`url-userinfo` 密钥模式、static-check 补 `node --check`（shim 与 validate_target 分别并入批 3 / 批 5） | `c60ea14` |
| 5 | 安装器事务化最小切片（dry-run + 锁 + marker + 路径边界，.sh/.ps1 成对） | `c60ea14` |
| 6 | `.claude/worktrees/` 进六份排除表——本轮并行时发现 Claude Code 隔离副本会被当框架文件登记与安装 | `c60ea14` |
