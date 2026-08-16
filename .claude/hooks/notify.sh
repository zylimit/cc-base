#!/bin/bash
# Notification(agent_needs_input|agent_completed|permission_prompt)：桌面通知——后台
# subagent 成为默认形态后（v2.1.198+ spawn 默认 async_launched），完成/需输入不再有
# 同步返回点，用户容易对着安静的终端干等。本 hook 把这三类通知转成终端转义序列
# （OSC 777 桌面通知 + BEL 响铃），经 hook JSON 的 terminalSequence 字段由 Claude Code
# 代发（hook 进程无 /dev/tty，直写会失败；terminalSequence 是官方指定通道）。
# Notification 事件忽略退出码与 stderr，terminalSequence 照常生效；python3 缺失时降级
# 纯 BEL。不拦任何东西，纯可见性。
set -u

HOOK_INPUT=$(cat)
OUT=$(printf '%s' "$HOOK_INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
msg = (d.get('message') or 'Claude Code needs your attention').replace('\n', ' ')[:120]
seq = '\u001b]777;notify;Claude Code;' + msg + '\u0007\u0007'
print(json.dumps({'terminalSequence': seq}))
" 2>/dev/null) || OUT='{"terminalSequence":"\u001b]777;notify;Claude Code;attention\u0007\u0007"}'

printf '%s\n' "$OUT"
exit 0
