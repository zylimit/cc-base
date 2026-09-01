---
name: audit-scripts-fragile-zones
description: .claude/harness/audit 三个扫描脚本的易碎边界——工作树/索引之别、pwsh 缺席、自举扫描会扫到测试文件本身
metadata:
  type: project
---

给 `scan-instructions` / `scan-secrets` / `check-syntax` 写测时，这几处最容易写出假红或假绿：

- **工作树 vs 索引**：默认 tracked 模式判的是工作树（正确），`--staged` 该判索引。两种模式的期望值相反，断言必须写明判的是哪一个，否则对照组会被误当缺陷。踩过一次：给默认模式写了「索引有密钥就该拦」，那是我写错不是代码错。
- **pwsh 缺席是本机常态**（WSL2 无 pwsh/powershell）。凡涉及 `check-syntax` 的 `.ps1` 类 SKIPPED 的断言，必须先 `command -v pwsh` 守卫，条件不成立就打 `[SKIP]` 说明理由，不许硬断言。
- **测试文件自己会被扫**：`test-audit-scripts.sh` 有一条自举断言「本仓 tracked 源码不许带密钥字面量」。所以 `.claude/tests/` 下的测试文件里**不许出现字面量形态的假 token**，要运行期拼接（`GH_TOKEN="ghp_$(printf 'AAAA...')"`），否则新测试一落地就把别人的自举断言干红。
- **JSON 字段名会撞车**：`scan-secrets` 输出里 `skipped.allowlisted` 已存在（文件级白名单计数），别用裸 grep `allowlisted` 判断行级豁免机制是否实现，要解析后看具体字段。
- **改完实现要还原时禁用 `git checkout --`**：audit 那几个 .mjs 长期是 `AM` 状态（已进索引 + 工作树又被并行 agent 改过），checkout 还原到的是**索引版**，会把别人未暂存的活儿悄悄抹掉。做变异验证一律 `cp` 到 /tmp 备份 → 变异 → `cp` 回来 → `sha256sum -c` 逐字节验，还原完再 `git status --short` 比对开工快照。
- **豁免走外置白名单**：`scan-instructions` 的行内 `scan-instructions:ignore` 已作废（被扫文件不可信），豁免只认 `.claude/harness/audit/instructions-allowlist.json` 的 `{file,line,rule,sha256}`，路径按**被扫仓的 cwd** 解析；`scan-secrets` 的行内标记则仍生效（两个脚本不同规矩，别混）。造白名单 fixture 后记得删掉再跑后续断言。
- 相关：[[cc-base-testing-infra]]
