#!/bin/bash
# PostToolUse hook: 项目业务代码被编辑/创建后，把文件登记进待审清单
# 设计（15W 规模优化）：
#   - 全局布尔 → 按文件登记：.needs-review 每行一个待审文件（相对项目根）
#   - 豁免判断基于「相对项目根路径」并顶层锚定：仅根级 tools/ 与 .claude/ 框架自身豁免，
#     不会误伤 src/tools/、packages/x/tools/ 这类业务目录
#   - 扩展名豁免用白名单末段，不用 *.env.* 中段通配（避免误伤 db.env.ts 源码）
#   - 读改写加 flock 串行（缺失则降级），防并发 PostToolUse 互相截断
#   - jq 缺失 / 无 PROJECT_DIR → 优雅降级退出

command -v jq >/dev/null 2>&1 || exit 0
[ -z "$CLAUDE_PROJECT_DIR" ] && exit 0

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$FILE_PATH" ] && exit 0

STATE_FILE="$CLAUDE_PROJECT_DIR/.claude/.needs-review"
REL="${FILE_PATH#"$CLAUDE_PROJECT_DIR"/}"

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
