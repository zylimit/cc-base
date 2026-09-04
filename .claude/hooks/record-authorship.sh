#!/bin/bash
# PostToolUse(Edit|Write|NotebookEdit)：作者台账自动记账——把「谁写了哪个文件」喂给
# harness authorship record，让 review verdict 的「评审者不是作者」从纸面变成引擎判得了的事。
# 为什么要它：引擎侧 authorship record|show 早就有，但全仓没有一处调用，账本永远是空的，
#   verdict 于是永远走「账本为空 → authorshipEnforced:false」——规则只存在于文字里。
#   Claude Code 的 hook 输入在 sub-agent 内触发时带 agent_type / agent_id，这正是账本缺的那一半。
# 谁算作者：agent_type 优先（角色名才是评审侧 review lens --agent <id> 用得上的同一把钥匙），
#   缺则退 agent_id，两者都无 = 主 Agent 自己在写，记 main。agentType 字段原样传 agent_type
#   （空串由引擎归一为 null），agentId 才是匹配键。
# 启用条件与降级：catalog + node 双满足才跑（lib-harness 守卫）——大仓治理默认关闭，无 catalog
#   时立刻 exit 0，不写任何文件、不调引擎；jq 缺失同样静默退出（可判定的降级，非假绿）。
# 这是记账不是闸：任何内部错误一律 exit 0（PostToolUse 的非 0 退出码会回灌工具结果），
#   只往 stderr 写一行说明；引擎调用套 timeout 10（无 timeout 命令则裸跑，settings 里注册的
#   timeout 兜底），一次卡死不许拖住每一次 Edit。

# fast-mode 总闸：共享库判定（.claude/.fast-mode 内 expires_epoch 未过期才静默放行；库缺失 fail-closed 不放行）
_FM_LIB="$(dirname "$0")/lib-fast-mode.sh"
if [ -f "$_FM_LIB" ]; then . "$_FM_LIB"; if fast_mode_active; then exit 0; fi; fi

INPUT=$(cat 2>/dev/null)

_HARNESS_LIB="$(dirname "$0")/lib-harness.sh"
[ -f "$_HARNESS_LIB" ] || exit 0
# shellcheck source=/dev/null
. "$_HARNESS_LIB"
harness_enabled || exit 0
harness_node_ok || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# harness_enabled 已保证 CLAUDE_PROJECT_DIR 非空
ROOT="$CLAUDE_PROJECT_DIR"

# NotebookEdit 的路径字段叫 notebook_path，不叫 file_path——只认一个会让 notebook 编辑无声漏账
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)
[ -n "$FILE_PATH" ] || exit 0

AGENT_TYPE=$(printf '%s' "$INPUT" | jq -r '.agent_type // empty' 2>/dev/null)
AGENT_ID=$(printf '%s' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null)
AUTHOR="$AGENT_TYPE"
[ -n "$AUTHOR" ] || AUTHOR="$AGENT_ID"
[ -n "$AUTHOR" ] || AUTHOR="main"

# 仓外路径（如 /tmp 下的一次性脚本）不在任何 diff 里，记了也永远匹配不上；相对路径按项目根解析
case "$FILE_PATH" in
  /*|[A-Za-z]:*) ;;
  *) FILE_PATH="$ROOT/$FILE_PATH" ;;
esac
case "$FILE_PATH" in
  "$ROOT"/*) ;;
  *) exit 0 ;;
esac
REL="${FILE_PATH#"$ROOT"/}"
[ -n "$REL" ] || exit 0
# 引擎侧比对的是正斜杠形态（core.mjs toPosixPath / changedSet），这边先归一，别把归一留给消费方
REL="${REL//\\//}"
# 前缀比对挡得住 /etc/passwd，挡不住 ../outside.ts——那条拼出来的字面量照样以 $ROOT/ 开头。
# 账本靠逐字相等匹配 changedSet，记一条带 .. 或 ./ 的路径只会留下永远匹配不上的脏行（.ps1 侧
# 由 GetFullPath 折叠掉，这边手动折）
while [ "${REL#./}" != "$REL" ]; do REL="${REL#./}"; done
case "$REL" in
  ..|../*|*/../*|*/..) exit 0 ;;
esac
[ -n "$REL" ] || exit 0

# 用 jq 造 payload：文件名里的引号 / 反斜杠 / 非 ASCII 交给它转义，手拼字符串迟早拼出坏 JSON
PAYLOAD=$(jq -nc --arg id "$AUTHOR" --arg type "$AGENT_TYPE" --arg f "$REL" \
  '{agentId:$id, agentType:$type, files:[$f]}' 2>/dev/null)
[ -n "$PAYLOAD" ] || exit 0

# cd 进项目根：record 要算 baseCommit（git 跑在 cwd），cwd 不对会记下一个无关仓的 HEAD
cd "$ROOT" 2>/dev/null || exit 0

run_record() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 10 node "$ROOT/.claude/harness/harness.mjs" authorship record
  else
    harness_run authorship record
  fi
}

ERR=$(printf '%s' "$PAYLOAD" | run_record 2>&1 >/dev/null)
RC=$?
if [ "$RC" -ne 0 ]; then
  echo "[record-authorship] 作者台账未记上（$REL ← $AUTHOR）：harness authorship record 退出码 $RC。$(printf '%s' "$ERR" | head -1)" >&2
fi
exit 0
