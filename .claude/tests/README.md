# cc-base 框架自测 harness

借鉴 Superpowers 的 `tests/`，验证 cc-base 自己的铁律会触发——尤其是
「匹配触发条件时先调 Skill 再动手，不偷跑」这条。

## 测什么

两层断言，对应两个失败模式：

1. **该调的 Skill 真被调了**——喂一个 naive prompt（如「我想做个 todo 应用」），
   断言事件日志里出现对应 Skill 的工具调用。验的是路由规则（CLAUDE.md [Skill 调用规则]）
   确实触发，而不是被 agent 忽略。
2. **调 Skill 之前没有偷跑**——在 invoke Skill 之前就出现 Edit/Write/Bash 等动作工具，
   说明 agent 跳过流程自己干了，判 FAIL。允许清单：`Skill`、`TodoWrite`、`Read`
   （规划与只读无副作用，不算偷跑）。

机制借 Superpowers：`claude -p --output-format stream-json` 把每个事件输出成一行 JSON，
再用 grep 在日志上做断言。

## 怎么跑

```bash
# 脚手架自测：无依赖、不耗 token、秒级返回。优先跑这个。
bash .claude/tests/selftest.sh

# 全量：先跑 selftest，再跑真触发 cases。
bash .claude/tests/cases/run-all.sh
```

- **selftest.sh** 用 `fixtures/` 里手造的 stream-json 样例跑断言库本身，
  **不需要 claude CLI、不调真 LLM**。验证：good-run 全 PASS、premature-run 的偷跑
  断言被正确判 FAIL（「预期失败」也算 selftest 通过——断言库正确识别偷跑才对）。
- **cases/*.sh** 是真触发测试，**需要真 claude CLI，会耗 token**（多 Agent 路由实测）。
  `run-all.sh` 会 `command -v claude` 探测：没有 CLI 就明确打印
  `SKIPPED: 无 claude CLI` 并只跑 selftest——**绝不因缺 CLI 静默假绿**
  （呼应框架反静默失败的铁律：未执行 != 通过）。

  两个落地约束（踩过的坑）：
  - **必须在能加载到 cc-base `.claude/CLAUDE.md` 的目录里跑**——case 脚本 `cd` 到仓库根
    （`git rev-parse --show-toplevel`，失败回退相对路径）。在空临时目录里跑框架路由规则
    根本不生效，Skill 不会触发，测出来是假阴。
  - **`--verbose` 是当前 claude CLI 对 `-p` + `--output-format stream-json` 的硬性要求**，
    少了会直接报 `requires --verbose` 并退出、日志只剩一行错误。

## 文件结构

```
.claude/tests/
├── test-helpers.sh                       # 可 source 的断言库
├── selftest.sh                           # 脚手架自测（无依赖）
├── README.md
├── fixtures/                             # 手造 stream-json 样例（让断言库脱离真 LLM 自测）
│   ├── good-run.jsonl                    # 先 Skill 再 Edit —— 应两个断言全过
│   └── premature-run.jsonl              # 先 Edit/Bash 再 Skill —— premature 断言应判 FAIL
└── cases/                                # 真触发测试（需 claude CLI）
    ├── run-all.sh                        # 跑全部；无 CLI 时 SKIP cases 只跑 selftest
    ├── todo-app-triggers-product-spec.sh # naive prompt → product-spec-builder
    └── bug-report-triggers-bug-fixer.sh  # naive prompt → bug-fixer
```

## 断言含义（test-helpers.sh）

| 断言 | 含义 |
|------|------|
| `assert_skill_invoked <log> <skill>` | 日志里有 `"name":"Skill"` 且 skill 参数匹配（裸名或 `namespace:名`）|
| `assert_no_premature_action <log>` | 第一个 Skill 调用之前的 tool_use，剔除允许清单后无残留；全程无 Skill 调用也判 FAIL |
| `assert_contains <log> <pattern>` | 日志匹配到 grep 扩展正则 pattern |
| `assert_order <log> <p1> <p2>` | p1 首次出现的行号早于 p2 首次出现的行号 |

每个断言打印 `[PASS]`/`[FAIL]` + 证据行，并累加 `TESTS_PASS`/`TESTS_FAIL`。
`print_summary` 打印计数小结。

## 怎么加新 case

1. 在 `cases/` 下照 `todo-app-triggers-product-spec.sh` 复制一份。
2. 改三处：`PROMPT`（naive 触发语）、`SKILL`（期望触发的 skill 名）、文件名。
3. 通常断言就是 `assert_skill_invoked` + `assert_no_premature_action` 两条；
   需要顺序/包含校验时再加 `assert_order` / `assert_contains`。
4. 无需改 `run-all.sh`——它自动遍历 `cases/*.sh`（除自己）。
5. 想顺手扩 selftest 的脱机覆盖，往 `fixtures/` 加一条 `.jsonl` 样例，
   再到 `selftest.sh` 里加对应的 `expect_pass`/`expect_fail` 行。

## 与框架铁律的关系

- 反静默失败：缺 CLI → SKIP 并明示，不假绿。
- 验证即证据：selftest/cases 的判定都基于事件日志的客观 grep 结果，不靠自述。
- 风格仿 `make-release.sh`：`set -eu`、中文头注释、`mktemp`+`trap` 清理、命令失败兜底。
- 脚手架自检类闸（本 selftest：验断言库没坏）不适用 CLAUDE.md「闸长期全绿就砍」——那条针对的是从不产出 FIX_REQUIRED 的**缺陷探测闸**，脚手架自检本就该常绿。
```
