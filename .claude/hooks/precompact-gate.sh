#!/bin/bash
# PreCompact hook: 压缩前守门——「session 内压缩丢决策」的可拦截化。
# 压缩会把对话正文换成摘要，未落盘的决策/待审状态最容易在这一步蒸发。本闸在压缩前检查：
#   C1：.needs-review 有待审文件（审查闭环没走完，压缩后欠账语境丢失）
#   C2：工作树有未提交代码/家底改动但 progress.md 不在改动集（决策还没写进项目记忆）
# 命中任一 → 拦一次压缩（decision:block），提示先 /record 固化 + 处理待审再压缩。
# 防砖设计（与 stop 闸相反，本闸倾向放行）：
#   - 同一 session 拦过一次后 10 分钟内不再拦（.precompact-block-epoch 记上次拦截时间）——
#     auto 压缩可能是上下文触顶的恢复动作，拦第二次只会让请求反复失败；
#   - 脚本自身出错 fail-open 放行（拦不住压缩顶多丢注记，拦死压缩会卡死整个会话）。
# 状态干净 / 非 git / 无 progress.md → 放行并清标记。

# fast-mode 总闸：共享库判定（.claude/.fast-mode 内 expires_epoch 未过期才静默放行；库缺失 fail-closed 不放行）
_FM_LIB="$(dirname "$0")/lib-fast-mode.sh"
if [ -f "$_FM_LIB" ]; then . "$_FM_LIB"; if fast_mode_active; then exit 0; fi; fi

# fail-open：本闸出错一律放行（见头注——压缩被拦死比丢一次提醒更伤）。
trap 'exit 0' ERR
set -E

# 消费 stdin（trigger/custom_instructions 本闸不区分，manual/auto 同一判定）
cat >/dev/null 2>&1 || true

ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
MARK="$ROOT/.claude/.precompact-block-epoch"

# 10 分钟冷却窗：拦过一次就先放行，给「记录后重试」留通道，也防 auto 压缩反复失败
NOW=$(date +%s 2>/dev/null || echo 0)
if [ -f "$MARK" ]; then
  LAST=$(sed -n 's/^\([0-9]\{1,\}\)$/\1/p' "$MARK" 2>/dev/null | head -1)
  case "$LAST" in
    ''|*[!0-9]*) ;;
    *) if [ $((NOW - LAST)) -lt 600 ]; then exit 0; fi ;;
  esac
fi

DIRTY_REASON=""

# C1：待审清单未清（复用 stop-gate 的清单语义：去空行去 clean 后仍有条目）
STATE_FILE="$ROOT/.claude/.needs-review"
if [ -f "$STATE_FILE" ]; then
  PENDING=$(grep -vE '^[[:space:]]*$' "$STATE_FILE" 2>/dev/null | grep -vx "clean" || true)
  if [ -n "$PENDING" ]; then
    N=$(printf '%s\n' "$PENDING" | wc -l | tr -d ' ')
    DIRTY_REASON="待审清单未清（${N} 个文件待 code review）"
  fi
fi

# C2：代码/家底脏而 progress.md 未同步（three-file-sync C1 的简化版，只判是否需要先记录）
if [ -z "$DIRTY_REASON" ] && [ -f "$ROOT/progress.md" ] && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  PREFIX=$(git -C "$ROOT" rev-parse --show-prefix 2>/dev/null)
  CODE_DIRTY=0
  PROG_DIRTY=0
  classify_path() {
    local path=$1
    [ "$path" = "progress.md" ] && PROG_DIRTY=1
    case "$path" in
      .claude/evidence/*|*/.claude/evidence/*|node_modules/*|*/node_modules/*|out/*|*/out/*|dist/*|*/dist/*) ;;
      *.sh|*.ps1|*.ts|*.tsx|*.js|*.jsx|*.py|*.css|*.go|*.rs) CODE_DIRTY=1 ;;
      .claude/*|*/.claude/*) CODE_DIRTY=1 ;;
    esac
  }
  classify_rel() {
    local path=$1
    if [ -n "$PREFIX" ]; then
      case "$path" in
        "$PREFIX"*) path=${path#"$PREFIX"} ;;
        *) return 0 ;;
      esac
    fi
    classify_path "$path"
  }
  while IFS= read -r -d '' rec; do
    status=${rec:0:2}
    classify_rel "${rec:3}"
    case "$status" in
      R*|C*|?R|?C) IFS= read -r -d '' oldpath && classify_rel "$oldpath" ;;
    esac
  done < <(git -C "$ROOT" status --porcelain -z -- . 2>/dev/null)
  if [ "$CODE_DIRTY" -eq 1 ] && [ "$PROG_DIRTY" -eq 0 ]; then
    DIRTY_REASON="工作树有未提交代码/家底改动但 progress.md 未同步（本轮决策还没进项目记忆）"
  fi
fi

if [ -z "$DIRTY_REASON" ]; then
  rm -f "$MARK"
  exit 0
fi

printf '%s\n' "$NOW" > "$MARK" 2>/dev/null || true
REASON="压缩前守门：${DIRTY_REASON}。压缩会把对话正文换成摘要，这些状态最容易随之蒸发——请先派 progress-recorder /record 固化决策/完成事项（待审项处理或显式记欠账），再重试压缩。本次拦截后 10 分钟内不会再拦。"

# shellcheck source=/dev/null
. "$(dirname "$0")/lib-gate-log.sh" 2>/dev/null || true
gate_log "precompact-gate" "$REASON"

if command -v jq >/dev/null 2>&1; then
  jq -nc --arg r "$REASON" '{decision:"block",reason:$r}'
else
  echo '{"decision":"block","reason":"压缩前守门：有待审文件或 progress.md 未同步，请先 /record 固化再压缩（10 分钟内不再拦）。"}'
fi
exit 0
