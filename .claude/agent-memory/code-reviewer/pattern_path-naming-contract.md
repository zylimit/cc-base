---
name: path-naming-contract
description: 审 harness「stdout 路径一律仓库相对」这条契约的固定攻法——符号链接降级、相对入参回退、断言同义反复、修复零覆盖
metadata:
  type: project
---

本仓 stdout 是机器契约，rules/harness-large-repo.md 立了「路径一律正斜杠、一律仓库相对」。
判据实现在 `core.mjs` 的 `repoRelative`（仓内转相对 / 仓外原样 / `..` 开头即判仓外）。
2026-09-03 审这条判据时，五条固定攻法四条有货：

1. **前缀撞名、`..foo`、根自身、跨盘符——都不用担心**。`path.relative` 按路径段比，
   `/repo-sibling` 不会被当仓内；`..foo/` 不触发 climb-out；Windows 侧 `D:\` 由
   `path.isAbsolute(rel)` 兜住，`c:` vs `C:` 照样转相对。验法：写一个 11 例 posix +
   8 例 `path.win32` 的矩阵直接跑函数，不要靠读。
2. **符号链接是唯一会悄悄降级的边界**。`projectRoot()` = `process.cwd()`（已解析真实路径），
   经软链传进来的仓内路径判成仓外 → 回显机器绝对路径，正是契约禁止的形态。
   macOS 的 `/var`→`/private/var`、`/tmp`→`/private/tmp` 就是它。
   **警报信号**：新 selftest 用 `fs.realpathSync(mkdtempSync(...))` 把这个形态绕开了——
   夹具主动 realpath = 作者知道函数怕软链，去问为什么不断言它。
3. **相对入参「原样回显」要当心方向搞反**。`path.relative(root, rel)` 本来就先按 cwd 解析入参，
   所以它给的是「真正被 fs 打开的那个文件」的仓相对名；改成原样回显后，cwd≠projectRoot 时
   报出的名字按仓相对读会指到**另一个文件**。判法：造一个 `cwd=.claude / CLAUDE_PROJECT_DIR=repo`
   的调用，再在两个候选位置各放一个文件，看错误信息变的是哪一个。
4. **断言可能由另一条分支给出同一答案 = 没钉住**。删 `if (!path.isAbsolute(raw)) return ...` 整行，
   selftest 仍 268 全绿——`repoRelative('docs/x.md')==='docs/x.md'` 在缺该分支时由 climb-out
   分支答出同值。查检：每条分支单独删一次跑一次，别整段替换。
5. **「命名」修好了不代表「读取」修好了**。同一轮里 `adr-check` 的真缺陷是
   `path.join(root, absPath)` 读错目录（accepted ADR 一条读不到还答 nothing to enforce），
   修法是 `path.resolve`；命名那半有 selftest 守，**读取那半零覆盖**——改回 `path.join`，
   selftest 268 / golden 20127 / test-harness 72 全绿。凡是「一个 bug 两半（读错 + 报错名）」，
   两半各要一条红。

相关：[[pattern_golden-baseline-rulers]]、[[pattern_duplicated-rule-tables]]、[[project_cc-base-is-a-framework-repo]]
