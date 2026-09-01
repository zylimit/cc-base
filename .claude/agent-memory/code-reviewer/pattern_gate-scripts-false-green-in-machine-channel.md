---
name: gate-scripts-false-green-in-machine-channel
description: cc-base 闸脚本的高发缺陷——覆盖缺口只写进 findings，退出码和 ok 字段仍报绿
metadata:
  type: project
---

本仓每写一个新闸脚本，都要按同一条线攻："有没有一条路径，是**没检查成**却报绿的？"
2026-09-01 审 `.claude/harness/audit/` 三只脚本时，三只全中同一模式：
跳过的类 / 超限没扫的文件 / 参数错导致扫了 0 个文件，都老老实实写进了人读输出和
findings 数组，但 **exit code 与 JSON 的 `ok` 字段只由 error 级命中决定**，一律 0/true。

**Why:** 人读那行只有人看；CI 和 git hook 消费的是 `$?` 和 `jq -e .ok`。
两个机器判据都报绿 = 覆盖缺口对唯一会拦人的那一方不可见。这跟本仓自己的
「缺命令 = BLOCKED，绝不假绿」「未执行 != 通过」立场自相矛盾。

**How to apply:** 审任何新闸时固定造这四个样例，逐个看 rc 和 ok：
① 检查器缺失（PATH 上拿掉 bash/pwsh）② 文件超 size 上限 ③ 文件读不了（权限/坏符号链接）
④ 参数写错或文件集为空。凡是「记录了但 rc=0 且 ok=true」的，就是一条 finding。
本仓已有的正解可以引用：harness 的四态门用 BLOCKED、rc 3 表降级，别让降级挤进 rc 0。

2026-09-02 复审同三只脚本，rc/ok 那层修好了，假绿换了三个新落点，都要单独造：
⑤ **换 cwd**。脚本靠 `git ls-files` 取清单、靠相对路径正则认文件。在子目录里跑，
   清单变成子目录相对路径，模式全不匹配，三只齐报 `rc 0 ok:true`、计数全 0——
   「一个文件都没扫」被印成通过。固定实验：`cd .claude && node <脚本>`，比对根目录结果。
⑥ **flag 组合把已修的路径开回来**。`--staged --paths X` 里 `--paths` 赢、`--staged`
   被静默丢掉，内容重新从工作树读——正是刚修掉的「名单来自索引、内容来自工作树」。
   审任何带互斥 flag 的脚本，把 flag 两两组合跑一遍，看 source 字段。
⑦ **降级路径永远为真 = 降级信号作废**。submodule gitlink（`ls-files` 列它、`statSync`
   不是普通文件、`git show :path` 直接失败）让每次运行恒 rc 3。恒红等于没红，
   接闸的人下一步就是忽略 rc 3。「本该出范围」和「该扫没扫成」必须分成两个桶。
相关：[[project_cc-base-is-a-framework-repo]]
