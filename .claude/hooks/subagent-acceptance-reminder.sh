#!/usr/bin/env bash
# Hook: SubagentStop（matcher: implementer|code-reviewer|tester|deployer）
# 执行类 Sub-Agent 返回时，注入提醒：按「验收以客观证据为准」铁律核验，勿信自报
set -euo pipefail

# fast-mode 总闸：共享库判定（.claude/.fast-mode 内 expires_epoch 未过期才静默放行；库缺失 fail-closed 不放行）
_FM_LIB="$(dirname "$0")/lib-fast-mode.sh"
if [ -f "$_FM_LIB" ]; then . "$_FM_LIB"; if fast_mode_active; then exit 0; fi; fi

# python3 缺失 → 无法解析/生成 JSON，降级退出（不阻断，不 block subagent）
command -v python3 >/dev/null 2>&1 || exit 0

INPUT=$(cat)
AGENT=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('agent_type','') or d.get('subagent_type',''))" 2>/dev/null || true)
[ -z "$AGENT" ] && AGENT="子 Agent"

# 去重：同一子代理完成事件可能重复触发本 hook（如 stop 闸拦回子代理、其再停一次），反复提醒
# 会淹没子代理终报。每个完成事件只提醒一次——有 agent_id 用之，否则取稳定字段哈希做键；
# 已提醒键记 .claude/.subagent-reminded（保留最近 50 条，状态损坏/缺失只会多提醒一次，不阻断）。
if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  KEY=$(echo "$INPUT" | python3 -c "import sys,json,hashlib; d=json.load(sys.stdin); print(d.get('agent_id') or hashlib.sha256(('%s|%s|%s' % (d.get('session_id',''), d.get('agent_type','') or d.get('subagent_type',''), d.get('transcript_path',''))).encode()).hexdigest())" 2>/dev/null || true)
  SEEN="$CLAUDE_PROJECT_DIR/.claude/.subagent-reminded"
  if [ -n "$KEY" ]; then
    if grep -qxF "$KEY" "$SEEN" 2>/dev/null; then exit 0; fi
    echo "$KEY" >> "$SEEN"
    if [ "$(wc -l < "$SEEN")" -gt 50 ]; then tail -50 "$SEEN" > "$SEEN.tmp" && mv "$SEEN.tmp" "$SEEN"; fi
  fi
fi

MSG="${AGENT} 已返回。按验收铁律：不以它的自报（完成/通过/空回复）为准，核客观证据——编码/修复→复核编译输出 + 对照 Spec 逐条；测试→复核测试运行器真实输出；部署→独立核查三件套。"

python3 -c "import json,sys; print(json.dumps({'hookSpecificOutput':{'hookEventName':'SubagentStop','additionalContext':sys.argv[1]}}))" "$MSG" 2>/dev/null || exit 0
exit 0
