#!/bin/bash
# UserPromptExpansion(release-builder)：发布指令展开前的前置闸——把「打包前先过测试卡点」
# 从 skill 文字升级为机器闸。用户敲 /release-builder 时（含 disable-model-invocation 后的
# 唯一入口），在 skill 内容展开进上下文之前检查：
#   - .needs-review 有待审文件 → block（review→fix 闭环没走完，不许进发布流程）
#   - 干净 → 放行，并注入 additionalContext 提醒发布前置卡点（测试全绿运行清单 /
#     打包禁跳步 / 部署三件套独立验收）
# 发布卡点不吃 fast-mode 豁免（CLAUDE.md：Fast Mode 不等于部署或 push 授权）。
# fail-open：本闸出错放行（发布流程自身还有 test-builder 卡点与 HIGH 档审批兜底）。
trap 'exit 0' ERR
set -E

HOOK_INPUT=$(cat)
CMD_NAME=$(echo "$HOOK_INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('command_name',''))" 2>/dev/null || true)
# matcher 已按命令名过滤；解析失败或非目标命令时不拦（belt-and-braces）
if [ -n "$CMD_NAME" ] && [ "$CMD_NAME" != "release-builder" ]; then exit 0; fi

ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
STATE_FILE="$ROOT/.claude/.needs-review"
PENDING=""
if [ -f "$STATE_FILE" ]; then
  PENDING=$(grep -vE '^[[:space:]]*$' "$STATE_FILE" 2>/dev/null | grep -vx "clean" || true)
fi

if [ -n "$PENDING" ]; then
  COUNT=$(printf '%s\n' "$PENDING" | wc -l | tr -d ' ')
  INLINE=$(printf '%s' "$PENDING" | tr '\n' ',' | sed 's/,$//; s/,/、/g')
  REASON="发布前置闸：待审清单未清（${COUNT} 个文件待 code review：${INLINE}）。先完成 review→fix 闭环（通过后 echo clean > .claude/.needs-review），再执行 /release-builder。"
  # shellcheck source=/dev/null
  . "$(dirname "$0")/lib-gate-log.sh" 2>/dev/null || true
  gate_log "release-gate" "$REASON"
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg r "$REASON" '{decision:"block",reason:$r}'
  else
    echo '{"decision":"block","reason":"发布前置闸：待审清单未清，先完成 review 闭环再执行 /release-builder。"}'
  fi
  exit 0
fi

CTX="发布前置卡点提醒（release-gate 注入）：① 打包前必过测试卡点——test-builder 全量跑，报绿须附运行清单（跑了哪些文件、各自结果），证据=运行器真实输出；② Fast Mode 不豁免发布卡点；③ 部署完成后主 Agent 独立核查三件套（容器创建时间戳+镜像 tag / 健康检查端点 / live 冒烟），不信 deployer 自报。"
if command -v jq >/dev/null 2>&1; then
  jq -nc --arg c "$CTX" '{hookSpecificOutput:{hookEventName:"UserPromptExpansion",additionalContext:$c}}'
else
  echo '{"hookSpecificOutput":{"hookEventName":"UserPromptExpansion","additionalContext":"发布前置卡点：打包前必过测试卡点（全量运行清单+运行器真实输出）；Fast Mode 不豁免；部署后独立核查三件套。"}}'
fi
exit 0
