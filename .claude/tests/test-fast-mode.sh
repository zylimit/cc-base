#!/usr/bin/env bash
# test-fast-mode.sh — fast-mode 总闸（expires_epoch 版）回归测试（无依赖 claude CLI）。
# 契约：开关文件 .claude/.fast-mode 内 expires_epoch=<unix秒> 行决定有效性——
#   > now 才放行 hook；缺行 / 非数字 / 已过期一律 fail-closed 走严格逻辑。
# 覆盖：① on 后 flag 含 expires_epoch 且 status 报 on ② on 3 写入 3h 的 epoch 差值
#   ③ off 删 flag ④ 手写过期 flag → status 报过期、hook 不放行 ⑤ 非法 hours 报错 exit 2
#   ⑥ 抽 tdd-gate.sh：有效 flag 放行 exit 0、过期/坏 flag 不放行（走原严格逻辑）。
# 临时目录当项目根（伪造 .claude/.fast-mode + 拷 scripts/hooks），trap 清理。
set -eu

SRC=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$SRC/scripts/fast-mode.sh" ] || { echo "test-fast-mode: 缺 $SRC/scripts/fast-mode.sh" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  [PASS] $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }

# 伪项目根：拷 fast-mode.sh 与抽测 hook，保持 .claude/ 相对结构
ROOT="$TMP/proj"
mkdir -p "$ROOT/.claude/scripts" "$ROOT/.claude/hooks"
cp "$SRC/scripts/fast-mode.sh" "$ROOT/.claude/scripts/"
cp "$SRC/hooks/tdd-gate.sh" "$ROOT/.claude/hooks/"
FM="bash $ROOT/.claude/scripts/fast-mode.sh"
FLAG="$ROOT/.claude/.fast-mode"

echo "===== test-fast-mode ====="

# ① on（默认 24h）→ flag 含 expires_epoch，status 报 on
$FM on >/dev/null
if grep -q '^expires_epoch=[0-9]\{1,\}$' "$FLAG" 2>/dev/null; then
  pass "on 后 flag 含 expires_epoch 行"
else
  fail "on 后 flag 缺 expires_epoch 行（内容：$(cat "$FLAG" 2>/dev/null)）"
fi
OUT=$($FM status)
case "$OUT" in *"fast-mode: on"*) pass "on 后 status 报 on" ;; *) fail "on 后 status 未报 on（实得：$OUT）" ;; esac

# ② on 3 → expires - enabled = 10800
$FM on 3 >/dev/null
EN=$(sed -n 's/^enabled_epoch=//p' "$FLAG")
EX=$(sed -n 's/^expires_epoch=//p' "$FLAG")
if [ "$((EX - EN))" -eq 10800 ]; then
  pass "on 3 写入 3h（10800s）epoch 差值"
else
  fail "on 3 的 epoch 差值不是 10800（实得：$((EX - EN))）"
fi

# ③ off → flag 删除
$FM off >/dev/null
if [ ! -f "$FLAG" ]; then pass "off 删除 flag"; else fail "off 未删除 flag"; fi

# ④ 手写过期 flag → status 报过期
printf 'enabled_epoch=1000\nexpires_epoch=2000\nhours=1\n' > "$FLAG"
OUT=$($FM status)
case "$OUT" in *"过期"*) pass "过期 flag：status 报过期" ;; *) fail "过期 flag：status 未报过期（实得：$OUT）" ;; esac

# ⑤ 非法 hours → exit 2
for BAD in abc 0 -1 1.5; do
  RC=0
  $FM on "$BAD" >/dev/null 2>&1 || RC=$?
  if [ "$RC" -eq 2 ]; then pass "非法 hours '$BAD' → exit 2"; else fail "非法 hours '$BAD' → exit $RC（期望 2）"; fi
done

# ⑥ 抽 tdd-gate.sh 验证放行/不放行
# hook 读 stdin，喂一个会触发提醒路径的 implementer 派发命令；fast-mode 有效时应先行 exit 0 且无输出。
# 严格路径的提醒走 stderr，故 2>&1 合并捕获；cd 进伪根（非 git 仓）让 PROJECT_ROOT 落在无 .red-verified 的位置。
HOOK_IN='{"tool_input":{"command":"claude agent implementer write code"}}'
run_hook() { printf '%s' "$HOOK_IN" | (cd "$ROOT" && CLAUDE_PROJECT_DIR="$ROOT" bash "$ROOT/.claude/hooks/tdd-gate.sh" 2>&1); }

$FM on >/dev/null
OUT=$(run_hook); RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  pass "有效 flag：tdd-gate.sh 静默放行（exit 0、无输出）"
else
  fail "有效 flag：tdd-gate.sh 未静默放行（exit $RC，输出：$OUT）"
fi

printf 'enabled_epoch=1000\nexpires_epoch=2000\nhours=1\n' > "$FLAG"
OUT=$(run_hook || true)
if [ -n "$OUT" ]; then
  pass "过期 flag：tdd-gate.sh 不放行（走严格逻辑，有输出）"
else
  fail "过期 flag：tdd-gate.sh 被放行了（期望走严格逻辑输出提醒）"
fi

printf 'garbage\nexpires_epoch=notanumber\n' > "$FLAG"
OUT=$(run_hook || true)
if [ -n "$OUT" ]; then
  pass "坏 flag（非数字）：tdd-gate.sh fail-closed 不放行"
else
  fail "坏 flag（非数字）：tdd-gate.sh 被放行了（期望 fail-closed）"
fi

rm -f "$FLAG"
echo ""
echo "结果：PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
