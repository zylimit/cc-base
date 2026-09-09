#!/usr/bin/env bash
# test-ui-audit.sh — UI 审计闸（scripts/ui-audit.mjs）的回归测试。
#
# 契约：node ui-audit.mjs <url|目录> [--themes a,b] [--widths 1280,900] [--out <dir>] [--strict] [--json]
#   无参 → stderr 用法 rc 2；--help → stdout 用法 rc 0；目标既非 URL 也非目录 → rc 2；
#   找不到浏览器引擎 → stderr 一行「UI 审计缺席」rc 3；有引擎 → 逐主题×宽度审计 + 截图，
#   写 <out>/ui-audit.json（含 pass 与 combos），--strict 且不 pass → rc 1。
#
# 为什么 rc 3 这条单列：缺引擎必须是「缺席」而不是「通过」。一个把「没装 playwright」
#   吞成 rc 0 的审计闸，会在 CI 上永远绿着，正是这个闸要防的那类空绿。
#
# U5 的取舍：真跑渲染要有引擎，没有就 SKIPPED 并计数，不算 PASS 也不算 FAIL——
#   「未执行 != 通过」，汇总里看得见。
#
# 用法：bash test-ui-audit.sh [ui-audit.mjs 路径]
set -u

SRC=$(cd "$(dirname "$0")/.." && pwd)
AUDIT=${1:-"$SRC/scripts/ui-audit.mjs"}
case "$AUDIT" in /*) ;; *) AUDIT="$PWD/$AUDIT" ;; esac   # U6/U7 要切 cwd，先钉成绝对路径

echo "===== test-ui-audit ====="
command -v node >/dev/null 2>&1 || {
    echo 'SKIPPED: 无 node——被测脚本是 .mjs，未执行 != 通过。'
    exit 0
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
SKIP=0
pass() { PASS=$((PASS + 1)); echo "  [PASS] $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }
skip() { SKIP=$((SKIP + 1)); echo "  [SKIPPED] $1"; }
chk() {
    if [ "$1" -eq 0 ]; then pass "$2"; else fail "$2"; fi
    echo "         EXPECT $3"
    echo "         GOT    $4"
}
contains() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
brief() { printf '%s' "$1" | tr '\n' ' ' | cut -c1-200 | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null; }
usage_like() { contains '用法' "$1" || contains 'usage' "$1" || contains 'Usage' "$1"; }

RC=0
STDOUT=""
STDERR=""
run() { # [args...]
    node "$AUDIT" ${@+"$@"} > "$TMP/o" 2> "$TMP/e"
    RC=$?
    STDOUT=$(cat "$TMP/o")
    STDERR=$(cat "$TMP/e")
}

# 引擎在不在，决定 U4 怎么隔离、U5 跑不跑
if node -e "require.resolve('playwright-core')" >/dev/null 2>&1 || node -e "require.resolve('playwright')" >/dev/null 2>&1; then
    HAS_ENGINE=1
else
    HAS_ENGINE=0
fi
echo "  [ENV] 浏览器引擎可用=$HAS_ENGINE"

if [ -f "$AUDIT" ]; then
    chk 0 "U0 被测脚本存在：$AUDIT" "ui-audit.mjs 存在" "存在"
else
    chk 1 "U0 被测脚本存在：$AUDIT" "ui-audit.mjs 存在" "不存在——下面每条都会红，红因是功能缺失"
fi

run
if [ "$RC" -eq 2 ] && usage_like "$STDERR"; then r=0; else r=1; fi
chk "$r" "U1 无参数 → stderr 出用法，rc 2" "rc=2 且 stderr 含用法/usage" "rc=$RC；stderr：$(brief "$STDERR")"

run --help
if [ "$RC" -eq 0 ] && usage_like "$STDOUT"; then r=0; else r=1; fi
chk "$r" "U2 --help → stdout 出用法，rc 0" "rc=0 且 stdout 含用法/usage" "rc=$RC；stdout：$(brief "$STDOUT")"

run "$TMP/nope"
if [ "$RC" -eq 2 ]; then r=0; else r=1; fi
chk "$r" "U3 目标既不是 URL 也不是目录 → rc 2" "rc=2" "rc=$RC；stderr：$(brief "$STDERR")"

mkdir -p "$TMP/site"
{
    printf '%s\n' '<!doctype html>'
    printf '%s\n' '<html lang="zh"><head><meta charset="utf-8"><title>派单</title></head>'
    printf '%s\n' '<body style="margin:0">'
    printf '%s\n' '<div style="width:3000px;height:40px;background:#eeeeee">这一行故意 3000px 宽，必须被判横向溢出</div>'
    printf '%s\n' '<p style="color:#cfcfcf;background:#ffffff">这行对比度不足</p>'
    printf '%s\n' '</body></html>'
} > "$TMP/site/index.html"

# U4 缺引擎必须是 rc 3。引擎在场时把脚本复制到仓外目录跑，让 require 沿 /tmp 往上找不到包。
if [ "$HAS_ENGINE" -eq 1 ] && [ -f "$AUDIT" ]; then
    mkdir -p "$TMP/iso"
    cp "$AUDIT" "$TMP/iso/ui-audit.mjs"
    NODE_PATH=/nonexistent node "$TMP/iso/ui-audit.mjs" "$TMP/site" > "$TMP/o" 2> "$TMP/e"
    RC=$?
    STDERR=$(cat "$TMP/e")
    echo "  [NOTE] U4 用「复制到仓外单文件跑」做隔离——若 ui-audit.mjs 还 import 了 harness/lib 里的东西，"
    echo "         这条会因找不到相对模块而红，那时该换隔离手法，不是实现的错。"
else
    NODE_PATH=/nonexistent node "$AUDIT" "$TMP/site" > "$TMP/o" 2> "$TMP/e"
    RC=$?
    STDERR=$(cat "$TMP/e")
fi
if [ "$RC" -eq 3 ] && contains 'UI 审计缺席' "$STDERR"; then r=0; else r=1; fi
chk "$r" "U4 引擎不可用 → stderr 一行「UI 审计缺席」，rc 3（缺席不许冒充通过）" \
    "rc=3 且 stderr 含「UI 审计缺席」" "rc=$RC；stderr：$(brief "$STDERR")"

if [ "$HAS_ENGINE" -eq 1 ]; then
    run "$TMP/site" --strict --themes light --widths 1280 --out "$TMP/out"
    ok=1
    [ "$RC" -eq 1 ] || ok=0
    [ -f "$TMP/out/ui-audit.json" ] || ok=0
    if [ -f "$TMP/out/ui-audit.json" ] && ! grep -qE '"pass"[[:space:]]*:[[:space:]]*false' "$TMP/out/ui-audit.json"; then ok=0; fi
    if [ "$ok" -eq 1 ]; then r=0; else r=1; fi
    chk "$r" "U5 3000px 溢出的页面 --strict → rc 1，报告落盘且 pass=false" \
        "rc=1 且 <out>/ui-audit.json 存在且 pass=false" \
        "rc=$RC；报告存在=$([ -f "$TMP/out/ui-audit.json" ] && echo yes || echo no)；stderr：$(brief "$STDERR")"
else
    skip "U5 真渲染审计：本机没有 playwright-core/playwright，未执行 != 通过"
fi

# ---------------------------------------------------------------------------
# 引擎桩：本机没装 playwright 也要能验「启动失败」和「审计判定」两条路径，不然这两条
#   永远随 U5 一起 SKIPPED——「未执行 != 通过」同样适用于闸自己的判定逻辑。
# 桩是个 CJS 包（package.json 的 main 指向 index.js；写成 exports.chromium 是为了让
#   cjs-module-lexer 认出具名导出），脚本里 `mod.chromium ? mod : mod.default ?? mod`
#   两种形状都认。
# 解析路径：默认以桩目录为 cwd 跑仓里那份 ui-audit.mjs，走 resolveModule 的
#   createRequire(cwd) 分支；本机若真装了 playwright（会抢在裸 import 那一步），
#   改把脚本复制进桩目录再跑，让裸 import 也落到桩上。两条路都通，判定不受本机环境摆布。
# ---------------------------------------------------------------------------
STUB_THROW='exports.chromium = { async launch() { throw new Error("boom-launch"); } };'

STUB_CONTRAST=$(cat <<'JS'
const fs = require('fs');
const AUDIT = {
  overflows: [],
  wrapped: [],
  contrastFails: [{ cls: 'x', text: '灰字', ratio: 2.1 }],
  genericTells: { upperTinyLabels: 0, midDotTexts: 0, arrowEndings: 0, radiusValues: 0, uniformRadius: false },
  elementCount: 50,
  textLength: 200,
};
const page = {
  async setViewportSize() {},
  async goto() {},
  async waitForTimeout() {},
  // 带参数那次是设 data-theme，不带参数那次才是 PAGE_AUDIT
  async evaluate(fn, ...args) { return args.length ? undefined : AUDIT; },
  async screenshot(opts) { fs.writeFileSync(opts.path, ''); },
};
const browser = { async newPage() { return page; }, async close() {} };
exports.chromium = { async launch() { return browser; } };
JS
)

STUB_GOTO_THROW=$(cat <<'JS'
const fs = require('fs');
const page = {
  async setViewportSize() {},
  async goto() { throw new Error('boom-goto'); },
  async waitForTimeout() {},
  async evaluate() { return undefined; },
  async screenshot(opts) { fs.writeFileSync(opts.path, ''); },
};
const browser = { async newPage() { return page; }, async close() {} };
exports.chromium = { async launch() { return browser; } };
JS
)

stub_run() { # <用例名> <index.js 内容> [args...]
    local name=$1 js=$2 runner
    shift 2
    local d="$TMP/$name"
    mkdir -p "$d/node_modules/playwright-core"
    printf '%s\n' '{"name":"playwright-core","version":"0.0.0-stub","main":"index.js"}' \
        > "$d/node_modules/playwright-core/package.json"
    printf '%s\n' "$js" > "$d/node_modules/playwright-core/index.js"
    if [ "$HAS_ENGINE" -eq 1 ]; then
        cp "$AUDIT" "$d/ui-audit.mjs"
        runner="$d/ui-audit.mjs"
    else
        runner="$AUDIT"
    fi
    ( cd "$d" && node "$runner" ${@+"$@"} ) > "$TMP/o" 2> "$TMP/e"
    RC=$?
    STDOUT=$(cat "$TMP/o")
    STDERR=$(cat "$TMP/e")
}

# ---------------------------------------------------------------------------
# 红锁：两个已核实的缺陷。断言写「修好之后应该成立的行为」，所以现在必红。
# ---------------------------------------------------------------------------
stub_run u6 "$STUB_THROW" "$TMP/site"
if [ "$RC" -eq 3 ] && contains 'UI 审计缺席' "$STDERR" && contains 'boom-launch' "$STDERR"; then r=0; else r=1; fi
chk "$r" "U6 引擎装着但 launch 抛错 → 除了 rc 3 还要说出原因，不能把异常吞成一句「缺席」" \
    "rc=3 且 stderr 同时含「UI 审计缺席」与 boom-launch" \
    "rc=$RC；stderr：$(brief "$STDERR")"

stub_run u7 "$STUB_CONTRAST" "$TMP/site" --strict --themes light --widths 1280 --out "$TMP/u7out"
ok=1
[ "$RC" -eq 1 ] || ok=0
[ -f "$TMP/u7out/ui-audit.json" ] || ok=0
if [ -f "$TMP/u7out/ui-audit.json" ] && ! grep -qE '"pass"[[:space:]]*:[[:space:]]*false' "$TMP/u7out/ui-audit.json"; then ok=0; fi
if [ "$ok" -eq 1 ]; then r=0; else r=1; fi
chk "$r" "U7 只有对比度不达标也要判红：4.5:1 是 ui-quality-floor 的 MUST，闸不拦等于没闸" \
    "rc=1 且 <out>/ui-audit.json 里 pass=false" \
    "rc=$RC；报告存在=$([ -f "$TMP/u7out/ui-audit.json" ] && echo yes || echo no)；pass 行：$(grep -a '\"pass\"' "$TMP/u7out/ui-audit.json" 2>/dev/null | tr -d ' ')；stderr：$(brief "$STDERR")"

# ---------------------------------------------------------------------------
# U8 目录服务不许把服务目录外的文件端出来。要 raw socket 发请求：fetch/undici 会先把
#   /../ 规范化掉，穿越压根发不出去，测出来的是客户端而不是服务端。
# 现状：import ui-audit.mjs 会直接把 main() 跑掉（无参 → 用法 rc 2），serveDir 也没导出，
#   所以这条现在必红。修后口径：resolve 后判前缀，越界一律 404；serveDir 导出；
#   main() 加 import.meta.url === pathToFileURL(process.argv[1]).href 守卫。
# ---------------------------------------------------------------------------
mkdir -p "$TMP/u8/site"
printf '%s\n' '<!doctype html><html lang="zh"><body>站点内的正常页面</body></html>' > "$TMP/u8/site/index.html"
printf '%s\n' 'CANARY-OUTSIDE-DO-NOT-SERVE' > "$TMP/u8/secret-outside.txt"
cat > "$TMP/u8-probe.mjs" <<'U8JS'
import net from 'node:net';
const mod = await import(process.env.U8_AUDIT);
if (typeof mod.serveDir !== 'function') { console.log('U8-NO-EXPORT'); process.exit(9); }
const { server, url } = await mod.serveDir(process.env.U8_ROOT + '/site');
const port = Number(new URL(url).port);
// 必须走 raw socket：fetch / undici 会先把 /../ 规范化掉，穿越根本发不出去
const raw = (path) => new Promise((ok) => {
  const c = net.connect(port, '127.0.0.1', () => c.write('GET ' + path + ' HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n'));
  let buf = ''; c.on('data', (d) => { buf += d; }); c.on('end', () => ok(buf)); c.on('error', (e) => ok('ERR ' + e.message));
});
const bad = [];
for (const t of ['/../secret-outside.txt', '/%2e%2e/secret-outside.txt', '/..%2Fsecret-outside.txt']) {
  const res = await raw(t);
  if (/^HTTP\/1\.\d 200/.test(res) || res.includes('CANARY-OUTSIDE')) bad.push(t);
}
const inside = await raw('/index.html');
server.close();
if (bad.length) { console.log('U8-LEAK ' + bad.join(' ')); process.exit(1); }
if (!/^HTTP\/1\.\d 200/.test(inside)) { console.log('U8-INSIDE-BROKEN'); process.exit(2); }
console.log('U8-OK');
U8JS
U8_AUDIT="$AUDIT" U8_ROOT="$TMP/u8" node "$TMP/u8-probe.mjs" > "$TMP/o" 2> "$TMP/e"
RC=$?
STDOUT=$(cat "$TMP/o"); STDERR=$(cat "$TMP/e")
if [ "$RC" -eq 0 ] && contains 'U8-OK' "$STDOUT"; then r=0; else r=1; fi
chk "$r" "U8 目录服务不许被 /../ 穿越读到服务目录外的文件（三种写法都要挡）" \
    "rc=0 且 stdout 含 U8-OK（三次穿越都非 200 且不含 canary，站内 index.html 仍 200）" \
    "rc=$RC；stdout：$(brief "$STDOUT")；stderr：$(brief "$STDERR")"

# ---------------------------------------------------------------------------
# U9 缺席不许留着上一轮的旧证据当通过。旧 ui-audit.json 还写着 pass:true 时，
#   下游看报告会以为这轮审计过了——缺席必须把结论覆写成「没跑」。
#   顺带守一条防回归位：rc 2 / 3 都不许顺手把 --out 目录建出来。
# 用抛错的引擎桩制造缺席，本机有没有真 playwright 都走同一条路径。
# ---------------------------------------------------------------------------
mkdir -p "$TMP/u9out"
printf '%s\n' '{"pass": true, "target": "OLD-RUN"}' > "$TMP/u9out/ui-audit.json"
stub_run u9 "$STUB_THROW" "$TMP/site" --strict --out "$TMP/u9out"
ok=1
[ "$RC" -eq 3 ] || ok=0
grep -aqE '"pass"[[:space:]]*:[[:space:]]*true' "$TMP/u9out/ui-audit.json" && ok=0
grep -aqE '"absent"[[:space:]]*:[[:space:]]*true' "$TMP/u9out/ui-audit.json" || ok=0
stub_run u9b "$STUB_THROW" "$TMP/site" --out "$TMP/u9never"
[ -d "$TMP/u9never" ] && ok=0
if [ "$ok" -eq 1 ]; then r=0; else r=1; fi
chk "$r" "U9 缺席时旧 ui-audit.json 必须被覆写成「没跑」，且不为缺席新建 --out 目录" \
    "rc=3；报告里 pass 不为 true 且含 absent:true；$TMP/u9never 不许被建出来" \
    "rc=$RC；报告=$(brief "$(cat "$TMP/u9out/ui-audit.json" 2>/dev/null)")；never 目录存在=$([ -d "$TMP/u9never" ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# U10 前缀校验只看解析后的路径字符串，符号链接是在 readFile 那一步才被跟随的——
#   站内一个指向站外的软链就能把 canary 端出来，路径前缀怎么看都还在 root 之内。
# ---------------------------------------------------------------------------
mkdir -p "$TMP/u10/site" "$TMP/u10/outside"
printf '%s\n' 'CANARY-OUTSIDE-DO-NOT-SERVE' > "$TMP/u10/outside/secret.txt"
printf '%s\n' '<!doctype html><html lang="zh"><body>站点内的正常页面</body></html>' > "$TMP/u10/site/index.html"
if ln -s ../outside/secret.txt "$TMP/u10/site/link.txt" 2>/dev/null && ln -s ../outside "$TMP/u10/site/dirlink" 2>/dev/null; then
    cat > "$TMP/u10-probe.mjs" <<'U10JS'
import net from 'node:net';
const mod = await import(process.env.U10_AUDIT);
if (typeof mod.serveDir !== 'function') { console.log('U10-NO-EXPORT'); process.exit(9); }
const { server, url } = await mod.serveDir(process.env.U10_ROOT + '/site');
const port = Number(new URL(url).port);
const raw = (path) => new Promise((ok) => {
  const c = net.connect(port, '127.0.0.1', () => c.write('GET ' + path + ' HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n'));
  let buf = ''; c.on('data', (d) => { buf += d; }); c.on('end', () => ok(buf)); c.on('error', (e) => ok('ERR ' + e.message));
});
const bad = [];
for (const t of ['/link.txt', '/dirlink/secret.txt']) {
  const res = await raw(t);
  if (/^HTTP\/1\.\d 200/.test(res) || res.includes('CANARY-OUTSIDE')) bad.push(t);
}
const inside = await raw('/index.html');
server.close();
if (bad.length) { console.log('U10-LEAK ' + bad.join(' ')); process.exit(1); }
if (!/^HTTP\/1\.\d 200/.test(inside)) { console.log('U10-INSIDE-BROKEN'); process.exit(2); }
console.log('U10-OK');
U10JS
    U10_AUDIT="$AUDIT" U10_ROOT="$TMP/u10" node "$TMP/u10-probe.mjs" > "$TMP/o" 2> "$TMP/e"
    RC=$?
    STDOUT=$(cat "$TMP/o"); STDERR=$(cat "$TMP/e")
    if [ "$RC" -eq 0 ] && contains 'U10-OK' "$STDOUT"; then r=0; else r=1; fi
    chk "$r" "U10 站内指向站外的软链（文件链 + 目录链）不许被端出来" \
        "rc=0 且 stdout 含 U10-OK（两条软链都非 200 且不含 canary，站内 index.html 仍 200）" \
        "rc=$RC；stdout：$(brief "$STDOUT")；stderr：$(brief "$STDERR")"
else
    skip "U10 软链穿越：本文件系统建不了符号链接，未执行 != 通过"
fi

# ---------------------------------------------------------------------------
# U11 覆写旧报告失败不许把缺席炸成用法错。<out>/ui-audit.json 被别的东西占着
#   （这里造成同名目录）时 writeFile 抛 EISDIR，异常一路冒到 main().catch 就成了 rc 2——
#   「缺席」这条结论被一个写盘小事故顶掉了。对照组是 U9：正常目录下同样缺席退 3。
# ---------------------------------------------------------------------------
mkdir -p "$TMP/u11out/ui-audit.json"
stub_run u11 "$STUB_THROW" "$TMP/site" --strict --out "$TMP/u11out"
if [ "$RC" -eq 3 ] && contains 'UI 审计缺席' "$STDERR"; then r=0; else r=1; fi
chk "$r" "U11 缺席时覆写旧报告失败（<out>/ui-audit.json 是目录）仍退 3，只警告不炸成 2" \
    "rc=3 且 stderr 含「UI 审计缺席」" "rc=$RC；stderr：$(brief "$STDERR")"

# ---------------------------------------------------------------------------
# U12 rc 2 出口（目标既不是 URL 也不是目录）同样不许把上一轮的旧报告留着当通过。
#   --out 这时已经解析出来了，报告在就覆写成「没跑」；不在就什么都不建。
# ---------------------------------------------------------------------------
mkdir -p "$TMP/u12out"
printf '%s\n' '{"pass": true}' > "$TMP/u12out/ui-audit.json"
run "$TMP/u12nosuch" --out "$TMP/u12out"
ok=1
[ "$RC" -eq 2 ] || ok=0
grep -aqE '"pass"[[:space:]]*:[[:space:]]*true' "$TMP/u12out/ui-audit.json" && ok=0
grep -aqE '"absent"[[:space:]]*:[[:space:]]*true' "$TMP/u12out/ui-audit.json" || ok=0
run "$TMP/u12nosuch" --out "$TMP/u12never"
[ -d "$TMP/u12never" ] && ok=0
if [ "$ok" -eq 1 ]; then r=0; else r=1; fi
chk "$r" "U12 rc 2 出口也要覆写旧 ui-audit.json，且不为它新建 --out 目录" \
    "rc=2；报告 pass 不为 true 且含 absent:true；$TMP/u12never 不许被建出来" \
    "rc=$RC；报告=$(brief "$(cat "$TMP/u12out/ui-audit.json" 2>/dev/null)")；never 目录存在=$([ -d "$TMP/u12never" ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# U13-U15：--out 一旦解析出来，**每个**没跑完的出口都要把旧报告作废。留着上一轮的
#   pass:true，下游看报告就当这轮审计过了——缺目标、主题解析空、跑到一半崩，都是没跑完。
#   参数解析本身就失败的出口（未知参数 / --widths 缺值）同样在此列：--out 靠 argv 预扫
#   拿到（--out X 与 --out=X 两种写法都要认），由 U16 / U16b 锁着。
# ---------------------------------------------------------------------------
# 把脚本副本放进临时目录，让 DEFAULT_OUT（按脚本自身位置解析）落在临时目录里——
#   否则断言「默认目录的旧报告被作废」就会写到仓内 .claude/evidence/ui-audit 去。
iso_run() { # <用例名> [args...]
    local name=$1
    shift
    ISO_DIR="$TMP/$name/evidence/ui-audit"
    mkdir -p "$TMP/$name/scripts" "$ISO_DIR"
    cp "$AUDIT" "$TMP/$name/scripts/ui-audit.mjs"
    printf '%s\n' '{"pass": true, "target": "OLD-RUN"}' > "$ISO_DIR/ui-audit.json"
    # 诱饵目录：--out 的值若被当成目录名吞下去，落点就在这几个里，预置成「上一轮通过」好分辨
    ISO_ROOT="$TMP/$name"
    for d in -x --strict; do
        mkdir -p "$ISO_ROOT/$d"
        printf '%s\n' '{"pass": true, "target": "DECOY"}' > "$ISO_ROOT/$d/ui-audit.json"
    done
    # cwd 也放沙箱：这样 resolve('--strict') 落在沙箱里，断言「没去动 ./--strict」才有地方看
    ( cd "$ISO_ROOT" && node ./scripts/ui-audit.mjs ${@+"$@"} ) > "$TMP/o" 2> "$TMP/e"
    RC=$?
    STDOUT=$(cat "$TMP/o")
    STDERR=$(cat "$TMP/e")
}

u_stale() { # <目录> → 预置一份「上一轮通过」的旧报告
    mkdir -p "$1"; printf '%s\n' '{"pass": true, "target": "OLD-RUN"}' > "$1/ui-audit.json"
}
u_voided() { # <目录> → 旧报告是否已被作废
    local f="$1/ui-audit.json"
    [ -f "$f" ] || return 1
    grep -aqE '"pass"[[:space:]]*:[[:space:]]*true' "$f" && return 1
    grep -aqE '"absent"[[:space:]]*:[[:space:]]*true' "$f"
}

u_stale "$TMP/u13out"
run --out "$TMP/u13out"
if [ "$RC" -eq 2 ] && u_voided "$TMP/u13out"; then r=0; else r=1; fi
chk "$r" "U13 连目标都没给（rc 2）也要作废旧报告，不许留着上一轮的 pass:true" \
    "rc=2 且报告被覆写成 absent:true / pass 非 true" \
    "rc=$RC；报告=$(brief "$(cat "$TMP/u13out/ui-audit.json" 2>/dev/null)")"

u_stale "$TMP/u14out"
run "$TMP/site" --themes "," --out "$TMP/u14out"
if [ "$RC" -eq 2 ] && u_voided "$TMP/u14out"; then r=0; else r=1; fi
chk "$r" "U14 --themes 「,」解析成空（rc 2）也要作废旧报告" \
    "rc=2 且报告被覆写成 absent:true / pass 非 true" \
    "rc=$RC；报告=$(brief "$(cat "$TMP/u14out/ui-audit.json" 2>/dev/null)")"

u_stale "$TMP/u15out"
stub_run u15 "$STUB_GOTO_THROW" "$TMP/site" --strict --themes light --widths 1280 --out "$TMP/u15out"
ok=1
[ "$RC" -eq 2 ] || ok=0
u_voided "$TMP/u15out" || ok=0
grep -aq 'boom-goto' "$TMP/u15out/ui-audit.json" 2>/dev/null || ok=0
if [ "$ok" -eq 1 ]; then r=0; else r=1; fi
chk "$r" "U15 跑到一半崩（page.goto 抛错，rc 2）也要作废旧报告，并把原因写进去" \
    "rc=2；报告 absent:true / pass 非 true 且含 boom-goto" \
    "rc=$RC；报告=$(brief "$(cat "$TMP/u15out/ui-audit.json" 2>/dev/null)")"

# ---------------------------------------------------------------------------
# U16 / U17：参数这一关没过，审计同样没跑。--out 得在严格解析之前先从 argv 里预扫出来
#   （--out X 与 --out=X 两种写法），否则「未知参数」这条出口连往哪写都不知道。
#   坏值不许静默丢档：--widths 1280,abc 现在会丢掉 abc 接着跑，跑出来的报告名不副实。
# ---------------------------------------------------------------------------
u_stale "$TMP/u16a"
run "$TMP/site" --out "$TMP/u16a" --bogus
ok=1
[ "$RC" -eq 2 ] || ok=0
u_voided "$TMP/u16a" || ok=0
grep -aqE '"screenshots"[[:space:]]*:[[:space:]]*\[\]' "$TMP/u16a/ui-audit.json" 2>/dev/null || ok=0
if [ "$ok" -eq 1 ]; then r=0; else r=1; fi
chk "$r" "U16 未知参数（rc 2）也要作废旧报告，且 absent 报告带 screenshots: []" \
    "rc=2；报告 absent:true / pass 非 true / 含 screenshots: []" \
    "rc=$RC；报告=$(brief "$(cat "$TMP/u16a/ui-audit.json" 2>/dev/null)")"

u_stale "$TMP/u16b"
run "$TMP/site" "--out=$TMP/u16b" --widths
if [ "$RC" -eq 2 ] && u_voided "$TMP/u16b"; then r=0; else r=1; fi
chk "$r" "U16b --widths 缺值（rc 2）也要作废旧报告，且 --out=X 这种写法也要能预扫到" \
    "rc=2 且报告被覆写成 absent:true / pass 非 true" \
    "rc=$RC；报告=$(brief "$(cat "$TMP/u16b/ui-audit.json" 2>/dev/null)")"

u_stale "$TMP/u17w"; u_stale "$TMP/u17t"
run "$TMP/site" --widths '1280,abc' --out "$TMP/u17w"; RCW=$RC
run "$TMP/site" --themes 'light,,dark' --out "$TMP/u17t"; RCT=$RC
stub_run u17ok "$STUB_CONTRAST" "$TMP/site" --themes light --widths '1280,900' --out "$TMP/u17ok"; RCOK=$RC
ok=1
[ "$RCW" -eq 2 ] || ok=0; u_voided "$TMP/u17w" || ok=0
[ "$RCT" -eq 2 ] || ok=0; u_voided "$TMP/u17t" || ok=0
[ "$RCOK" -eq 0 ] || ok=0
if [ "$ok" -eq 1 ]; then r=0; else r=1; fi
chk "$r" "U17 --widths/--themes 里有坏值一律 rc 2 并作废旧报告，不许静默丢档（好参数仍 rc 0）" \
    "1280,abc → rc=2 且作废；light,,dark → rc=2 且作废；1280,900 桩下 rc=0" \
    "1280,abc rc=$RCW 已作废=$(u_voided "$TMP/u17w" && echo yes || echo no)；light,,dark rc=$RCT 已作废=$(u_voided "$TMP/u17t" && echo yes || echo no)；对照 1280,900 rc=$RCOK"

# ---------------------------------------------------------------------------
# U18 --out 的边角：预扫必须和 parseArgs 看到的是同一个目录，否则「作废旧报告」作废错了人——
#   写重复 --out 时 parseArgs 取末位，预扫也得取末位。
#   --out= 是坏值：目录名为空谁也说不清往哪写，按 rc 2 处理。
# ---------------------------------------------------------------------------
u_stale "$TMP/u18a"; u_stale "$TMP/u18b"
run "$TMP/site" --out "$TMP/u18a" --out "$TMP/u18b" --bogus
ok=1
[ "$RC" -eq 2 ] || ok=0
u_voided "$TMP/u18b" || ok=0
u_voided "$TMP/u18a" && ok=0        # 头一个 --out 不该被动
if [ "$ok" -eq 1 ]; then r=0; else r=1; fi
chk "$r" "U18 写了两次 --out 时，作废的必须是末位那个（与 parseArgs 一致），头一个不许动" \
    "rc=2；B 目录报告 absent；A 目录仍是原样的 pass:true" \
    "rc=$RC；A=$(brief "$(cat "$TMP/u18a/ui-audit.json" 2>/dev/null)")；B=$(brief "$(cat "$TMP/u18b/ui-audit.json" 2>/dev/null)")"

run "$TMP/site" --out=
if [ "$RC" -eq 2 ]; then r=0; else r=1; fi
chk "$r" "U18b --out= 空值是坏值，rc 2（默认目录里的报告作废与否不在此断言，避免动到仓内 evidence）" \
    "rc=2" "rc=$RC；stderr：$(brief "$STDERR")"

# ---------------------------------------------------------------------------
# U19 --out 后面跟着的若是另一个 flag，或 --out 干脆是最后一个参数，都叫缺值——
#   不许把 --strict 当成目录名吞下去。这时 --out 不可知，作废的对象是默认目录。
#   实测（node v24.14.1）：parseArgs 对 ["site","--out","--strict"] 与 ["site","--out","-x"] 都抛
#   ERR_PARSE_ARGS_INVALID_OPTION_VALUE「argument is ambiguous」，所以这两种都走**解析失败通道**，
#   判定全落在预扫上；--out=--strict 则解析**成功**，走另一条通道。脚本里那个 flagOut 分支是给
#   旧版 node 留的防御（旧版会把下一个 token 直接当值吞掉），本机走不到，别据此以为它是死代码。
# ---------------------------------------------------------------------------
iso_run u19 "$TMP/site" --out --strict
if [ "$RC" -eq 2 ] && u_voided "$ISO_DIR"; then r=0; else r=1; fi
chk "$r" "U19 --out 后面跟着 --strict 是缺值（rc 2），默认目录里的旧报告要作废" \
    "rc=2 且默认目录报告 absent:true / pass 非 true" \
    "rc=$RC；默认目录报告=$(brief "$(cat "$ISO_DIR/ui-audit.json" 2>/dev/null)")"

iso_run u19b "$TMP/site" --out
if [ "$RC" -eq 2 ] && u_voided "$ISO_DIR"; then r=0; else r=1; fi
chk "$r" "U19b 防回归位（现在就绿）：--out 是最后一个参数时同样按缺值处理并作废默认目录" \
    "rc=2 且默认目录报告 absent:true / pass 非 true" \
    "rc=$RC；默认目录报告=$(brief "$(cat "$ISO_DIR/ui-audit.json" 2>/dev/null)")"

# ---------------------------------------------------------------------------
# U20 / U21：取值型 flag 的值以 - 开头一律算缺值，单横线双横线不分家；两条通道同判。
#   缺值时 --out 不可知，作废对象是默认目录——绝不能拿那个「值」当目录名去作废别人。
# ---------------------------------------------------------------------------
iso_run u20 "$TMP/site" --out -x
ok=1
[ "$RC" -eq 2 ] || ok=0
u_voided "$ISO_DIR" || ok=0
u_voided "$ISO_ROOT/-x" && ok=0
if [ "$ok" -eq 1 ]; then r=0; else r=1; fi
chk "$r" "U20 --out 后面跟着单横线的 -x 同样是缺值：作废默认目录，不许去动 ./-x" \
    "rc=2；默认目录报告 absent；./-x 里的报告原样不动" \
    "rc=$RC；默认=$(brief "$(cat "$ISO_DIR/ui-audit.json" 2>/dev/null)")；./-x=$(brief "$(cat "$ISO_ROOT/-x/ui-audit.json" 2>/dev/null)")"

iso_run u21a "$TMP/site" --out=--strict --bogus
RCA=$RC; ADEF="$ISO_DIR"; ADEC="$ISO_ROOT/--strict"
iso_run u21b "$TMP/site" --out=--strict
RCB=$RC; BDEF="$ISO_DIR"; BDEC="$ISO_ROOT/--strict"
ok=1
[ "$RCA" -eq 2 ] || ok=0; u_voided "$ADEF" || ok=0; u_voided "$ADEC" && ok=0
[ "$RCB" -eq 2 ] || ok=0; u_voided "$BDEF" || ok=0; u_voided "$BDEC" && ok=0
if [ "$ok" -eq 1 ]; then r=0; else r=1; fi
chk "$r" "U21 等号写法 --out=--strict 在解析失败与解析成功两条通道上判得一样" \
    "两次都 rc=2；两次都作废默认目录；两次都不动 ./--strict" \
    "失败通道 rc=$RCA 默认已作废=$(u_voided "$ADEF" && echo yes || echo no) 动了./--strict=$(u_voided "$ADEC" && echo yes || echo no)；成功通道 rc=$RCB 默认已作废=$(u_voided "$BDEF" && echo yes || echo no) 动了./--strict=$(u_voided "$BDEC" && echo yes || echo no)"

echo "  [NOTE] 未覆盖：URL 目标、多主题×多宽度组合矩阵、截图文件命名、--json 的 combos 结构细节。"
echo "         这些要真引擎 + 稳定渲染环境，先只锁「缺席不冒充通过」和「溢出必须判红」两条命脉。"
echo "  [NOTE] U0-U4 与 U6-U17 都已是绿的；唯一没执行的是 U5——真渲染要浏览器引擎，"
echo "         本机没装就 SKIPPED，套件退 3 而不是 0（未执行 != 通过）。装上 playwright 后它才会真跑。"

echo ""
echo "==== test-ui-audit：PASS=$PASS FAIL=$FAIL SKIPPED=$SKIP ===="
# 退出码三态（同 harness-golden --strict 的约定）：有红退 1；全绿但有跳过退 3，
#   「未执行 != 通过」必须传得出这一层，否则 CI 上没装引擎就是永远的绿。
[ "$FAIL" -eq 0 ] || exit 1
[ "$SKIP" -eq 0 ] || exit 3
exit 0
