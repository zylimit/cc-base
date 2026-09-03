---
name: duplicated-rule-tables
description: 本仓「同一张规则表抄成 N 份」的固定审法——先数清到底几份，再对每一份单独做删除突变看有没有闸
metadata:
  type: project
---

本仓有意不共用来源的重复表（排除表 / 规则表）不止一处，作者在注释里会写「另有两份，改这里必须
同改」。**那句注释是待验证的断言，不是事实**。2026-09-03 审 #27 排除表时四条全中：

1. **先自己数一遍有几份，别信注释里的数字**。#27 注释写「三处」，实际是四处
   （`setup.sh` / `gen-manifest.sh` / `setup.ps1` / `release.mjs MANIFEST_RULES`），
   加上 `core.mjs` 的 `STATE_EXCLUDE` + `STATE_EXCLUDE_PREFIXES`（同一批运行态目录、另一个用途）就是六份。
   查检：拿表里一个**独有**条目（如 `harness/trend`）全仓 grep，命中几个文件就是几份。
2. **逐份做删除突变，每份单独跑闸**。四份里只要有一份没有任何测试盯着，它就是唯一会漂的那份。
   本轮 `release.mjs` 那份删掉全部 8 条新规则后 selftest 267 + golden 20127 全绿——真修复零覆盖。
3. **对齐要双向查**：不光「该排的排了没」，还要「排过头了没」。正向用 `git ls-files` 看被排除的
   前缀下有没有 tracked 文件；反向拿一个真框架文件（`harness/harness.mjs`）过一遍membership 函数。
4. **表的补集也要查**：把 `.gitignore` 逐条对着排除表比。本轮 `.DS_Store` / `Thumbs.db` / `*.swp`
   在 gitignore 里、不在排除表里 → Mac 上跑一次生成器就把机器垃圾写进 tracked 清单。

**测试夹具依赖开发机脏状态 = CI 上恒绿**（同轮抓到的第二类）：`test-setup.sh` 新增的「运行态目录
不入装」断言不自己造夹具，靠源树**碰巧**有 `harness/state/` 才有力。dev 机脏树上删排除项会红，
CI 干净 checkout 上删同样的排除项全绿——闸只在不需要它的地方响。
固定实验：把源树复制一份、删光运行态文件（模拟 CI checkout），再做突变，看还红不红。
相关：[[pattern_gate-scripts-false-green-in-machine-channel]]、[[pattern_golden-baseline-rulers]]
