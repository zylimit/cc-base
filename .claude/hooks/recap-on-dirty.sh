#!/usr/bin/env bash
# Hook: SessionStart
# 工作树有未提交改动（上个 session 可能中断/上下文压缩、状态未落 progress.md）
# → 注入提醒：先 /recap 读 progress.md，对照实际改动校准后再继续
set -euo pipefail

[ -z "${CLAUDE_PROJECT_DIR:-}" ] && exit 0
command -v git >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

cd "$CLAUDE_PROJECT_DIR" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

COUNT=$(git status --porcelain 2>/dev/null | wc -l | tr -d '[:space:]')
[ "${COUNT:-0}" = "0" ] && exit 0

MSG="检测到 git 工作树有 ${COUNT} 处未提交改动——上个 session 可能中断或上下文已压缩，progress.md 未必反映真实状态。建议先 /recap 读 progress.md，对照实际改动校准（决策/完成是否已记）后再继续。"

python3 -c "import json,sys; print(json.dumps({'hookSpecificOutput':{'hookEventName':'SessionStart','additionalContext':sys.argv[1]}}))" "$MSG" 2>/dev/null || exit 0
exit 0
