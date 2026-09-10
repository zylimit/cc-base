#!/usr/bin/env bash
# test-fast-mode.sh — 旧入口 scripts/fast-mode.sh 的回归测试（Phase A 起它是薄壳）。
# 契约：开关只有一个——`.claude/.runtime/tier.json` 的档位会话覆盖。fast-mode.sh 自己不再解析、
#   不再落盘，`on N` 转发 `tier set fast --hours N`、`off` 转发 `tier set standard`、
#   `status` 转发 `tier status`；`.claude/.fast-mode` 既不写也不读（#38：一个开关不许两个解析器）。
# 覆盖：① on 4 产生 tier.json（tier=fast）且不产生 .fast-mode ② on 3 写入 3h 差值
#   ③ 默认 hours 被 8h 上限截住 ④ off 后 effective 回默认 ⑤ status 输出含档位
#   ⑥ 非法 hours 报错 exit 2 且不落盘 ⑦ 抽 tdd-gate.mjs：fast 档放行、过期回严格
#   ⑧ 判定库 hooks/lib/tier.mjs 缺失 → 仍 exit 0 且走严格（闸不因少一个文件而消失）。
# 临时目录当项目根（拷 scripts / hooks / harness / profile），trap 清理；对本仓只读。
set -eu

SRC=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$SRC/scripts/fast-mode.sh" ] || { echo "test-fast-mode: 缺 $SRC/scripts/fast-mode.sh" >&2; exit 1; }
[ -f "$SRC/harness/profile.json" ] || { echo "test-fast-mode: 缺 $SRC/harness/profile.json——档位没启用，这份测的东西不存在" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "test-fast-mode: 无 node——引擎与抽测的 hook 都是 .mjs，跑不起来；未执行 != 通过。" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  [PASS] $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }

# 伪项目根：拷薄壳、引擎（薄壳要转发给它）、档位表、抽测 hook。
# hooks/lib/ 与 harness/lib/ 都按目录整拷、不枚举模块名：枚举法漏一个就是
# ERR_MODULE_NOT_FOUND 的假红。
ROOT="$TMP/proj"
mkdir -p "$ROOT/.claude/scripts" "$ROOT/.claude/hooks/lib" "$ROOT/.claude/harness"
cp "$SRC/scripts/fast-mode.sh" "$ROOT/.claude/scripts/"
cp "$SRC/hooks/tdd-gate.mjs" "$ROOT/.claude/hooks/"
cp -R "$SRC/hooks/lib/." "$ROOT/.claude/hooks/lib/"
cp "$SRC/harness/harness.mjs" "$ROOT/.claude/harness/"
[ -d "$SRC/harness/lib" ] && cp -R "$SRC/harness/lib" "$ROOT/.claude/harness/"
cp "$SRC/harness/profile.json" "$ROOT/.claude/harness/"
FM="bash $ROOT/.claude/scripts/fast-mode.sh"
TIERF="$ROOT/.claude/.runtime/tier.json"
LEGACY="$ROOT/.claude/.fast-mode"

# jf <文件> <js 表达式（变量 d）> —— 取 tier.json 字段；文件缺失/坏 JSON 输出 <none>。
jf() {
    node -e '
const fs = require("node:fs");
try {
  const d = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  process.stdout.write(String(eval(process.argv[2])));
} catch (e) { process.stdout.write("<none>"); }
' "$1" "$2"
}

# tier <argv…> —— 直接问引擎当前档位（薄壳的效果要从旁路读，不从它自己的回显读）。
tier() { ( cd "$ROOT" && CLAUDE_PROJECT_DIR="$ROOT" node "$ROOT/.claude/harness/harness.mjs" "$@" ); }

echo "===== test-fast-mode ====="

# ① on 4 → tier.json 里 tier=fast，且不产生旧开关文件
$FM on 4 >/dev/null 2>&1 || true
if [ "$(jf "$TIERF" 'd.tier')" = "fast" ]; then
  pass "on 4 → .claude/.runtime/tier.json 的 tier=fast"
else
  fail "on 4 未写出 fast 档的 tier.json（实得：$(jf "$TIERF" 'JSON.stringify(d)')）"
fi
if [ ! -f "$LEGACY" ]; then
  pass "on 不再产生 .claude/.fast-mode（薄壳自己不落盘）"
else
  fail "on 仍写了 .claude/.fast-mode（内容：$(cat "$LEGACY" 2>/dev/null)）"
fi

# ② on 3 → expires - set = 10800
$FM on 3 >/dev/null 2>&1 || true
DIFF3=$(jf "$TIERF" 'Number(d.expires_epoch) - Number(d.set_epoch)')
if [ "$DIFF3" = "10800" ]; then
  pass "on 3 写入 3h（10800s）的过期差值"
else
  fail "on 3 的差值不是 10800（实得：$DIFF3）"
fi

# ③ 默认 hours（脚本里是 24）必须被 fast 的 8h 上限截住——薄壳不许绕过上限
$FM on >/dev/null 2>&1 || true
DIFFD=$(jf "$TIERF" 'Number(d.expires_epoch) - Number(d.set_epoch)')
case "$DIFFD" in
  ''|*[!0-9]*) fail "默认 on 未写出可读的过期差值（实得：$DIFFD）" ;;
  *) if [ "$DIFFD" -le 28800 ]; then
       pass "默认 on 的有效期被 8h 上限截住（${DIFFD}s ≤ 28800s）"
     else
       fail "默认 on 绕过了 8h 上限（${DIFFD}s > 28800s）"
     fi ;;
esac

# ④ off → effective 回默认（锁可观测结果，不锁 tier.json 是删是改写成 standard）
$FM off >/dev/null 2>&1 || true
ST=$(tier tier status 2>/dev/null || true)
T=$(printf '%s' "$ST" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{const d=JSON.parse(s);process.stdout.write(String(d.tier)+"/"+String(d.source));}catch(e){process.stdout.write("<not-json>");}})')
if [ "$T" = "standard/default" ]; then
  pass "off 后 effective 回默认（tier=standard source=default）"
else
  fail "off 后未回默认（实得：$T，status=$ST）"
fi
if [ ! -f "$LEGACY" ]; then
  pass "off 不留下 .claude/.fast-mode"
else
  fail "off 后仍有 .claude/.fast-mode"
fi

# ⑤ status 输出要看得见档位（防忘关靠它，转发完不能把输出吞了）
# 「输出里有 fast 这个词」单独判不作数——旧脚本自己印 "fast-mode: on" 也含它。
# 与「状态确实从新通道来」一起判：tier.json 在，且回显说得出档位。
$FM on 2 >/dev/null 2>&1 || true
OUT=$($FM status 2>&1 || true)
if [ "$(jf "$TIERF" 'd.tier')" = "fast" ] && case "$OUT" in *fast*) true ;; *) false ;; esac; then
  pass "status 输出含当前档位 fast，且档位确实来自 tier.json"
else
  fail "status 未反映 tier.json 的档位（tier.json=$(jf "$TIERF" 'd.tier')，输出：$OUT）"
fi

# ⑥ 非法 hours → exit 2，且不动已有档位（先开成 fast 再喂非法值，判它有没有被清掉/改写；
#    从「什么都没有」的状态起判是恒真的，那种写法在薄壳没落地时也绿）
$FM on 4 >/dev/null 2>&1 || true
for BAD in abc 0 -1 1.5; do
  RC=0
  $FM on "$BAD" >/dev/null 2>&1 || RC=$?
  if [ "$RC" -eq 2 ]; then pass "非法 hours '$BAD' → exit 2"; else fail "非法 hours '$BAD' → exit $RC（期望 2）"; fi
done
if [ "$(jf "$TIERF" 'd.tier')" = "fast" ]; then
  pass "非法 hours 不改动已有档位（原来的 fast 还在）"
else
  fail "非法 hours 把已有档位弄丢了（实得：$(jf "$TIERF" 'JSON.stringify(d)')）"
fi

# ⑦ 抽 tdd-gate.mjs 验证放行/不放行
# hook 读 stdin，喂一个会触发提醒路径的 implementer 派发命令；fast 档（profile 里 tdd-gate: off）
# 应先行 exit 0 且无输出。严格路径的提醒走 stderr，故 2>&1 合并捕获。
HOOK_IN='{"tool_input":{"command":"claude agent implementer write code"}}'
run_hook() { printf '%s' "$HOOK_IN" | (cd "$ROOT" && CLAUDE_PROJECT_DIR="$ROOT" node "$ROOT/.claude/hooks/tdd-gate.mjs" 2>&1); }

$FM on 4 >/dev/null 2>&1 || true
OUT=$(run_hook); RC=$?
if [ "$RC" -eq 0 ] && [ -n "$OUT" ]; then
  pass "fast 档：tdd-gate.mjs 只提醒不拦（exit 0、有提醒；三档都是 advise）"
else
  fail "fast 档：tdd-gate.mjs 没照 advise 走（exit $RC，输出：$OUT）"
fi

# 手写一份过期的会话覆盖：过期即视为无覆盖，回 default(standard) 走 advise 提醒
mkdir -p "$ROOT/.claude/.runtime"
printf '{"tier":"fast","reason":"t","by":"test","set_epoch":1000,"expires_epoch":2000}\n' > "$TIERF"
OUT=$(run_hook || true)
if [ -n "$OUT" ]; then
  pass "过期的 tier.json：tdd-gate.mjs 回严格档照常提醒"
else
  fail "过期的 tier.json：tdd-gate.mjs 被放行了（期望回 default 走提醒）"
fi

printf '{"tier":"fast", broken,,\n' > "$TIERF"
OUT=$(run_hook || true)
if [ -n "$OUT" ]; then
  pass "坏 JSON 的 tier.json：tdd-gate.mjs fail-closed 不放行"
else
  fail "坏 JSON 的 tier.json：tdd-gate.mjs 被放行了（期望 fail-closed）"
fi

# ⑧ 判定库缺失 → fail-closed：fast 档也不放行（走严格逻辑），且 hook 不崩（exit 0 + 有提醒输出）。
# 缺件就是 hooks/lib/tier.mjs 不在。裸 import 一个不存在的模块会让 node 在跑到第一行之前就
# rc 1 退出，那正是这条要挡的形态——闸不许因为少一个文件而整个消失，判定要退回严格而不是退回「不响」。
$FM on 4 >/dev/null 2>&1 || true
rm -f "$ROOT/.claude/hooks/lib/tier.mjs"
RC=0
OUT=$(run_hook) || RC=$?
if [ "$RC" -eq 0 ] && [ -n "$OUT" ]; then
  pass "判定库 tier.mjs 缺失：fail-closed 不放行（走严格逻辑有输出）且 hook 不崩"
else
  fail "判定库 tier.mjs 缺失：期望 fail-closed 走严格逻辑且不崩（exit $RC，输出：$OUT）"
fi
cp "$SRC/hooks/lib/tier.mjs" "$ROOT/.claude/hooks/lib/"

rm -f "$TIERF"
echo ""
echo "结果：PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
