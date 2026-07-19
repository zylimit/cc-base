#!/bin/bash
# Hook: PreToolUse(Bash)。启动 dev server 前清掉常用端口占用进程，避免端口被旧进程占住起不来。
# if = Bash(pnpm dev*) 失效（harness 不稳）→ 脚本内自判：命令非 pnpm dev 直接放行（exit 0）。

# fast-mode 总闸：开关文件内 expires_epoch 未过期则本 hook 静默放行（缺行/非法一律不放行）
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ "$(sed -n 's/^expires_epoch=\([0-9]\{1,\}\)$/\1/p' "${CLAUDE_PROJECT_DIR:-}/.claude/.fast-mode" 2>/dev/null | head -1)" -gt "$(date +%s)" ] 2>/dev/null; then exit 0; fi
INPUT=$(cat 2>/dev/null)
if command -v jq >/dev/null 2>&1; then
  CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
else
  CMD="$INPUT"
fi
printf '%s' "$CMD" | grep -qE 'pnpm[[:space:]]+dev' || exit 0

for port in 3000 3001 4173 5173 8080; do
  lsof -ti:"$port" 2>/dev/null | xargs -r kill -9 2>/dev/null
done
sleep 1
exit 0
