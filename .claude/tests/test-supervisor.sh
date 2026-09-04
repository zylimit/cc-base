#!/usr/bin/env bash
# test-supervisor.sh — 开发态韧性 supervisor 回归（SKIP-非假绿）。
# 契约：无 node → 打印 SKIPPED 并 exit 0（未执行 != 通过，对齐 run-all.sh SKIPPED 语义）；
#   有 node → 验七条链：① start 长驻 -> status running ② 强杀子进程 -> 自动拉起（restarts+1、新 childPid）
#   ③ 崩溃循环 -> 熔断 crashed（fail visible，不无限空转）④ stop -> 收敛 stopped、进程全清
#   ⑤ win32 stop 分支（正向，垫片）-> 只写 flag 不发信号，靠 1s tick 收敛 stopped
#   ⑥ win32 SIGTERM 语义（负向对照）-> 无条件终止收敛不出 stopped，只能是 dead + state 停在 running
#   ⑦ 无孤儿孙进程残留（测试自身卫生，同时锁住 kill 按进程组走）。
#   ⑧⑨⑩ state.json 坏掉 != 服务不存在 -> status 报 corrupt、start 拒绝再起一个、stop 不说没有
set -eu

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
# 可选位置参数：被测 supervisor.mjs 的路径，默认本仓那份。变异验证专用——把实现 cp 到 /tmp
# 打上「退回旧行为」的补丁再跑同一份断言，就能证明这些断言真会红，全程不碰仓里的文件。
SUP="${1:-$ROOT/.claude/scripts/supervisor.mjs}"

echo "===== test-supervisor ====="

if ! command -v node >/dev/null 2>&1; then
  echo "SKIPPED: 无 node（command -v node 未找到）——supervisor 回归跳过，未执行 != 通过。"
  exit 0
fi
[ -f "$SUP" ] || { echo "  [FAIL] 缺 supervisor.mjs：$SUP" >&2; exit 1; }

PASS=0
FAIL=0
SKIP=0
pass() { PASS=$((PASS + 1)); echo "  [PASS] $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }
# 未执行 != 通过：跑不了的用例单独计数并说明理由，绝不悄悄算进 PASS。
skip() { SKIP=$((SKIP + 1)); echo "  [SKIP] $1"; }

TMP="$(mktemp -d)"
cleanup() {
  # 兜底清进程：state 里记录的 supervisor/child pid 全部补刀，临时目录删除。
  for id in svc crashy winstop winneg badstate badstart badstop; do
    ( cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" node "$SUP" stop --id "$id" ) >/dev/null 2>&1 || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

json_field() { python3 -c "import sys,json;d=json.load(sys.stdin);print($2)" <<<"$1"; }

STATE_OF() { printf '%s' "$TMP/.claude/.runtime/supervisor/$1/state.json"; }

# 强杀子进程必须分平台：Git Bash 的 kill 只认 MSYS 进程，对 cmd.exe / node.exe 这类 Windows
# 原生进程发不出信号，子进程根本不死，「崩了要自动拉起」这条断言的前提就不成立。Windows 改走
# taskkill（同 supervisor.mjs killTree 的 win32 分支），/T 连 shell:true 起的孙进程一起收。
# 两个 MSYS_* 变量是防 /PID 被当路径转换成 C:/Program Files/Git/PID——Git Bash 认前者、
# MSYS2 原生认后者；不用 //PID 写法，它靠运行时把 // 缩成 /，环境里设了 ARG_CONV_EXCL 就失效。
# POSIX 侧不能只杀 childPid 那一个：shell:true 起的是 `sh -c "sleep 300"`，dash 对单条简单命令
# **不 exec**，真正的负载是它 fork 的孙进程；单杀那层 shell 会把孙进程孤儿化留在机器上。
# supervisor 起子进程时 detached:true 已让它自成进程组（pgid == childPid），按 -pgid 整组杀
# 才等价于 Windows 那边的 taskkill /T。
kill_child() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' taskkill /PID "$1" /T /F >/dev/null 2>&1 || true ;;
    *)
      _pgid=$(ps -o pgid= -p "$1" 2>/dev/null | tr -d ' ') || _pgid=""
      _selfpgid=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ') || _selfpgid=""
      # 自保：pgid 读不出来、或读出来就是本测试自己所在的组时，退回单杀——绝不自杀。
      if [ -n "$_pgid" ] && [ "$_pgid" != "$_selfpgid" ]; then
        kill -9 -"$_pgid" 2>/dev/null || true
      fi
      kill -9 "$1" 2>/dev/null || true ;;
  esac
}

# 列出仍活着、且属于给定进程组的进程。子进程 detached 起（pgid == childPid），所以拿记录下来的
# childPid 当 pgid 查，就能精确抓到「那层 shell 死了、孙进程还在」的孤儿，不会误伤别的并发测试。
leaked_in_group() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) printf '' ;;   # Windows 无进程组语义，taskkill /T 已杀树
    *) ps -eo pgid=,pid=,args= 2>/dev/null | awk -v g="$1" '$1 == g { print }' || true ;;
  esac
}

# chmod 000 能不能真的挡住本进程读？root 读得穿、Windows 的 mode 位压根不是这个语义。
# 挡不住时对应用例走 skip 而不是 pass——⑪ 的主用例用「路径在、但不是目录」那种形态，
# 不需要权限、各平台同义，所以这条只是给能做权限试验的机器多加一档。
chmod_can_deny() {
  _probe="$TMP/.chmod-capability-probe"
  printf 'x' > "$_probe" 2>/dev/null || return 1
  chmod 000 "$_probe" 2>/dev/null || { rm -f "$_probe"; return 1; }
  if cat "$_probe" >/dev/null 2>&1; then chmod 600 "$_probe"; rm -f "$_probe"; return 1; fi
  chmod 600 "$_probe"; rm -f "$_probe"; return 0
}

# ---------------------------------------------------------------------------
# win32 垫片：⑤ 用。把 **stop 客户端** 逼上 win32 分支，supervisor 本体仍是普通 Linux 进程。
# ---------------------------------------------------------------------------
mkdir -p "$TMP/shim"
SIGLOG="$TMP/win32-signals.log"
TKLOG="$TMP/win32-taskkill.log"
: > "$SIGLOG"
: > "$TKLOG"

cat > "$TMP/win32-stop-client.mjs" <<'EOF'
// 只伪装 stop 客户端，不碰 supervisor 本体——被测的正是 cmdStop 那条 win32 分支。
// 两处伪装缺一不可：
//   ① platform=win32 —— cmdStop 据此走 flagOnly（只写 stop.flag、不发信号、超时放宽到 15s）。
//   ② process.kill 重放 Windows 语义 —— Node 在 Windows 上把任何终止信号实现为无条件终止
//      （TerminateProcess），目标的 process.on('SIGTERM') 压根不触发。不装这一层，Linux 的
//      优雅 SIGTERM 会让「删掉 win32 分支」也照样收敛成 stopped，正向断言就成了恒真的空断言。
//      signal 0 是探活（Windows 上同样是探活），必须原样透传，否则 pidAlive 会把活的判成死的。
import fs from 'node:fs';
import { pathToFileURL } from 'node:url';

const SIGLOG = process.env.WIN32_SIGLOG;
Object.defineProperty(process, 'platform', { value: 'win32' });
const realKill = process.kill.bind(process);
process.kill = (pid, sig = 'SIGTERM') => {
  if (sig === 0 || sig === '0') return realKill(pid, 0);
  if (SIGLOG) fs.appendFileSync(SIGLOG, 'kill pid=' + pid + ' sig=' + sig + '\n');
  return realKill(pid, 'SIGKILL');
};

const [supPath, ...rest] = process.argv.slice(2);
process.argv = [process.argv[0], supPath, ...rest];
await import(pathToFileURL(supPath).href);
EOF

cat > "$TMP/shim/taskkill" <<'EOF'
#!/usr/bin/env bash
# 假 taskkill —— killTree 的 win32 分支调的就是它。正确实现下 ⑤ 走不到这里（stop 不该自己收尸）；
# 一旦走到，它按进程组硬杀，等价于真 taskkill /T 杀树。这样分支被改坏时红的是「语义不对」，
# 而不是「ENOENT 崩了顺带漏一堆进程」——要的是与 Windows 上一模一样的症状。
[ -n "${TASKKILL_LOG:-}" ] && printf '%s\n' "$*" >> "$TASKKILL_LOG"
pid=""
while [ $# -gt 0 ]; do
  case "$1" in
    /PID|/pid) pid="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$pid" ] || exit 0
pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ') || pgid=""
[ -n "$pgid" ] && kill -9 -"$pgid" 2>/dev/null
kill -9 "$pid" 2>/dev/null
exit 0
EOF
chmod +x "$TMP/shim/taskkill"

# ① start 长驻进程 -> rc 0 + status running + 双 pid 活
RC=0
OUT=$(cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" node "$SUP" start --id svc -- sleep 300) || RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"status":"running"'; then
  pass "start 长驻 -> rc 0 + running"
else
  fail "start 应 rc 0 running（rc=$RC，输出：$OUT）"
fi

# ② 强杀子进程 -> 自动拉起（新 childPid、restarts>=1、状态回 running）
ST=$(cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" node "$SUP" status --id svc)
OLD_CHILD=$(json_field "$ST" 'd["services"][0]["childPid"]')
kill_child "$OLD_CHILD"
sleep 3
ST=$(cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" node "$SUP" status --id svc)
NEW_CHILD=$(json_field "$ST" 'd["services"][0]["childPid"]')
RESTARTS=$(json_field "$ST" 'd["services"][0]["restarts"]')
STATUS=$(json_field "$ST" 'd["services"][0]["status"]')
if [ "$STATUS" = "running" ] && [ "$NEW_CHILD" != "$OLD_CHILD" ] && [ "$RESTARTS" -ge 1 ]; then
  pass "强杀子进程 -> 自动拉起（childPid $OLD_CHILD -> $NEW_CHILD，restarts=$RESTARTS）"
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

# ④ stop -> 收敛 stopped，supervisor 与 child 全清（POSIX 快路径：SIGTERM 直达 shutdown）
RC=0
OUT=$(cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" node "$SUP" stop --id svc) || RC=$?
ST=$(cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" node "$SUP" status --id svc)
STATUS=$(json_field "$ST" 'd["services"][0]["status"]')
CHILD_ALIVE=$(json_field "$ST" 'd["services"][0]["childAlive"]')
if [ "$RC" -eq 0 ] && [ "$STATUS" = "stopped" ] && [ "$CHILD_ALIVE" = "False" ]; then
  pass "stop（POSIX 信号快路径）-> 收敛 stopped + 进程全清"
else
  fail "stop（POSIX 信号快路径）未收敛（rc=$RC，status=$STATUS，childAlive=$CHILD_ALIVE）"
fi

# ⑤ win32 stop 分支（正向）：只写 stop.flag、不发信号，靠 1s tick 走完 shutdown() -> stopped。
#    这条分支在 Linux 上永远走不到——谁删掉它本机全绿，而 CI 的 Windows 那格已经不跑 .sh 了，
#    所以不靠垫片把 stop 客户端逼进去，这段实现就是零回归防线。
#    判据取 `status` 的收敛结果，不取 stop 自己回的那句 status：分支坏掉时 stop 会自己把
#    孤儿子进程收掉，然后照样回 {"ok":true,"status":"stopped"}——只信它的自述就是假绿。
RC=0
OUT=$(cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" node "$SUP" start --id winstop -- sleep 300) || RC=$?
ST=$(cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" node "$SUP" status --id winstop)
W_SUP=$(json_field "$ST" 'd["services"][0]["supervisorPid"]')
W_CHILD=$(json_field "$ST" 'd["services"][0]["childPid"]')

W_T0=$SECONDS
W_RC=0
W_OUT=$(cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" WIN32_SIGLOG="$SIGLOG" TASKKILL_LOG="$TKLOG" \
        PATH="$TMP/shim:$PATH" node "$TMP/win32-stop-client.mjs" "$SUP" stop --id winstop) || W_RC=$?
W_SEC=$((SECONDS - W_T0))
ST=$(cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" node "$SUP" status --id winstop)
W_STATUS=$(json_field "$ST" 'd["services"][0]["status"]')
W_SUPALIVE=$(json_field "$ST" 'd["services"][0]["supervisorAlive"]')
W_RAW=$(json_field "$(cat "$(STATE_OF winstop)")" 'd["status"]')
if [ "$W_RC" -eq 0 ] && [ "$W_STATUS" = "stopped" ] && [ "$W_RAW" = "stopped" ] && [ "$W_SUPALIVE" = "False" ]; then
  pass "⑤ win32 stop 分支（正向 flag-only）-> 收敛 stopped（rc=0，state.json=stopped，约 ${W_SEC}s）"
else
  fail "⑤ win32 stop 分支（正向 flag-only）没收敛：期望 rc=0 + status=stopped + state.json=stopped，实得 rc=$W_RC status=$W_STATUS state.json=$W_RAW supervisorAlive=$W_SUPALIVE（stop 自述：$W_OUT）"
fi

# ⑤b flag-only 的字面含义：这条路上一个终止信号都不许发给 supervisor。
#     信号发出去就等于回到修复前——Windows 那边它是无条件终止，shutdown() 永远跑不到。
#     只盯 supervisor 那个 pid，不搞「全程零信号」：收孤儿子进程的 killTree 是另一码事。
if grep -q "pid=$W_SUP " "$SIGLOG" 2>/dev/null; then
  fail "⑤b win32 stop 分支给 supervisor(pid=$W_SUP) 发了终止信号，flag-only 名存实亡（信号日志：$(tr '\n' ';' < "$SIGLOG")）"
else
  pass "⑤b win32 stop 分支全程未向 supervisor(pid=$W_SUP) 发终止信号（走的是 stop.flag + tick）"
fi

# ⑥ 负向对照 —— 重放 win32 的 SIGTERM 语义（无条件终止：shutdown() 不跑、状态不落盘）。
#    没有这条，⑤ 有可能是恒真的空断言。这条证明「同一套夹具下，被无条件终止的 supervisor
#    收敛不出 stopped」——它必须落在 status=dead + state.json 停在 running，与 CI 上那次红同形。
#    先 SIGSTOP 冻住 1s tick 再写 flag，是为了消掉「flag 恰好被这一 tick 读走」的毫秒级竞态，
#    让对照组不 flaky；SIGSTOP / SIGKILL 都不可捕获，语义仍是货真价实的无条件终止。
RC=0
OUT=$(cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" node "$SUP" start --id winneg -- sleep 300) || RC=$?
ST=$(cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" node "$SUP" status --id winneg)
N_SUP=$(json_field "$ST" 'd["services"][0]["supervisorPid"]')
N_CHILD=$(json_field "$ST" 'd["services"][0]["childPid"]')
kill -STOP "$N_SUP" 2>/dev/null || true
printf 'replay-win32-sigterm\n' > "$TMP/.claude/.runtime/supervisor/winneg/stop.flag"
kill -9 "$N_SUP" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$N_SUP" 2>/dev/null || break; sleep 0.3; done
ST=$(cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" node "$SUP" status --id winneg)
N_STATUS=$(json_field "$ST" 'd["services"][0]["status"]')
N_RAW=$(json_field "$(cat "$(STATE_OF winneg)")" 'd["status"]')
if [ "$N_STATUS" = "dead" ] && [ "$N_RAW" = "running" ]; then
  pass "⑥ 负向对照：无条件终止 -> status=dead + state.json 停在 running（⑤ 的绿因此是有信息量的）"
else
  fail "⑥ 负向对照没复现出坏结局：期望 status=dead + state.json=running，实得 status=$N_STATUS state.json=$N_RAW——⑤ 那条正向断言可能是恒真的空断言，先查夹具再信它"
fi
kill_child "$N_CHILD"   # 对照组自己制造的孤儿，自己收

# ⑦ 无孤儿孙进程残留：`sh -c "sleep 300"` 在 dash 下不 exec，孙进程只能靠进程组杀收。
#    这条同时是 kill_child 的红锁——把它改回 `kill -9 <pid>` 单杀，这里必红。
sleep 1
LEAKS=""
HIT=""
for g in "$OLD_CHILD" "$NEW_CHILD" "$W_CHILD" "$N_CHILD"; do
  [ -n "$g" ] && [ "$g" != "None" ] || continue
  for _ in 1 2 3; do
    HIT="$(leaked_in_group "$g")"
    [ -n "$HIT" ] || break
    sleep 0.5
  done
  [ -z "$HIT" ] || LEAKS="$LEAKS
[pgid=$g] $HIT"
done
if [ -z "$LEAKS" ]; then
  pass "⑦ 无孤儿孙进程残留（已核各 childPid 进程组：$OLD_CHILD/$NEW_CHILD/$W_CHILD/$N_CHILD）"
else
  fail "⑦ 有孤儿孙进程残留（只杀了 shell 那层、没按进程组杀）：$LEAKS"
fi

# ⑧⑨⑩ 坏掉的 state.json 不等于「没这个服务」。三条各锁一个动词：读不出来时 status 不许报
#     「dead」（dead 说的是进程死了、状态是可信的；corrupt 说的是这份状态根本没读出来），
#     start 不许当没在跑直接再起一个 supervisor（真起了就是同一个 id 两个守护进程在抢一个
#     子进程和一份 state.json），stop 不许说「no state for id」（文件就在那儿，只是坏了）。
#     判据都避开 id 字面量里带 corrupt 的写法，否则 grep 会匹配到自己发出去的那行命令行。

# ⑧ status：坏 state.json -> 报 corrupt + rc 1，且不得报成 dead
mkdir -p "$TMP/.claude/.runtime/supervisor/badstate"
printf '{ "supervisorPid": 424242, "status": "runn' > "$(STATE_OF badstate)"
RC=0
OUT=$(cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" node "$SUP" status --id badstate 2>&1) || RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'corrupt' && ! printf '%s' "$OUT" | grep -q '"status":"dead"'; then
  pass "⑧ 坏 state.json -> status 报 corrupt + rc 1（不冒充 dead）"
else
  fail "⑧ 坏 state.json 被读成「没在跑」：期望 rc=1 且输出点名 corrupt、不出现 \"status\":\"dead\"，实得 rc=$RC 输出：$OUT"
fi

# ⑨ start：同 id 的 state.json 坏着 -> 拒绝启动 + rc 1 + 点名那个文件。
#    判据不看 start 自己回什么，看 state.json 有没有被覆盖——它被改写就说明第二个 supervisor
#    真起来了并开始往里写，那才是这条要挡的事故。
mkdir -p "$TMP/.claude/.runtime/supervisor/badstart"
printf '{ "supervisorPid": 424243, "status": "run' > "$(STATE_OF badstart)"
SHA_BEFORE=$(sha256sum "$(STATE_OF badstart)" | cut -d' ' -f1)
RC=0
OUT=$(cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" node "$SUP" start --id badstart -- sleep 30 2>&1) || RC=$?
SHA_AFTER=$(sha256sum "$(STATE_OF badstart)" | cut -d' ' -f1)
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'state.json' && [ "$SHA_BEFORE" = "$SHA_AFTER" ]; then
  pass "⑨ 坏 state.json -> start 拒绝启动 + rc 1 + 点名 state.json（未覆盖原文件）"
else
  fail "⑨ 坏 state.json 被当成「没在跑」直接起了第二个 supervisor：期望 rc=1 + 输出点名 state.json + 文件未被覆盖，实得 rc=$RC state.json 覆盖=$([ "$SHA_BEFORE" = "$SHA_AFTER" ] && echo 否 || echo 是) 输出：$OUT"
fi
( cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" node "$SUP" stop --id badstart ) >/dev/null 2>&1 || true

# ⑩ stop：坏 state.json -> 报 corrupt + rc 1，不得说「no state for id」
mkdir -p "$TMP/.claude/.runtime/supervisor/badstop"
printf '{ "supervisorPid": 424244, "status"' > "$(STATE_OF badstop)"
RC=0
OUT=$(cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" node "$SUP" stop --id badstop 2>&1) || RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'corrupt' && ! printf '%s' "$OUT" | grep -q 'no state for id'; then
  pass "⑩ 坏 state.json -> stop 报 corrupt + rc 1（不说 no state for id）"
else
  fail "⑩ 坏 state.json 被 stop 说成「没有这个 id 的状态」：期望 rc=1 且点名 corrupt、不出现 no state for id，实得 rc=$RC 输出：$OUT"
fi

# ⑪ 列不出来的 baseDir 不等于「一个服务都没有」。⑧⑨⑩ 锁的是单个 state.json 坏掉，这条锁的是
#    上一层：整个 .claude/.runtime/supervisor/ 读不出来时，status 现在回 rc 0 + services:[]，
#    和「这台机器上从没起过服务」一模一样——于是「都停干净了吗」这个问题得到一个没人核实过的
#    「是」。用独立的 TMP2 做，免得毁掉前面几条用例的运行态；主形态取「路径在、但是个文件」
#    （ENOTDIR），不吃权限、Windows 上同样成立，权限形态另做一档。
TMP2="$(mktemp -d)"
cleanup2() { chmod 700 "$TMP2/.claude/.runtime/supervisor" 2>/dev/null || true; rm -rf "$TMP2"; }
trap 'cleanup; cleanup2' EXIT
BASE2="$TMP2/.claude/.runtime/supervisor"
mkdir -p "$BASE2/svc"
printf '{ "supervisorPid": 424245, "childPid": 424246, "status": "running" }' > "$BASE2/svc/state.json"

# 对照组：目录读得出来时，那个服务是列得出来的——下面两条红才说明是「读不出来」造成的。
RC=0
OUT=$(cd "$TMP2" && CLAUDE_PROJECT_DIR="$TMP2" node "$SUP" status 2>&1) || RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"id":"svc"'; then
  pass "⑪a 对照组：baseDir 读得出来时 status 列得出 svc（rc 0）"
else
  fail "⑪a 对照组没搭起来：期望 rc=0 且输出含 \"id\":\"svc\"，实得 rc=$RC 输出：$OUT"
fi

# ⑪b 主形态：baseDir 位置是个文件（ENOTDIR）。判据取「码」和「话」两件：rc 不许是 0，
#     且不许交出 services:[] 这个和「真没有服务」逐字节相同的答案。
rm -rf "$BASE2"
printf 'somebody dropped a file where the supervisor state directory belongs\n' > "$BASE2"
RC=0
OUT=$(cd "$TMP2" && CLAUDE_PROJECT_DIR="$TMP2" node "$SUP" status 2>&1) || RC=$?
if [ "$RC" -eq 1 ] \
   && printf '%s' "$OUT" | grep -q 'runtime/supervisor' \
   && ! printf '%s' "$OUT" | grep -q '"services":\[\]'; then
  pass "⑪b baseDir 列不出来 -> status rc 1 + 点名那个路径（不冒充「没有服务」）"
else
  fail "⑪b baseDir 列不出来被读成「一个服务都没有」：期望 rc=1 + 输出点名 runtime/supervisor + 不出现 \"services\":[]，实得 rc=$RC 输出：$OUT"
fi

# ⑪c 权限形态：目录在、内容也在，只是本进程没权限列。挡不住 chmod 的机器上走 skip。
rm -f "$BASE2"
mkdir -p "$BASE2/svc"
printf '{ "supervisorPid": 424247, "childPid": 424248, "status": "running" }' > "$BASE2/svc/state.json"
if chmod_can_deny; then
  chmod 000 "$BASE2"
  RC=0
  OUT=$(cd "$TMP2" && CLAUDE_PROJECT_DIR="$TMP2" node "$SUP" status 2>&1) || RC=$?
  chmod 700 "$BASE2"
  if [ "$RC" -eq 1 ] && ! printf '%s' "$OUT" | grep -q '"services":\[\]'; then
    pass "⑪c 无权限列 baseDir -> status rc 1（服务好端端在里面，答案不许是「没有服务」）"
  else
    fail "⑪c 无权限列 baseDir 被读成「一个服务都没有」：期望 rc=1 且不出现 \"services\":[]，实得 rc=$RC 输出：$OUT"
  fi
else
  skip "⑪c chmod 000 在本机挡不住读（root 或 Windows），权限形态未执行；同一族的 ⑪b 不吃权限、已真跑"
fi

echo ""
echo "结果：PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
