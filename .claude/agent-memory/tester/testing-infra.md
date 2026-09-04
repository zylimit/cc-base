---
name: cc-base-testing-infra
description: cc-base 的测试基建约定——bash 脚本式测试、PASS/FAIL 逐条、run-all 汇总，以及跑测前必须实测基线而非信任派单描述
metadata:
  type: project
---

cc-base 没有 pytest/vitest；测试全是 `.claude/tests/*.sh` 的 bash 脚本，`set -eu`，`pass()/fail()` 逐条计数，末尾 `==== <名>：PASS=n FAIL=m ====` + 非零退出，`cases/run-all.sh` 统一跑。新测试照这个形状写就能被收编。

**Why:** 交付物是 `.claude/` 编排配置本身，被测对象是 hook / mjs 脚本 / 退出码契约，没有语言运行时可挂测试框架。

**How to apply:**
- 断言辅助函数固定三件套：`run()` 回填 RC/OUT_JSON/OUT_HUMAN、`jval()` 用 node 取 JSON 字段、`has()` 包 grep。零外部依赖（只要 node + git），python3/pwsh 一律当可选增强。
- 每条断言打印 EXPECT / GOT，判定不依赖措辞——主 Agent 复核时只看这两行。
- 可变样例一律 `mktemp -d` 里新建 git 仓 + `trap` 清理，对本仓只读。
- **派单里写的基线数字要当场重测**：本仓有并行 sub-agent 持有文件，工作树会在任务中途变。实测过一次 `test-audit-scripts.sh` 从 rc1/PASS=37 FAIL=1 变成 rc0/PASS=38 FAIL=0，就是并行任务改了 harness.mjs。
- **沙箱里搬被测程序要按目录整拷、路径从入口推导**：harness.mjs 已拆库（import 同级 `lib/`），只 `cp` 单文件的夹具会 ERR_MODULE_NOT_FOUND，hook 拿不到契约退出码而假绿。写 `install_x()` 助手用 `dirname "$ENTRY"` 推 lib/ 路径整目录拷，别枚举模块名——后续 Phase 还会加模块。
- **给 pre-commit-check 写测必须先守 python3**：它靠 `python3 -c` 解析 PreToolUse JSON 取命令，缺 python3 时 CMD 为空、对任何输入直接 exit 0 放行——不守卫就是一整段假绿。同理 stop-gate 无 jq 时走硬编码兜底文案，「诊断必须含 X」类断言要 `command -v jq` 守卫。
- **run-all.sh 第二段有红就进不了第三段**：机制是 `STATIC_RC` 累加（整段跑完再停），不是撞见第一条红就跳出——所以日志里后面那些 PASS 是真跑过的，别误读成没执行。红锁在库期间整仓 run-all 必然停在这里。挂新脚本进第二段要照 golden / audit 块加 `command -v node` 守卫——这些脚本无 node 时是 `exit 1` 而非 SKIPPED，裸塞 for 循环会在没装 node 的机器上报假红。
- **整仓 run-all 红了先归因再背锅**：并行 agent 的在制品会把不相干的段搞红（实测撞上 `harness/lib/**` + golden 基线改到一半，`test-harness` 与 `harness-golden` 双红，与我改的测试无关）。归因手法是 `git archive <HEAD> | tar -x -C /tmp/pristine`（对本仓纯只读，不用 stash / worktree，不惊动并行 agent）+ `git init` 后在干净树上重跑那两段；干净树绿 = 红出自工作树在制品。再把自己的改动单独覆盖进干净树跑一遍整仓，就能给出「我这份不背这个红」的硬证据。
- **本机跑整仓 run-all 要按 15 分钟以上算**：这台机器装了 `claude` CLI，第三段「真触发 cases」会真起 `claude -p`（每个 case 最长 300s，共三个），CI 上那句 SKIPPED 在本地不成立。别拿默认 timeout 直接跑，用后台任务 + 日志轮询，否则超时被杀还得回头清残留进程。
- **`spawn(cmd,{shell:true})` 起的是 `sh -c "cmd"`，本机 /bin/sh 是 dash，对单条简单命令也**不 exec**，真负载是它 fork 的孙进程**。所以「杀子进程」类夹具只 `kill -9 <child.pid>` 会把孙进程孤儿化残留（在这台机器上实测复现）。detached spawn 的 pgid == child.pid，所以 `kill -9 -<child.pid>` 整组杀就够；顺带这个等式也让「拿记录下的 childPid 当 pgid 查残留」成为精确的泄漏检测，不误伤并发跑的其它测试。
- **`pgrep -af '<模式>'` 会匹配到发起它的那层 bash 自己的命令行**（cmdline 里含该字面量）。拿它当「无残留」证据会被自匹配骗；要么 `ps -eo pid,args= | awk '$2=="sleep" && $3=="300"'` 精确判，要么明说那条命中是自匹配。
- **给 harness 子命令做端到端隔离：`projectRoot()` = `CLAUDE_PROJECT_DIR || cwd`**，所以 `cd` 进 mktemp 的 git 仓 + `env -u CLAUDE_PROJECT_DIR node <本仓>/harness.mjs <子命令>` 就能拿真引擎跑假仓，对本仓纯只读。沙箱里 `release`（含它 spawn 的 `dod`）一趟 ~1.4s，逐类造文件跑十几趟也才 25s——比拿单元函数凑合值得多。
- **`release` 的 findings 名单被 `capped()` 截断（超限只留前 N + "... k more"）**：拿「点名里有 X」当判据的对照断言，必须先把别的干扰文件清场，否则规则真坏了时 X 被挤出名单，红因会错判成「对照没红」。计数则不被截断，`unlisted` 一律从 summary 的 `(\d+) unlisted` 取，别数 evidence 数组长度。
- **「同一张表抄三处」的规则（gen-manifest.sh 的 case / setup.sh copy_claude_tree / release.mjs MANIFEST_RULES）这样测**：沙箱里跑**真的** gen-manifest.sh 生成清单 → 再造运行态文件 → 断言 `release` 的 manifest 项仍 PASS；外加一条「带运行态文件重跑生成器，产物须逐字节不变」锁两侧不分叉。手搓清单只能证明 release 自洽，证不出它跟生成器一致，而分叉正是这批规则要防的事。
- **动 `.claude/tests/` 下的文件会让 FRAMEWORK-MANIFEST.txt 的 sha256 变陈**：清单由 `.claude/scripts/gen-manifest.sh` 生成，没有机器闸校验新鲜度（test-setup.sh 只验文件在、条目在），近期 commit 也是半数带半数不带。它决定 setup.sh 升级时「框架层 vs 项目私有层」的判定，改完在回执里点出来让主 Agent 决定要不要重生成。
- **给 harness 子命令补行为断言就挂 `cases/test-harness.sh`，不动 selftest.mjs**：那里已有 `install_harness()` 沙箱 + `pass/fail` 计数，加断言只涨它自己的 PASS 数，selftest 的 268 和 golden 的 20127 都不动，省掉 golden 重录。用 `node -e` 配 `ADRJSON=` 环境变量取 JSON 字段（本段已守过 node），别引 python3——㉔b/㉔c 那两处 python3 是历史遗留，不是本脚本的依赖基线。
- **改了 `.claude/tests/` 或 `.claude/agent-memory/` 下的文件，`FRAMEWORK-MANIFEST.txt` 里那条 sha256 立刻变陈**——两处都有条目（清单共 228 条带 sha），写自己的 agent memory 也会让清单变陈。`test-setup.sh` / `test-release-manifest.sh` 判的是条目在不在与排除表对不对，都不判新鲜度；没有机器闸，回执里点名让主 Agent 定夺要不要跑 gen-manifest.sh。
- **`doctor.sh` 的 manifest 那行是随机抽 3 个，别拿它当「清单新鲜」的证据**：同一棵工作树连跑 5 次实测出「✓ 抽验 3 个一致」和「! 1/3 不符」两种结果交替，rc 恒 0。我自己就被一次好签骗过，把它写进过回执。要数字就自己遍历清单逐条比 sha（228 条跑完不到一秒），别引用抽样那行。
- **`node <脚本> | tail -N` 之后取 `$?` 拿的是 tail 的退出码**，不是 node 的。踩过一次：拿它当「golden 在突变态下仍绿」的证据，实际 `harness-golden.mjs` 裸 `--strict` / 无参 / 错参一律 rc 2（用法错），真跑要 `--check --strict`。凡「命令 rc 是几」类证据一律 `${PIPESTATUS[0]}` 或干脆重定向到文件不接管道。
- **selftest / golden 不能靠「拷引擎到 /tmp 打补丁」验红**：`loadFx()` 按引擎位置往上找 `tests/fixtures/harness/`，副本跑起来是 `fixture load failed`。这两者的突变验证只能在仓内做——`cp` 备份 + `trap '...' EXIT INT TERM` 还原（trap 必须带 INT/TERM：本机跑一次 golden 超 120s 会被挪去后台，靠 trap 才保证还原），跑完 `sha256sum` 复核。带引擎路径入参的 .sh（如 test-release-manifest.sh）才走 /tmp 副本那条路。
- **CI 平台矩阵三者待遇不同**（gate.yml）：run-all 在 Windows 格 `if: runner.os != 'Windows'` 整段不跑；golden 在 Windows 按设计 SKIPPED（只接受 rc 3）；**selftest 两个平台都真跑**。所以断言落 `.sh` = 零 Windows 覆盖，落 `selftest.mjs` = 有 Windows 覆盖但要动 golden 的 tests 计数。选落点先想清要哪一边。
- **一张表有 N 条就把断言写成 N 条的循环，别只锁触发本次 finding 的那一条**：`STATE_EXCLUDE` 10 条 pathspec，最初只守住 `.runtime`，删掉其余 9 条中任意一条仍然全绿——同一缺陷类别留了 9 个同形缺口。扩成循环后逐条删验证：10 次变异每次都恰好 FAIL=2（force-add 形态 + once-tracked 形态）且各自点名自己那条。顺带一个易被 grep 骗到的点：`.needs-review` 是 `.needs-review.lock` 的子串，拿 `grep -c "$PAT"` 数「点名数」会把两条混起来，要真的把失败行打出来看是哪条才算数（实测确认 git 的无 magic pathspec 不会把 `.lock` 也排掉，两条互相独立）。
- **路径命名契约上，realpath 只该参与「判仓内仓外」，不该参与「回显」**：无条件两侧 realpath 修好了「软链传入的仓内路径」，却带进两个回退——仓内软链指向仓外时回显机器绝对路径（契约明文禁止的形态），仓内软链指向仓内时被解开成另一个名字（调用方探测的不是这个路径）。正解是「拼法优先、身份兜底」：入参拼法落在 root 拼法内就按拼法命名，拼法在外才两侧 realpath 用身份再判一次。写这类断言要七条一起摆（两条身份态 + 两条拼法态 + 三条防砖），单看任一条都推不出规则。
- **`core.mjs` 的 diff 指纹有两条互不相交的排除路径**：tracked 半边走 `canonicalDiff()` 里 `git diff HEAD -- ...STATE_EXCLUDE` 的 `:(exclude)` pathspec，untracked 半边走 `hashUntracked()` 的 `STATE_EXCLUDE_PREFIXES`（JS 前缀过滤，**不传 pathspec**）。造 untracked 文件只测到后者——删掉 pathspec 那半张表，selftest（268）、golden（20127 断言）、原有用例全绿。要测 pathspec 必须 `git add -f` 进索引，或提交后改内容。实测 `:(exclude)` 对 `ls-files --others` 是生效的，两张表是实现选择不是 git 限制。
- **selftest 里做端到端沙箱 lane 的成本比想象低**：`newGitRepo(roots,label)` + `commitFiles` + 一个自写的 `runIn(root,argv,stdin)`（spawn 真引擎、`CLAUDE_PROJECT_DIR=root`、回 `{code,out,err}`）就够把 receipt / task / review / waiver / trend / verify / gate / trace 全部按 CLI 行为层锁住，比拿纯函数凑合能测到调用点。helper 写在文件底部（函数声明会提升），lane 里直接用。
- **selftest 的 check 命令一律写 `process.execPath + ' --version'`，别写 `true` 或 `node`**：golden 把 PATH 钉成 git 目录 + /usr/bin:/bin，裸 `node` 在 hosted runner 上解析不到会变 BLOCKED 而不是 SKIPPED，`true` 在 Windows 又不存在——绝对路径两头都成立。fast-mode 的 SKIP 判定在 `whichCmd` **之后**，命令解析不到就永远走不到 SKIPPED 分支。
- **`.claude/FRAMEWORK-MANIFEST.txt` 在 `.claude/` 下，不在仓根**（我按仓根找过一次，find 不到就误报成「清单里没有条目」，差点把「变陈」写成「无条目」）。键是去掉 `.claude/` 前缀的相对路径 + TAB + sha256（内容先 `tr -d '\r'`）。`harness/lib/selftest.mjs` 和 `tests/test-supervisor.sh` 都在里面，改任一个清单当场变陈。
- **给 harness 造「便宜的截断场景」用 catalog 的 `maxTrackedPaths`**：`trackedFiles(cap)` 拿它切 `git ls-files`，写 `{"version":1,"maxTrackedPaths":1,...}` 的 side catalog 传 `--catalog`，两三个文件的沙箱仓就能让 `trace` / `catalog-lint` 报 `truncated:true`，不用造几万文件。注意 catalog 加载失败时 cap 回落成默认 10 万，对照组要确认 `truncated:false` 才算数。
- **测「读不出来」别只会 chmod 000：EISDIR / ENOTDIR 才是跨平台那一档**。把该是文件的路径造成目录（EISDIR）、该是目录的造成文件（ENOTDIR），不要权限、root 也挡得住、Windows 同义，所以断言主体放这儿；chmod 000 只当额外一档，用 `chmodCanDeny()` 现场探能力，挡不住就打可见 SKIP。selftest 的 runner 只有 pass/fail、**没有 skipped 计数**，跳过只能往 stderr 写（stdout 是 JSON）；`.sh` 那边可以自己加 SKIP 计数器——`run-all.sh` 只看退出码，不解析 `结果：PASS=…` 那行。
- **验「SKIP 分支真的会走」必须叠在候选修复之上跑**：红着的时候 lane 在前一条断言就抛了，根本走不到后面的 chmod 块，于是「只看到 1 条 SKIP 提示」会被误读成 skip 机制坏了。正解是「候选修复 + 模拟 win32/root」两个补丁一起打（`chmodCanDeny` 里插 `if (true) return false;`），全绿且 7 条 lane 各打一行 SKIP 才算证到。同一份模拟单独跑（不带修复）则证明另一半：Windows 上这些 lane 仍是真断言、不是空跑。
- **`task complete` 的全绿夹具比传说中便宜**：committed catalog（放仓内且提交，免得自己变成 untracked 改动面）+ `task start` 六字段信封（全是字符串，数组会被 `validateEnvelope` 判 missing）+ `gate`（不带 --changed，scopeSource 必须是 computed）+ `receipt write --verdict accept`，四步就能 rc 0 blockers[]。receipts/state 都在 STATE_EXCLUDE 里，中途加坏回执**不需要**再跑一次 gate。
- **`.claude/harness/receipts` 当成「文件」造 ENOTDIR 会改 diffHash**：排除表写的是 `receipts/**` 和前缀 `receipts/`，路径本身作为一个 untracked 文件不在里面。断言别去锁 diffHash，锁 state/note/unreadable 就好。
- **给 `spec` / `trace` 造截断场景时 catalog 要放到仓外**：放仓内它自己是个没人认领的 untracked 路径，impact 直接 degraded、`narrowed` 变 false，答案被第二个原因污染，断言就说不清是截断造成的。放 `mkdtemp` 的兄弟目录传 `--catalog` 绝对路径，`narrowed:true` 才干净——顺带对照组的 view 里也不会混进 "degraded" 这种会被模糊匹配蹭到的词。
- 相关：[[audit-scripts-fragile-zones]]、[[red-lock-test-writing]]、[[windows-gitbash-process-tests]]
- **worktree 隔离的 agent 跑不了 `pwsh`**：guard 一律拒（「runs pwsh in a plain command … cannot be shown not to run git」），换绝对路径、去掉重定向、`dangerouslyDisableSandbox` 都不行。所以在 worktree 里给 `.ps1` 写断言只能静态自查：`LC_ALL=C grep -n '[^\x00-\x7F]'` 验纯 ASCII、`grep -n '`[[:space:]]\+$'` 抓反引号续行后的尾空格（PS 的经典语法杀手）、grep 变量名确认不与既有代码撞车，再照抄同文件已有构造（`Chk` / `Get-InstalledList` / 两参 `Join-Path`）。回执里必须把「ps1 没跑过」写进 Not verified，让主 Agent 在主树补跑。
- **给 setup.sh 类安装器写路径 / 参数用例，源码树换一棵 mktemp 里的迷你树**：`validate_target` 跑在 `mkdir -p "$target"` 之前，与源码树规模无关；真树一趟 2.2s，5 个文件的迷你树近乎瞬时，四十几个用例才跑得起（⑥b 已有同款写法可抄）。整段 ⑦–⑩ 连真安装带迷你安装共 68 条断言，实测 35s。
- **doctor.sh 对「装出来的 target」恒 rc 1**：它把仓根 `make-release.sh` 当必查项，而那文件不进安装产物——所以任何「doctor 该报错」的断言在装出来的目标上都是偶然绿。造 target 时 `: >"$T/make-release.sh"` 补个 stub 才能把基线压到 rc 0，再验「中断后 doctor 转红」才有判别力（顺带：先完整装一遍再打断，别拿半空目录当靶子，否则一堆缺失文件也会撑红）。
- **`session-rules-banner.sh` 要喂 stdin**：`HOOK_INPUT=$(cat)` 会一直等，`printf '{"source":"startup"}' | env CLAUDE_PROJECT_DIR=... bash <hook>` 才跑得完；现有六条铁律横幅里不含「未完成 / interrupted / install.marker」，拿这些词做告警断言不会被原文蒙混（配一条无 marker 的对照组，期望值写死 0 命中）。
- **`/tmp/patch.py`、`/tmp/cand` 这类通用名会和并行 agent 撞车**：实测写完 `/tmp/patch2.py` 后被别的 agent 覆盖成了它自己的补丁脚本。临时脚本 / 沙箱一律带任务前缀或 `mktemp -d` 出来的目录名。
- **被测目标是「仓根 + .claude 整棵」的脚本（setup.sh / gen-manifest.sh）时，验「修得好」的办法是整仓 tar 到 /tmp 再打补丁**：这两个脚本的路径全从 `dirname $0/../..` 推，不吃入参，拷单文件必错位。`tar --exclude=.claude/worktrees --exclude=.git` 拷一份，在副本上打候选修复，跑 `/tmp/副本/.claude/tests/*.sh`——本仓零改动，还能顺手做「只修一份表」的部分修复变异，验对拍断言点名的是不是那份。
- **`.claude/worktrees/` 是 Claude Code sub-agent 隔离建出的整棵仓副本，且默认没被任何排除表挡住**（f3cd449 实测：进 manifest、被 release 判 unlisted、扰动 diff 指纹、被 setup.sh 装进目标）。给本仓造沙箱、算清单、比指纹时都要留意它；tar/find 类操作记得排除，否则会把并行 agent 的整棵工作树卷进去。
- **整拷 `.claude/` 进沙箱必须跳过 `worktrees/`**：主树里那层装着各并行 agent 的完整工作树，`cp -r` 会把整个仓复制 N 遍。在 agent 自己的 worktree 里跑感觉不到（那儿没有这层），一进主树就炸。同理 `gen-manifest.sh` 的排除表里也没有 `worktrees/*` 这条臂。
- **给「整树校验」类脚本（doctor 的 manifest 项）写测，清单一定要在沙箱里用真的 `gen-manifest.sh` 重生成**：仓里那份天然是陈的（改 tests/ 或 agent-memory/ 就陈，没有机器闸守新鲜度），沿用它会让「未篡改时不报」的控制断言变成随机红，把 implementer 送去修一个不存在的 bug。重生成后实测 232 条 0 处不符，基线才干净。
- **`doctor.sh` 的沙箱要补一个 `make-release.sh` 桩**：它只判 `-f`，但缺了它基线就 rc=1，「有不一致时 rc 非 0」那条断言当场失去分辨力（红得对但理由是假的）。凡是拿 rc 当判据的整树自检，先把基线跑成 rc=0 再说。
- **`command -v X >/dev/null && cmd && echo yes || echo no` 这种链式探测会误报「没装」**：中间任一环非 0 都落到 `|| echo no`。实测被它骗过一次——报了 shellcheck 未装，单独跑 `command -v shellcheck` 却是 `/usr/bin/shellcheck`。工具在不在一律单独一条命令问。
- **`harness-golden.mjs` 自己的所有路径从 `path.dirname(import.meta.url)` 推**（REPO_ROOT / fixtures / golden 基线三样都是），所以它的**候选实现副本必须仍放 `.claude/tests/` 下**才跑得起来，挪去 /tmp 找不到基线——和上一条「引擎不能拷 /tmp」是同一个病、不同的文件。给它写的 .sh 收 `${1:-默认路径}` 入参就能拿候选验「修得好」，零改动本仓。实测全量 `--check` 2m52s / 20127 断言 / 9 场景 + in-repo，**单场景 ~18s**——所以「按场景切片」是给突变类工具唯一跑得动的形态，别按全量估时间。
- **`harness-golden.mjs` 的 `main()` 无条件 `console.log('===== harness-golden <mode> =====')`**：给它加任何「stdout 单行 JSON」的新模式，这行 banner 必须改走 stderr，否则机器通道第一行就是横幅。这类「老模式的人读输出撞上新模式的机器契约」只有拿候选实现真跑一遍才看得见，读 main() 很容易漏。
