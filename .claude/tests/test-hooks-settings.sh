#!/usr/bin/env bash
# test-hooks-settings.sh — Phase D 注册面回归：settings.json 的 hook 必须是 exec form 的
#   `node <项目根>/.claude/hooks/<name>.mjs`，两平台逐字相同，且 hooks 目录里不再有 .sh/.ps1。
#
# red-locks-the-bug：本文件写的是**迁移完成后应该成立的状态**，不是「现状能复现」。
#   `.mjs` 尚未落地、settings 里还是 `.sh` command 时，本脚本整体必然 FAIL——这是它的成功状态。
#   迁移完成后它变成永久防线：谁把某条 hook 改回 shell form、谁漏装一个 .mjs、谁动了 timeout，
#   哪条立刻红。
#
# 契约来源（不是从代码反推，是从底本）：
#   docs/v3-work-packs.md D.1（目标状态表）/ D.2（hooks/lib 四件）/ D.6（触点表）
#   docs/v3-tiered-harness-proposal.md ADR-0002「执法方式：test-hook-parity 改为断言
#   settings.json 无 .sh/.ps1 命令」
#
# 依赖：node（解析 JSON，故意不用 jq——目标机器只保证 node + git + coreutils）。
# 纪律：对本仓只读；每条断言打印 EXPECT / GOT，判定不依赖措辞。
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SETTINGS="$ROOT/.claude/settings.json"
HOOKDIR="$ROOT/.claude/hooks"

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

# sq <js 表达式> —— 在 settings.json 上求值，打印结果。
# 作用域里可用：s（整份 settings）、entries（[{ev, matcher, h}] 展平的 hook 条目）、
#              ROOT（项目根绝对路径）、fs / path。
# 故意用 node 而非 jq：目标机器只保证 node。表达式里一律用双引号，别用单引号（外层是 bash 单引号）。
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

# 期望表（写死字面量，不从被测文件反算——对照组必须独立于被测物）。
# 三元组 = 事件 / matcher / hook 名 / timeout，取自迁移前 settings.json 的原值；
# D.1 明写「timeout 值不变」「matcher 与 shell form 完全一样」。
EXPECTED_ENTRIES='UserPromptSubmit||detect-feedback-signal|5
UserPromptExpansion|release-builder|release-gate|10
SessionStart||check-evolution|10
SessionStart||session-rules-banner|5
SessionStart||recap-on-dirty|5
PreToolUse|Bash|pre-commit-check|30
PreToolUse|Bash|kill-dev-ports|10
PreToolUse|Bash|dangerous-pkill-guard|5
PreToolUse|Bash|secret-exfil-guard|5
PreToolUse|Bash|tdd-gate|5
PreToolUse|Edit|Write|no-direct-code-guard|5
PostToolUse|Bash|auto-push|15
PostToolUse|Edit|Write|mark-review-needed|3
PostToolUse|Edit|Write|harness-async-verify|300
PostToolUse|Edit|Write|NotebookEdit|record-authorship|10
PreCompact||precompact-gate|10
PostCompact||postcompact-reinject|15
Notification|agent_needs_input|agent_completed|permission_prompt|notify|5
Stop||stop-gate|5
Stop||three-file-sync-gate|5
SubagentStop|implementer|code-reviewer|tester|deployer|subagent-acceptance-reminder|5'

# 22 个 hook（21 个注册 + 未注册的 static-check），盘点 A 段事实校正 1/3。
ALL_HOOKS='auto-push check-evolution dangerous-pkill-guard detect-feedback-signal
harness-async-verify kill-dev-ports mark-review-needed no-direct-code-guard notify
postcompact-reinject pre-commit-check precompact-gate recap-on-dirty record-authorship
release-gate secret-exfil-guard session-rules-banner static-check stop-gate
subagent-acceptance-reminder tdd-gate three-file-sync-gate'

# ---------------------------------------------------------------------------
echo ""
echo "--- HS 前置：settings.json 可解析 ---"

RC=0
PARSE=$(sq 'entries.length' 2>&1) || RC=$?
chk "$([ "$RC" -eq 0 ] && echo 0 || echo 1)" \
    "HS-1 settings.json 是合法 JSON 且能展平出 hook 条目" \
    "node 解析成功" \
    "rc=$RC 输出=[$PARSE]"

chk "$([ "$PARSE" = "21" ] && echo 0 || echo 1)" \
    "HS-2 注册 hook 条目共 21 条（迁移不许顺手漏注册/多注册）" \
    "21 条" \
    "$PARSE 条"

# ---------------------------------------------------------------------------
echo ""
echo "--- HS 形态：exec form（command==node + args[0] 指向 .mjs）---"

BADCMD=$(sq 'entries.filter(e => e.h.command !== "node").map(e => nameOf(e.h) + ":" + JSON.stringify(e.h.command)).join(" ") || "无"')
chk "$([ "$BADCMD" = "无" ] && echo 0 || echo 1)" \
    "HS-3 每条 hook 的 command 逐字等于 \"node\"（exec form，两平台相同）" \
    "零条 command != node" \
    "违例：$BADCMD"

NOARGS=$(sq 'entries.filter(e => !Array.isArray(e.h.args) || e.h.args.length < 1).map(e => nameOf(e.h)).join(" ") || "无"')
chk "$([ "$NOARGS" = "无" ] && echo 0 || echo 1)" \
    "HS-4 每条 hook 都有非空 args 数组（有 args 才不经 shell）" \
    "零条缺 args" \
    "违例：$NOARGS"

BADARG=$(sq 'entries.filter(e => !/^\$\{CLAUDE_PROJECT_DIR\}\/\.claude\/hooks\/[A-Za-z0-9_-]+\.mjs$/.test(String((e.h.args||[])[0] || ""))).map(e => nameOf(e.h) + ":" + JSON.stringify((e.h.args||[])[0])).join(" ") || "无"')
chk "$([ "$BADARG" = "无" ] && echo 0 || echo 1)" \
    'HS-5 每条 args[0] 形如 ${CLAUDE_PROJECT_DIR}/.claude/hooks/<name>.mjs（花括号占位符 + 正斜杠）' \
    "零条不符" \
    "违例：$BADARG"

MISSING=$(sq 'entries.filter(e => { const a = (e.h.args||[])[0]; return !a || !fs.existsSync(resolveArg(a)); }).map(e => nameOf(e.h)).join(" ") || "无"')
chk "$([ "$MISSING" = "无" ] && echo 0 || echo 1)" \
    "HS-6 每条 args[0] 指向的文件真实存在（注册了但没装 = 每次事件都报 hook error）" \
    "零条指向不存在的文件" \
    "缺文件：$MISSING"

# ---------------------------------------------------------------------------
echo ""
echo "--- HS 零残留：command / args 里不许再出现 .sh / .ps1（ADR-0002 执法点）---"

SHHIT=$(sq 'entries.filter(e => JSON.stringify([e.h.command].concat(e.h.args||[])).includes(".sh")).map(e => nameOf(e.h)).join(" ") || "无"')
chk "$([ "$SHHIT" = "无" ] && echo 0 || echo 1)" \
    "HS-7 hook 的 command/args 里零 .sh" \
    "零命中" \
    "命中：$SHHIT"

PSHIT=$(sq 'entries.filter(e => JSON.stringify([e.h.command].concat(e.h.args||[])).includes(".ps1")).map(e => nameOf(e.h)).join(" ") || "无"')
chk "$([ "$PSHIT" = "无" ] && echo 0 || echo 1)" \
    "HS-8 hook 的 command/args 里零 .ps1" \
    "零命中" \
    "命中：$PSHIT"

WHOLE_SH=$(grep -c '\.claude/hooks/[A-Za-z0-9_-]*\.sh' "$SETTINGS" 2>/dev/null || true)
WHOLE_SH=${WHOLE_SH:-0}
chk "$([ "$WHOLE_SH" = "0" ] && echo 0 || echo 1)" \
    "HS-9 settings.json 全文零 .claude/hooks/*.sh 字面量（含被注释/遗漏的段）" \
    "0 处" \
    "$WHOLE_SH 处"

WHOLE_PS=$(grep -c '\.claude[/\\]hooks[/\\][A-Za-z0-9_-]*\.ps1' "$SETTINGS" 2>/dev/null || true)
WHOLE_PS=${WHOLE_PS:-0}
chk "$([ "$WHOLE_PS" = "0" ] && echo 0 || echo 1)" \
    "HS-10 settings.json 全文零 .claude/hooks/*.ps1 字面量" \
    "0 处" \
    "$WHOLE_PS 处"

# ---------------------------------------------------------------------------
echo ""
echo "--- HS 保值：事件 / matcher / timeout 三元组逐条对照写死表 ---"

ACTUAL_ENTRIES=$(sq 'entries.map(e => [e.ev, e.matcher, nameOf(e.h), (e.h.timeout === undefined ? "-" : e.h.timeout)].join("|")).join("\n")')
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
printf '%s\n' "$EXPECTED_ENTRIES" | sort > "$TMPD/exp"
printf '%s\n' "$ACTUAL_ENTRIES" | sort > "$TMPD/act"
DIFF_OUT=$(diff "$TMPD/exp" "$TMPD/act" 2>&1 || true)
chk "$([ -z "$DIFF_OUT" ] && echo 0 || echo 1)" \
    "HS-11 21 条 (事件|matcher|hook名|timeout) 与迁移前逐条一致（D.1：timeout 值不变、matcher 一样）" \
    "与写死期望表零差异" \
    "diff=[${DIFF_OUT:-无差异}]"

ASYNC=$(sq 'entries.filter(e => nameOf(e.h) === "harness-async-verify").map(e => String(e.h.asyncRewake)).join(",") || "缺条目"')
chk "$([ "$ASYNC" = "true" ] && echo 0 || echo 1)" \
    "HS-12 harness-async-verify 仍带 asyncRewake:true（丢了它 exit 2 唤醒就失效）" \
    "asyncRewake=true" \
    "asyncRewake=$ASYNC"

# ---------------------------------------------------------------------------
echo ""
echo "--- HS statusLine：shell form 指向 scripts/statusline.mjs ---"

SL=$(sq 'String((s.statusLine || {}).command || "")')
case "$SL" in
    *".claude/scripts/statusline.mjs"*) r=0 ;;
    *) r=1 ;;
esac
chk "$r" \
    "HS-13 statusLine.command 指向 .claude/scripts/statusline.mjs（statusLine 无 exec form，只能 shell form）" \
    "命令串含 .claude/scripts/statusline.mjs" \
    "command=[$SL]"

case "$SL" in
    *"node"*) r=0 ;;
    *) r=1 ;;
esac
chk "$r" \
    "HS-14 statusLine 由 node 拉起" \
    "命令串含 node" \
    "command=[$SL]"

case "$SL" in
    *".sh"*|*".ps1"*) r=1 ;;
    *) r=0 ;;
esac
chk "$r" \
    "HS-15 statusLine 命令串零 .sh / .ps1" \
    "不含 .sh 也不含 .ps1" \
    "command=[$SL]"

chk "$([ -f "$ROOT/.claude/scripts/statusline.mjs" ] && echo 0 || echo 1)" \
    "HS-16 .claude/scripts/statusline.mjs 文件存在" \
    "文件存在" \
    "$([ -f "$ROOT/.claude/scripts/statusline.mjs" ] && echo 存在 || echo 缺失)"

# ---------------------------------------------------------------------------
echo ""
echo "--- HS 目录面：hooks/ 下零 .sh/.ps1，22 个 .mjs + lib 四件齐 ---"

SH_LEFT=$(find "$HOOKDIR" -maxdepth 1 -name '*.sh' 2>/dev/null | sed "s#^$HOOKDIR/##" | tr '\n' ' ')
chk "$([ -z "$SH_LEFT" ] && echo 0 || echo 1)" \
    "HS-17 .claude/hooks/ 下零 .sh（含 lib-*.sh）" \
    "0 个 .sh" \
    "残留：${SH_LEFT:-无}"

PS_LEFT=$(find "$HOOKDIR" -maxdepth 1 -name '*.ps1' 2>/dev/null | sed "s#^$HOOKDIR/##" | tr '\n' ' ')
chk "$([ -z "$PS_LEFT" ] && echo 0 || echo 1)" \
    "HS-18 .claude/hooks/ 下零 .ps1（含 lib-*.ps1）" \
    "0 个 .ps1" \
    "残留：${PS_LEFT:-无}"

for m in io gatelog fastmode harness; do
    chk "$([ -f "$HOOKDIR/lib/$m.mjs" ] && echo 0 || echo 1)" \
        "HS-19/$m hooks/lib/$m.mjs 存在（D.2 四件 lib）" \
        "文件存在" \
        "$([ -f "$HOOKDIR/lib/$m.mjs" ] && echo 存在 || echo 缺失)"
done

MISS_MJS=""
for h in $ALL_HOOKS; do
    [ -f "$HOOKDIR/$h.mjs" ] || MISS_MJS="$MISS_MJS $h"
done
chk "$([ -z "$MISS_MJS" ] && echo 0 || echo 1)" \
    "HS-20 22 个 hook 的 .mjs 全部就位（21 注册 + 未注册的 static-check）" \
    "0 个缺失" \
    "缺失：${MISS_MJS:- 无}"

chk "$([ -f "$HOOKDIR/feedback-signals.txt" ] && echo 0 || echo 1)" \
    "HS-21 feedback-signals.txt 原样保留（D.3：sidecar 不动）" \
    "文件存在" \
    "$([ -f "$HOOKDIR/feedback-signals.txt" ] && echo 存在 || echo 缺失)"

# hooks 里不许 import 引擎 lib（D.2 铁律：进程级隔离，引擎 lib/ 被删时 hook 还得起得来）
ENGINE_IMPORT=$(grep -lE "from[[:space:]]+[\"'][^\"']*harness/lib/" "$HOOKDIR"/*.mjs "$HOOKDIR"/lib/*.mjs 2>/dev/null | sed "s#^$HOOKDIR/##" | tr '\n' ' ' || true)
chk "$([ -z "$ENGINE_IMPORT" ] && echo 0 || echo 1)" \
    "HS-22 没有任何 hook / hook lib import .claude/harness/lib/*（进程级隔离铁律）" \
    "0 个文件 import 引擎 lib" \
    "违例：${ENGINE_IMPORT:-无}"

# node --check 每个 .mjs：注册了但语法坏掉 = 每次事件都报 hook error
SYNTAX_BAD=""
for f in "$HOOKDIR"/*.mjs "$HOOKDIR"/lib/*.mjs; do
    [ -f "$f" ] || continue
    node --check "$f" >/dev/null 2>&1 || SYNTAX_BAD="$SYNTAX_BAD $(basename "$f")"
done
MJS_N=$(find "$HOOKDIR" -maxdepth 2 -name '*.mjs' 2>/dev/null | wc -l | tr -d '[:space:]')
chk "$([ -z "$SYNTAX_BAD" ] && [ "${MJS_N:-0}" -gt 0 ] && echo 0 || echo 1)" \
    "HS-23 hooks/*.mjs 与 hooks/lib/*.mjs 全部通过 node --check（且至少有一个，防空转全绿）" \
    "0 个语法错且 .mjs 数 > 0" \
    "扫到 ${MJS_N:-0} 个，语法错：${SYNTAX_BAD:- 无}"

# ---------------------------------------------------------------------------
echo ""
echo "==== test-hooks-settings：PASS=$PASS FAIL=$FAIL ===="
if [ "$FAIL" -gt 0 ]; then
    echo "test-hooks-settings: failed —— Phase D 迁移完成前这是预期状态（红锁）；完成后必须转全绿" >&2
    exit 1
fi
echo "test-hooks-settings: passed（settings 全 exec form、零 .sh/.ps1、hook 与 lib 齐备）"
