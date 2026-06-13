#!/bin/bash
# Hook: PostToolUse(Bash) if git commit*
# commit 后若本地领先上游则自动 push。
# 不解析 hook 退出码字段（PostToolUse 输入 schema 跨版本不稳，旧写法用了
# 不存在的 .tool_exit_code 导致永不 push）——改用 git 状态判断，确定可靠。

# 脚本内自判触发命令：非 git commit 输入直接退出（替代失效的 if = Bash(git commit*)）
HOOK_INPUT=$(cat)
CMD=$(echo "$HOOK_INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('command',''))" 2>/dev/null || true)
echo "$CMD" | grep -qE 'git[[:space:]]+commit' || exit 0

# 空值兜底：cd "" 是 no-op 不会失败，会误推 cwd 所在的无关 repo，必须显式拦截
[ -z "$CLAUDE_PROJECT_DIR" ] && exit 0
cd "$CLAUDE_PROJECT_DIR" 2>/dev/null || exit 0

# 无上游分支（没配远程/未设 tracking）→ 跳过
git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1 || exit 0

# 本地领先上游的 commit 数 > 0 才推
AHEAD=$(git rev-list '@{u}..HEAD' --count 2>/dev/null)
if [ "${AHEAD:-0}" -gt 0 ]; then
  git push >/dev/null 2>&1 || true
fi
exit 0
