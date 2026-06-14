#!/usr/bin/env bash
# static-check.sh — 识别技术栈并跑静态检查（shellcheck / ruff|py_compile / tsc）。
# 全绿 exit 0；任一红 exit 1（并打印错误）；工具未装 → 跳过该栈（绝不因缺工具卡死）。
# 用法： bash static-check.sh [project_dir]
#
# 定位：code-review 的 Stage 0「静态闸」。单模型审查（同模型，盲区重合）天生弱，
#       用模型无关的机械化静态检查补偿——静态绿才进语义审查（Stage 1/2）。
set -u

DIR="${1:-.}"
case "$DIR" in *..*) echo "static-check: unsafe dir $DIR" >&2; exit 1 ;; esac
cd "$DIR" 2>/dev/null || { echo "static-check: bad dir $DIR" >&2; exit 1; }

# 排除依赖/运行态/构建/VCS + 框架自身（.opencode/.claude 是装进来的基建，非被审的用户代码）
PRUNE=(-not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/.ccb/*'
  -not -path '*/dist/*' -not -path '*/build/*' -not -path '*/.venv/*' -not -path '*/out/*'
  -not -path '*/.opencode/*' -not -path '*/.claude/*')

fail=0
ran=""

have() { command -v "$1" >/dev/null 2>&1; }
report_fail() { echo "[$1 未通过]"; printf '%s\n' "$2" | head -40; fail=1; }

# ---- shell ----
mapfile -t SH < <(find . -name '*.sh' "${PRUNE[@]}" 2>/dev/null)
if [ "${#SH[@]}" -gt 0 ] && have shellcheck; then
  ran="$ran shellcheck"
  if ! out=$(shellcheck "${SH[@]}" 2>&1); then report_fail shellcheck "$out"; fi
fi

# ---- python ----
mapfile -t PY < <(find . -name '*.py' "${PRUNE[@]}" 2>/dev/null)
if [ "${#PY[@]}" -gt 0 ]; then
  if have ruff; then
    ran="$ran ruff"
    if ! out=$(ruff check . 2>&1); then report_fail ruff "$out"; fi
  elif have python3; then
    ran="$ran py_compile"
    if ! out=$(python3 -m py_compile "${PY[@]}" 2>&1); then report_fail py_compile "$out"; fi
  fi
fi

# ---- TypeScript ----
if [ -f tsconfig.json ] && have npx; then
  ran="$ran tsc"
  if ! out=$(npx --no-install tsc --noEmit 2>&1); then report_fail tsc "$out"; fi
fi

if [ -z "$ran" ]; then
  echo "static-check: 未识别到可跑的静态检查（无对应栈或工具未装），跳过。"
  exit 0
fi
if [ "$fail" -ne 0 ]; then
  echo "static-check: 静态检查有错（见上），请修绿后再进语义审查。"
  exit 1
fi
echo "static-check: 全绿（$ran）。"
exit 0
