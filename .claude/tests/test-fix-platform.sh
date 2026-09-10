#!/usr/bin/env bash
# risk: high
# test-fix-platform.sh — fix-platform 老安装归一回归测试（无依赖 claude CLI）。
# 契约（docs/v3-work-packs.md D.1 / D.6）：单运行时之后 fix-platform 只干三件事——
#   ① 删 hooks/ 下历史遗留的 *.sh / *.ps1（含 lib-*）② settings.json 里指向 .sh/.ps1 的 hook
#   command 改写成 exec form（command=node + args[0] 指 .mjs）、statusLine 归一到 statusline.mjs
#   ③ scripts/*.sh 补执行位。
# fixture 造的是**老安装残留**形态：settings 里还挂着 .sh command、hooks/ 下 .sh/.ps1 与新的
#   .mjs 并存。这形态最要命的地方在于「删了文件却没改 settings」——每次事件报一次 hook error，
#   所以「残留清空」与「settings 切 exec form」必须一起断言，缺一条都读不出这个洞。
# 覆盖：① fix-platform.sh（Linux/Mac 路径）② fix-platform.ps1（Windows 对称路径）。
# 无 pwsh → ② 标 SKIP；被测脚本自己缺依赖跑不起来 → 标 SKIP 并说明（不假绿也不冤枉它）。
# fixture JSON 与断言都用 node（目标机器只保证 node + git + coreutils）。
set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
[ -f "$ROOT/.claude/scripts/fix-platform.sh" ] || { echo "test-fix-platform: 缺 fix-platform.sh" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "test-fix-platform: 无 node——fixture 与断言都要解析 JSON；未执行 != 通过。" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
SKIP=0
pass() { PASS=$((PASS + 1)); echo "  [PASS] $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }
skip() { SKIP=$((SKIP + 1)); echo "  [SKIP] $1"; }
chk() {
  if [ "$1" -eq 0 ]; then pass "$2"; else fail "$2"; fi
  echo "         EXPECT $3"
  echo "         GOT    $4"
}

# mkfixture <项目根> —— 造一份「老安装升级上来」的 .claude/：
#   settings.json 里两条 hook 还是 shell form 的 .sh command、statusLine 还指 statusline.sh；
#   hooks/ 下 .sh + .ps1 + lib-*.sh 残留与新装的 .mjs 并存；scripts/ 下有个没执行位的 .sh。
mkfixture() {
  local proj="$1" cl="$1/.claude"
  rm -rf "$proj"
  mkdir -p "$cl/hooks/lib" "$cl/scripts"
  # 残留（老形态，该被删光）
  printf '#!/usr/bin/env bash\n'   > "$cl/hooks/tdd-gate.sh"
  printf '#!/usr/bin/env pwsh\n'   > "$cl/hooks/tdd-gate.ps1"
  printf '#!/usr/bin/env bash\n'   > "$cl/hooks/pre-commit-check.sh"
  printf '#!/usr/bin/env bash\n'   > "$cl/hooks/lib-fast-mode.sh"
  printf '#!/usr/bin/env pwsh\n'   > "$cl/hooks/lib-harness.ps1"
  # 新装的（该原封不动留着）
  printf 'process.exitCode = 0;\n' > "$cl/hooks/tdd-gate.mjs"
  printf 'process.exitCode = 0;\n' > "$cl/hooks/pre-commit-check.mjs"
  printf 'export const x = 1;\n'   > "$cl/hooks/lib/fastmode.mjs"
  printf '#!/usr/bin/env bash\necho hi\n' > "$cl/scripts/fast-mode.sh"
  chmod -x "$cl/scripts/fast-mode.sh" 2>/dev/null || true
  node -e '
const fs = require("node:fs");
const data = {
  statusLine: { type: "command", command: "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/statusline.sh\"", padding: 0 },
  hooks: {
    PreToolUse: [{ matcher: "Bash", hooks: [
      { type: "command", command: "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/tdd-gate.sh", timeout: 5 },
      { type: "command", command: "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/pre-commit-check.sh", timeout: 30 }
    ]}]
  }
};
fs.writeFileSync(process.argv[1], JSON.stringify(data, null, 2) + "\n");
' "$cl/settings.json"
}

# 同形的 .ps1 老安装 fixture：形态与上面一致（Windows 老安装挂的是 pwsh -File ...ps1）。
mkfixture_ps1() {
  local proj="$1" cl="$1/.claude"
  mkfixture "$proj"
  node -e '
const fs = require("node:fs");
const data = {
  statusLine: { type: "command", command: "pwsh -NoProfile -File .claude/scripts/statusline.ps1", padding: 0 },
  hooks: {
    PreToolUse: [{ matcher: "Bash", hooks: [
      { type: "command", command: "pwsh -NoProfile -File .claude/hooks/tdd-gate.ps1", timeout: 5 },
      { type: "command", command: "pwsh -NoProfile -File .claude/hooks/pre-commit-check.ps1", timeout: 30 }
    ]}]
  }
};
fs.writeFileSync(process.argv[1], JSON.stringify(data, null, 2) + "\n");
' "$cl/settings.json"
}

# sq <settings 路径> <js 表达式> —— 在 settings.json 上求值。作用域里可用 s / entries / fs。
sq() {
  node -e '
const fs = require("node:fs");
let s;
try { s = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); }
catch (e) { process.stdout.write("<not-json>"); process.exit(0); }
const entries = [];
for (const ev of Object.keys(s.hooks || {})) {
  for (const g of (s.hooks[ev] || [])) {
    for (const h of (g.hooks || [])) entries.push(h);
  }
}
process.stdout.write(String(eval(process.argv[2])));
' "$1" "$2"
}

# residue <hooks 目录> —— 列出该删而没删的 .sh/.ps1。
residue() { find "$1" -maxdepth 1 \( -name '*.sh' -o -name '*.ps1' \) 2>/dev/null | sed "s#^$1/##" | sort | tr '\n' ' '; }

# assert_idempotent <标签> <项目根> <重跑命令…> —— 幂等两条：
#   ⑥ settings.json 逐字节不变（派单口径的幂等）
#   ⑦ 首次留下的备份不许被二次跑覆盖。备份是给「迁移前长什么样」用的，被归一后的内容盖掉
#      就等于没有备份——而人往往正是发现不对劲才第二次跑它。只在被测脚本真写了 .bak 时判，
#      没写就打一行 note（两侧一个写一个不写，本身也值得看见）。
assert_idempotent() {
  local tag="$1" proj="$2"; shift 2
  local cl="$proj/.claude" bak="$proj/.claude/settings.json.bak"
  cp "$cl/settings.json" "$TMP/idem-$tag-settings.before"
  local hadbak=0
  if [ -f "$bak" ]; then hadbak=1; cp "$bak" "$TMP/idem-$tag-bak.before"; fi
  local rc=0
  "$@" >"$TMP/idem-$tag.log" 2>&1 || rc=$?
  local d; d=$(diff "$TMP/idem-$tag-settings.before" "$cl/settings.json" 2>&1 || true)
  chk "$([ "$rc" -eq 0 ] && [ -z "$d" ] && echo 0 || echo 1)" \
      "$tag ⑥ 幂等：二次跑 rc 0 且 settings.json 逐字节不变" \
      "rc=0 且零 diff" "rc=$rc diff=[${d:-无}]"
  if [ "$hadbak" -eq 1 ]; then
    chk "$(cmp -s "$TMP/idem-$tag-bak.before" "$bak" && echo 0 || echo 1)" \
        "$tag ⑦ 二次跑不许覆盖首次留下的 settings.json.bak（备份被归一后的内容盖掉 = 迁移前的原件没了）" \
        "备份内容与首次跑完时一致" \
        "一致=$(cmp -s "$TMP/idem-$tag-bak.before" "$bak" && echo Y || echo N)；二次跑后备份是否等于当前 settings=$(cmp -s "$bak" "$cl/settings.json" && echo Y || echo N)"
  else
    echo "  [NOTE] $tag 未产生 settings.json.bak，⑦ 无对象（两侧一写一不写的话，这行就是那处不对称）"
  fi
}

# assert_normalized <标签> <项目根> —— 归一后应成立的五件事，逐条断言。
assert_normalized() {
  local tag="$1" proj="$2" cl="$2/.claude"

  local left; left=$(residue "$cl/hooks")
  chk "$([ -z "$left" ] && echo 0 || echo 1)" \
      "$tag ① hooks/ 下的历史 .sh/.ps1（含 lib-*）全部删光" \
      "0 个残留" "残留：${left:-无}"

  local kept=0
  [ -f "$cl/hooks/tdd-gate.mjs" ] && [ -f "$cl/hooks/pre-commit-check.mjs" ] && [ -f "$cl/hooks/lib/fastmode.mjs" ] || kept=1
  chk "$kept" \
      "$tag ② .mjs 与 hooks/lib/ 一个没被误删（清残留不许连正装文件一起清）" \
      "三个 .mjs 都在" \
      "tdd-gate.mjs=$([ -f "$cl/hooks/tdd-gate.mjs" ] && echo Y || echo N) pre-commit-check.mjs=$([ -f "$cl/hooks/pre-commit-check.mjs" ] && echo Y || echo N) lib/fastmode.mjs=$([ -f "$cl/hooks/lib/fastmode.mjs" ] && echo Y || echo N)"

  local bad; bad=$(sq "$cl/settings.json" 'entries.filter(h => h.command !== "node" || !Array.isArray(h.args) || !/\.claude\/hooks\/[A-Za-z0-9_-]+\.mjs$/.test(String(h.args[0] || ""))).map(h => JSON.stringify(h.command)).join(" ") || "无"')
  chk "$([ "$bad" = "无" ] && echo 0 || echo 1)" \
      "$tag ③ settings 里每条 hook 都成了 exec form（command=node + args[0] 指 .mjs）" \
      "零条不是 exec form" "违例：$bad"

  local shleft; shleft=$(grep -cE '\.claude[/\\]hooks[/\\][A-Za-z0-9_-]+\.(sh|ps1)' "$cl/settings.json" 2>/dev/null || true)
  chk "$([ "${shleft:-0}" = "0" ] && echo 0 || echo 1)" \
      "$tag ④ settings 全文零指向 hooks 的 .sh/.ps1 字面量（文件删了引用还在 = 每次事件报 hook error）" \
      "0 处" "${shleft:-0} 处"

  local sl; sl=$(sq "$cl/settings.json" 'String((s.statusLine || {}).command || "")')
  local r=1
  case "$sl" in *".claude/scripts/statusline.mjs"*) case "$sl" in *".sh"*|*".ps1"*) r=1 ;; *) r=0 ;; esac ;; esac
  chk "$r" \
      "$tag ⑤ statusLine 归一到 statusline.mjs 且不再含 .sh/.ps1" \
      "命令串含 statusline.mjs 且不含 .sh/.ps1" "command=[$sl]"
}

echo "===== test-fix-platform ====="

# ---- ① fix-platform.sh ----
echo "--- ① fix-platform.sh：老安装残留 → 清空 + settings 切 exec form + 幂等 ---"
FP="$ROOT/.claude/scripts/fix-platform.sh"
PROJ="$TMP/proj-sh"
mkfixture "$PROJ"
RC=0
CLAUDE_PROJECT_DIR="$PROJ" bash "$FP" >"$TMP/fp-1.log" 2>&1 || RC=$?
if [ "$RC" -ne 0 ] && ! command -v python3 >/dev/null 2>&1; then
    skip "fix-platform.sh：本机无 python3，被测脚本自己退出 $RC（见 $TMP/fp-1.log）——未执行 != 通过"
else
    chk "$([ "$RC" -eq 0 ] && echo 0 || echo 1)" \
        "①⓪ fix-platform.sh 跑完 rc 0" "rc=0" "rc=$RC 日志尾：[$(tail -2 "$TMP/fp-1.log" | tr '\n' '~')]"
    assert_normalized "①" "$PROJ"

    assert_idempotent "①" "$PROJ" env CLAUDE_PROJECT_DIR="$PROJ" bash "$FP"
fi

# ---- ② fix-platform.ps1（对称路径）----
echo ""
echo "--- ② fix-platform.ps1：同形老安装残留（Windows 对称路径） ---"
if ! command -v pwsh >/dev/null 2>&1; then
    skip "fix-platform.ps1：无 pwsh（对称路径无法验证，不假绿）"
else
    FPPS1="$ROOT/.claude/scripts/fix-platform.ps1"
    PROJ2="$TMP/proj-ps1"
    mkfixture_ps1 "$PROJ2"
    RC=0
    CLAUDE_PROJECT_DIR="$PROJ2" pwsh -NoProfile -File "$FPPS1" >"$TMP/fpp-1.log" 2>&1 || RC=$?
    chk "$([ "$RC" -eq 0 ] && echo 0 || echo 1)" \
        "②⓪ fix-platform.ps1 跑完 rc 0" "rc=0" "rc=$RC 日志尾：[$(tail -2 "$TMP/fpp-1.log" | tr '\n' '~')]"
    assert_normalized "②" "$PROJ2"

    assert_idempotent "②" "$PROJ2" env CLAUDE_PROJECT_DIR="$PROJ2" pwsh -NoProfile -File "$FPPS1"
fi

echo ""
echo "结果：PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
