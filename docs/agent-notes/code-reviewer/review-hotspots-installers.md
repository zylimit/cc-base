---
name: review-hotspots-installers
description: cc-base 审查热点：安装器可选包分支、按路径键的审计机制、以及造「装完后的目标树」这种复现手法
metadata:
  type: project
---

- 高发模式：安装器新增「同一文件拷两处」的分支时，按**路径键**的机制不会跟着走——`harness/audit/instructions-allowlist.json` 的 `file` 键、`FRAMEWORK-MANIFEST.txt`、四份排除表各自认路径，第二份副本拿不到豁免/记录，下游装完被自家地板审计判红。新增拷贝目标路径时逐个对这四处。
- 薄弱模块：`setup.sh` / `setup.ps1` 的可选包分支（`--with-tests` / `--with-harness`）刻意绕过 manifest 分层，也绕过主循环的排除表过滤（`.bak` / `.DS_Store` 等不再被挡）；两侧 copy 语义还不同（sh 走 `copy_file` 留 `.bak`，ps1 走 `Copy-Item -Force` 不留），fresh 装对等、重装才分叉。
- 复现手法（比读代码硬）：① 在 scratchpad 拼出「装完后的目标树」，把框架自带审计脚本连 `lib.mjs` + 白名单一起拷进去按相对路径跑（`scan-instructions.mjs --paths …`，无 `--staged` 时不需要 git）；② `bash setup.sh --dry-run [--with-harness] <scratchpad 目标>` 只写目标侧锁文件，可安全对比两种模式的 plan 条数。
- 判缺陷影响面时的链路：审计脚本 rc 1 → `.claude/githooks/pre-commit` 的 `classify audit` 判 block → commit 阻断；githooks 随装进目标但 `core.hooksPath` 要用户自己 `install-githooks.sh on`，所以「会不会真拦」取决于下游是否开了 githooks，而 `.github/workflows/gate.yml` 的无参全量扫描一开就持续红。
