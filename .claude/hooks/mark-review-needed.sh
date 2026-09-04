#!/bin/bash
# PostToolUse hook: 项目业务代码被编辑/创建后，把文件登记进待审清单
# 设计（15W 规模优化）：
#   - 全局布尔 → 按文件登记：.needs-review 每行一个待审文件（相对项目根）
#   - 豁免判断基于「相对项目根路径」并顶层锚定：仅根级 tools/ 与 .claude/ 框架自身豁免，
#     不会误伤 src/tools/、packages/x/tools/ 这类业务目录
#   - 扩展名豁免用白名单末段，不用 *.env.* 中段通配（避免误伤 db.env.ts 源码）
#   - 登记前先归一路径（反斜杠转正斜杠 + 折叠 ./..）：src/../../out.ts 这类折完出根的不登记，
#     免得留下一条永远匹配不上、也就永远清不掉的脏行，把 stop-gate 卡死
#   - 读改写加 flock 串行（缺失则降级），防并发 PostToolUse 互相截断
#   - jq 缺失 / 无 PROJECT_DIR → 优雅降级退出

# fast-mode 总闸：共享库判定（.claude/.fast-mode 内 expires_epoch 未过期才静默放行；库缺失 fail-closed 不放行）
_FM_LIB="$(dirname "$0")/lib-fast-mode.sh"
if [ -f "$_FM_LIB" ]; then . "$_FM_LIB"; if fast_mode_active; then exit 0; fi; fi

command -v jq >/dev/null 2>&1 || exit 0
[ -z "$CLAUDE_PROJECT_DIR" ] && exit 0

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$FILE_PATH" ] && exit 0

STATE_FILE="$CLAUDE_PROJECT_DIR/.claude/.needs-review"
# 项目外路径（如 /tmp 下的一次性脚本）不是项目代码，不登记；相对路径按项目根解析
# （项目内文件绝不能被误判成项目外——那等于跳过审查）
case "$FILE_PATH" in
  /*|[A-Za-z]:*) ;;
  *) FILE_PATH="$CLAUDE_PROJECT_DIR/$FILE_PATH" ;;
esac
case "$FILE_PATH" in
  "$CLAUDE_PROJECT_DIR"/*) ;;
  *) exit 0 ;;
esac
REL="${FILE_PATH#"$CLAUDE_PROJECT_DIR"/}"
# 正斜杠形态先归一（与引擎侧 toPosixPath 同口径），别把归一留给消费方
REL="${REL//\\//}"

# 前缀比对挡得住 /tmp/x.ts，挡不住 src/../../out.ts——那条拼出来的字面量照样以项目根开头，
# 原样登记就是一行谁也匹配不上、谁也清不掉的脏行，stop-gate 从此拦停不放。逐段折 . 与 ..
# （.ps1 侧由 GetFullPath 折掉，这边手动折）
NORM=""
REST="$REL"
while [ -n "$REST" ]; do
  SEG="${REST%%/*}"
  if [ "$SEG" = "$REST" ]; then REST=""; else REST="${REST#*/}"; fi
  case "$SEG" in
    ''|.) ;;
    ..)
      case "$NORM" in
        ''|..|*/..) NORM="${NORM:+$NORM/}.." ;;
        */*) NORM="${NORM%/*}" ;;
        *) NORM="" ;;
      esac
      ;;
    *) NORM="${NORM:+$NORM/}$SEG" ;;
  esac
done
# 折完出了根（或折成空）→ 不是项目文件，不登记。这是记账 hook，不为一条怪路径拦住工具
case "$NORM" in
  ''|..|../*)
    echo "[mark-review-needed] 未登记 $FILE_PATH：折完 ./.. 落在项目根外（${NORM:-空}），登记了也永远清不掉" >&2
    exit 0
    ;;
esac
REL="$NORM"

# 豁免 1：基础设施/框架自身（顶层锚定，由独立 code-reviewer 手动审，不进自动闸门）
case "$REL" in
  tools/*|.claude/*) exit 0 ;;
esac
# 豁免 2：文档/配置类（按最终扩展名白名单）
case "$REL" in
  *.md|*.txt|*.json|*.yaml|*.yml|*.toml|*.lock|*.log|*.gitignore|*.prettierrc|*.eslintrc) exit 0 ;;
  *.env|*.env.local|*.env.development|*.env.production|*.env.test) exit 0 ;;
esac

# 加锁读改写（flock 不可用则裸跑）
(
  command -v flock >/dev/null 2>&1 && flock 9
  # 上一轮已 clean（或文件不存在）→ 开新清单
  if [ ! -f "$STATE_FILE" ] || grep -qx "clean" "$STATE_FILE" 2>/dev/null; then
    : > "$STATE_FILE"
  fi
  # 去重登记
  grep -qxF "$REL" "$STATE_FILE" 2>/dev/null || echo "$REL" >> "$STATE_FILE"
) 9>>"${STATE_FILE}.lock" 2>/dev/null

exit 0
