#!/bin/bash
# PreToolUse(Bash)：密钥读取/拷贝/外传闸——把「密钥隐私是安全护栏」做成机器拦截。
# 拦三类高置信度动作（锚定命令起始/分隔符，放过 echo/grep 字符串场景）：
#   R1 读密钥文件：cat/less/head/tail/strings/xxd/od 直读 .env 家族 / id_rsa / *.pem /
#      credentials 等（读 .env.example/.sample/.template/.dist 属合法，先剔除再判）
#   R2 拷贝/搬运密钥文件：cp/scp/rsync/mv 命中同一密钥文件集
#   R3 环境变量外传：env/printenv/set 输出管进 curl/wget/nc
# wrapper 剥壳：先剥 sudo/nohup/nice/timeout/env 前缀与 bash -c 引号壳再判——套壳绕闸是
# 已知逃逸路径（借鉴 codex-base v3），原文与剥壳后两个形态都要过检。
# 本闸属安全护栏：fast-mode 不放行（放水不放安全）。python3 缺失时降级放行（与
# dangerous-pkill-guard 同一取舍——无解析能力时不误伤正常命令）。
set -euo pipefail

HOOK_INPUT=$(cat)
CMD=$(echo "$HOOK_INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('command',''))" 2>/dev/null || true)

[ -z "$CMD" ] && exit 0

# 剔除合法样例文件名，再做密钥判定（.env.example 等不当密钥算）
strip_examples() {
  printf '%s' "$1" | sed -E 's/\.env\.(example|sample|template|dist)[A-Za-z0-9_.-]*//g'
}

# wrapper 剥壳：迭代剥 sudo/nohup/nice/timeout/env 前缀与 shell -c 引号壳（上限 5 层）
strip_wrappers() {
  local c="$1" prev="" i=0
  while [ "$c" != "$prev" ] && [ "$i" -lt 5 ]; do
    prev="$c"
    i=$((i + 1))
    c=$(printf '%s' "$c" | sed -E \
      -e 's/^[[:space:]]+//' \
      -e 's/^sudo[[:space:]]+//' \
      -e 's/^nohup[[:space:]]+//' \
      -e 's/^nice([[:space:]]+-n[[:space:]]*[0-9]+)?[[:space:]]+//' \
      -e 's/^timeout([[:space:]]+--?[A-Za-z-]+([[:space:]]+[^[:space:]]+)?)*[[:space:]]+[0-9]+[smhd]?[[:space:]]+//' \
      -e 's/^env([[:space:]]+[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*)*[[:space:]]+//' \
      -e "s/^(ba|z|da)?sh[[:space:]]+-l?c[[:space:]]+[\"']?//" \
      -e "s/[\"']\$//")
  done
  printf '%s' "$c"
}

# 密钥文件核心集（.pem/.ppk 任意路径命中；尾界防误伤 .env2/.envoy 之类）
SECRET_CORE='(\.env(\.[A-Za-z0-9_-]+)?|id_rsa[A-Za-z0-9_.-]*|id_ed25519[A-Za-z0-9_.-]*|[^[:space:]]*\.(pem|ppk)|credentials\.json|\.aws/credentials|\.ssh/[^[:space:]]+)([[:space:]"'"'"']|$)'
# 参数区前缀：动词后紧跟（空格即边界）或经任意参数后以空格/斜杠/引号/= 为前界——两种都算命中
ARGPFX='[[:space:]]+([^|;&]*[[:space:]/"'"'"'=@])?'
# 命令锚定（起始或 ; && || ` $( 之后）
ANCHOR='(^|;|&&|\|\||`|\$\()[[:space:]]*'

check_one() {
  local c
  c=$(strip_examples "$1")
  # R1 读密钥
  if printf '%s' "$c" | grep -qE "${ANCHOR}(cat|less|more|head|tail|strings|xxd|od|bat|grep|rg|awk|sed)${ARGPFX}${SECRET_CORE}"; then
    REASON="检测到直读密钥文件（cat/head 等 + .env/id_rsa/*.pem/credentials）"
    return 0
  fi
  # R2 拷贝/搬运密钥
  if printf '%s' "$c" | grep -qE "${ANCHOR}(cp|scp|rsync|mv)${ARGPFX}${SECRET_CORE}"; then
    REASON="检测到拷贝/搬运密钥文件（cp/scp/rsync/mv + 密钥文件名）"
    return 0
  fi
  # R3 环境变量整包外传
  if printf '%s' "$c" | grep -qE "${ANCHOR}(env|printenv|set)\b[^|]*\|[[:space:]]*(curl|wget|nc)\b"; then
    REASON="检测到环境变量整包管道外传（env/printenv | curl/wget/nc）"
    return 0
  fi
  # R3b 网络命令直接携带密钥文件
  if printf '%s' "$c" | grep -qE "${ANCHOR}(curl|wget|nc)${ARGPFX}${SECRET_CORE}"; then
    REASON="检测到网络命令携带密钥文件（curl/wget/nc + 密钥文件名）"
    return 0
  fi
  return 1
}

REASON=""
STRIPPED=$(strip_wrappers "$CMD")
if check_one "$CMD" || { [ "$STRIPPED" != "$CMD" ] && check_one "$STRIPPED"; }; then
  echo "⛔ [secret-exfil-guard] ${REASON}，已拦截。" >&2
  echo "密钥/隐私是安全护栏，Fast Mode 也不豁免。正确做法：" >&2
  echo "- 需要了解配置结构 → 读 .env.example / 文档，不读真实密钥文件" >&2
  echo "- 确需操作密钥（轮换/迁移）→ 停下来向用户说明并由用户亲自执行" >&2
  echo "- 需要个别环境变量 → 按名取用（printf '%s' \"\$VAR_NAME\"），不整包导出外传" >&2
  # shellcheck source=/dev/null
  . "$(dirname "$0")/lib-gate-log.sh" 2>/dev/null || true
  gate_log "secret-exfil-guard" "$REASON"
  exit 2
fi

exit 0
