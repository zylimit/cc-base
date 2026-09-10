#!/usr/bin/env bash
# test-ui-audit.sh — UI 审计闸（scripts/ui-audit.mjs）的回归测试。
#
# 契约：node ui-audit.mjs <url|目录> [--themes a,b] [--widths 1280,900] [--out <dir>] [--strict] [--json]
#   无参 → stderr 用法 rc 2；--help → stdout 用法 rc 0；目标既非 URL 也非目录 → rc 2；
#   找不到浏览器引擎 → stderr 一行「UI 审计缺席」rc 3；有引擎 → 逐主题×宽度审计 + 截图，
#   写 <out>/ui-audit.json（含 pass 与 combos），--strict 且不 pass → rc 1。缺引擎那条单列：一个把「没装 playwright」吞成 rc 0 的审计闸，会在 CI 上永远绿着。
# 只留高风险几条：缺席不冒充通过（U4/U9）、目录与软链穿越（U8/U10）、对比度判红（U7）、
#   空 catch（U22）。参数解析的花样组合与要真引擎的渲染用例已删。跑不成的路径走 SKIPPED
#   并计数，不算 PASS 也不算 FAIL：「未执行 != 通过」。
# 用法：bash test-ui-audit.sh [ui-audit.mjs 路径]
set -u

SRC=$(cd "$(dirname "$0")/.." && pwd)
AUDIT=${1:-"$SRC/scripts/ui-audit.mjs"}
case "$AUDIT" in /*) ;; *) AUDIT="$PWD/$AUDIT" ;; esac   # U7 要切 cwd，先钉成绝对路径

echo "===== test-ui-audit ====="
command -v node >/dev/null 2>&1 || {
    echo 'SKIPPED: 无 node——被测脚本是 .mjs，未执行 != 通过。'
    exit 0
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0; SKIP=0
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

RC=0; STDOUT=""; STDERR=""
run() { # [args...]
    node "$AUDIT" ${@+"$@"} > "$TMP/o" 2> "$TMP/e"
    RC=$?; STDOUT=$(cat "$TMP/o"); STDERR=$(cat "$TMP/e")
}

# 引擎在不在，决定 U4 与 U7 怎么隔离
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

# U4 缺引擎必须是 rc 3。引擎在场时把脚本复制到仓外目录跑，让 require 沿 /tmp 往上找不到包——
#   ui-audit.mjs 哪天 import 了 harness/lib 里的东西，这条会因找不到相对模块而红，
#   那时该换隔离手法，不是实现的错。
U4RUN="$AUDIT"
if [ "$HAS_ENGINE" -eq 1 ] && [ -f "$AUDIT" ]; then
    mkdir -p "$TMP/iso"; cp "$AUDIT" "$TMP/iso/ui-audit.mjs"; U4RUN="$TMP/iso/ui-audit.mjs"
fi
NODE_PATH=/nonexistent node "$U4RUN" "$TMP/site" > "$TMP/o" 2> "$TMP/e"
RC=$?; STDERR=$(cat "$TMP/e")
if [ "$RC" -eq 3 ] && contains 'UI 审计缺席' "$STDERR"; then r=0; else r=1; fi
chk "$r" "U4 引擎不可用 → stderr 一行「UI 审计缺席」，rc 3（缺席不许冒充通过）" \
    "rc=3 且 stderr 含「UI 审计缺席」" "rc=$RC；stderr：$(brief "$STDERR")"

# ---------------------------------------------------------------------------
# 引擎桩：本机没装 playwright 也要能验「审计判定」与「启动失败」两条路径。
# 桩是个 CJS 包（package.json 的 main 指向 index.js；写成 exports.chromium 是为了让
#   cjs-module-lexer 认出具名导出）。默认以桩目录为 cwd 跑仓里那份 ui-audit.mjs；本机若
#   真装了 playwright（会抢在裸 import 那一步），改把脚本复制进桩目录，让裸 import 也落到桩上。
# ---------------------------------------------------------------------------
STUB_THROW='exports.chromium = { async launch() { throw new Error("boom-launch"); } };'

STUB_CONTRAST=$(cat <<'JS'
const fs = require('fs');
const AUDIT = {
  overflows: [], wrapped: [], contrastFails: [{ cls: 'x', text: '灰字', ratio: 2.1 }],
  genericTells: { upperTinyLabels: 0, midDotTexts: 0, arrowEndings: 0, radiusValues: 0, uniformRadius: false },
  elementCount: 50, textLength: 200,
};
const page = {
  async setViewportSize() {}, async goto() {}, async waitForTimeout() {},
  // 带参数那次是设 data-theme，不带参数那次才是 PAGE_AUDIT
  async evaluate(fn, ...args) { return args.length ? undefined : AUDIT; },
  async screenshot(opts) { fs.writeFileSync(opts.path, ''); },
};
const browser = { async newPage() { return page; }, async close() {} };
exports.chromium = { async launch() { return browser; } };
JS
)

stub_run() { # <用例名> <index.js 内容> [args...]
    local name=$1 js=$2 runner; shift 2
    local d="$TMP/$name"
    mkdir -p "$d/node_modules/playwright-core"
    printf '%s\n' '{"name":"playwright-core","version":"0.0.0-stub","main":"index.js"}' \
        > "$d/node_modules/playwright-core/package.json"
    printf '%s\n' "$js" > "$d/node_modules/playwright-core/index.js"
    runner="$AUDIT"
    if [ "$HAS_ENGINE" -eq 1 ]; then cp "$AUDIT" "$d/ui-audit.mjs"; runner="$d/ui-audit.mjs"; fi
    ( cd "$d" && node "$runner" ${@+"$@"} ) > "$TMP/o" 2> "$TMP/e"
    RC=$?; STDOUT=$(cat "$TMP/o"); STDERR=$(cat "$TMP/e")
}

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
# 穿越探针：U8（/../ 三种写法）与 U10（软链）判的是同一件事——服务目录外的文件不许被端出来，
#   只有待试路径不同，所以共用一份。必须走 raw socket：fetch / undici 会先把 /../ 规范化掉，
#   穿越根本发不出去，测出来的是客户端而不是服务端。
# ---------------------------------------------------------------------------
cat > "$TMP/probe.mjs" <<'PROBEJS'
import net from 'node:net';
const L = process.env.PROBE_LABEL;
const mod = await import(process.env.PROBE_AUDIT);
if (typeof mod.serveDir !== 'function') { console.log(L + '-NO-EXPORT'); process.exit(9); }
const { server, url } = await mod.serveDir(process.env.PROBE_ROOT + '/site');
const port = Number(new URL(url).port);
const raw = (path) => new Promise((ok) => {
  const c = net.connect(port, '127.0.0.1', () => c.write('GET ' + path + ' HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n'));
  let buf = ''; c.on('data', (d) => { buf += d; }); c.on('end', () => ok(buf)); c.on('error', (e) => ok('ERR ' + e.message));
});
const bad = [];
for (const t of process.env.PROBE_PATHS.split(' ')) {
  const res = await raw(t);
  if (/^HTTP\/1\.\d 200/.test(res) || res.includes('CANARY-OUTSIDE')) bad.push(t);
}
const inside = await raw('/index.html');
server.close();
if (bad.length) { console.log(L + '-LEAK ' + bad.join(' ')); process.exit(1); }
if (!/^HTTP\/1\.\d 200/.test(inside)) { console.log(L + '-INSIDE-BROKEN'); process.exit(2); }
console.log(L + '-OK');
PROBEJS

probe() { # <标签> <root（其 site/ 子目录被服务）> <待试路径，空格分隔>
    PROBE_LABEL="$1" PROBE_AUDIT="$AUDIT" PROBE_ROOT="$2" PROBE_PATHS="$3" \
        node "$TMP/probe.mjs" > "$TMP/o" 2> "$TMP/e"
    RC=$?; STDOUT=$(cat "$TMP/o"); STDERR=$(cat "$TMP/e")
}

mkdir -p "$TMP/u8/site"
printf '%s\n' '<!doctype html><html lang="zh"><body>站点内的正常页面</body></html>' > "$TMP/u8/site/index.html"
printf '%s\n' 'CANARY-OUTSIDE-DO-NOT-SERVE' > "$TMP/u8/secret-outside.txt"
probe U8 "$TMP/u8" '/../secret-outside.txt /%2e%2e/secret-outside.txt /..%2Fsecret-outside.txt'
if [ "$RC" -eq 0 ] && contains 'U8-OK' "$STDOUT"; then r=0; else r=1; fi
chk "$r" "U8 目录服务不许被 /../ 穿越读到服务目录外的文件（三种写法都要挡）" \
    "rc=0 且 stdout 含 U8-OK（三次穿越都非 200 且不含 canary，站内 index.html 仍 200）" \
    "rc=$RC；stdout：$(brief "$STDOUT")；stderr：$(brief "$STDERR")"

# U10 前缀校验只看解析后的路径字符串，软链是在 readFile 那一步才被跟随的——站内一个指向
#   站外的软链就能把 canary 端出来，路径前缀怎么看都还在 root 之内。
mkdir -p "$TMP/u10/site" "$TMP/u10/outside"
printf '%s\n' 'CANARY-OUTSIDE-DO-NOT-SERVE' > "$TMP/u10/outside/secret.txt"
printf '%s\n' '<!doctype html><html lang="zh"><body>站点内的正常页面</body></html>' > "$TMP/u10/site/index.html"
if ln -s ../outside/secret.txt "$TMP/u10/site/link.txt" 2>/dev/null && ln -s ../outside "$TMP/u10/site/dirlink" 2>/dev/null; then
    probe U10 "$TMP/u10" '/link.txt /dirlink/secret.txt'
    if [ "$RC" -eq 0 ] && contains 'U10-OK' "$STDOUT"; then r=0; else r=1; fi
    chk "$r" "U10 站内指向站外的软链（文件链 + 目录链）不许被端出来" \
        "rc=0 且 stdout 含 U10-OK（两条软链都非 200 且不含 canary，站内 index.html 仍 200）" \
        "rc=$RC；stdout：$(brief "$STDOUT")；stderr：$(brief "$STDERR")"
else
    skip "U10 软链穿越：本文件系统建不了符号链接，未执行 != 通过"
fi

# ---------------------------------------------------------------------------
# U9 缺席不许留着上一轮的旧证据当通过：旧 ui-audit.json 还写着 pass:true，下游看报告就
#   以为这轮审计过了。顺带守一条防回归位：rc 2 / 3 都不许顺手把 --out 目录建出来。
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
# U22 空的 catch 把失败换成了错误答案，而且没人知道。fitness 的 no-silent-failure 规则扫的是
#   已跟踪文件，提交前一路绿、提交后才在 dod 里炸出来；这条把它提前到套件里。
#   --paths 只认**相对仓根**的路径：喂绝对路径会得到 scannedFiles=0 / findings 空，那是
#   「什么都没扫」而不是「扫干净了」——所以 scannedFiles>=1 与「零命中」缺一不可。
# ---------------------------------------------------------------------------
fitpaths() { # <json> → 「扫了几个文件 命中几条 规则@行」
    printf '%s' "$1" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let j;try{j=JSON.parse(s)}catch{return console.log("- - PARSE_ERROR")}const f=(j.findings||[]).filter(x=>String(x.path||"").endsWith("ui-audit.mjs"));console.log((j.scannedFiles===undefined?"?":j.scannedFiles)+" "+f.length+" "+([...new Set(f.map(x=>x.rule+"@"+x.line))].join(",")||"-"))})'
}
FITREL=""
case "$AUDIT" in "$SRC"/*) FITREL=".claude/${AUDIT#"$SRC"/}" ;; esac
if [ ! -f "$SRC/harness/harness.mjs" ]; then
    echo "  [NOTE] U22 跳过：找不到 $SRC/harness/harness.mjs"
elif [ -z "$FITREL" ]; then
    skip "U22 被测脚本不在 $SRC 之下（$AUDIT），fitness --paths 表达不出相对仓根的路径，未执行 != 通过"
else
    FIT=$( cd "$SRC/.." && node .claude/harness/harness.mjs fitness --paths "$FITREL" 2>/dev/null )
    FRC=$?
    if [ "$FRC" -eq 3 ]; then
        skip "U22 fitness 降级（rc 3），未执行 != 通过"
    else
        HIT=$(fitpaths "$FIT")
        SCANNED=${HIT%% *}; REST=${HIT#* }; N=${REST%% *}
        r=0
        [ "$FRC" -eq 0 ] || r=1
        [ "$SCANNED" -ge 1 ] 2>/dev/null || r=1
        [ "$N" = 0 ] || r=1
        chk "$r" "U22 ui-audit.mjs 里不许有空的 catch（fitness 的 no-silent-failure 零命中）" \
            "rc=0 且 scannedFiles>=1（确实扫到了）且 ui-audit.mjs 上零条 finding" \
            "rc=$FRC；扫到 $SCANNED 个文件；命中 $N 条：${REST#* }"
    fi
fi

echo "  [NOTE] 未覆盖：URL 目标、多主题×多宽度组合矩阵、截图文件命名、--json 的 combos 结构细节，"
echo "         以及参数解析的花样组合——那些要真引擎或从没挡下过缺陷，删了不补。"

echo ""
echo "==== test-ui-audit：PASS=$PASS FAIL=$FAIL SKIPPED=$SKIP ===="
# 退出码三态：有红退 1；全绿但有跳过退 3——「未执行 != 通过」必须传得出这一层，
#   否则 CI 上没装引擎就是永远的绿。
[ "$FAIL" -eq 0 ] || exit 1
[ "$SKIP" -eq 0 ] || exit 3
exit 0
