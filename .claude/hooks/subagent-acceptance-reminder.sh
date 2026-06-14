#!/usr/bin/env bash
# Hook: SubagentStop（matcher: implementer|code-reviewer|tester|deployer）
# 执行类 Sub-Agent 返回时，注入提醒：按「验收以客观证据为准」铁律核验，勿信自报
set -euo pipefail

# python3 缺失 → 无法解析/生成 JSON，降级退出（不阻断，不 block subagent）
command -v python3 >/dev/null 2>&1 || exit 0

INPUT=$(cat)
AGENT=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('agent_type','') or d.get('subagent_type',''))" 2>/dev/null || true)
[ -z "$AGENT" ] && AGENT="子 Agent"

MSG="${AGENT} 已返回。按验收铁律：不以它的自报（完成/通过/空回复）为准，核客观证据——编码/修复→复核编译输出 + 对照 Spec 逐条；测试→复核测试运行器真实输出；部署→独立核查三件套。"

python3 -c "import json,sys; print(json.dumps({'hookSpecificOutput':{'hookEventName':'SubagentStop','additionalContext':sys.argv[1]}}))" "$MSG" 2>/dev/null || exit 0
exit 0
