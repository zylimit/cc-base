#!/bin/bash
# Stop hook: 三文件同步铁律恢复侧强制闸——只认 git 工作树实际未提交改动（弃用裸 mtime
#   比较，mtime 在 checkout 1ms 先后下会假阳性）。
# C1：未提交改动里有代码/家底文件（.sh/.ps1/.ts/.tsx/.js/.jsx/.py/.css/.go/.rs，以及 .claude/
#     下的家底 CLAUDE.md/agents/skills/settings.json 等；排除 .claude/evidence/node_modules/out/
#     dist）且 progress.md 不在改动集 → 拦停提醒同步。
# C2：改动集含 Product-Spec.md 但不含 Product-Spec-CHANGELOG.md（或反之）→ 需求变更漏记。
#     只校验存在的文件——Spec/CHANGELOG 任一不存在则不强造、不拦停（框架本体可无 Spec）。
# 干净树 / 改动已含 progress 或两份成对 / 非 git 仓 / 无 progress.md → 优雅放行。
# 项目根解析：CLAUDE_PROJECT_DIR 优先，缺失回退 git root，再回退 pwd。
ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
PROG="$ROOT/progress.md"
[ ! -f "$PROG" ] && exit 0

# 非 git 仓 → 无工作树可判，优雅放行。
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

CODE_DIRTY=0
PROG_DIRTY=0
SPEC_DIRTY=0
CHANGELOG_DIRTY=0
FIRST_CODE=""

# 把单条改动路径归类到三文档命中 / 代码改动标志。
classify_path() {
  local path=$1
  case "$path" in
    progress.md) PROG_DIRTY=1 ;;
    Product-Spec.md) SPEC_DIRTY=1 ;;
    Product-Spec-CHANGELOG.md) CHANGELOG_DIRTY=1 ;;
  esac
  case "$path" in
    .claude/evidence/*|*/.claude/evidence/*|node_modules/*|*/node_modules/*|out/*|*/out/*|dist/*|*/dist/*) ;;
    *.sh|*.ps1|*.ts|*.tsx|*.js|*.jsx|*.py|*.css|*.go|*.rs)
      CODE_DIRTY=1
      [ -z "$FIRST_CODE" ] && FIRST_CODE="$path"
      ;;
    .claude/*|*/.claude/*)
      # .claude/ 下家底（CLAUDE.md / agents / skills / settings.json 等）改了也属「改了要记
      # progress」，计入家底代码集；evidence 账本由上面排除分支先行拦掉，到不了这里。
      CODE_DIRTY=1
      [ -z "$FIRST_CODE" ] && FIRST_CODE="$path"
      ;;
  esac
}

# --porcelain -z：NUL 分隔、路径不加引号；NUL 无法存进变量，故用进程替换直读。
# rename/copy 记录是两段：`XY <new-path>` NUL `<old-path>` NUL（旧路径裸路径无前缀），
# 故 X/Y 命中 R/C 时要再读一段裸 old-path，new/old 都计入改动集。
while IFS= read -r -d '' rec; do
  status=${rec:0:2}
  classify_path "${rec:3}"
  case "$status" in
    R*|C*|?R|?C)
      IFS= read -r -d '' oldpath && classify_path "$oldpath"
      ;;
  esac
done < <(git -C "$ROOT" status --porcelain -z 2>/dev/null)

BLOCK=0
REASON=""

if [ "$CODE_DIRTY" -eq 1 ] && [ "$PROG_DIRTY" -eq 0 ]; then
  REASON="三文件同步铁律：检测到未提交的代码/家底改动（如 ${FIRST_CODE}）但 progress.md 未同步。请把本轮的决策/完成事项/进度/新任务即时写入 progress.md（doc 类主 Agent 直接写），保证随时可 Clear→recap 完整恢复，然后重试停止。"
  BLOCK=1
fi

# 成对校验只在两份都存在时进行，缺一不强造、不拦停。
if [ -f "$ROOT/Product-Spec.md" ] && [ -f "$ROOT/Product-Spec-CHANGELOG.md" ]; then
  if [ "$SPEC_DIRTY" -eq 1 ] && [ "$CHANGELOG_DIRTY" -eq 0 ]; then
    REASON="${REASON:+$REASON }Product-Spec.md 有未提交改动但 Product-Spec-CHANGELOG.md 未同步，需求变更可能漏记 CHANGELOG。请在 Product-Spec-CHANGELOG.md 补本次需求变更记录后重试停止。"
    BLOCK=1
  fi
  if [ "$CHANGELOG_DIRTY" -eq 1 ] && [ "$SPEC_DIRTY" -eq 0 ]; then
    REASON="${REASON:+$REASON }Product-Spec-CHANGELOG.md 有未提交改动但 Product-Spec.md 未同步，需求变更须成对更新两份文件。请同步 Product-Spec.md 后重试停止。"
    BLOCK=1
  fi
fi

[ "$BLOCK" -eq 0 ] && exit 0

# shellcheck source=/dev/null
. "$(dirname "$0")/lib-gate-log.sh" 2>/dev/null || true
gate_log "three-file-sync-gate" "$REASON"

if command -v jq >/dev/null 2>&1; then
  jq -nc --arg r "$REASON" '{decision:"block",reason:$r}'
else
  echo '{"decision":"block","reason":"三文件同步铁律：代码/家底有未提交改动但 progress.md 未同步，或 Product-Spec.md 与 CHANGELOG 未成对更新，请同步后重试停止。"}'
fi
exit 0
