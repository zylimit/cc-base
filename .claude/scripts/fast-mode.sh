#!/usr/bin/env bash
# fast-mode.sh — fast-mode 总闸开关管理。开关文件 .claude/.fast-mode 存在且未过 24h TTL 时，
# .claude/hooks/ 下全部 hook 入口静默放行（快速迭代修 bug 用）；过期自动失效回严格模式。
# 防忘关双保险：session-rules-banner 每次 SessionStart 醒目播报开关状态；TTL 到期自动失效。
# 用法： bash .claude/scripts/fast-mode.sh on|off|status   （不带参数 = status）
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FLAG="$ROOT/.claude/.fast-mode"

# 剩余有效期（分钟）；开关不存在或已过期输出空
remaining() {
  [ -f "$FLAG" ] || return 0
  local mtime age
  mtime=$(stat -c %Y "$FLAG" 2>/dev/null || stat -f %m "$FLAG" 2>/dev/null) || return 0
  age=$(( ( $(date +%s) - mtime ) / 60 ))
  [ "$age" -lt 1440 ] && echo $((1440 - age))
}

case "${1:-status}" in
  on)
    printf 'fast-mode 总闸开关文件：存在且 24h 内有效时全部 hook 静默放行。用 fast-mode.sh off 关闭。\n' > "$FLAG"
    echo "fast-mode: on（$FLAG 已创建/续期，24h 后自动失效；修完务必跑 off 恢复严格模式）"
    ;;
  off)
    rm -f "$FLAG"
    echo "fast-mode: off（开关文件已删，hook 恢复严格拦截）"
    ;;
  status)
    if [ -f "$FLAG" ]; then
      LEFT=$(remaining)
      if [ -n "$LEFT" ]; then
        echo "fast-mode: on（剩余有效期约 ${LEFT} 分钟：$FLAG）"
      else
        echo "fast-mode: 已过期自动失效（开关文件仍在：$FLAG，如需继续请重新 on，不用就 off 清掉）"
      fi
    else
      echo "fast-mode: off"
    fi
    ;;
  *)
    echo "用法: bash .claude/scripts/fast-mode.sh on|off|status" >&2
    exit 2
    ;;
esac
exit 0
