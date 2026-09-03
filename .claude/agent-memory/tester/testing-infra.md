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
- **run-all.sh 第二段一红就 exit，第三段（需 claude CLI）永远跑不到**：红锁在库期间整仓 run-all 必然停在静态段。挂新脚本进第二段要照 golden / audit 块加 `command -v node` 守卫——这些脚本无 node 时是 `exit 1` 而非 SKIPPED，裸塞 for 循环会在没装 node 的机器上报假红。
- **本机跑整仓 run-all 要按 15 分钟以上算**：这台机器装了 `claude` CLI，第三段「真触发 cases」会真起 `claude -p`（每个 case 最长 300s，共三个），CI 上那句 SKIPPED 在本地不成立。别拿默认 timeout 直接跑，用后台任务 + 日志轮询，否则超时被杀还得回头清残留进程。
- **动 `.claude/tests/` 下的文件会让 FRAMEWORK-MANIFEST.txt 的 sha256 变陈**：清单由 `.claude/scripts/gen-manifest.sh` 生成，没有机器闸校验新鲜度（test-setup.sh 只验文件在、条目在），近期 commit 也是半数带半数不带。它决定 setup.sh 升级时「框架层 vs 项目私有层」的判定，改完在回执里点出来让主 Agent 决定要不要重生成。
- 相关：[[audit-scripts-fragile-zones]]、[[red-lock-test-writing]]、[[windows-gitbash-process-tests]]
