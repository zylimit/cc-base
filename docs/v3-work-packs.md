# v3 施工底本（各 Phase 派单包共用上下文）

> 配合 `docs/v3-tiered-harness-proposal.md`。提案讲为什么，本文讲怎么切、判据是什么。每个派单包只引用本文对应 Phase 一节 + 盘点文件，不复述。
> 分支 `feat/v3-tiered`；顺序 D → A → B → C → E。收口闸每 Phase 一样：selftest 全绿 + golden `--check` 零差异（或差异逐条归因后重录）+ run-all 全绿 + 本 Phase 新增测试 + 每条新闸同批一条反向验证。

---

## Phase D：hook 单运行时（25 对 .sh/.ps1 → 25 个 .mjs）

### D.0 已核实的宿主事实（2026-09-05，code.claude.com/docs/en/hooks）

- hook 有 **exec form**：`{"type":"command","command":"node","args":["${CLAUDE_PROJECT_DIR}/.claude/hooks/x.mjs"],"timeout":N}`。`args` 存在即不经 shell，占位符按纯字符串代入 `command` 与 `args` 每个元素；`timeout` / `matcher` 与 shell form 完全一样。
- 占位符**只认花括号**：`${CLAUDE_PROJECT_DIR}` / `${CLAUDE_PLUGIN_ROOT}` / `${CLAUDE_PLUGIN_DATA}`；三者同时作为环境变量导出给子进程，脚本内 `process.env.CLAUDE_PROJECT_DIR` 可读。
- Windows 上 `node.exe` 是真可执行文件，exec form 直接 spawn；`.cmd/.bat` shim 不行。官方原话：「The `node` plus script-path pattern works on every platform」。
- **statusLine 没有 exec form**，只有 shell form；Windows 装了 Git Bash 走 Git Bash，没装走 PowerShell。路径要写正斜杠。stdin JSON 带 `workspace.project_dir`。
- 本机 node v24.14.1；CI 矩阵 node 22 / 24 × ubuntu / windows；`.ps1 (windows)` 格另跑 Parser + `test-ps1-behavior.ps1`。

### D.1 目标状态

| 面 | 现在 | 改后 |
|---|---|---|
| `.claude/hooks/` | **22 对** hook `.sh/.ps1` + 3 对 `lib-*.sh/.ps1` + `feedback-signals.txt`（盘点校正：不是 25 个 hook） | 22 个 `<同名>.mjs` + `lib/{io,gatelog,fastmode,harness}.mjs` + `feedback-signals.txt`；`.sh/.ps1` 全部删除。settings.json 注册 21 个，`static-check.mjs` 不注册、由 code-review Stage 0 手调 |
| `.claude/settings.json` 21 条 hook | `"command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/x.sh"` | `"command":"node","args":["${CLAUDE_PROJECT_DIR}/.claude/hooks/x.mjs"]`，两平台逐字相同，timeout 值不变 |
| `statusLine` | `statusline.sh` / `.ps1` | `.claude/scripts/statusline.mjs`；settings 里 `"command":"node \"$CLAUDE_PROJECT_DIR/.claude/scripts/statusline.mjs\""`（shell form，正斜杠） |
| `setup.ps1` 的 `.sh→.ps1` 改写段 | 逐条把 hook command 改写成 `powershell -File …ps1` | **整段删除**；只保留一处：纯 PowerShell 环境把 statusLine 改成 `node "$env:CLAUDE_PROJECT_DIR/.claude/scripts/statusline.mjs"` |
| `fix-platform.sh/.ps1` | 删异平台 hook 残留 + 改写 statusline | 只剩「删历史遗留的 `.sh/.ps1` hook 文件」这一件（升级老安装用），其余逻辑删 |
| `doctor.sh` | 查 `.sh` hook 存在 / 可执行 | 查 `.mjs` 存在 + `node --check` 通过 + settings 里每条 hook 的 `args[0]` 指向的文件存在；另查 `claude --version` ≥ 支持 exec form 的版本（拿不到版本只 note 不 ✗） |
| 测试 | `test-hook-failopen.sh` 28 条 + `test-ps1-behavior.ps1` 28 条 + `test-hook-parity.sh` + `test-fix-platform.sh` | `test-hooks-node.sh`：每个 hook 喂 stdin 夹具、断言 stdout JSON / 退出码 / 状态文件副作用，**Linux 与 Windows（Git Bash + node）同一份**；`test-hook-parity` 改为断言 settings 里零 `.sh/.ps1` 命令且每条 `args[0]` 文件存在；`test-ps1-behavior.ps1` 缩到只测 `setup.ps1` / `fast-mode.ps1` / `fix-platform.ps1` |
| CI `ps1 (windows)` 格 | Parser 27 个 .ps1 + 行为 28 条 | Parser 只剩 `setup.ps1` / 三个 scripts；行为改跑 `test-hooks-node.sh` |
| Pinned「.ps1 纯 ASCII」 | 对 hook 与 scripts 都适用 | 只对剩下的 `.ps1`（`setup.ps1` / `fast-mode.ps1` / `fix-platform.ps1` / `install-githooks.ps1`）适用，hook 不再有 .ps1 |

### D.2 node 侧 lib 契约（与三个 shell lib 一一对应，行为不变）

```
hooks/lib/io.mjs
  readStdinJson()            // 读完 stdin，解析失败返回 null（不抛）；空输入返回 {}
  projectDir()               // process.env.CLAUDE_PROJECT_DIR，缺则 git rev-parse --show-toplevel，再缺则 process.cwd()
  emit(obj)                  // fs.writeSync(1, JSON.stringify(obj)+'\n')——必须同步写，禁 console.log 后 process.exit（管道下 stdout 异步会丢）
  say(text)                  // fs.writeSync(2, …)
  block(reason)              // emit({decision:'block', reason}) 且 exitCode 0（与现契约一致：block 靠 JSON 不靠退出码）
  runFailClosed(main, reason)// try { main() } catch → block(reason)；给 stop-gate / three-file-sync-gate / pre-commit-check / harness-async-verify 这类 fail-closed 闸
  runFailOpen(main)          // try { main() } catch → say 一行 + exit 0；给提醒类 hook
  git(args, {cwd})           // spawnSync('git', args, {shell:false})，返回 {status, stdout, stderr}
  toPosix(p)                 // 反斜杠→正斜杠（与 core.mjs 的 toPosixPath 同语义，但 hook 不 import 引擎）
hooks/lib/gatelog.mjs
  gateLog(hook, reason)      // 追加 `<ISO-UTC>\t<hook>\t<reason 首行>\n` 到 .claude/evidence/gate-block.log，任何错误吞掉返回
hooks/lib/fastmode.mjs       // Phase A 会被 tier.mjs 取代，D 里语义 = lib-fast-mode.sh
  fastModeActive()           // 读 .claude/.fast-mode，剥 \r，`expires_epoch=<n>` 且 n > now 才 true；缺文件/缺行/非数字/过期 → false
hooks/lib/harness.mjs        // 语义 = lib-harness.sh
  harnessEnabled()           // .claude/harness/module-catalog.json 存在
  harnessRun(argv)           // spawnSync(process.execPath, [harness.mjs, ...argv])——用当前 node 自身，不再 command -v
  rcInContract(rc, ...codes)
  errHead(stderr)            // 去空行取前 3 行拼一行截 400 字符
```

铁律：**hook 不 import `.claude/harness/lib/*`**——今天 22 个 hook 与引擎是进程级隔离（盘点 E4），`test-hook-failopen.sh:89-92` 造的故障形态正是「只有 `harness.mjs`、`lib/` 被删」，hook 必须还能起来并判出「引擎跑不成」。`core.mjs` 里 `repoRelative` / `withDirLock` / `readTextFile` 这些好用，但**只许在 `hooks/lib/` 里抄一份精简版**（各 ≤ 30 行），不许 import。锁用 `fs.openSync(lock,'wx')` 独占创建 + 过期回收，文件名仍是 `.needs-review.lock`（六份排除表都列着它，别改名）。需要引擎结论的 hook（stop-gate / pre-commit-check / harness-async-verify / record-authorship / postcompact-reinject）一律 `harnessRun` 子进程调用并按退出码契约分流，契约外退出码的处理照现有 `.sh` 逐字保留（三振熔断等）。

### D.3 逐 hook 移植规则

- 文件名 = 现 `.sh` 去后缀 + `.mjs`；头注释保留原 `.sh` 的中文说明（含历史坑），只把「与 .ps1 对齐」之类句子删掉。
- 行为以盘点文件 `docs/v3-phase-d-inventory.md` 的契约卡为准：stdin 字段、状态文件、外部命令、输出形态、退出码、fail-open/closed。两侧**本来就不等价的 9 处**（盘点 A'），取法已定，照做不再各自判断：

| hook | 取哪边 | 理由 |
|---|---|---|
| `check-evolution` TOTAL 计数 | `.sh` 的 `^- (✅\[已毕业\] )?\[` | 与 FEEDBACK-INDEX 实际格式对得上，`.ps1` 的「含 `](`」是近似 |
| `detect-feedback-signal` 触发词 | sidecar `feedback-signals.txt` 为唯一来源，**文件缺失时退回内置默认表**（不许像 `.ps1` 那样静默永不触发） | 用户可扩展 + 不因丢文件静默失效 |
| `subagent-acceptance-reminder` | `agent_type` 缺则回退 `subagent_type`（`.sh`） | `.ps1` 单边缺口 |
| `record-authorship` 路径含 `..` | 折叠后再判仓内（`.ps1`） | `.sh` 遇 `..` 直接不记是漏账 |
| `mark-review-needed` 路径 | 折叠（`path.resolve` 语义）+ 存在时 `fs.realpathSync.native` 展开 8.3 短名 + `.sh` 的 stderr 诊断 | 两侧各修了一半 |
| `session-rules-banner` fast-mode 提示 | 一句话同时给两种命令：`bash .claude/scripts/fast-mode.sh off`（Windows 纯 PowerShell：`pwsh .claude/scripts/fast-mode.ps1 off`） | 平台中立 |
| `pre-commit-check` Python 分支 | `.ps1` 的形态：探 `python3` → `python` → `py -3`、校验 `--version` 含 `Python 3`、逐文件 `py_compile`、**只有输出含 `SyntaxError` 才拦**，其余非零降级跳过 | 挡 Microsoft Store stub + 命令行长度 |
| `stop-gate` 清单指纹 | node `crypto` sha256 | 只是 strike 文件内部键，两侧本就各算各的 |
| `kill-dev-ports` / `notify` / `dangerous-pkill-guard` | 按 `process.platform` 分支，各保留原平台工具 | 真平台差异 |
- 平台分支只在真需要的地方：`notify`（notify-send / osascript / PowerShell toast）、`kill-dev-ports`（lsof / netstat）、`static-check`（工具探测）、`dangerous-pkill-guard`（`pkill` vs `taskkill` 形态）。其余零 `process.platform` 判断。
- 所有外部命令 `spawnSync(cmd, argv, {shell:false})`；禁 `shell:true`、禁字符串拼命令。
- 输出只走 `emit` / `say`；退出码只设 `process.exitCode`，最后自然退出；唯一例外是 `runFailClosed` 里 catch 分支。
- 状态文件写入用 `writeFileSync` + LF；读取一律先剥 `\r`。
- `feedback-signals.txt` 不动，`detect-feedback-signal.mjs` 照读。

### D.4 分批与派单（串行，同一 implementer 不跨批）

| 批 | 内容 | 判据 |
|---|---|---|
| D-T | **tester 先造红**：写 `test-hooks-node.sh`——每个 hook ≥3 条（正常放行 / 触发拦停或提醒 / 输入损坏时的 fail-open 或 fail-closed），从盘点契约卡与现有 56 条断言移植；`.mjs` 尚不存在 → 全红。另写 `test-hook-parity.sh` 新版（settings 零 `.sh/.ps1` + `args[0]` 存在）。主 Agent 亲验红 | 红数 ≥ 75，红因是「文件不存在」而非测试自身语法错 |
| D-1 | `lib/` 四件 + 12 个简单 hook：notify / check-evolution / session-rules-banner / recap-on-dirty / subagent-acceptance-reminder / detect-feedback-signal / release-gate / precompact-gate / postcompact-reinject / tdd-gate / no-direct-code-guard / auto-push | 对应测试转绿；不动 settings.json、不删 `.sh/.ps1` |
| D-2 | 8 个状态与守卫 hook：dangerous-pkill-guard / secret-exfil-guard / mark-review-needed / record-authorship / kill-dev-ports / static-check / harness-async-verify / pre-commit-check | 对应测试转绿；不动 settings.json、不删 `.sh/.ps1` |
| D-3 | 最重两件 stop-gate / three-file-sync-gate + `statusline.mjs` + **D.6 全部触点**（settings 切换、安装器、fix-platform、doctor、gate-audit、既有测试改造、删 `.sh/.ps1` hook 与 lib、manifest 重生、CI `ps1` 格、docs / Pinned 措辞） | 全部测试绿；`setup.sh` 装到临时目录后 settings 里零 `.sh`；`doctor` 通过；run-all 全绿 |
| D-R | code-reviewer 三阶段（Stage 0 `node --check` 全部 .mjs + shellcheck 剩余 .sh；Stage 1 对照盘点契约卡逐 hook 核；Stage 2 质量）；FIX_REQUIRED 回 implementer 从 Stage 0 重审 | PASS |
| D-V | 反向验证：随机挑 5 个 hook 各注入一处缺陷（改退出码 / 删状态文件写入 / 改 JSON 字段名），`test-hooks-node.sh` 必须各红 | 5/5 抓住 |

每批派单包六字段照 CLAUDE.md；Existing Pattern 指向本文 D.2 / D.3 与盘点文件；Out of Scope 明写「不动引擎 `.claude/harness/lib/`、不动 `.claude/scripts/fast-mode.*`、不做 Phase A 的档位」。

### D.6 全部触点（盘点 C 段，D-3 逐条清）

| 触点 | 位置 | 改法 |
|---|---|---|
| `settings.json` 21 条 hook + statusLine | `:29,38,50,…,140` | hook 改 exec form；statusLine 改 `node "$CLAUDE_PROJECT_DIR/.claude/scripts/statusline.mjs"` |
| `setup.ps1` 改写段 | `:303-340`（`Convert-ToPs1Command`、timeout 强制 30）、`:6` 头注释、`:362-383` `Test-IsShResidue`/`Remove-ShResidue`、`:455-457` `ps1_hooks=` 计数 | 改写段只留 statusLine 一条（`node "$env:CLAUDE_PROJECT_DIR/.claude/scripts/statusline.mjs"`），残留清理改为「删 `hooks/*.sh|*.ps1` 与 `lib-*`」，计数改 `mjs_hooks=`（`test-installer-parity.ps1:210,214` 断言这两行文本，同步改） |
| `setup.sh` | `:295` 执行位只发给 `hooks/*.sh`、`:346-348` `is_ps1_residue`、`:470-481` 计数与收尾文案 | 执行位段删；残留判定改「hook 目录里的 `.sh/.ps1`」；计数 `hooks=`（数 `.mjs`）；文案去掉「需 Git Bash」 |
| `fix-platform.sh/.ps1` | 整个文件 | 缩到「删 `hooks/` 下历史 `.sh/.ps1` + statusLine 归一 + `scripts/*.sh` chmod」 |
| `doctor.sh` | `:53-58` 执行位、`:61-62` 硬点名 `lib-harness.sh` 与 `.ps1` | 改「每个 `hooks/*.mjs` 过 `node --check`」+「settings 每条 `args[0]` 指向文件存在」+ 硬点名改 `hooks/lib/harness.mjs` |
| `gate-audit.sh` | `:27-29` 从 `hooks/*.sh` grep `lib-gate-log` 现算注册清单 | 改 `hooks/*.mjs` grep `gatelog` |
| `test-gate-audit.sh` | `:29-33` 遍历 `hooks/*.sh` + 双栖探测 | 同上改 `.mjs` + 探 `args` |
| `test-hook-parity.sh` | 全文 | 重写：settings 零 `.sh/.ps1`、每条 `args[0]` 存在、`command == "node"` |
| `test-hook-failopen.sh` | 28 条 | 移进 `test-hooks-node.sh` 的 stop-gate / pre-commit-check 组，故障形态照旧（删 `harness/lib/`） |
| `test-ps1-behavior.ps1` | 组 0 保留（扫剩余 `.ps1` 纯 ASCII）；A–E 组删（已由 node 测试覆盖）；F 组（fast-mode.ps1）保留 | rc 契约不变 |
| `test-fix-platform.sh` | fixture 造 `.sh/.ps1` 残留 | 改造成「装了旧版残留后 fix-platform 清干净、`.mjs` 齐全」 |
| `test-setup.sh` | `:36-37` 硬点名 lib 两份、`:52-58` 执行位 | 改 `.mjs` 与 `hooks/lib/harness.mjs` |
| `test-installer-parity.ps1` | `:275,279` 用 `hooks/notify.ps1` 当扰动点 | 改用 `hooks/notify.mjs` |
| `test-fast-mode.sh` | `:26-27` 拷 `tdd-gate.sh` + lib 进临时根、`:101/109` mv 走 lib 造「lib 缺失」 | 改拷 `tdd-gate.mjs` + `hooks/lib/`；「lib 缺失 fail-closed」改为删 `hooks/lib/fastmode.mjs` 后 hook 仍 exit 0 且走严格 |
| `test-three-file-sync-gate.sh` | `:13-14` `[ -x "$HOOK" ]` | 改为 `node "$HOOK"` |
| `test-static-check.sh` | `:21,48` `bash "$CHECK"` | 改 `node` |
| `cases/run-all.sh` | `:41,86-87,191,206-214` | 挂 `test-hooks-node.sh`；`test-ps1-behavior.ps1` 仍在有 pwsh 时跑 |
| `.github/workflows/gate.yml` | `:263-344` `ps1` 格；`:8-10,164-172` 注释 | Parser 步保留（剩余 `.ps1`）；行为步改跑 `bash .claude/tests/test-hooks-node.sh`（windows runner 自带 Git Bash + node）；注释改 |
| `FRAMEWORK-MANIFEST.txt` | hooks 51 行 → 26 行 | `gen-manifest.sh` 重生 |
| `.claude/harness/audit/check-syntax.mjs` | `:4,31,228-231` 注释与三类分流 | `hooks/*.mjs` 归 `jsFiles`，注释改 |
| 文档 | `ARCHITECTURE.md:143-173,201`、`README.md:31,88,93-131,147`、`rules/file-structure.md:20`、`rules/harness-large-repo.md:10,81,82,169-173`、`rules/dev-workflow-details.md:127`、`CLAUDE.md:42,59,66,268`、`skills/code-review/SKILL.md:62`、`githooks/README.md:114,116` | 文件名 `.sh` → `.mjs`，删「双写 / 成对」段，`README` 双写机制节改成「单运行时」三行 |
| `progress.md` Pinned | `:7,8,13,16,18` | 措辞收窄到剩余 `.ps1`（D-3 落账时主 Agent 改） |

### D.5 已知必踩的坑（含盘点「最容易漏的 10 处」）

- `gate-audit.sh:27-29` 与 `test-gate-audit.sh:29-33` 从 `hooks/*.sh` 现算注册清单——不改会**静默空转不报错**。
- `doctor.sh:61-62` 硬点名 `lib-harness.ps1`，删了就 ✗。
- 执行位在 `setup.sh:295` / `fix-platform.sh:122-130` 发放、三处测试断言；`.mjs` 不需要，五处逻辑要一起拿掉。
- `.needs-review.lock`：`.sh` 用 flock 会创建它、`.ps1` 用 Mutex 不创建，两侧释放都去删它；node 版用独占创建，释放照删。
- `test-fast-mode.sh` 靠「hook 与 lib 同目录 dot-source」造 lib 缺失用例，`.mjs` 的 import 解析不同，红锁造法要重写。

- `stop-gate.ps1` 六处 `Remove-Item` 缺 `-Force` 曾让闸清不掉自己的状态——node 里 `rmSync(p, {force:true})`。
- fail-closed 闸的 `try/catch` 必须包住**全部**逻辑含 stdin 解析；fail-open 闸损坏输入时静默 exit 0。
- `three-file-sync-gate` 的 `git status --porcelain -z` 双段（R/C）解析要按 NUL 切，不能按行。
- `auto-push` 的触发正则（#37 刚修）与 `record-authorship` / `mark-review-needed` 的路径归一化（#49 刚修）逐字移植，别顺手「改进」。
- 管道 stdout 异步：hook 输出后不许 `process.exit()`，用 `fs.writeSync(1, …)`。
- Windows 上 `CLAUDE_PROJECT_DIR` 可能是 `C:\…` 反斜杠形态，所有回显路径先 `toPosix`。

---

## Phase A：档位（待 D 收口后写细则）

要点见提案 §三：`profile.json` 三档 + 闸门三态 + 地板 + `raise.paths`；`hooks/lib/fastmode.mjs` → `tier.mjs` 暴露 `gateMode(id)`；引擎 `tier` 子命令 status / set / explain / validate；`fast` 硬上限 8h；降档带 reason + expiry 进 gate log；`scripts/fast-mode.sh/.ps1` 变薄壳。

## Phase B / C / E：待排
