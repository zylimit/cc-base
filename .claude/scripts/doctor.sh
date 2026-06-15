#!/usr/bin/env bash
# doctor.sh — cc-base 安装/配置完整性自检。每项打 ✓/✗，有缺报非零退出。
# 用法： bash .claude/scripts/doctor.sh [仓库根目录]   默认当前目录
set -u

ROOT="${1:-.}"
case "$ROOT" in *..*) echo "doctor: 路径不安全: $ROOT" >&2; exit 2 ;; esac
[ -d "$ROOT" ] || { echo "doctor: 目标不存在: $ROOT" >&2; exit 2; }
cd "$ROOT" 2>/dev/null || { echo "doctor: 无法进入: $ROOT" >&2; exit 2; }

fail=0
warn=0

ok()   { printf '✓ %s\n' "$1"; }
bad()  { printf '✗ %s\n' "$1" >&2; fail=1; }
note() { printf '! %s\n' "$1" >&2; warn=1; }

# 主控文件
[ -f .claude/CLAUDE.md ] && ok ".claude/CLAUDE.md 存在" || bad ".claude/CLAUDE.md 缺失"

# 7 个 agent
[ -d .claude/agents ] && ok ".claude/agents 存在" || bad ".claude/agents 缺失"
agent_count=$(find .claude/agents -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
[ "$agent_count" = "7" ] && ok "agent 数量 = 7" || bad "agent 数量应为 7，实为 $agent_count"
for name in implementer code-reviewer tester deployer feedback-observer evolution-runner progress-recorder; do
  [ -f ".claude/agents/$name.md" ] && ok "agent $name" || bad "agent $name 缺失"
done

# 每个 skill 都有 SKILL.md
[ -d .claude/skills ] && ok ".claude/skills 存在" || bad ".claude/skills 缺失"
for d in .claude/skills/*/; do
  [ -d "$d" ] || continue
  s=$(basename "$d")
  [ -f "$d/SKILL.md" ] && ok "skill $s/SKILL.md" || bad "skill $s 缺 SKILL.md"
done

# hooks 可执行位
[ -d .claude/hooks ] && ok ".claude/hooks 存在" || bad ".claude/hooks 缺失"
for hook in .claude/hooks/*.sh; do
  [ -e "$hook" ] || continue
  [ -x "$hook" ] && ok "hook 可执行 $hook" || bad "hook 缺可执行位 $hook"
done

# settings.json 合法 JSON
if [ -f .claude/settings.json ]; then
  if command -v jq >/dev/null 2>&1; then
    if jq -e . .claude/settings.json >/dev/null 2>&1; then
      ok ".claude/settings.json 是合法 JSON"
    else
      bad ".claude/settings.json 不是合法 JSON"
    fi
  else
    note "未装 jq，跳过 settings.json JSON 校验"
  fi
else
  bad ".claude/settings.json 缺失"
fi

# 关键脚本存在
[ -f make-release.sh ] && ok "make-release.sh 存在" || bad "make-release.sh 缺失"
for s in doctor.sh plan-lint.sh skill-description-lint.sh; do
  [ -f ".claude/scripts/$s" ] && ok ".claude/scripts/$s 存在" || bad ".claude/scripts/$s 缺失"
done

# 运行时工具
command -v git  >/dev/null 2>&1 && ok "git 可用"  || note "未找到 git；git 相关 hook 能力受限"
command -v bash >/dev/null 2>&1 && ok "bash 可用" || note "未找到 bash"
command -v jq   >/dev/null 2>&1 && ok "jq 可用（可选）"      || note "未找到 jq（可选）"

if [ "$fail" -ne 0 ]; then
  echo "doctor: 自检失败"
  exit 1
fi
if [ "$warn" -ne 0 ]; then
  echo "doctor: 通过（有告警）"
else
  echo "doctor: 通过"
fi
exit 0
