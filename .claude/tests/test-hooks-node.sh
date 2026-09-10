#!/usr/bin/env bash
# risk: low
# test-hooks-node.sh — 提醒类 hook 的存活回归：每个 .claude/hooks/<name>.mjs 各一条
#   「触发 → 期望输出 / 退出码」，喂 stdin 夹具，断言 stdout / stderr / 退出码 / 状态文件。
#
# 分级取舍（2026-09-10 测试预算表）：地板闸（secret-exfil-guard / dangerous-pkill-guard）
#   的用例全份搬去 test-hooks-floor.sh，一条不减；留在这里的都是提醒类——判错的代价是
#   少一句提醒，不是密钥外传，所以每个 hook 只保一条主路径，损坏输入 / 三档矩阵 /
#   lib 契约那些穷举不再养。tdd-gate 与 three-file-sync-gate 三档都是 advise，
#   围绕「拦停」写的那批断言随之作废，改判「出提醒且没拦」。
#
# 契约来源：docs/v3-phase-d-inventory.md A 段契约卡（stdin 字段 / 状态文件 / 输出形态 / 退出码）。
#
# 跨平台：只用 bash + node + git + coreutils。可变样例一律落 mktemp 沙箱，trap 清理；对本仓只读。
#   每条断言打印 EXPECT / GOT，判定不依赖措辞；组号沿用契约卡（EX / LB / AP / …）。
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HOOKS="$ROOT/.claude/hooks"
LIBDIR="$HOOKS/lib"
PROFILE="$ROOT/.claude/harness/profile.json"

echo "===== test-hooks-node ====="

if ! command -v node >/dev/null 2>&1; then
    echo "SKIPPED: 无 node——hook 全是 .mjs，跑不起来；未执行 != 通过。" >&2
    exit 1
fi
if ! command -v git >/dev/null 2>&1; then
    echo "SKIPPED: 无 git——沙箱仓造不出来；未执行 != 通过。" >&2
    exit 1
fi

TMP=$(mktemp -d)
trap 'chmod -R u+rwX "$TMP" 2>/dev/null || true; rm -rf "$TMP"' EXIT

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

RC=0
OUT=""
ERRT=""

# run_script <脚本> <工作目录> <stdin 文本> [argv…] —— 回填 RC / OUT(stdout) / ERRT(stderr)。
# stdout 与 stderr 分开收：「纯 stderr」与「stdout JSON」是两种形态，混在一起就分不清。
run_script() {
    local script="$1" d="$2" input="$3"
    shift 3
    RC=0
    printf '%s' "$input" | ( cd "$d" && CLAUDE_PROJECT_DIR="$d" node "$script" "$@" ) \
        >"$TMP/.o" 2>"$TMP/.e" || RC=$?
    OUT=$(cat "$TMP/.o" 2>/dev/null || true)
    ERRT=$(cat "$TMP/.e" 2>/dev/null || true)
}

run_hook() { local n="$1"; shift; run_script "$HOOKS/$n.mjs" "$@"; }

# newsb <名> [git] [progress] —— 造沙箱项目，回显路径。
#   档位表随沙箱一起装：profile.json 在不在 = 档位启不启用；必须赶在 git 提交之前，
#   未跟踪的 .claude/harness/** 命中 raise.paths 会把沙箱悄悄抬成 strict。
newsb() {
    local d="$TMP/$1"
    shift
    mkdir -p "$d/.claude/harness" "$d/src"
    cp "$PROFILE" "$d/.claude/harness/profile.json" 2>/dev/null || true
    local a
    for a in "$@"; do
        case "$a" in
            progress) printf '# progress\n' > "$d/progress.md" ;;
            git)
                ( cd "$d" && git init -q . \
                    && git config core.autocrlf false \
                    && git config user.email t@example.com && git config user.name t \
                    && printf 'echo hi\n' > src/app.sh && git add -A && git commit -qm init ) >/dev/null 2>&1
                ;;
        esac
    done
    printf '%s' "$d"
}

# newrepo_remote <名> —— 带 bare 远端的沙箱仓（auto-push 要真推一次才算数）。
newrepo_remote() {
    local d="$TMP/$1" r="$TMP/$1-remote.git"
    mkdir -p "$d/.claude"
    git init -q --bare "$r" >/dev/null 2>&1
    ( cd "$d" && git init -q . && git config core.autocrlf false \
        && git config user.email t@example.com && git config user.name t \
        && printf 'x\n' > a.txt && git add -A && git commit -qm init \
        && git remote add origin "$r" && git push -q -u origin HEAD ) >/dev/null 2>&1
    printf '%s' "$d"
}
ahead_by_one() { ( cd "$1" && printf 'y\n' >> a.txt && git commit -aqm second ) >/dev/null 2>&1; }
synced() {
    local d="$1" br lh rh
    br=$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null || echo x)
    lh=$(git -C "$d" rev-parse HEAD 2>/dev/null || echo L)
    rh=$(git -C "$TMP/$(basename "$d")-remote.git" rev-parse "refs/heads/$br" 2>/dev/null || echo R)
    [ "$lh" = "$rh" ]
}

# 判定小工具
blocked()  { printf '%s' "$1" | grep -q '"decision":"block"'; }
hasq()     { printf '%s' "$2" | grep -qF "$1"; }
mentions() { printf '%s' "$2" | grep -qE "(^|[^0-9])$1([^0-9]|\$)"; }
silent()   { [ -z "$OUT" ] && [ -z "$ERRT" ]; }
show()     { printf '%s' "${1:-空}" | tr '\n' '~' | cut -c1-260; }

# advise 档：Stop 类闸改出 systemMessage 提醒，不再出 decision:block。判「有提醒且没拦」，
# 别只判「不是 block」——什么都不输出也不是 block，那是闸没跑。
advised() {
    case "$1" in *'"systemMessage"'*) ;; *) return 1 ;; esac
    case "$1" in *'"decision":"block"'*|*'"decision": "block"'*) return 1 ;; esac
    return 0
}

# jq_ <json 文本> <js 表达式（用变量 d）> —— 用 node 取字段（故意不依赖 jq）。
jq_() {
    printf '%s' "$1" | node -e '
let s = "";
process.stdin.on("data", (c) => { s += c; });
process.stdin.on("end", () => {
  try { const d = JSON.parse(s); process.stdout.write(String(eval(process.argv[1]))); }
  catch (e) { process.stdout.write("<not-json>"); }
});
' "$2"
}

# ---------------------------------------------------------------------------
echo ""
echo "--- EX / LB 存在性（这两条红 = 装漏了；下面所有红的根因都是它）---"

MISS=""
for h in auto-push check-evolution dangerous-pkill-guard detect-feedback-signal \
         harness-async-verify kill-dev-ports mark-review-needed no-direct-code-guard notify \
         postcompact-reinject pre-commit-check precompact-gate recap-on-dirty record-authorship \
         release-gate secret-exfil-guard session-rules-banner static-check stop-gate \
         subagent-acceptance-reminder tdd-gate three-file-sync-gate; do
    [ -f "$HOOKS/$h.mjs" ] || MISS="$MISS $h"
done
chk "$([ -z "$MISS" ] && echo 0 || echo 1)" \
    "EX-1 22 个 hook 的 .mjs 全部就位" "0 个缺失" "缺失：${MISS:- 无}"

LBMISS=""
for m in io gatelog tier harness; do
    [ -f "$LIBDIR/$m.mjs" ] || LBMISS="$LBMISS $m"
done
chk "$([ -z "$LBMISS" ] && echo 0 || echo 1)" \
    "LB-1 hooks/lib 四件齐（缺一件就是每次事件报 hook error）" "0 个缺失" "缺失：${LBMISS:- 无}"

# ---------------------------------------------------------------------------
echo ""
echo "--- 各 hook 一条主路径 ---"

SB=$(newrepo_remote ap-commit); ahead_by_one "$SB"
run_hook auto-push "$SB" '{"tool_input":{"command":"git commit -m t"}}'
chk "$([ "$RC" -eq 0 ] && synced "$SB" && echo 0 || echo 1)" \
    "AP git commit 且本地领先上游 → 真的 push 上去（远端 ref 追平本地 HEAD）" \
    "rc=0 且远端 = 本地 HEAD" \
    "rc=$RC 已同步=$(synced "$SB" && echo Y || echo N) err=[$(show "$ERRT")]"

SB=$(newsb ce-two)
mkdir -p "$SB/.claude/feedback"
cat > "$SB/.claude/feedback/FEEDBACK-INDEX.md" <<'IDX'
# Feedback Index

- [甲](a.md) — 描述
- [乙](b.md) — 描述
- ✅[已毕业] [丙](c.md) — 描述
IDX
run_hook check-evolution "$SB" ''
chk "$([ "$RC" -eq 0 ] && mentions 2 "$OUT" && mentions 3 "$OUT" && echo 0 || echo 1)" \
    "CE 2 条待处理 + 1 条已毕业 → stdout 报「2 条待处理（共 3 条）」" \
    "stdout 同时出现 2 与 3" "rc=$RC out=[$(show "$OUT")]"

SB=$(newsb df-hit)
run_hook detect-feedback-signal "$SB" '{"prompt":"你搞错了，不是这样"}'
chk "$([ "$RC" -eq 0 ] && [ "$(jq_ "$OUT" 'typeof d.additionalContext')" = "string" ] && echo 0 || echo 1)" \
    "DF 命中修正信号 → 顶层 {\"additionalContext\":…}（不是 hookSpecificOutput）" \
    "顶层 additionalContext 是字符串" "rc=$RC out=[$(show "$OUT")]"

SB=$(newsb av-off)
run_hook harness-async-verify "$SB" '{"tool_input":{"file_path":"src/a.ts"}}'
chk "$([ "$RC" -eq 0 ] && silent && echo 0 || echo 1)" \
    "AV 无 catalog（大仓治理默认关）→ rc 0、零输出、零行为变化" \
    "rc=0 无输出" "rc=$RC out=[$(show "$OUT")] err=[$(show "$ERRT")]"

SB=$(newsb kd-plain)
run_hook kill-dev-ports "$SB" '{"tool_input":{"command":"ls"}}'
chk "$([ "$RC" -eq 0 ] && silent && echo 0 || echo 1)" \
    "KD 非 dev server 命令 → rc 0 零输出（脚本内自判，不进清端口分支）" \
    "rc=0 无输出" "rc=$RC out=[$(show "$OUT")] err=[$(show "$ERRT")]"

SB=$(newsb mr-src)
run_hook mark-review-needed "$SB" '{"tool_input":{"file_path":"src/app.ts"}}'
chk "$([ "$RC" -eq 0 ] && grep -qxF 'src/app.ts' "$SB/.claude/.needs-review" 2>/dev/null && echo 0 || echo 1)" \
    "MR 编辑业务源码 → rc 0 且 .needs-review 登记 src/app.ts" \
    "清单含 src/app.ts" "rc=$RC 清单=[$(cat "$SB/.claude/.needs-review" 2>/dev/null | tr '\n' ',')] err=[$(show "$ERRT")]"

SB=$(newsb nd-src)
run_hook no-direct-code-guard "$SB" '{"tool_input":{"file_path":"src/app.ts"}}'
chk "$([ "$RC" -eq 2 ] && [ -n "$ERRT" ] && [ -z "$OUT" ] && echo 0 || echo 1)" \
    "ND 主 Agent 直接写 src/ 业务源码 → exit 2 拦截，警告走 stderr" \
    "rc=2 且 stderr 非空、stdout 空" "rc=$RC out=[$(show "$OUT")] err=[$(show "$ERRT")]"

SB=$(newsb nt-basic)
run_hook notify "$SB" '{"message":"NOTIFY-PROBE done"}'
chk "$([ "$RC" -eq 0 ] && [ "$(jq_ "$OUT" 'typeof d.terminalSequence')" = "string" ] \
      && hasq 'NOTIFY-PROBE' "$OUT" && echo 0 || echo 1)" \
    "NT 正常消息 → rc 0 且 stdout 是含 terminalSequence 的合法 JSON，消息正文进转义序列" \
    "terminalSequence 是字符串且含 NOTIFY-PROBE" "rc=$RC out=[$(show "$OUT")]"

SB=$(newsb pr-noharness)
run_hook postcompact-reinject "$SB" '{"compact_trigger":"auto"}'
chk "$([ "$RC" -eq 0 ] && [ "$(jq_ "$OUT" 'typeof d.systemMessage')" = "string" ] \
      && [ "$(jq_ "$OUT" 'd.additionalContext === undefined')" = "true" ] && echo 0 || echo 1)" \
    "PR 引擎文件缺失 → 只给 systemMessage 降级说明、不给 additionalContext（别让人以为不变量已回来）" \
    "systemMessage 是字符串且无 additionalContext" "rc=$RC out=[$(show "$OUT")]"

SB=$(newsb pc-nocommit git)
run_hook pre-commit-check "$SB" '{"tool_input":{"command":"ls -la"}}'
chk "$([ "$RC" -eq 0 ] && silent && echo 0 || echo 1)" \
    "PC 非 git commit 命令 → rc 0 零输出" "rc=0 无输出" "rc=$RC err=[$(show "$ERRT")]"

SB=$(newsb pg-pending)
printf 'src/app.ts\nsrc/lib.ts\n' > "$SB/.claude/.needs-review"
run_hook precompact-gate "$SB" '{"trigger":"auto"}'
chk "$([ "$RC" -eq 0 ] && blocked "$OUT" && echo 0 || echo 1)" \
    "PG 待审清单未清 → decision:block 拦一次压缩，rc 仍 0" \
    'rc=0 且 stdout 含 "decision":"block"' "rc=$RC out=[$(show "$OUT")]"

SB=$(newsb rd-dirty git)
printf 'x\n' > "$SB/uncommitted.ts"
run_hook recap-on-dirty "$SB" '{"source":"startup"}'
chk "$([ "$RC" -eq 0 ] && [ "$(jq_ "$OUT" 'String((d.hookSpecificOutput||{}).hookEventName)')" = "SessionStart" ] \
      && [ "$(jq_ "$OUT" 'typeof (d.hookSpecificOutput||{}).additionalContext')" = "string" ] && echo 0 || echo 1)" \
    "RD 工作树脏 → hookSpecificOutput.hookEventName = SessionStart 且 additionalContext 是字符串" \
    "hookEventName=SessionStart 且提醒正文非空" "rc=$RC out=[$(show "$OUT")]"

SB=$(newsb ra-off)
run_hook record-authorship "$SB" '{"tool_input":{"file_path":"src/a.ts"},"agent_type":"implementer"}'
chk "$([ "$RC" -eq 0 ] && silent && [ ! -e "$SB/.claude/harness/state" ] && echo 0 || echo 1)" \
    "RA 无 catalog（大仓治理默认关）→ rc 0、零输出、不调引擎" \
    "rc=0、无输出、无 harness/state" \
    "rc=$RC out=[$(show "$OUT")] state=$([ -e "$SB/.claude/harness/state" ] && echo 有 || echo 无)"

SB=$(newsb rg-clean)
run_hook release-gate "$SB" '{"command_name":"release-builder"}'
chk "$([ "$RC" -eq 0 ] && [ "$(jq_ "$OUT" 'String((d.hookSpecificOutput||{}).hookEventName)')" = "UserPromptExpansion" ] \
      && hasq additionalContext "$OUT" && ! blocked "$OUT" && echo 0 || echo 1)" \
    "RG 待审清单干净 → 放行并注入卡点提醒（hookEventName=UserPromptExpansion，不许 block）" \
    "hookEventName=UserPromptExpansion 且无 decision:block" "rc=$RC out=[$(show "$OUT")]"

SB=$(newsb sb-normal)
run_hook session-rules-banner "$SB" '{"source":"startup"}'
chk "$([ "$RC" -eq 0 ] && hasq '铁律' "$OUT" && hasq '6.' "$OUT" && echo 0 || echo 1)" \
    "SB 正常启动 → 输出六条核心铁律横幅" "stdout 含「铁律」与第 6 条" "rc=$RC out=[$(show "$OUT")]"

SB=$(newsb sc-good)
mkdir -p "$SB/work"; printf 'export const a = 1;\n' > "$SB/work/ok.mjs"
run_script "$HOOKS/static-check.mjs" "$SB" '' "$SB/work"
chk "$([ "$RC" -eq 0 ] && hasq 'node --check' "$OUT" && echo 0 || echo 1)" \
    "SC 语法正确的 .mjs → rc 0 且报告里点出跑了 node --check（没跑却报绿是假绿）" \
    "rc=0 且 stdout 含 node --check" "rc=$RC out=[$(show "$OUT")]"

SB=$(newsb sg-pending)
printf 'src/app.ts\nsrc/lib.ts\n' > "$SB/.claude/.needs-review"
run_hook stop-gate "$SB" ''
chk "$([ "$RC" -eq 0 ] && blocked "$OUT" && hasq 'src/app.ts' "$OUT" && echo 0 || echo 1)" \
    "SG 待审 2 个文件 → decision:block 且点名待审文件（不点名的拦停没法处理）" \
    'rc=0 且含 "decision":"block" 与 src/app.ts' "rc=$RC out=[$(show "$OUT")]"

SB=$(newsb sa-basic)
run_hook subagent-acceptance-reminder "$SB" '{"agent_type":"implementer","agent_id":"a-1"}'
chk "$([ "$RC" -eq 0 ] && [ "$(jq_ "$OUT" 'String((d.hookSpecificOutput||{}).hookEventName)')" = "SubagentStop" ] \
      && hasq implementer "$(jq_ "$OUT" 'String((d.hookSpecificOutput||{}).additionalContext)')" && echo 0 || echo 1)" \
    "SA implementer 返回 → hookSpecificOutput.hookEventName = SubagentStop 且提醒正文点名角色" \
    "hookEventName=SubagentStop 且 additionalContext 含 implementer" "rc=$RC out=[$(show "$OUT")]"

SB=$(newsb td-en)
run_hook tdd-gate "$SB" '{"tool_input":{"command":"claude agent implementer write code"}}'
chk "$([ "$RC" -eq 0 ] && [ -n "$ERRT" ] && [ -z "$OUT" ] && echo 0 || echo 1)" \
    "TD 派 implementer 且无红锁标记 → 出提醒走 stderr，但恒 exit 0（三档都是 advise，不硬拦）" \
    "rc=0 且 stderr 非空、stdout 空" "rc=$RC out=[$(show "$OUT")] err=[$(show "$ERRT")]"

SB=$(newsb tf-dirty progress git)
printf 'echo more\n' >> "$SB/src/app.sh"
run_hook three-file-sync-gate "$SB" ''
chk "$([ "$RC" -eq 0 ] && advised "$OUT" && echo 0 || echo 1)" \
    "TF 改了代码而 progress.md 未同步 → 出 systemMessage 提醒且不 block（三档都是 advise）" \
    "rc=0 且 stdout 含 systemMessage、不含 decision:block" "rc=$RC out=[$(show "$OUT")]"

# ---------------------------------------------------------------------------
echo ""
echo "==== test-hooks-node：PASS=$PASS FAIL=$FAIL ===="
if [ "$FAIL" -gt 0 ]; then
    echo "test-hooks-node: failed（上面点名了是哪个 hook 的主路径变了）" >&2
    exit 1
fi
echo "test-hooks-node: passed（各 hook 主路径的输出形态与退出码符合契约）"
