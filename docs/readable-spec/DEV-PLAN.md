# Development Plan — 人读文档

> 记录这项框架能力的开发阶段、当前进度和剩余工作。需求来源 docs/readable-spec/Product-Spec.md，架构 docs/readable-spec/Architecture-Design.md，第一期的行为契约 docs/readable-spec/phase1-db-contract.md。

## 开工前置

- [默认] 条目：REQ-DOC-001 的两条细则（每张表列哪几样、一张图只画一组表）与 REQ-DOC-006 的两条细则，小样出来请用户挑错。
- 待定「接手方是否要求 Word / PDF」「客户审核用什么语言」：押后到首份文档交出去之前，期间只出中文网页。
- 待定「conflation 的文档在哪台机器上生成」：第一期的小样在本机那份副本上跑、产物放仓外，不动那个仓；正式生成前再定。

---

## Phase 1: 数据库设计（2026-11-23，CONCERNS：等用户看小样，残留 #142）

**交付内容**：
- 维护者跑一条命令，从项目的建表定义读出每张表，生成按组切开、带关系图的数据库设计页面
- 页面标明每段内容的来历，读不出的定义明着列出来
- 每张表上能看到哪些文件在写它、读它
- AI 写的表用途与字段含义经命令落盘并盖指纹，来源变了自动标「待更新」
- 一条核对命令报出页面与来源的不一致

**验证的假设**：
- 只读建表定义的文本、不连真库，就能合并出现行表结构（技术未知）——拿 conflation 的 schema.sql 实跑，取出的表数要等于原文行首的 77 条建表；117 条加列（行首 105 条）每一条要么加出了新列、要么是重申已有列被跳过、要么列在清单里；17 个 `DO $$` 块里碰表结构的 16 个全部出现在「未合并」清单里（2026-11-23 实数）
- 从字符串里的 SQL 能推出「谁写谁读」（技术未知）——在小样上抽十张表人工核对，漏报不超过两成
- [默认] 没有项目判断时按表名前缀分组，读者看得懂——小样给用户看

**关键文件**：
- `.claude/scripts/readable-docs.mjs` — 入口与子命令
- `.claude/scripts/readable/model.mjs` — 实体、锚点、指纹（owner：Task 1.1）
- `.claude/scripts/readable/sources/sql-ddl.mjs` — 建表定义的取事实器
- `.claude/scripts/readable/render/db.mjs`、`.claude/scripts/readable/render/layout.mjs` — 数据库设计页面与共用版式
- `.claude/scripts/readable/sources/code-scan.mjs`、`.claude/scripts/readable/links.mjs` — 代码里对表的写读与关联
- `.claude/scripts/readable/notes.mjs` — 配置、项目判断、说明的读写
- `.claude/scripts/readable/check.mjs` — 核对器
- `.claude/skills/readable-docs/SKILL.md` — 什么时候跑、待办怎么补、说明怎么写

**Task 清单**：
- **Task 1.1：建表定义的取事实器与配置（REQ-DOC-001）** — 新建 `readable-docs.mjs`（`init` 与 `build --facts-json`）、`readable/model.mjs`、`readable/sources/sql-ddl.mjs`；按契约 A、B 节；验证 `node .claude/scripts/readable-docs.mjs build --facts-json --root <conflation 副本>` 报出的表数、未合并块数
  - Business Context：接手团队第一步看数据库设计，conflation 约一百张表没有任何说明；建表文件是 77 条 CREATE、117 条 ADD COLUMN、17 个 `DO $$` 块（2026-11-23 实数）。区分例子：`ALTER TABLE orders ADD COLUMN IF NOT EXISTS note TEXT` 而表里已有这一列 → 保留原定义、不重复；`DO $$` 里的 `ALTER` → 进「未合并」清单，不合并
  - 依赖类型：功能前置无；验证前置＝conflation 的 schema.sql（只读，拷到临时目录）
  - 证据产生者：HIGH 档——implementer 自检，tester 独立写测；code-reviewer 整期一轮（四步走第 1 步），依据用户 2026-09-22 给脚手架仓定的快速开发模式
- **Task 1.2：数据库设计页面与原子落盘（REQ-DOC-001、REQ-DOC-011）** — 新建 `readable/render/db.mjs`、`readable/render/layout.mjs`，`readable-docs.mjs` 加 `build`；按契约 C 节；验证对同一来源跑两次 `build` 后 `diff -r` 无差异
  - Business Context：读者只有浏览器、可能离线，每页要自成一体；页面是生成物，同样的来源必须生成同样的文件，否则每次提交都是噪音。区分例子：一组 30 张表 → 切成三页，每页的关系图不超过 12 张表
  - 依赖类型：功能前置＝Task 1.1（要它的文档模型）；`readable-docs.mjs` 的唯一 owner 是 Task 1.1，本 Task 只加 `build` 分支
  - 证据产生者：HIGH 档——同上
- **Task 1.3：谁写谁读、代码里建的表、项目判断（REQ-DOC-001、REQ-DOC-005）** — 新建 `readable/sources/code-scan.mjs`、`readable/links.mjs`，读 `docs/readable-src/map.json`；表页加「谁在写」「谁在读」、小关系图与「服务的需求：未关联」，按项目判断分组；按契约 F 节；验证在小样上抽十张表人工核对。谁写谁读先到文件这一层，到模块那一层等第二期定了模块怎么分再接
  - Business Context：成功判据 SC-1 要求说清每张表谁写谁读；conflation 的 SQL 全写在字符串里（非测试代码 161 处 INSERT、77 处 DELETE、29 处 UPDATE、11 处走 `copy_records_to_table`），18 处表名是运行时拼的要明示；有两张主库的表只在代码里建；按表名前缀分组会把最核心的几张表甩进「其它」（它们的前缀下都只有一张表），所以要能按业务分组（2026-11-23 实数）
  - 依赖类型：功能前置＝Task 1.1、1.2
  - 证据产生者：HIGH 档——同上
- **Task 1.4：说明的落盘、指纹与待更新（REQ-DOC-006）** — 新建 `readable/notes.mjs`，入口加 `pending`、`note put`、`note confirm`、`note drop`；表页、组页、清单显示说明与状态，敏感字样隐去；按契约 G 节；验证改一张表的列之后重跑，原说明带「待更新」，只加一个索引则不带
  - Business Context：说明只能经命令落盘、指纹由命令盖，AI 碰不到指纹；锚点不存在的拒收；规格把「生成物里不出现密钥、内网地址与账号」定为 P0
  - 依赖类型：功能前置＝Task 1.2、1.3（同改表页与入口，排在 1.3 之后）
  - 证据产生者：HIGH 档——同上
- **Task 1.5：核对器的数据库部分（REQ-DOC-007）** — 新建 `readable/check.mjs`，`build` 改为先核临时目录再替换；按契约 H 节；验证手工改坏一页后 `check` 退出码 1 并点名
  - Business Context：核对器不读渲染器的任何中间结果，自己重新取事实、自己从页面反读，否则渲染器吞了字它看不见
  - 依赖类型：功能前置＝Task 1.1～1.4
  - 证据产生者：HIGH 档——同上

**验收标准**：
- 对 conflation 的副本跑 `build`，每张表一页，浏览器离线能开，用户看过小样
- 假设成立的证据：取出的表数与原文一致；16 处碰表结构的运行时定义全部列在「未合并」；十张表的写读抽查漏报不超过两成
- `check` 在未改动时报不一致 0 条，改坏任一页或改了建表定义而未重出时退出码 1

---

## 范围外（本次不计划）

- REQ-DOC-002：已押后——第二期（架构设计），要先定模块怎么分
- REQ-DOC-003：已押后——第三期；算法规则只投影设计详述，先要用户定给哪些模块补设计详述
- REQ-DOC-004：已押后——第二期（人读版需求规格）；「一字不丢」与「不出内网地址」的冲突待用户裁定
- REQ-DOC-008：已押后——第三期（测试设计）
- REQ-DOC-009：已押后——第三期（上手指南），要有人真跑一遍
- REQ-DOC-010：已押后——第三期（业务入门）

---

## 技术栈

| 层级 | 技术 | 版本 | 说明 |
|------|------|------|------|
| 生成器 | Node.js 内置模块 | 与框架现有脚本同 | 不引第三方依赖 |
| 产物 | 静态 HTML、内联 SVG | — | 浏览器直接打开 |

## 开发规则

- 每完成一个 Phase 走四步走：Code Review → 测试完整性 → 编译验证 → 功能测试
- 四步走全部通过才算 Phase 完成
- Commit message 格式：`phase-N: 简要描述`
