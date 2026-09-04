#!/usr/bin/env bash
# fast-mode.sh — fast-mode 总闸开关管理。开关文件 .claude/.fast-mode 内记录 expires_epoch（unix 秒），
# 未过期时 .claude/hooks/ 下全部 hook 入口静默放行（快速迭代修 bug 用）；过期自动失效回严格模式。
# 防忘关双保险：session-rules-banner 每次 SessionStart 醒目播报开关状态；TTL 到期自动失效。
# 用法： bash .claude/scripts/fast-mode.sh on [hours]|off|status   （不带参数 = status；hours 默认 24）
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FLAG="$ROOT/.claude/.fast-mode"
DEFAULT_HOURS=24

# 从开关文件读 expires_epoch（纯数字才算数）；缺文件/缺行/非数字输出空
expiry() {
  [ -f "$FLAG" ] || return 0
  local exp
  # 同 lib-fast-mode.sh：先剥 \r，CRLF 版开关文件不许在这里读成「没这行」
  exp=$(tr -d '\r' < "$FLAG" 2>/dev/null | sed -n 's/^expires_epoch=\([0-9]\{1,\}\)$/\1/p' | head -1)
  [ -n "$exp" ] && echo "$exp"
}

# 剩余有效期（分钟）；开关不存在、格式坏或已过期输出空
remaining() {
  local exp now
  exp=$(expiry)
  [ -n "$exp" ] || return 0
  now=$(date +%s)
  [ "$exp" -gt "$now" ] && echo $(( (exp - now + 59) / 60 ))
}

case "${1:-status}" in
  on)
    HOURS="${2:-$DEFAULT_HOURS}"
    case "$HOURS" in
      ''|*[!0-9]*|0) echo "hours 必须是正整数（如 fast-mode.sh on 3）" >&2; exit 2 ;;
    esac
    NOW=$(date +%s)
    EXPIRES=$((NOW + HOURS * 3600))
    {
      printf 'enabled_epoch=%s\n' "$NOW"
      printf 'expires_epoch=%s\n' "$EXPIRES"
      printf 'hours=%s\n' "$HOURS"
    } > "$FLAG"
    echo "fast-mode: on（$FLAG 已创建/续期，${HOURS}h 后自动失效；修完务必跑 off 恢复严格模式）"
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
    echo "用法: bash .claude/scripts/fast-mode.sh on [hours]|off|status" >&2
    exit 2
    ;;
esac
exit 0
