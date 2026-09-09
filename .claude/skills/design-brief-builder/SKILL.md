---
name: design-brief-builder
description: 当用户说要确定设计风格、视觉方向，或说'我想要高级感/简洁/现代'这类模糊描述时使用。
---

[任务]
    像设计师采访甲方，从使用情境与首要动作出发，把用户的感受翻译成可执行的设计决策，产出两份互为姊妹的文件：**Design-Brief.md**（怎么运作：信息架构、页面与组件、状态、交互原语、文案、无障碍、关键流程）与 **DESIGN.md**（怎么看：按 Google DESIGN.md 开放规范写的视觉身份，YAML token + 八段 prose，设计工具、Claude Code、Cursor、Stitch 都能直接读）。
    **0-1 模式**：从 Product-Spec 到两份文件。**迭代模式**：用户调整设计方向时，追问清楚、更新两份文件、提醒设计稿与已写样式跟着改。

[依赖检测]
    Skill 启动时第一步自动执行。
    必需：Product-Spec.md → 缺失则提示先调用 /product-spec-builder。
    可选：设计工具（odc / Pencil / Figma MCP）→ 未连接标「手动设计模式」，两份文件照样生成；`npx @google/design.md lint DESIGN.md` 能跑就跑（校 token 引用与对比度），跑不了（内网无 npm）标「未经 lint」不阻塞。

[文件结构]
    design-brief-builder/
    ├── SKILL.md                          # 本文件：原则、感受翻译、采访策略、Phase、收敛、交接
    ├── references/
    │   ├── question-bank.md              # 六 Phase 问题库，界面型 / 终端与 Agent 型分轨
    │   ├── workflow-0-1.md               # 0-1 流程与完成度判据
    │   ├── workflow-iteration.md         # 迭代流程
    │   ├── style-vocabulary.md           # 风格词汇、参考锚点对、2026 趋势注记、AI 通病清单
    │   ├── ui-quality-floor.md           # 界面质量地板（MUST / SHOULD / NEVER），设计稿与代码共用
    │   └── agent-ux-patterns.md          # AI 产品交互模式与人在回路规则
    ├── templates/
    │   ├── design-brief-template.md      # Design-Brief.md 输出模板（行为脊柱）
    │   └── design-md-template.md         # DESIGN.md 输出模板（视觉身份，Google 规范）
    └── examples/
        ├── after-sales-dispatch-brief.md # 售后工单派单：Design-Brief 范例
        └── after-sales-dispatch-DESIGN.md# 同一产品的 DESIGN.md 范例
    访谈原理（五条铁律、四把刀、反失败自检、回放公式）共用 ../product-spec-builder/references/interview-principles.md，采访前先读它。

[第一性原则]
    **任务与环境优先**：先从 Spec 拿使用情境（站着还是坐着、单手还是双手、几秒钟还是几小时、专注还是随时被打断、设备与光线）和这一屏上最要紧的那一个动作。密度、对比、字号、动效从这里推；参考产品只是校准锚点，不是根据。
    **形态先于视觉**：先认产品形态——界面型、终端型、对话式 Agent、嵌入式扩展，可叠加。形态决定设计的本体和可用的视觉轴：界面型本体是页面与组件，终端与 Agent 本体是会话流、交互范式与渲染。认错形态后面每问都错。
    **一个具体参照胜过一堆形容词**：「1970 年代老牌大学的研究生讲义」自带一整套约束，「现代、干净、可信、高级」什么都不是。逼用户给出一个具体的参照点（产品、场所、物件），否定约束随它免费而来。
    **选择题优先，给默认让否决**：永远给 2 到 3 个带画面、带后果、带真实产品的选项，推荐的放最前；用户不是设计师，问「你要什么风格」等于没问。主动给一个合理默认让用户否决，比让他从零指定省力。
    **捕捉，不代笔**：把用户的偏好拉出来、翻译成属性、读回确认；不主动报颜色、不替用户挑风格。用户说不出时给选项，不给答案。
    **视觉方向是挣来的**：先业务受众情境，再情绪人格，再参考，最后才 token。一上来聊颜色的，拉回来。
    **不问像素**：圆角、阴影、间距的具体值交给 DESIGN.md token 和设计工具，采访只定方向。
    **AI 通病先校准**：AI 生成的界面有固定的五类聚簇（style-vocabulary 列了），它们是默认不是选择；brief 没钉死的轴，不许落在这些默认上。把大胆花在一处，其余安静。

[感受翻译表]
    用户说抽象词，按这张表逼成具体属性，绝不直接接受形容词。每翻译完 recap 回去确认；更细的风格词汇与锚点见 references/style-vocabulary.md。
    | 形容词 | 翻译成的属性决策 |
    |---|---|
    | 简洁 clean | 大留白 + 克制配色 + 少字重；追问是东西更少、留白更多、颜色更少、还是字体更简单 |
    | 高级 premium | 高对比 + 大量负空间 + 克制强调色 + 精致衬线或精准无衬线 + 更慢更松的间距；追问是苹果那种大留白还是爱马仕那种深色配金 |
    | 现代 modern | 扁平表面 + 无衬线 + 明亮饱和强调色 + 简化图标 |
    | 时尚 / 潮 | 一处放大胆（一个强色、一种大字、一段动效），其余极安静；参照当年而不是三年前的产品 |
    | 紧凑专业工具 | compact 密度，4px 步进缩间距，但警示、表单、小点击区不缩 |
    | 活泼 playful | 大圆角 pill + 暖色亮色 + 表现性动效 |
    | 技术感 工程感 | 等宽或近等宽字体 + 克制色板 + 高信息密度 + 功能性动效不装饰 + 方角精确边框 |
    | 透明可信 Agent 向 | 显式展示在做什么 + 动作前先示意再执行 + 全程可中断 + 不黑箱不替用户做主；AI 活动有专属视觉语言且不外借给普通组件 |

[采访策略]
    二选一引导：展示两个对立方向让选，每对带真实产品参考——信息密度 Linear 紧凑 vs Notion 宽松；色彩温度 Stripe 冷 vs Airbnb 暖；正式程度 Bloomberg 严肃 vs Figma 活泼；主题 GitHub 默认深 vs Google Docs 默认浅。锚点产品迭代快，进场前按 [搜索增强双遍] 先搜当前公认做得好的，不照搬记忆里的名字。
    终端型与对话式 Agent 别拿界面产品当锚，用同形态的：命令行编程 Agent、终端工具、AI 编辑器。
    品牌人格化：用生活类比绕开术语——「产品是个走进房间的人，穿西装还是卫衣，张扬还是内敛」。
    反面排除：知道用户不要什么，缩小范围最快；「有没有哪种风格你一看就讨厌？」
    矛盾检测：偏好冲突时逼排序，不允许「都要」。
    方向样张：设计工具可用时，在 Phase 3 收尾为首屏出 3 个完整视觉方向的离线 HTML 样张（不是换色，是完整人格：密度、字重、动效暗示、品牌气质各不同）让用户挑；没有工具就用文字把三个方向各描一句画面。

[搜索增强双遍]
    第一遍，提问前搜种子：Phase 3 前 WebSearch 用户行业竞品 + 跨行业标杆 + 当前趋势，带具体参考进场问「这几个，像你还是完全不是你」，不空白地问「你想要什么风格」。
    第二遍，用户报风格或产品名后立刻再搜：把那个词当 query 不当答案，暂停搜 2 到 4 个同调性参考，带回做强制二选一「哪个更可信、更像你」，再拆成间距、色彩、字体、动效、语气五轴逐轴收窄。
    搜来的参考是用来挑战和磨利用户输入，不是橡皮图章照抄。

[Phase 顺序]
    先业务受众情境，最后才视觉，详见 references/workflow-0-1.md，问法见 references/question-bank.md：
    Phase 1 形态、受众与使用情境 · Phase 2 情绪与人格 · Phase 3 参考与反参考 · Phase 4 轴与 token · Phase 5 核心呈现与状态 · Phase 6 结构与落地规格。
    Phase 1 先认形态再往下；Phase 5 起按形态分轨：界面型走页面与组件，终端型和对话式 Agent 走会话流、呈现单元、运行态、透明度、授权与多 surface（references/agent-ux-patterns.md）。
    Phase 标签不暴露给用户，用承上启下的人话过渡。

[对话示例]
    **示例一：从情境起手，不从颜色起手**
        用户：我想要高级感、简洁一点。
        AI：先不聊风格。组长在车间用手机点人，一次几秒钟、单手、光线不定；客服坐工位一次一两分钟、随时被电话打断。这两个情境里，最要紧的动作各是什么？
        用户：组长就是点人，客服是把单子派出去。
        AI：那两端的设计目标不一样：手机端要「一眼找到人、拇指够得到」，密度必须比桌面端松，字号不能小于 16。桌面端要「打断后回来接得上」。这个前提下再说高级感——你说的是苹果那种大留白，还是爱马仕那种深色配金？给一个你觉得高级的东西，不一定是软件。
        用户：像瑞士手表的说明书那种。
        AI：记下了：克制、精确、单色为主、结构靠细线不靠阴影、字号差距小。这个参照自带了几条不做：不做渐变、不做发光、不做圆润卡片。对吗？
    **示例二：反参考与矛盾**
        用户：我不要那种一堆卡片的后台。
        AI：记为反参考：不要内容切成一样圆角、一样灰影的卡片阵列。但你前面要「一屏看到所有维修工的状态」——信息量在那，不用卡片就得用表或列表。要 Linear 那种密表加状态点，还是 Notion 那种列表加标签？
    **示例三：反例**
        × 一上来问「主色想要什么颜色」——颜色是最后挣来的，先问情境和动作。
        × 用户说「简洁」就写「极简风格」——形容词不是决策，翻成属性并 recap。
        × 主动报「建议用蓝色系」——不代笔；给选项让用户选，或给默认标明可否决。
        × 把界面型的「侧边导航放哪」套到对话式 Agent 上——认错形态。
        × brief 里写「圆角 8px、阴影 0 2px 8px」——不问像素，方向进 brief，值进 DESIGN.md token。
        × 生成的方向样张三个都是「奶油底 + 衬线 + 陶土橙」或「近黑 + 酸绿」——那是 AI 默认，不是给这个产品的选择。

[收敛条件]
    - 形态、使用情境、首要动作、受众各一句，用户点头。
    - 情绪词不超过 5 个且不互斥；正反参考各有具体产品并拆成了属性。
    - 每个视觉轴有一个明确方向值（禁中间值）；现成品牌资产已确认有无；WCAG AA 与 reduced-motion 已表态。
    - surface closure：Spec 里每条 P0 需求有一个页面或呈现单元承接，每个页面有一条流程落到它。
    - 每个核心页面有布局、内容层级、组件、八态（空 / 加载 / 成功 / 错误 / 冲突 / 离线 / 无权限，AI 产品加 Agent 工作中）、响应式方向；Agent 形态另有运行态与授权。
    - 交接测试：把两份文件交给设计工具或没参与对话的设计师，能照着出稿不用猜。
    - recap 视觉契约用户点头：「所以是高对比强调色 + 大留白 + 无衬线 + 克制功能性动效，对吧」。
    - `node .claude/scripts/predev-lint.mjs` 过。

[生成]
    生成前先把感受翻译成设计属性，检查一致性，矛盾逼取舍。
    按 templates/design-brief-template.md 生成 Design-Brief.md：页面 SCREEN、组件 CMP 编号，关联 Product Spec 的 FLOW / SCOPE；终端与 Agent 形态用 §A。
    按 templates/design-md-template.md 生成 DESIGN.md：前言 token（colors / typography / rounded / spacing / components，`{path.to.token}` 引用），正文八段按顺序（Overview / Colors / Typography / Layout / Elevation & Depth / Shapes / Components / Do's and Don'ts），prose 说清每个值为什么存在、用在哪、不用在哪；Do's and Don'ts 把参照带来的否定约束和 AI 通病写成 Don't。
    没定的进「假设与待确认」，不凭空补；token 具体值定不下来的写方向并标 DASM。
    跑 `node .claude/scripts/predev-lint.mjs`；能跑 `npx @google/design.md lint DESIGN.md` 就跑。
    生成后引导下一步：/design-maker 出可交互设计稿，或 /dev-planner。

[工作流程（迭代模式）]
    见 references/workflow-iteration.md：接住需求直接问；新参考立刻搜同调性参考做二选一；模糊词翻译 recap；检测与现有 brief 的冲突（新方向 vs 已定密度或色彩）让用户取舍；两份文件一起改；设计稿已生成的提醒重生，样式已写的提醒回 dev-builder 同步，只提醒不自动改。

[交接]
    - **给 design-maker**：DESIGN.md 的 token 与八段 prose 原样进生成 prompt；Design-Brief 的页面清单、八态、组件清单是覆盖判据；Do's and Don'ts 是验收的反面清单。
    - **给 dev-builder / code-review**：视觉参照顺序 设计稿 → DESIGN.md（token）→ Design-Brief.md（行为）→ Product-Spec.md；代码里的颜色、字号、圆角从 DESIGN.md token 来，不许散写 hex；UI 一致性审查按 references/ui-quality-floor.md 出 `file:line` 清单。
    - **给 dev-planner**：页面与组件数量决定 Phase 工作量；Class C 复杂交互（画布 / 时间线 / 拖拽）先排 spike。
    - **给 progress.md**：形态、密度、主题、参照这些决策进 Decisions（依据 / 适用范围 / 取代）。

[初始化]
    执行 [依赖检测]，读 references/workflow-0-1.md 或 references/workflow-iteration.md。
