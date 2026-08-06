# DFX Spec — [项目名]

> 生成：[日期] · 模式：[设计 Design-in / 评审 Review] · 状态：待批准
> 档位定义与判定规则见 `.claude/rules/quality-attributes.md`；机器执行版为 `.claude/harness/module-catalog.json` 的 modules[].attributes（如有）。

## 1. DFX 优先级栈（冲突时前压后）

1. [security] 2. [reliability] 3. [cost] 4. [performance] …
理由：[一句话，如"金融数据，安全压倒一切；营销期成本优先于极致性能"]

## 2. 十二维总表

| # | 维度 | 适用 | 全局档 | 场景（六要素摘要） | 度量（数字+单位+测法） | 设计对策 | 验证落点 |
|---|---|---|---|---|---|---|---|
| 1 | 可靠性 Reliability | ✅ | high | | 错误率 <0.1%（周报） | | mutation-stryker + 回归 |
| 2 | 韧性 Resilience | | | | MTTR <5min | 熔断+supervisor | load-k6 + 熔断实测 |
| 3 | 安全 Security | | | | 高危漏洞=0 | | semgrep/osv/gitleaks |
| 4 | 功能安全 Safety | [N/A：纯信息系统，理由…] | | | | | |
| 5 | 隐私 Privacy | | | | 日志 PII=0 | 数据分级+禁边 | no-pii-in-logs/presidio |
| 6 | 性能 Performance | | | | P95 <200ms | 延迟预算分解 | load-k6 |
| 7 | 可服务性 Serviceability | | | | 定位 <10min | 结构化日志+health 端点 | supervisor 探针 |
| 8 | 可安装性 Installability | | | | 全新安装 ≤3 步 | 一键脚本+幂等 | 干净环境安装测试 |
| 9 | 可测试性 Testability | | | | 核心逻辑可 mock 边界 100% | 依赖注入+纯函数核心 | test-builder 基建 |
| 10 | 可修改性/扩展性 | | | | 典型变更 ≤3 文件 | 七大原则+扩展点 | arch-check 漂移=0 |
| 11 | 归一化 Normalization | | | | 同类组件 1 种 | 公共库下沉 | sbom-syft 依赖审计 |
| 12 | 成本 Cost | | | | CI 全量 <10min；月账 <$X | 规模分级 | CI 时长/账单看板 |

## 3. 质量属性场景明细（critical/high 维度逐条展开）

### 场景 R-1：[名称]
- 来源：[谁/什么触发] · 刺激：[发生什么] · 环境：[什么状态下] · 制品：[哪个模块]
- 响应：[系统应做什么] · 响应度量：[数字+单位]
- 验证：[落在哪个工具/测试/闸]

## 4. 按模块定档表（有 Architecture-Design 时）

| 模块 | security | privacy | reliability | resilience | safety | 其他 | none/minimal 理由 |
|---|---|---|---|---|---|---|---|
| [payments] | critical | high | high | high | minimal | | safety: 纯信息系统… |

## 5. 取舍记录（被牺牲方 + 理由）

- [性能 P99 放宽到 500ms，换取可修改性：不引入缓存层，v2 视数据再议]

## 6. 评审评分卡（评审模式填写）

| 维度 | 判定 | 依据 | 最小整改建议 |
|---|---|---|---|
| | 满足/风险/缺口 | | |

## 7. 待办

- [ ] [adapters 接线：security → sast-semgrep（待用户确认安装）]
