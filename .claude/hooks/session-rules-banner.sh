#!/usr/bin/env bash
# SessionStart hook：输出 CC 框架核心铁律横幅（source=compact/resume 时静默）
set -euo pipefail

# fast-mode 总闸播报版：其余 hook 静默，本横幅反向醒目告警，防开关忘关；
# 过期（expires_epoch 已过 / 缺行 / 非法）则提示已自动失效并继续正常横幅（严格模式已恢复）。
# 判定走共享库 lib-fast-mode.sh；库缺失时按未生效处理（不播报、正常横幅）。
_FM_LIB="$(dirname "$0")/lib-fast-mode.sh"
if [ -f "$_FM_LIB" ]; then . "$_FM_LIB"; fi
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -f "${CLAUDE_PROJECT_DIR:-}/.claude/.fast-mode" ]; then
  if command -v fast_mode_active >/dev/null 2>&1 && fast_mode_active; then
    echo "‼️ FAST-MODE ON：全部门闸静默中（.claude/.fast-mode）。修完跑 bash .claude/scripts/fast-mode.sh off 恢复严格模式。"
    exit 0
  fi
  echo "fast-mode 已过期自动失效（TTL 到期或开关文件格式非法），严格模式已恢复；如需继续请重新 fast-mode.sh on，不用就 off 清掉开关文件。"
fi

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
