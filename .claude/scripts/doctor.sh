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

# 主控下沉细则（rules/）
[ -d .claude/rules ] && ok ".claude/rules 存在" || bad ".claude/rules 缺失"
for r in file-structure workflow-orchestration dev-workflow-details harness-large-repo; do
  [ -f ".claude/rules/$r.md" ] && ok "rule $r" || bad "rule $r 缺失"
done

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

# harness 接线依赖库（stop-gate / pre-commit-check source 它，缺失会静默降级）
[ -f .claude/hooks/lib-harness.sh ]   && ok "lib-harness.sh 存在"   || bad "lib-harness.sh 缺失"
[ -f .claude/hooks/lib-harness.ps1 ] && ok "lib-harness.ps1 存在" || bad "lib-harness.ps1 缺失"

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

# 大仓治理 harness（默认关闭，catalog 存在即启用）——只报告状态，不 fail 小项目
[ -f .claude/harness/harness.mjs ] && ok "harness.mjs 存在" \
  || note "harness.mjs 缺失（大仓治理运行时；若不用大仓治理可忽略）"
[ -f .claude/harness/lib/core.mjs ] && ok "harness lib/ 存在（引擎拆库后 harness.mjs 单文件跑不起来）" \
  || note "harness lib/ 缺失（只拷 harness.mjs 不够，须连 .claude/harness/lib/ 一起装）"
if [ -f .claude/harness/module-catalog.json ]; then
  ok "module-catalog.json 存在（大仓治理已启用）"
  command -v node >/dev/null 2>&1 && ok "node 可用（harness 可跑）" \
    || note "未找到 node；大仓治理 harness 判定将降级跳过（非假绿）"
else
  printf -- '- %s\n' "module-catalog.json 未配置（大仓治理默认关闭，接线走原逻辑）"
fi

# FRAMEWORK-MANIFEST 全量比对：清单里每一条都算 LF 归一化 SHA256 对一遍，不符的逐条点名
# （路径 + 期望/实际 sha 前 8 位）并判 ✗。旧实现是「前 20 行里随机抽 3 个」的 note 级抽验，
# 两处都不成立：抽样窗口外的篡改永远看不见；shuf 让同一棵树每次给出不同结论。
# 分发完整性这种事要么全量确定地答，要么别答——不符也不再降级成告警，
# 它意味着框架文件被改过或清单已陈，两种都得有人看一眼。
if [ -f .claude/FRAMEWORK-MANIFEST.txt ] && command -v sha256sum >/dev/null 2>&1; then
  mismatch=0; checked=0; missing=0
  # 逐条点名有上限：几百条全不符时刷屏没人读，超出部分只报条数（下面那行）。
  MAN_MAX_NAMED=20
  while IFS=$(printf '\t') read -r m_rel m_sha; do
    case "$m_rel" in ''|\#*) continue ;; esac
    if [ ! -f ".claude/$m_rel" ]; then missing=$((missing + 1)); continue; fi
    checked=$((checked + 1))
    actual=$(tr -d '\r' <".claude/$m_rel" | sha256sum | awk '{print $1}')
    [ "$actual" = "$m_sha" ] && continue
    mismatch=$((mismatch + 1))
    [ "$mismatch" -le "$MAN_MAX_NAMED" ] \
      && bad "FRAMEWORK-MANIFEST 不符：$m_rel 期望 ${m_sha:0:8} 实际 ${actual:0:8}"
  done < <(grep -v '^#' .claude/FRAMEWORK-MANIFEST.txt)
  if [ "$mismatch" -gt "$MAN_MAX_NAMED" ]; then
    bad "FRAMEWORK-MANIFEST 另有 $((mismatch - MAN_MAX_NAMED)) 条不符未逐条列出（先修上面这些）"
  fi
  if [ "$checked" -eq 0 ]; then
    note "FRAMEWORK-MANIFEST 存在但一条都没验到（清单为空，或登记的文件都不在本地）"
  elif [ "$mismatch" -eq 0 ]; then
    ok "FRAMEWORK-MANIFEST 全量比对 $checked 条 SHA 一致"
  else
    bad "FRAMEWORK-MANIFEST 全量比对 $checked 条，$mismatch 条 SHA 不符"
  fi
  # 登记了却不在本地的另算一档：没参与比对，不许混进「一致」的计数里。
  [ "$missing" -ne 0 ] && note "FRAMEWORK-MANIFEST 有 $missing 条登记的文件不在本地（未参与比对）"
fi

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
