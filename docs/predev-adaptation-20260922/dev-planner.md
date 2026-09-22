# dev-planner 回向适配来源表（2026-09-22）

依据：`codex-base` 分支 `improve/predev-synthesis-20260922` @ `d1a3287`（只读克隆路径见派单）；T4 判据见 `docs/predev-skills-diff-20260922.md` 第 6 节「dev-planner」；来源标注对照 `docs/predev-synthesis-20260922.md` 对应节。本表只记录本仓 `.claude/skills/dev-planner/SKILL.md` 与 `templates/dev-plan-template.md` 的章节级来源，不代表已获授权修改本仓其它 Skill。

Codex 的 resolver 六输入 / `harness.mjs plan lint` / `[Assurance]` 是它的运行时概念，本次不搬；`[Assurance]` 节本身不落地到本仓。

| 本仓原章节 | 适配后章节 | 来源（K 本仓 / C codex-base / 合并） | 一句理由 |
|---|---|---|---|
| [任务] | [任务] | 合并 | K 的生成模式 / 迭代模式框架与"一句话 diff 跳过计划"不动；追加 C 的「完整结果一个 Task 就能交付、多个交付组才拆 Phase」判据，但受本仓 `plan-lint.sh` 要求至少一个 `## Phase` 小节的结构约束，改写为「单 Task 仍装一个 Phase，不硬拆多个」——是判据在本仓工具链下的落地，不是 C 原句字面搬运（见下方「拿不准的合并决定」）。 |
| [依赖检测] | [依赖检测] | 合并 | K 的六路可选输入判据骨架不动；DESIGN.md 一行从「固定单开 token Task」改判据为「按实际需要折进相关 UI Task」，对应 T4「不把固定 DESIGN token Task 普遍化」；插入 C 的「局部需求已确认可先出计划，未确认部分只阻断相关 Phase/Task」；括注补「文档实际拆分或不在默认路径时按项目实际路径读，不假设都叫固定文件名」，对应 T4「沿用实际 Spec/ADR/DFX/原型路径」。 |
| （新增） | [文件结构] | C | 从合成版对应节整段搬入（`.agents/` → `.claude/`），登记 `references/acceptance-and-dependencies.md` 与 `templates/dev-plan-template.md`；放在 [依赖检测] 之后、[第一性原则] 之前，对齐 arch-designer / product-spec-builder 等本仓已有 Skill 的章节顺序惯例。 |
| [第一性原则] | [第一性原则] | K | 未改动——T4 判 C 领先的「按价值与关键未知切片、保留真实依赖与最小基础设施」，本节「价值与未知先行」一条（先交付核心价值、先验证关键未知、基础设施只做支撑第一条价值流程所需的最小部分）已实质覆盖；T4 同时要求保留的「K 的依赖 DAG、假设前置、文件路径要求」分别落在本节「文件路径明确」与 [分析策略]，本来就有，不动。 |
| [分析维度清单] | [分析维度清单] | K | 未改动，T4 判 K 对 `[推断]`/`[待定]` 的早期验证与默认前提表更具体，属于要保留的一侧。 |
| [分析策略] | [分析策略] | K | 未改动——依赖图构建法、价值排序法、粒度校准法、假设前置法是 T4 明确点名「判 K 领先，本仓已有、不动」的内容（依赖 DAG、假设前置）。 |
| [待定问题处理] | [待定问题处理] | K | 未改动，T4 判 K 对 `[推断]`/`[待定]` 更具体，保留。 |
| [信息充足度判断] | [信息充足度判断] | 合并 | K 的六条「必须满足」骨架保留；「技术栈已确定」「Phase 拆分完成」两条改判据为「首次引入才 WebSearch、已有项目不强行重选」「多个交付组才用多个 Phase、单结果不凑数」，对应 C「不强行在小任务选技术栈、定版本或生成完整计划」；追加「范围外仍待定的部分只阻断依赖它的 Task/Phase，不倒过来阻断已确认部分先出计划」，对应 C「未知只阻断相关切片」；「不使用占位符」逐字保留，对应 T4「K 的『无占位符』保留为待派 Task 的质量要求」。 |
| [生成前自检] | [生成前自检] | 合并 | K 原四条（无占位符 / 命名一致 / Spec 覆盖 / 假设覆盖）一字不动；新增「Task 可派发」（Business Context / 依赖类型 / 证据产生者三项齐全，能直接抄进 implementer 派单）与「REQ 覆盖」两条，对应 C「Goal/Scope/Business context/owned paths/Verification 及适用 REQ 直接服务派单，验收含业务例子与产生者」。 |
| [确认策略] | [确认策略] | K | 未改动，T4 本节未提及，本仓原判据独立成立。 |
| [命名纪律] | [命名纪律] | K | 未改动——T4「K 的跨 Phase 命名核对有用」对应的实质内容在 [生成前自检]「命名一致」一条，已保留；本节讲的是 Phase 编号对用户的沟通口径，是另一件事，不动。 |
| [工作流程] | [工作流程] | 合并 | 生成模式一步插入「完整结果一个 Task 就够时只开一个 Phase，不硬拆多个」，并如实写明 `plan-lint.sh` 只按整份 Spec/Plan 做双向覆盖检查、不支持传需求子集参数（有该检查时说清楚它检查什么，没有子集能力就不假装能跑）；迭代模式把「已完成的 Phase（标 ✅）不动」改写为「已完成只证明当时那版行为、不证明 Spec 改完后新行为也成立，修正需求要落成新 Task，不能因为已标 ✅ 就漏掉」，对应 C「已完成证据保留历史但不证明新行为」，也是 T4 点名 K 原表述会漏掉修正任务的问题。 |
| [初始化] | [初始化] | K | 未改动。 |

新增 `references/acceptance-and-dependencies.md`：来源 C，codex-base `d1a3287` 教学材料整文件搬入，文件头加声明「codex-base `d1a3287` 教学材料；预约例是虚构案例，其中数字、命令、路径不自动成为本项目要求」。宿主适配：①「完整 Assurance 仍由主 Agent 派发」改写为「完整验收安排仍由主 Agent 按 Task 定档（LOW / MEDIUM / HIGH，见 dev-workflow-details.md）派发」；②「独立 reviewer/tester 的责任按 controls 安排」改写为「按 Task 定档安排（MEDIUM 起才派 code-reviewer，HIGH 加派 tester，与实现者不同实例）」；③ 删除末段指向 `../../dev-builder/references/async-proofreading-case.md` 的跨技能示例链接——该文件本仓不存在、也超出本次只改 dev-planner 的范围，避免留悬空引用。方法正文（补读界面/数据/技术依据、按完整结果切片排序、让结果有产生证据的人和动作、区分功能依赖与验证依赖、研究任务结束的是未知、交给下一角色）未改写。[文件结构] 已同步登记。

`templates/dev-plan-template.md` 同步改动（来源：合并）：顶部说明追加 Task 子字段与本仓「派单包七字段」（`.claude/rules/subagent-dispatch.md`）的对应关系，以及「单 Task 仍装一个 Phase」的判据；每个 `- **Task N.M：**` 条目下追加 Business Context / 依赖类型 / 证据产生者三个子字段（不受 `plan-lint.sh` 检查，但对齐派单字段）；「关键文件」写作要点补「共写文件标唯一 owner Task」；片段示例追加一条子字段示范；写作要点新增第 11–14 条，对应 Business Context 写法、依赖类型区分、证据产生者对应本仓 LOW/MEDIUM/HIGH 判档、Phase 数量不是固定门槛。原有段名锚点（**交付内容** / **验证的假设** / **关键文件** / **Task 清单** / **验收标准**）与 `- **Task N.M：**` 格式一字不改。

## 拿不准的合并决定

- **`plan-lint.sh` 与「不必用 Phase」的字面冲突**：T4 与派单原文都写「完整结果可用一个 Task 交付」，读起来像是可以完全不设 Phase 容器；但本仓 `plan-lint.sh`（`if not phase_matches: fail("未找到任何 ## Phase 小节")`）对任何 DEV-PLAN.md 硬性要求至少一个 `## Phase` 标题，且本次改动范围不含这个脚本。我把判据收窄成「单 Task 仍装进一个 Phase，只是不强行拆成多个」，这是在现有工具链约束下最贴近原判据的落地，但不是 C 原文的字面搬运。如果判断应该是改脚本本身（放开「零 Phase」结构），这个决定需要主 Agent 或 Codex 侧重新裁定，我没有改 `plan-lint.sh`。
- **`plan-lint.sh` 的「需求子集检查」没有对应能力**：派单原文写「plan-lint 按所选需求子集检查」，但脚本实际只支持 `[plan] [spec]` 两个位置参数，做的是整份双向覆盖检查，没有 `--requirements`/`--section` 这类子集入参（那是 Codex `harness.mjs plan lint` 的能力，按规则不搬）。工作流程一节如实写了这个限制，没有假装脚本已经支持子集过滤；如果需要脚本层面补这个能力，应作为独立的 MEDIUM 档改动交主 Agent 排期，不在本次范围内顺手加。
- **Business Context / 依赖类型 / 证据产生者的措辞选择**：三个新字段直接借用了本仓已有「派单包七字段」里的 `Business Context`（`.claude/rules/subagent-dispatch.md`）而不是另造贴近 C 原文（`Business context`/`Verification`）的新词，目的是让 DEV-PLAN 的 Task 条目能直接对上派单字段、少一次翻译；「依赖类型」「证据产生者」是我按 C 原文「依赖类型：功能前置与验收前置分开」「证据产生者」的意思起的本仓中文名，C 原文没有现成的对应字段名可抄。如果认为应该更贴近 C 的措辞或字段拆法，请指出。
- **acceptance-and-dependencies.md 末段跨技能链接被整段删除**：原文末段指向 `dev-builder` 的一个示例文件，本仓当前不存在，也不在本次「只改 dev-planner」的授权范围内新建；如果 dev-builder 那条适配线后续把这个文件补上了，可以再把链接加回来，这个决定留给主 Agent 判断是否需要跨 Skill 补链接。
