---
name: installer-and-selfcheck-attacks
description: 审安装器 / 自检工具（setup.sh·ps1、doctor）的六条固定攻法——分母缩水报绿、装完自检恒红、锁 test-then-write、trap 标记扛不住 SIGKILL
metadata:
  type: project
---

本仓凡是「往别人项目里装」或「装完自查完整性」的工具，照这六条打。2026-09-04 审批 4/5 时六条中五条。

1. **「全量比对」的分母会自己缩水**。`doctor.sh` 逐条比 sha 报 `✓ 全量比对 N 条一致`，但「登记了、盘上没有」的走 `continue` 不进分母、只落一句 stderr `!`，rc 仍 0。
   固定实验：移走 10 个清单登记的文件（挑只有清单管的，避开工具的其它显式检查）→ 看 rc 和那行 ✓ 的数字。
   本仓已有正解可引用：`release.mjs` 的 `manifestFindings` 把 `stale`（listed but absent）计进 FAIL 总数。同一件事两个工具两套口径，是这类仓的常态。
   同族一起造：清单文件整个删掉 / 清空成 0 条 / 清单里的路径变成目录 —— 本轮三个全是 rc 0。

2. **自检工具必须装到干净目标再跑，不能只在开发仓里跑**。`doctor.sh` 硬判仓根的 `make-release.sh`，而安装器按设计只装 `.claude/` —— 于是**每一个被安装的项目**上 doctor 恒 rc 1。恒红等于没红。
   查检：`setup.sh /tmp/x && doctor.sh /tmp/x`，看 rc。
   **它自己的测试会用桩文件绕过而不是修**：`test-doctor.sh` 沙箱里补了个 `make-release.sh` 桩，注释还写明「缺了它基线就 rc=1，rc 断言当场失去分辨力」——夹具绕过缺陷的原话就写在那儿，读测试注释能直接捡到 finding。

3. **锁是 `[ -f ] … > lock` 的一律不是锁**。test-then-write 中间没有原子原语。
   固定实验：**别只读代码**，用原样脚本跑 24~36 轮 × 2 并发装同一个 mktemp 目标，数「两边都 rc 0 装完」的轮数——本轮约 8%（3/36），足够当复现证据。再拿 /tmp 副本在 `-f` 与写之间插一行 sleep 做 100% 确证。
   本仓已有原子范式：`core.mjs` 的 `withDirLock()`（`mkdirSync` + EEXIST + 陈旧龄）。

4. **trap 写的「中断标记」扛不住 trap 跑不了的场景**，而那恰恰是标记存在的理由。
   `setup.sh` 的 EXIT trap 把 marker 翻 `interrupted`（doctor 判 ✗ rc 1）；`kill -9` 后 marker 停在 `active` + 死 pid，doctor 只给 `!` warn、rc 0。marker 里已经记了 pid、`acquire_lock` 里已经有 `kill -0`，消费方却不用。
   查检：每个「状态标记」都问一句「写它的那条路径跑不了时，标记停在哪个值，消费方怎么判」。
   附带：`written` 清单只在 start 时写一次（空的），硬崩后永远是 `[]`。

5. **`case` 里的 `*) target="$1"` = 未知参数被静默当参数**。`setup.sh --dryrun /tmp/x` 真装 240 个文件、rc 0、零告警——零写入安全开关拼错一个连字符就变成完整写入。
   查检：安全类 flag 一律白名单，未知参数 die。

6. **多份排除表要自己数，注释里的数字不算**。本轮注释写「另有三份/四份」，实际七处（+ `static-check.sh` 的 `JS_PRUNE`）。
   验的正确姿势不是读表：源树里造**真实形态**的样本（worktree 副本里还有一层 `.claude/`），把两个安装器 + 生成器都跑一遍，比 `comm` 双向差集；`manifestIncludes` / `isStateExcluded` / `isDenied` 三个纯函数直接 import 探针，一次问完深层/反斜杠/嵌套/裸目录四种形态。
   本轮七处全对齐——排除表这次是干净的，别再重复审同一面。

**同一个文件里两张排除表口径不一致 = 其中一张裸奔**：`static-check.sh` 给 JS 专门写了第二张不排 `.claude/` 的表（注释还写明理由），`.sh` 那张原样排掉整个 `.claude/` —— 于是 shellcheck 面只覆盖 63 个 `.sh` 里的 2 个。证据不是「覆盖率低」，是**把它打开当场就红**（本轮改动的 15 个 .sh 里 7 个非零、含一个 SC1087 error）——从来没跑过才会这样。
相关：[[pattern_gate-scripts-false-green-in-machine-channel]]、[[pattern_duplicated-rule-tables]]、[[pattern_evidence-ledger-attacks]]
