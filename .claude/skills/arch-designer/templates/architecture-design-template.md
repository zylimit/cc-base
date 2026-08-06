# Architecture Design — [项目名]

> 生成：[日期] · 档位：[S/M/L] · 状态：待批准
> 本文档的依赖规则与禁边以 `.claude/harness/module-catalog.json` 为机器执行版（L 档）；两处冲突时以 catalog + arch-check 实测为准并回改本文档。

## 1. 架构概览

- **架构风格**：[模块化单体 / 六边形 / 事件驱动 / …]（被拒备选：[X]，理由见 ADR-001）
- **技术栈**：[语言 / 框架 / 存储 / 关键中间件，各附版本]
- **一句话数据流**：[请求从哪进 → 经过哪些模块 → 落到哪]

## 2. 模块划分

| 模块 id | 职责（一句话） | 对外契约 | dependsOn | 禁依赖 | 变化原因（SRP 检验） | riskTier |
|---|---|---|---|---|---|---|
| [core] | | | | | | low/medium/high |

## 3. 依赖规则

- **分层**（外 → 内，依赖只许向内）：[api] → [service] → [domain] ← [storage 实现 domain 接口]
- **禁边**：[analytics ✗→ pii-store（隐私边界）]、[…]
- **数据所有权**：[表/集合 X 归模块 A single writer，其余模块经 A 的契约读]

## 4. 扩展点（开闭原则落点）

| 易变轴 | 扩展机制 | 新增一种时改哪 |
|---|---|---|
| [支付渠道] | [策略注册表] | [新增一个 provider 文件 + 注册] |

## 5. 关键场景走查

### 场景 1：[最重要用例名]
[模块间调用链 / 数据流走查，验证边界可行]

## 6. 架构决策记录（ADR）

### ADR-001：[决策名]
- **状态**：accepted（废弃时改 superseded/deprecated，adr-check 即豁免）
- **背景**：
- **决策**：
- **被拒备选与理由**：
- **执法方式**：[必须含可识别 token，adr-check 机器校验：catalog check id / fitness 规则 id / arch-check / layers / forbiddenDependencies / verify / receipt / 或"人工评审"；幽灵引用会 fail]

## 7. 目录结构骨架

```
[project]/
├── [module-a]/
└── [module-b]/
```

## 8. 七大原则自检记录

| 原则 | 结论 | 备注（过不了的写理由或整改项） |
|---|---|---|
| 开闭 OCP | ✅/⚠️ | |
| 依赖倒置 DIP | | |
| 单一职责 SRP | | |
| 接口隔离 ISP | | |
| 迪米特 LoD | | |
| 里氏替换 LSP | | |
| 合成聚合 CARP | | |

## 9. 演进路线（本版不做但已预留）

- [先单库；分库时只动 storage 模块]

## 10. 待办与开放问题

- [ ] [待 DFX-Spec 补质量属性档位]
