#!/usr/bin/env bash
# skill-description-lint.sh — skill description CSO 门（把手工 CSO 规则自动化）。
# 扫 .claude/skills/*/SKILL.md 的 frontmatter description：
#   ① 必须存在  ② ≤180 字  ③ 触发式开头（含"当…时使用"或"由…调用"这类触发条件）
#   ④ 禁流程总结词作主体（通篇是 生成/通过/分阶段/输出/支持…… 而无触发条件）
# 命中列文件 + 问题 + 非零退出。
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)

python3 - "$ROOT" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
skills_dir = root / ".claude" / "skills"
failures = []
passed = []

def fail(path, message):
    failures.append(f"{path.relative_to(root)}: {message}")

# 触发条件信号：有"当…时"或"由…调用"即视为触发式描述
def has_trigger(desc):
    if re.search(r"当.*?时", desc):
        return True
    if re.search(r"由.*?调用", desc):
        return True
    return desc.startswith("当") or desc.startswith("由")

# 流程总结词：当描述只有这些、没有任何触发条件时判为"流程总结作主体"
workflow_tokens = ["生成", "通过", "分阶段", "输出", "支持", "执行", "内置", "维护"]

for path in sorted(skills_dir.glob("*/SKILL.md")):
    text = path.read_text(encoding="utf-8")
    m = re.match(r"---\n(.*?)\n---\n", text, re.S)
    if not m:
        fail(path, "缺 frontmatter")
        continue

    # 逐行解析顶层字段；遇 块标量指示符（> | >- |- >+ |+）则续读后续缩进行拼成真正的值
    fields = {}
    fm_lines = m.group(1).splitlines()
    i = 0
    while i < len(fm_lines):
        line = fm_lines[i]
        # 只认顶层键（行首无缩进），缩进行交给块标量续读处理
        if not line or line[0] in (" ", "\t") or ":" not in line:
            i += 1
            continue
        key, value = line.split(":", 1)
        key = key.strip()
        value = value.strip()
        if value in (">", "|", ">-", "|-", ">+", "|+"):
            folded = value.startswith(">")  # 折叠：行间空格拼；字面：行间换行拼
            block = []
            i += 1
            while i < len(fm_lines):
                nxt = fm_lines[i]
                if nxt.strip() == "":
                    block.append("")
                    i += 1
                    continue
                if nxt[0] in (" ", "\t"):
                    block.append(nxt.strip())
                    i += 1
                    continue
                break  # 回到顶层键，块结束
            joined = " ".join(b for b in block if b) if folded else "\n".join(block).strip()
            fields[key] = joined
        else:
            fields[key] = value.strip('"')
            i += 1

    desc = fields.get("description", "")

    # ① 必须存在
    if not desc:
        fail(path, "缺 description")
        continue

    problems = []
    # ② ≤180 字
    if len(desc) > 180:
        problems.append(f"description 超长: {len(desc)} 字 (上限 180)")

    # ③ 触发式开头
    trigger = has_trigger(desc)
    if not trigger:
        problems.append("description 应以触发条件开头（当…时使用 / 由…调用）")

    # ④ 禁流程总结词作主体——仅在无触发条件时才追究
    if not trigger:
        hits = [t for t in workflow_tokens if t in desc]
        if hits:
            problems.append("description 以流程总结词作主体且无触发条件: " + "、".join(hits))

    if problems:
        for p in problems:
            fail(path, p)
    else:
        passed.append(path.relative_to(root))

print(f"skill-description-lint: 扫描 {len(passed) + len({f.split(':')[0] for f in failures})} 个 skill")
for p in passed:
    print(f"  ✓ {p}")

if failures:
    print("skill-description-lint: 失败", file=sys.stderr)
    for item in failures:
        print(f"  ✗ {item}", file=sys.stderr)
    raise SystemExit(1)

print("skill-description-lint: 通过")
PY
