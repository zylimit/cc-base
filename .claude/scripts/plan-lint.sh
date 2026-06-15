#!/usr/bin/env bash
# plan-lint.sh — DEV-PLAN.md 静态质量门（把 dev-planner 的规则自动化）。
# 用法： bash .claude/scripts/plan-lint.sh [path]   默认 DEV-PLAN.md
# 文件不存在则提示并正常退出（cc-base 本体没有 DEV-PLAN）。
set -eu

PLAN="${1:-DEV-PLAN.md}"

if [ ! -f "$PLAN" ]; then
  echo "plan-lint: 无 DEV-PLAN，跳过 ($PLAN)"
  exit 0
fi

python3 - "$PLAN" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
lines = text.splitlines()
failures = []

def fail(message):
    failures.append(message)

# 标记 ``` 围栏内的行号（成对围栏之间，含围栏行本身），占位符扫描跳过这些行
fenced = set()
in_fence = False
for i, line in enumerate(lines):
    if re.match(r"\s*```", line):
        fenced.add(i)
        in_fence = not in_fence
        continue
    if in_fence:
        fenced.add(i)

def lines_matching(pattern):
    return [i + 1 for i, line in enumerate(lines)
            if i not in fenced and re.search(pattern, line, re.I)]

# 1) 禁占位符（对齐 dev-planner SKILL.md 已写的规则）
placeholder_patterns = [
    r"\bTBD\b",
    r"\bTODO\b",
    "待补充",
    "待确定",
    "类似 Task",
    "类似 Phase",
    "按需调整",
    "做相应修改",
    "implement later",
]
for pattern in placeholder_patterns:
    hits = lines_matching(pattern)
    if hits:
        loc = ", ".join(f"L{n}" for n in hits)
        fail(f"占位符命中: {pattern}  ({loc})")

# 2) Phase 结构完整：每个 Phase 须有 交付内容/关键文件/Task 清单/验收标准
phase_matches = list(re.finditer(r"^## Phase\s+\d+[:：].*$", text, re.M))
if not phase_matches:
    fail("未找到任何 ## Phase 小节")

def line_no(pos):
    return text.count("\n", 0, pos) + 1

for index, match in enumerate(phase_matches):
    start = match.start()
    end = phase_matches[index + 1].start() if index + 1 < len(phase_matches) else len(text)
    section = text[start:end]
    title = match.group(0).strip()
    ln = line_no(start)
    for anchor in ["**交付内容**", "**关键文件**", "**Task 清单**", "**验收标准**"]:
        if anchor not in section:
            fail(f"L{ln} {title} 缺字段 {anchor}")
    # 3) 任务粒度：每个 Phase ≥ 1 个 Task
    task_count = len(re.findall(r"^\s*-\s*\*\*Task\s+\d+\.\d+[:：]", section, re.M))
    if task_count == 0:
        fail(f"L{ln} {title} 没有可执行的 Task 条目（需 - **Task N.M：...**）")

if failures:
    print("plan-lint: 失败", file=sys.stderr)
    for item in failures:
        print(f"- {item}", file=sys.stderr)
    raise SystemExit(1)

print(f"plan-lint: 通过 ({path})")
PY
