#!/usr/bin/env bash
# static-check.sh — 识别技术栈并跑静态检查（shellcheck / ruff|py_compile / tsc / node --check）。
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
# tsconfig 不一定在仓库顶层（前端常在子目录，如 conflation/web）——有限深度探测全部
# tsconfig.json；目录里装好依赖（有 node_modules）才进去跑，否则跳过该目录（缺依赖不卡死）。
TSDIRS=()
if have npx; then
  mapfile -t TSCONFIGS < <(find . -maxdepth 3 -name 'tsconfig.json' "${PRUNE[@]}" 2>/dev/null)
  for cfg in "${TSCONFIGS[@]}"; do
    tsdir=$(dirname "$cfg")
    [ -d "$tsdir/node_modules" ] || continue
    TSDIRS+=("$tsdir")
    ran="$ran tsc($tsdir)"
    if ! out=$(cd "$tsdir" && npx --no-install tsc --noEmit 2>&1); then report_fail "tsc $tsdir" "$out"; fi
  done
fi

# ---- JavaScript ----
# JS 用的是另一张排除表，不复用上面的 PRUNE：.claude 底下就是框架自己的 JS（引擎、审计
# 脚本、workflow 编排），按 PRUNE 整块排掉等于框架的 .mjs 从来没人做过语法检查。
# 但 .claude/worktrees/ 必须挡——那底下是各 agent 的完整工作树副本，扫进去就是把同一个仓
# 重复检查 N 遍，还会把别的分支的代码算到本次审查头上。
JS_PRUNE=(-not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/.ccb/*'
  -not -path '*/dist/*' -not -path '*/build/*' -not -path '*/.venv/*' -not -path '*/out/*'
  -not -path '*/coverage/*' -not -path '*/.opencode/*' -not -path '*/.claude/worktrees/*')

mapfile -t JS < <(find . \( -name '*.mjs' -o -name '*.cjs' -o -name '*.js' \) "${JS_PRUNE[@]}" 2>/dev/null)
if [ "${#JS[@]}" -gt 0 ] && have node; then
  jsout=""
  jsn=0
  for f in "${JS[@]}"; do
    # 落在跑过 tsc 的子树里的不重复检查：tsc 看得比语法更远，同一份文件报两遍只是噪音。
    skip=0
    if [ "${#TSDIRS[@]}" -gt 0 ]; then
      for d in "${TSDIRS[@]}"; do case "$f" in "$d"/*) skip=1; break ;; esac; done
    fi
    [ "$skip" -eq 1 ] && continue
    jsn=$((jsn + 1))
    # node --check 自己就打 <文件>:<行>，原样透出去、不另造格式；只滤掉纯噪音的调用栈。
    if ! o=$(node --check "$f" 2>&1); then
      jsout="$jsout$(printf '%s\n' "$o" | grep -v '^    at ' | grep -v '^Node\.js v')
"
    fi
  done
  if [ "$jsn" -gt 0 ]; then
    ran="$ran node --check($jsn)"
    [ -n "$jsout" ] && report_fail "node --check" "$jsout"
  fi
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
