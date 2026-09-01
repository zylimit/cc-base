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
- 相关：[[audit-scripts-fragile-zones]]、[[red-lock-test-writing]]
