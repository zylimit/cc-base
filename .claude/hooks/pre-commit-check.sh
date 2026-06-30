#!/bin/bash
# Hook: PreToolUse (Bash) if git commit*
# commit 前按技术栈分发编译/语法门禁，任一栈不通过则阻止 commit。
# 设计原则（对齐 dev-builder「工具缺失降级」）：
#   - 只检查本次 staged 改动涉及的栈，不全量误伤（改 .md 不会触发 tsc）
#   - 工具未安装 → 降级或跳过该栈，绝不因环境缺工具而卡死 commit
#   - TS：tsc --noEmit（整项目类型检查）
#   - Python：优先 ruff check，降级到 python3 -m py_compile（语法级，python3 必在）

# 脚本内自判触发命令：非 git commit 输入直接放行（替代失效的 if = Bash(git commit*)）
HOOK_INPUT=$(cat)
CMD=$(echo "$HOOK_INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('command',''))" 2>/dev/null || true)
echo "$CMD" | grep -qE 'git[[:space:]]+commit' || exit 0

cd "$CLAUDE_PROJECT_DIR" || exit 0

# 本次提交涉及的文件（新增/复制/修改）
STAGED=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null)
[ -z "$STAGED" ] && exit 0

FAIL=0

# ---------- TypeScript ----------
if echo "$STAGED" | grep -qE '\.(ts|tsx)$'; then
  TSCONFIG=$(find "$CLAUDE_PROJECT_DIR" -maxdepth 3 -name "tsconfig.json" \
    -not -path "*/node_modules/*" -not -path "*/.next/*" 2>/dev/null | head -1)
  if [ -n "$TSCONFIG" ] && command -v npx >/dev/null 2>&1; then
    TS_OUTPUT=$(cd "$(dirname "$TSCONFIG")" && npx --no-install tsc --noEmit 2>&1)
    if [ $? -ne 0 ]; then
      echo "❌ TypeScript 编译检查未通过，commit 被阻止：" >&2
      echo "$TS_OUTPUT" >&2
      FAIL=1
    fi
  fi
fi

# ---------- Python ----------
PY_FILES=$(echo "$STAGED" | grep -E '\.py$')
if [ -n "$PY_FILES" ]; then
  if command -v ruff >/dev/null 2>&1; then
    PY_OUTPUT=$(ruff check $PY_FILES 2>&1)
    PY_EXIT=$?
    TOOL="ruff check"
  else
    # 降级：语法级编译检查，python3 一定可用
    PY_OUTPUT=$(python3 -m py_compile $PY_FILES 2>&1)
    PY_EXIT=$?
    TOOL="python3 -m py_compile（未装 ruff，降级语法检查）"
  fi
  if [ $PY_EXIT -ne 0 ]; then
    echo "❌ Python 检查未通过（$TOOL），commit 被阻止：" >&2
    echo "$PY_OUTPUT" >&2
    FAIL=1
  fi
fi

if [ $FAIL -ne 0 ]; then
  # shellcheck source=/dev/null
  . "$(dirname "$0")/lib-gate-log.sh" 2>/dev/null || true
  gate_log "pre-commit-check" "编译/语法门禁未通过，commit 被阻止"
  exit 2
fi
exit 0
