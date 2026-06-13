#!/usr/bin/env bash
# SessionStart hook：输出 CC 框架核心铁律横幅（source=compact/resume 时静默）
set -euo pipefail

# compact/resume 不重复输出
HOOK_INPUT=$(cat)
SOURCE=$(echo "$HOOK_INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('source',''))" 2>/dev/null || true)
if [[ "$SOURCE" == "compact" || "$SOURCE" == "resume" ]]; then
  exit 0
fi

cat <<'BANNER'
🔒 CC框架核心铁律：
1. 主 Agent 不亲自编码/审查/测试/部署——一律派 Sub-Agent（implementer / code-reviewer / tester / deployer）
2. 交叉审查：implementer 写 → code-reviewer 审（用 fresh 实例，非同 session 自审）
3. 验收以客观证据为准：跑命令核查，不只信 Sub-Agent 自述
4. 存量资产保留复用：删/停/重写现有 hook/skill 须用户拍板
5. 查证后再结论：结论前必须有证据（WebSearch / 命令输出 / 官方文档）
6. 三文件同步：决策/约束/完成即时写 progress.md；需求变更写 Product-Spec + CHANGELOG
BANNER

exit 0
