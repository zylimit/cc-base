---
name: golden-baseline-rulers
description: 审 golden/基线快照类工具（尺子）的固定攻法——覆盖矩阵不进机器判据、transitive selftest 撑绿、环境耦合字段入库
metadata:
  type: project
---

本仓凡是「录一份基线再回放比对」的工具（`harness-golden.mjs` 一类），照这四条打，2026-09-02
审 golden 基线时四条全中：

1. **矩阵本身不是断言**。删掉一个 scenario / 一个 command 条目，`--check` 照样 rc 0，只有人读那行
   的计数变了（`GOLDEN OK: 7 scenarios`）。命令 id 列表有比对、**scenario 列表没有**。
   固定实验：注释掉一个 scenario 跑 `--check`，看 rc。
2. **transitive selftest 撑绿会掩盖矩阵缺口**。golden 里录了 `selftest` 的 `{ok, tests:N}`，很多突变
   是被 selftest 的断言抓到的、不是被 8 场景输出抓到的。判据：FAIL 出现在**全部**场景且差异数一致
   （本仓是 7 diffs/场景）= selftest 抓的；只在部分场景 FAIL = 矩阵真抓的。
   所以问"覆盖率"时要分开算：矩阵覆盖 vs selftest 覆盖。selftest 也要跟着拆库走，别当独立第二意见。
3. **环境探测字段入库 = 假红源**。`adapters list` 的 `available` 是真 PATH 探测，录进了 git 的基线。
   往 pinned PATH 里放一个同名可执行文件，8 个场景全红。查检：`grep` 基线里有没有
   available/present/installed/version 这类描述机器而非描述行为的字段。
4. **正则大 alternation 只测一支**。fitness / 提取器这类规则，fixture 通常只命中第一支；
   逐支置换成 NEVERMATCH 跑 `--check`，没红的就是裸奔支。本仓 12 语言 import 提取器里 7 个
   可静默删除，secret 规则 6 支里 3 支（AKIA/ghp_/PRIVATE KEY）可静默删除。

**攻法的正确姿势（别改被审仓）**：`cp -a .claude $HOME/playground/.claude`，工具用 `import.meta.url`
推 REPO_ROOT，整套在 playground 里跑，突变随便做，被审仓零写入。先跑一次确认 playground 断言数与
原仓一致（本仓 5188）再开打。
相关：[[pattern_gate-scripts-false-green-in-machine-channel]]、[[project_cc-base-is-a-framework-repo]]
