#!/usr/bin/env bash
# risk: low
# test-hooks-settings.sh — 注册面回归：settings.json 的 hook 必须是 exec form 的
#   `node <项目根>/.claude/hooks/<name>.mjs`，且 args[0] 指到的文件真实存在。
#
# 分级取舍（2026-09-10 测试预算表）：注册面判错的代价是「每次事件报一次 hook error」，
#   吵但不致命，所以只留两条主判据——形态（exec form）与落地（文件在）。
#   timeout/matcher 逐条对拍、statusLine、零 .sh/.ps1 残留、node --check 那批穷举不再养；
#   两侧集合对拍归 test-hook-parity.sh。
#
# 依赖：node（解析 JSON，故意不用 jq——目标机器只保证 node + git + coreutils）。
# 纪律：对本仓只读；每条断言打印 EXPECT / GOT，判定不依赖措辞。
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SETTINGS="$ROOT/.claude/settings.json"

echo "===== test-hooks-settings ====="

if ! command -v node >/dev/null 2>&1; then
    echo "SKIPPED: 无 node——settings.json 解析不了，未执行 != 通过。" >&2
    exit 1
fi

PASS=0
FAIL=0

# chk <判定 0=过/1=不过> <标题> <EXPECT 描述> <GOT 描述>
chk() {
    if [ "$1" -eq 0 ]; then
        PASS=$((PASS + 1)); echo "  [PASS] $2"
    else
        FAIL=$((FAIL + 1)); echo "  [FAIL] $2"
    fi
    echo "         EXPECT $3"
    echo "         GOT    $4"
}

# sq <js 表达式> —— 在 settings.json 上求值，打印结果。作用域里可用：s（整份 settings）、
# entries（[{ev, matcher, h}] 展平的 hook 条目）、ROOT、fs / path、nameOf、resolveArg。
sq() {
    node -e '
const fs = require("node:fs");
const path = require("node:path");
const ROOT = process.argv[1];
const s = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const entries = [];
for (const ev of Object.keys(s.hooks || {})) {
  for (const g of (s.hooks[ev] || [])) {
    for (const h of (g.hooks || [])) entries.push({ ev: ev, matcher: g.matcher || "", h: h });
  }
}
const nameOf = (h) => {
  const a = Array.isArray(h.args) && h.args.length ? String(h.args[0]) : String(h.command || "");
  const m = a.match(/hooks[\/\\]([A-Za-z0-9_-]+)\.(mjs|sh|ps1)$/);
  return m ? m[1] : "?";
};
const resolveArg = (a) => String(a).split("${CLAUDE_PROJECT_DIR}").join(ROOT);
process.stdout.write(String(eval(process.argv[3])));
' "$ROOT" "$SETTINGS" "$1"
}

# ---------------------------------------------------------------------------
echo ""

N=$(sq 'entries.length')
chk "$([ "${N:-0}" -gt 0 ] && echo 0 || echo 1)" \
    "HS-1 settings.json 是合法 JSON 且能展平出 hook 条目（展不出 = 下面两条空转全绿）" \
    "至少 1 条 hook 条目" "$N 条"

BAD_CMD=$(sq 'entries.filter(e => String(e.h.command) !== "node" || !Array.isArray(e.h.args) || !e.h.args.length).map(e => e.ev + ":" + nameOf(e.h)).join(" ") || "无"')
chk "$([ "$BAD_CMD" = "无" ] && echo 0 || echo 1)" \
    "HS-2 每条 hook 都是 exec form：command 逐字 \"node\" + 非空 args（有 args 才不经 shell，两平台相同）" \
    "零条非 exec form" "违规：$BAD_CMD"

BAD_ARG=$(sq 'entries.filter(e => Array.isArray(e.h.args) && e.h.args.length && !fs.existsSync(resolveArg(e.h.args[0]))).map(e => nameOf(e.h) + "<-" + e.h.args[0]).join(" ") || "无"')
chk "$([ "$BAD_ARG" = "无" ] && echo 0 || echo 1)" \
    "HS-3 每条 args[0] 指向的文件真实存在（注册了但没装 = 每次事件都报 hook error）" \
    "零个指空的 args[0]" "指空：$BAD_ARG"

# ---------------------------------------------------------------------------
echo ""
echo "==== test-hooks-settings：PASS=$PASS FAIL=$FAIL ===="
if [ "$FAIL" -gt 0 ]; then
    echo "test-hooks-settings: failed（settings 的 hook 注册形态或落地文件对不上）" >&2
    exit 1
fi
echo "test-hooks-settings: passed（$N 条 hook 全 exec form 且 args[0] 都装着）"
