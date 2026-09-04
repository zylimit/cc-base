#!/usr/bin/env bash
# lib-fast-mode.sh — fast-mode 总闸共享判定库（各 hook source 后调 fast_mode_active）。
# 开关文件 $CLAUDE_PROJECT_DIR/.claude/.fast-mode 内 expires_epoch=<unix秒> 行决定有效性：
# > now 才算开着（返回 0 = hook 可静默放行）；缺环境变量 / 缺文件 / 缺行 / 非数字 / 已过期
# 一律返回 1（fail-closed，走严格逻辑）。故意不依赖 jq，Bash / PowerShell 读同一个文件。

# 开关文件路径（缺 CLAUDE_PROJECT_DIR 输出空）
fast_mode_flag() {
  [ -n "${CLAUDE_PROJECT_DIR:-}" ] || return 1
  printf '%s/.claude/.fast-mode\n' "$CLAUDE_PROJECT_DIR"
}

# fast-mode 是否生效：0 = 生效（放行），非 0 = 严格模式
fast_mode_active() {
  local flag exp now
  flag=$(fast_mode_flag) || return 1
  [ -f "$flag" ] || return 1
  # 先剥 \r 再匹配：fast-mode.ps1 在 Windows 上写的是 CRLF，sed 的 $ 不认 \r 会读成「没这行」，
  # 而引擎侧的 JS 把 \r 当行终止符照样读到——同一个开关一边开一边关，比两边都关更糟。
  exp=$(tr -d '\r' < "$flag" 2>/dev/null | sed -n 's/^expires_epoch=\([0-9]\{1,\}\)$/\1/p' | head -1)
  case "$exp" in
    ''|*[!0-9]*) return 1 ;;
  esac
  now=$(date +%s 2>/dev/null) || return 1
  [ "$exp" -gt "$now" ]
}
