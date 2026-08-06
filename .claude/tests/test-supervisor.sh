#!/usr/bin/env bash
# test-supervisor.sh — 开发态韧性 supervisor 回归（SKIP-非假绿）。
# 契约：无 node → 打印 SKIPPED 并 exit 0（未执行 != 通过，对齐 run-all.sh SKIPPED 语义）；
#   有 node → 验四条链：① start 长驻 -> status running ② kill -9 子进程 -> 自动拉起（restarts+1、新 childPid）
#   ③ 崩溃循环 -> 熔断 crashed（fail visible，不无限空转）④ stop -> 收敛 stopped、进程全清。
set -eu

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
SUP="$ROOT/.claude/scripts/supervisor.mjs"

echo "===== test-supervisor ====="

if ! command -v node >/dev/null 2>&1; then
  echo "SKIPPED: 无 node（command -v node 未找到）——supervisor 回归跳过，未执行 != 通过。"
  exit 0
fi
[ -f "$SUP" ] || { echo "  [FAIL] 缺 supervisor.mjs：$SUP" >&2; exit 1; }

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  [PASS] $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }

TMP="$(mktemp -d)"
cleanup() {
  # 兜底清进程：state 里记录的 supervisor/child pid 全部补刀，临时目录删除。
  for id in svc crashy; do
    ( cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" node "$SUP" stop --id "$id" ) >/dev/null 2>&1 || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

json_field() { python3 -c "import sys,json;d=json.load(sys.stdin);print($2)" <<<"$1"; }

# ① start 长驻进程 -> rc 0 + status running + 双 pid 活
RC=0
OUT=$(cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" node "$SUP" start --id svc -- sleep 300) || RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"status":"running"'; then
  pass "start 长驻 -> rc 0 + running"
else
  fail "start 应 rc 0 running（rc=$RC，输出：$OUT）"
fi

# ② kill -9 子进程 -> 自动拉起（新 childPid、restarts>=1、状态回 running）
ST=$(cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" node "$SUP" status --id svc)
OLD_CHILD=$(json_field "$ST" 'd["services"][0]["childPid"]')
kill -9 "$OLD_CHILD" 2>/dev/null || true
sleep 3
ST=$(cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" node "$SUP" status --id svc)
NEW_CHILD=$(json_field "$ST" 'd["services"][0]["childPid"]')
RESTARTS=$(json_field "$ST" 'd["services"][0]["restarts"]')
STATUS=$(json_field "$ST" 'd["services"][0]["status"]')
if [ "$STATUS" = "running" ] && [ "$NEW_CHILD" != "$OLD_CHILD" ] && [ "$RESTARTS" -ge 1 ]; then
  pass "kill -9 子进程 -> 自动拉起（childPid $OLD_CHILD -> $NEW_CHILD，restarts=$RESTARTS）"
else
  fail "自动拉起未发生（status=$STATUS，old=$OLD_CHILD，new=$NEW_CHILD，restarts=$RESTARTS）"
fi

# ③ 崩溃循环 -> 熔断 crashed（max-restarts=2 / window 60s / backoff 50ms，秒级完成）
( cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" node "$SUP" start --id crashy --max-restarts 2 --window-sec 60 --backoff-ms 50 -- node -e "process.exit(7)" ) >/dev/null 2>&1 || true
sleep 4
ST=$(cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" node "$SUP" status --id crashy)
STATUS=$(json_field "$ST" 'd["services"][0]["status"]')
SUP_ALIVE=$(json_field "$ST" 'd["services"][0]["supervisorAlive"]')
if [ "$STATUS" = "crashed" ] && [ "$SUP_ALIVE" = "False" ]; then
  pass "崩溃循环 -> 熔断 crashed + supervisor 退出（fail visible，不无限空转）"
else
  fail "熔断未触发（status=$STATUS，supervisorAlive=$SUP_ALIVE）"
fi

# ④ stop -> 收敛 stopped，supervisor 与 child 全清
RC=0
OUT=$(cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" node "$SUP" stop --id svc) || RC=$?
ST=$(cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" node "$SUP" status --id svc)
STATUS=$(json_field "$ST" 'd["services"][0]["status"]')
CHILD_ALIVE=$(json_field "$ST" 'd["services"][0]["childAlive"]')
if [ "$RC" -eq 0 ] && [ "$STATUS" = "stopped" ] && [ "$CHILD_ALIVE" = "False" ]; then
  pass "stop -> 收敛 stopped + 进程全清"
else
  fail "stop 未收敛（rc=$RC，status=$STATUS，childAlive=$CHILD_ALIVE）"
fi

echo ""
echo "结果：PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
