#!/usr/bin/env bash
# test-githooks.sh — .claude/githooks/ 三个 git hook 的回归测试（只需 node + git）。
# 这一层是 Claude Code 之外的强制层：会话内的 .claude/hooks/ 管不到手敲的 git commit，
#   这三个 hook 管得到。它们判错一次的代价是「密钥被提交」或「每次 commit 都被拦到人卸掉闸」，
#   所以下面每条都卡到具体退出码，不满足于「跑起来没崩」。
#
# 覆盖：
#   ① commit-msg  本仓全部历史 subject 必须全过（对 cc-base 只读）/ 无信息词被拒 /
#                 中文标题不被误拒（按字符数会误拒、按显示宽度才对）/ 过短被拒 /
#                 Merge|fixup! 放行 / 超长只告警 / 空消息交给 git
#   ② pre-commit  只剩 secrets + syntax 两项：干净树放行 / 注入假密钥被拦 / rc 3 降级不阻断但出声 /
#                 rc 2 用法错阻断 / 契约外退出码打 SKIPPED 不阻断 / 脚本缺失打 SKIPPED /
#                 node 不在 PATH 上打 SKIPPED 不阻断
#   ③ pre-push    读 stdin 的 ref 列表判这次推的是文档还是代码：纯文档一行放行 /
#                 代码推送只跑 selftest + secrets 两项 / 任一阻断即 rc 1 / secrets rc 3 降级放行 /
#                 判不出改了什么（一条 ref 都没读到）按代码推送办 / node 缺失打 SKIPPED 放行
#   ④ install-githooks.sh 的 on/off/status 往返
#   ⑤ 三个 hook 的 sh -n / bash -n 语法
#
# 退出码可控靠打桩：临时仓里放假的 scan-*.mjs / harness.mjs（按参数返回指定码），
#   把「rc 3 降级」「rc 2 用法错」「契约外崩了」这三类在任何机器上都变成确定行为——
#   靠「本机恰好没装 pwsh 所以 check-syntax 恒 3」是碰运气，装了 pwsh 的机器上就测不到。
# 全部在 mktemp -d 出来的临时仓里跑，对 cc-base 只读，trap 清理。
set -eu

SRC=$(cd "$(dirname "$0")/.." && pwd)          # <repo>/.claude
REPO_ROOT=$(cd "$SRC/.." && pwd)               # cc-base 仓库根
HOOKS="$SRC/githooks"
AUDIT="$SRC/harness/audit"

for h in pre-commit commit-msg pre-push README.md; do
    [ -f "$HOOKS/$h" ] || { echo "test-githooks: 缺 $HOOKS/$h" >&2; exit 1; }
done
command -v node >/dev/null 2>&1 || { echo "test-githooks: 缺 node，hook 里的检查全跑不起来" >&2; exit 1; }
SH=$(command -v sh)

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  [PASS] $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }

# chk <判定 0=过/1=不过> <标题> <EXPECT> <GOT> —— 过不过都把期望和实际打出来，
# 光一个 [PASS] 没法给第三方复核。
chk() {
    if [ "$1" -eq 0 ]; then pass "$2"; else fail "$2"; fi
    echo "         EXPECT $3"
    echo "         GOT    $4"
}

# ---------------------------------------------------------------------------
# 公共夹具
# ---------------------------------------------------------------------------

# mkrepo <dir> —— 干净的临时 git 仓：一个无害的 README，已 add 进索引。
mkrepo() {
    mkdir -p "$1/.claude/harness/audit" "$1/.claude/tests"
    (cd "$1" && git init -q . \
        && git config user.email t@example.com \
        && git config user.name t \
        && git config commit.gpgsign false)
    printf '# demo\n\nnothing dangerous here.\n' > "$1/README.md"
    (cd "$1" && git add -A)
}

# use_real_audit <dir> —— 把真的三只审计脚本放进临时仓（真行为，不打桩）。
use_real_audit() {
    cp "$AUDIT/lib.mjs" "$AUDIT/scan-secrets.mjs" "$AUDIT/scan-instructions.mjs" "$AUDIT/check-syntax.mjs" \
       "$1/.claude/harness/audit/"
    cp "$AUDIT/instructions-allowlist.json" "$1/.claude/harness/audit/" 2>/dev/null || true
}

# stub_audit <dir> <脚本名> <rc> —— 打桩一只审计脚本，固定返回 rc。
stub_audit() {
    printf 'process.stderr.write("stub %s: forced rc %s\\n");\nprocess.exit(%s);\n' \
        "$2" "$3" "$3" > "$1/.claude/harness/audit/$2"
}

# stub_engine <dir> <catalog-lint rc> <fitness rc> <gate rc> <selftest rc>
#   打桩引擎：按子命令返回指定码，其余子命令返回 0；顺带把收到的 argv 追加进
#   .claude/harness/stub-argv.log——「hook 到底把哪些路径传进去了」只有这样才看得见，
#   光看退出码看不出漏传（引擎的 parseArgs 静默吞未知 flag，传错传漏都不报错）。
stub_engine() {
    cat > "$1/.claude/harness/harness.mjs" <<EOF
import fs from 'node:fs';
const rc = { 'catalog-lint': $2, 'fitness': $3, 'gate': $4, 'selftest': $5 };
const sub = process.argv[2] || '';
try { fs.appendFileSync(new URL('./stub-argv.log', import.meta.url), process.argv.slice(2).join(' ') + '\n'); } catch (e) {}
process.stderr.write('stub harness ' + sub + '\n');
process.exit(Object.prototype.hasOwnProperty.call(rc, sub) ? rc[sub] : 0);
EOF
}

# run_hook <dir> <hook 名> [参数...] —— 在临时仓里跑 hook，回填 RC / OUT。
RC=0
OUT=""
run_hook() {
    local dir="$1" hook="$2"; shift 2
    RC=0
    OUT=$( (cd "$dir" && "$SH" "$HOOKS/$hook" "$@" </dev/null 2>&1) ) || RC=$?
}

# run_hook_env <dir> <VAR=VAL> <hook 名> —— 带一个环境变量跑。
run_hook_env() {
    local dir="$1" kv="$2" hook="$3"; shift 3
    RC=0
    OUT=$( (cd "$dir" && env "$kv" "$SH" "$HOOKS/$hook" "$@" </dev/null 2>&1) ) || RC=$?
}

# 无 node 的 PATH：只软链 hook 真正会用到的外部命令，**故意不链 node**。
# 用「删掉 node」而不是「PATH 置空」——PATH 置空连 git 都没了，测出来的是别的东西。
FAKEBIN="$TMP/bin-no-node"
mkdir -p "$FAKEBIN"
for b in git sed tr wc cat rm sh grep bash printf mktemp; do
    p=$(command -v "$b" 2>/dev/null) || continue
    # command -v 对 shell 函数/内建只回名字不回路径，照单软链会做出自指链接
    # （$FAKEBIN/grep -> grep），跑起来是 "Too many levels of symbolic links"。只收绝对路径。
    case "$p" in /*) ;; *) continue ;; esac
    ln -sf "$p" "$FAKEBIN/$b"
done

run_hook_nonode() {
    local dir="$1" hook="$2"; shift 2
    RC=0
    OUT=$( (cd "$dir" && PATH="$FAKEBIN" "$SH" "$HOOKS/$hook" "$@" </dev/null 2>&1) ) || RC=$?
}

echo "===== test-githooks ====="

# ---------------------------------------------------------------------------
# ① commit-msg
# ---------------------------------------------------------------------------
echo ""
echo "--- ① commit-msg：subject 门槛 ---"

MSGF="$TMP/COMMIT_EDITMSG"
# msg <subject> —— 写进消息文件跑 commit-msg，回填 RC / OUT。
msg() {
    printf '%s\n' "$1" > "$MSGF"
    RC=0
    OUT=$("$SH" "$HOOKS/commit-msg" "$MSGF" </dev/null 2>&1) || RC=$?
}

# ①-1 本仓全部历史 subject 必须全过。这条闸真正的失败模式不是「拦不住 wip」，
#      是「把正常提交也拦了」——那样它活不过第二天。拿 122 条真实历史当回归靶子。
HIST_BAD=0
HIST_N=0
HIST_FIRST=""
while IFS= read -r s; do
    HIST_N=$((HIST_N + 1))
    msg "$s"
    if [ "$RC" -ne 0 ]; then
        HIST_BAD=$((HIST_BAD + 1))
        [ -z "$HIST_FIRST" ] && HIST_FIRST="$s"
    fi
done < <(cd "$REPO_ROOT" && git log --format=%s 2>/dev/null || true)
if [ "$HIST_N" -eq 0 ]; then
    chk 1 "本仓历史 subject 全过" "至少取到 1 条历史 subject" "git log 一条都没取到（这条断言等于没跑）"
else
    chk "$([ "$HIST_BAD" -eq 0 ] && echo 0 || echo 1)" \
        "本仓 $HIST_N 条历史 subject 全过" \
        "全部 rc 0" \
        "被拒 $HIST_BAD 条${HIST_FIRST:+，第一条：$HIST_FIRST}"
fi

# ①-2 无信息词
msg "wip"
chk "$([ "$RC" -eq 1 ] && echo 0 || echo 1)" "「wip」被拒" "rc 1" "rc $RC；$OUT"

msg "chore: update"
chk "$([ "$RC" -eq 1 ] && echo 0 || echo 1)" \
    "「chore: update」被拒（剥掉 type(scope): 前缀后余部是无信息词）" "rc 1" "rc $RC；$OUT"

msg "wip 2"
chk "$([ "$RC" -eq 1 ] && echo 0 || echo 1)" "「wip 2」被拒（带序号照样等于没说）" "rc 1" "rc $RC；$OUT"

# ①-3 中文不被误拒 —— 本仓最容易踩的一脚。
#      "fix: 修好登录崩溃" 按字符个数是 11（< 12 会被误拒），按显示宽度是 17（应通过）。
msg "fix: 修好登录崩溃"
chk "$([ "$RC" -eq 0 ] && echo 0 || echo 1)" \
    "中文标题「fix: 修好登录崩溃」通过（11 字符 / 17 显示列）" \
    "rc 0（按显示宽度判）" \
    "rc $RC；$OUT"

# ①-4 过短的中文照样拒（不是「见中文就放行」）
msg "修复登录"
chk "$([ "$RC" -eq 1 ] && echo 0 || echo 1)" \
    "「修复登录」被拒（8 显示列 < 12）" "rc 1" "rc $RC；$OUT"

# ①-5 git 自己生成的 / autosquash 前缀放行
for s in "Merge branch 'feature/x' into main" "Revert \"feat: 某个改动\"" "fixup! feat(x): 原始提交" "# 这是注释行"; do
    msg "$s"
    chk "$([ "$RC" -eq 0 ] && echo 0 || echo 1)" "放行：$s" "rc 0" "rc $RC；$OUT"
done

# ①-6 超长只告警不拒，且告警确实打出来了（不出声的告警等于没有）
LONG="feat(harness): 补 Claude Code 之外的强制层——git hooks 三件套加 CI 矩阵，把会话内的闸门扩到所有提交路径上去"
msg "$LONG"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '72'; then
    chk 0 "超长中文标题只告警不拒" "rc 0 且 stderr 提到 72" "rc $RC；$OUT"
else
    chk 1 "超长中文标题只告警不拒" "rc 0 且 stderr 提到 72" "rc $RC；$OUT"
fi

# ①-7 空消息不接管，交给 git 自己中止（免得把 --allow-empty-message 弄坏）
: > "$MSGF"
RC=0
OUT=$("$SH" "$HOOKS/commit-msg" "$MSGF" </dev/null 2>&1) || RC=$?
chk "$([ "$RC" -eq 0 ] && echo 0 || echo 1)" "空消息放行（交给 git 自己判）" "rc 0" "rc $RC；$OUT"

# ---------------------------------------------------------------------------
# ② pre-commit
# ---------------------------------------------------------------------------
echo ""
echo "--- ② pre-commit：静态检查 ---"

# ②-1 干净树 + 真扫描器 → 放行
R1="$TMP/r1"; mkrepo "$R1"; use_real_audit "$R1"
(cd "$R1" && git add -A)
run_hook "$R1" pre-commit
chk "$([ "$RC" -eq 0 ] && echo 0 || echo 1)" "干净树放行（真扫描器）" "rc 0" "rc $RC；$(printf '%s' "$OUT" | tail -3)"

# ②-2 注入假密钥 → 阻断
FAKE_TOKEN="ghp_AAAABBBBCCCCDDDDEEEEFFFF0123456789"   # scan-secrets:ignore 假 token，供断言用
printf 'const t = "%s";\n' "$FAKE_TOKEN" > "$R1/leak.js"
(cd "$R1" && git add -A)
run_hook "$R1" pre-commit
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'BLOCK'; then
    chk 0 "staged 假密钥被拦" "rc 1 且输出含 BLOCK" "rc $RC"
else
    chk 1 "staged 假密钥被拦" "rc 1 且输出含 BLOCK" "rc $RC；$OUT"
fi
if printf '%s' "$OUT" | grep -q 'github-token'; then
    pass "阻断输出点名了命中的规则（github-token）"
else
    fail "阻断输出没说命中了什么（拦住却不说原因，等于让人去猜）：$OUT"
fi
rm -f "$R1/leak.js"
(cd "$R1" && git add -A)

# ②-3 rc 3 降级 → 不阻断，但必须出声
R2="$TMP/r2"; mkrepo "$R2"; use_real_audit "$R2"
stub_audit "$R2" check-syntax.mjs 3
(cd "$R2" && git add -A)
run_hook "$R2" pre-commit
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'DEGRADE'; then
    chk 0 "rc 3 降级不阻断但出声" "rc 0 且输出含 DEGRADE" "rc $RC"
else
    chk 1 "rc 3 降级不阻断但出声" "rc 0 且输出含 DEGRADE" "rc $RC；$OUT"
fi
if printf '%s' "$OUT" | grep -q '未执行 != 通过'; then
    pass "降级说明写着「未执行 != 通过」（降级不是通过）"
else
    fail "降级没说清它不等于通过：$OUT"
fi

# ②-4 rc 2 用法错 → 阻断，且说的是 hook 自己写错了参数
R3="$TMP/r3"; mkrepo "$R3"; use_real_audit "$R3"
stub_audit "$R3" scan-secrets.mjs 2
(cd "$R3" && git add -A)
run_hook "$R3" pre-commit
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q '用法错'; then
    chk 0 "rc 2 用法错阻断" "rc 1 且输出说「用法错」" "rc $RC"
else
    chk 1 "rc 2 用法错阻断" "rc 1 且输出说「用法错」" "rc $RC；$OUT"
fi

# ②-5 契约外退出码（工具自己崩了）→ SKIPPED 出声，不阻断
R4="$TMP/r4"; mkrepo "$R4"; use_real_audit "$R4"
stub_audit "$R4" check-syntax.mjs 42
(cd "$R4" && git add -A)
run_hook "$R4" pre-commit
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'SKIPPED'; then
    chk 0 "契约外退出码打 SKIPPED 不阻断" "rc 0 且输出含 SKIPPED" "rc $RC"
else
    chk 1 "契约外退出码打 SKIPPED 不阻断" "rc 0 且输出含 SKIPPED" "rc $RC；$OUT"
fi
if printf '%s' "$OUT" | grep -q 'rc 42'; then
    pass "SKIPPED 说明点名了实际退出码 42"
else
    fail "SKIPPED 没点名实际退出码（「崩了」和「门没过」要采取的行动不一样）：$OUT"
fi

# ②-6 脚本压根不在 → SKIPPED 出声，不阻断
R5="$TMP/r5"; mkrepo "$R5"    # 不放任何审计脚本
(cd "$R5" && git add -A)
run_hook "$R5" pre-commit
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'SKIPPED'; then
    chk 0 "审计脚本缺失打 SKIPPED 不阻断" "rc 0 且输出含 SKIPPED" "rc $RC"
else
    chk 1 "审计脚本缺失打 SKIPPED 不阻断" "rc 0 且输出含 SKIPPED" "rc $RC；$OUT"
fi

# ②-7 node 不在 PATH 上 → SKIPPED 出声，不阻断，且明说这次一条都没跑成
run_hook_nonode "$R1" pre-commit
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'SKIPPED'; then
    chk 0 "缺 node 打 SKIPPED 不阻断" "rc 0 且输出含 SKIPPED" "rc $RC"
else
    chk 1 "缺 node 打 SKIPPED 不阻断" "rc 0 且输出含 SKIPPED" "rc $RC；$OUT"
fi
if printf '%s' "$OUT" | grep -q '没有任何检查跑成'; then
    pass "缺 node 时明说「本次提交没有任何检查跑成」（放行 != 通过）"
else
    fail "缺 node 时放行得静悄悄，读起来像通过了：$OUT"
fi

# ②-8 有 catalog 时才跑大仓那两条（默认关不变）
R6="$TMP/r6"; mkrepo "$R6"; use_real_audit "$R6"
stub_engine "$R6" 0 0 0 0
printf '{}\n' > "$R6/.claude/harness/module-catalog.json"
(cd "$R6" && git add -A)
run_hook "$R6" pre-commit
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'catalog-lint' && printf '%s' "$OUT" | grep -q 'fitness'; then
    chk 0 "有 catalog 时跑 catalog-lint + fitness" "rc 0 且两条都出现在输出里" "rc $RC"
else
    chk 1 "有 catalog 时跑 catalog-lint + fitness" "rc 0 且两条都出现在输出里" "rc $RC；$OUT"
fi
run_hook "$R1" pre-commit    # R1 没有 catalog
if printf '%s' "$OUT" | grep -q 'catalog-lint'; then
    fail "无 catalog 却跑了 catalog-lint（默认关被破坏）：$OUT"
else
    pass "无 catalog 时不碰大仓那两条（默认关不变）"
fi

# ②-8b 重命名过来的文件必须进 fitness --paths。
#   git 默认开重命名检测（diff.renames 默认 true），`--diff-filter=ACM` 会把 R 态整条漏掉，
#   fitness 就从没扫过这个文件——退出码全绿，实际有个文件没人看过。这条锁住那个漏。
R6B="$TMP/r6b"; mkrepo "$R6B"; use_real_audit "$R6B"
stub_engine "$R6B" 0 0 0 0
printf '{}\n' > "$R6B/.claude/harness/module-catalog.json"
printf 'export const a = 1;\n' > "$R6B/old-name.js"
(cd "$R6B" && git add -A && git commit -q -m "chore(demo): 建立基线以便下一步做重命名")
(cd "$R6B" && git mv old-name.js new-name.js && git add -A)
rm -f "$R6B/.claude/harness/stub-argv.log"
run_hook "$R6B" pre-commit
ARGV=$(cat "$R6B/.claude/harness/stub-argv.log" 2>/dev/null || true)
if printf '%s' "$ARGV" | grep -q 'new-name.js'; then
    chk 0 "重命名文件进了 fitness --paths" "argv 里出现 new-name.js" "$(printf '%s' "$ARGV" | tr '\n' '|')"
else
    chk 1 "重命名文件进了 fitness --paths" "argv 里出现 new-name.js" "$(printf '%s' "$ARGV" | tr '\n' '|')"
fi

# ②-8c 文件名含逗号时退回 changed 作用域，不拿切错的清单假装扫过
R6C="$TMP/r6c"; mkrepo "$R6C"; use_real_audit "$R6C"
stub_engine "$R6C" 0 0 0 0
printf '{}\n' > "$R6C/.claude/harness/module-catalog.json"
printf 'export const b = 2;\n' > "$R6C/has,comma.js"
(cd "$R6C" && git add -A)
rm -f "$R6C/.claude/harness/stub-argv.log"
run_hook "$R6C" pre-commit
ARGV=$(cat "$R6C/.claude/harness/stub-argv.log" 2>/dev/null || true)
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '切不开' \
   && ! printf '%s' "$ARGV" | grep -q -- '--paths'; then
    chk 0 "含逗号文件名退回 changed 作用域" "rc 0、输出说「切不开」、argv 不带 --paths" "$(printf '%s' "$ARGV" | tr '\n' '|')"
else
    chk 1 "含逗号文件名退回 changed 作用域" "rc 0、输出说「切不开」、argv 不带 --paths" "rc $RC；argv=$(printf '%s' "$ARGV" | tr '\n' '|')"
fi

# ②-9 catalog-lint rc 1 → 阻断
R7="$TMP/r7"; mkrepo "$R7"; use_real_audit "$R7"
stub_engine "$R7" 1 0 0 0
printf '{}\n' > "$R7/.claude/harness/module-catalog.json"
(cd "$R7" && git add -A)
run_hook "$R7" pre-commit
chk "$([ "$RC" -eq 1 ] && echo 0 || echo 1)" "catalog-lint rc 1 阻断 commit" "rc 1" "rc $RC；$(printf '%s' "$OUT" | tail -4)"

# ---------------------------------------------------------------------------
# ③ pre-push：判文档/代码，代码推送只跑 selftest + secrets
# ---------------------------------------------------------------------------
echo ""
echo "--- ③ pre-push：纯文档放行 / 代码推送两项 ---"

# push_line <dir> <这次要改的文件…> —— 在临时仓里造一次「已提交待推送」的改动，回填 PUSH_STDIN：
# git 喂给 pre-push 的就是这一行 <local_ref> <local_sha> <remote_ref> <remote_sha>。
PUSH_STDIN=""
push_line() {
    local dir="$1"; shift
    (cd "$dir" && git add -A && git commit -q -m "chore(demo): 基线" >/dev/null 2>&1) || true
    local base head f
    base=$(cd "$dir" && git rev-parse HEAD)
    for f in "$@"; do
        mkdir -p "$dir/$(dirname "$f")"
        printf 'x\n' >> "$dir/$f"
    done
    (cd "$dir" && git add -A && git commit -q -m "chore(demo): 待推送的改动")
    head=$(cd "$dir" && git rev-parse HEAD)
    PUSH_STDIN="refs/heads/main $head refs/heads/main $base"
}

# run_push <dir> [PATH 覆盖] —— 把 PUSH_STDIN 喂进 stdin 跑 pre-push，回填 RC / OUT。
run_push() {
    local dir="$1" pathenv="${2:-}"
    RC=0
    if [ -n "$pathenv" ]; then
        OUT=$( (cd "$dir" && printf '%s\n' "$PUSH_STDIN" | PATH="$pathenv" "$SH" "$HOOKS/pre-push" 2>&1) ) || RC=$?
    else
        OUT=$( (cd "$dir" && printf '%s\n' "$PUSH_STDIN" | "$SH" "$HOOKS/pre-push" 2>&1) ) || RC=$?
    fi
}

# ③-1 纯文档推送：一行放行，两项检查一项都不跑（跑了就是白等）
P1="$TMP/p1"; mkrepo "$P1"; use_real_audit "$P1"
stub_engine "$P1" 0 0 0 0
push_line "$P1" progress.md docs/note.md .claude/feedback/lesson.md
run_push "$P1"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '纯文档推送'; then
    chk 0 "纯文档推送放行" "rc 0 且输出说「纯文档推送」" "rc $RC；$OUT"
else
    chk 1 "纯文档推送放行" "rc 0 且输出说「纯文档推送」" "rc $RC；$OUT"
fi
if printf '%s' "$OUT" | grep -q 'selftest'; then
    fail "纯文档推送还是跑了 selftest（放行的意义就在于不跑）：$OUT"
else
    pass "纯文档推送没跑 selftest（省下的就是这一分钟）"
fi

# ③-2 代码推送：selftest + secrets 两项都跑，全绿放行
push_line "$P1" src/app.js
run_push "$P1"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'selftest' && printf '%s' "$OUT" | grep -q 'secrets'; then
    chk 0 "代码推送跑 selftest + secrets 两项" "rc 0 且两项都出现在输出里" "rc $RC；$OUT"
else
    chk 1 "代码推送跑 selftest + secrets 两项" "rc 0 且两项都出现在输出里" "rc $RC；$OUT"
fi
# 只数带标记的检查行，别拿整段输出 grep——横幅里本来就要写「全量回归归 run-all.sh」。
LBLS=$(printf '%s\n' "$OUT" | grep -oE '\[(OK|BLOCK|SKIPPED)\][[:space:]]+[a-z-]+' | awk '{print $2}' | tr '\n' ' ')
if [ "$LBLS" = "selftest secrets " ]; then
    pass "代码推送只有 selftest + secrets 两项（全量回归 / gate / golden 已归 run-all 与 CI）"
else
    fail "代码推送的检查项不是「selftest secrets」而是「$LBLS」：$OUT"
fi

# ③-3 selftest rc 1 → 阻断
P2="$TMP/p2"; mkrepo "$P2"; use_real_audit "$P2"
stub_engine "$P2" 0 0 0 1
push_line "$P2" src/app.js
run_push "$P2"
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'BLOCK'; then
    chk 0 "selftest rc 1 阻断 push" "rc 1 且输出含 BLOCK" "rc $RC；$(printf '%s' "$OUT" | tail -4)"
else
    chk 1 "selftest rc 1 阻断 push" "rc 1 且输出含 BLOCK" "rc $RC；$OUT"
fi
if printf '%s' "$OUT" | grep -q 'run-all.sh'; then
    pass "阻断时给了自查命令（拦住却不说怎么查等于让人去猜）"
else
    fail "阻断时没给自查命令：$OUT"
fi

# ③-4 secrets rc 1 有命中 → 阻断
P3="$TMP/p3"; mkrepo "$P3"; use_real_audit "$P3"
stub_engine "$P3" 0 0 0 0
stub_audit "$P3" scan-secrets.mjs 1
push_line "$P3" src/app.js
run_push "$P3"
chk "$([ "$RC" -eq 1 ] && echo 0 || echo 1)" "secrets rc 1 阻断 push" "rc 1" "rc $RC；$(printf '%s' "$OUT" | tail -4)"

# ③-5 secrets rc 3 降级 → 出声但不阻断（该扫的没扫成，拦住只会让人 --no-verify）
P4="$TMP/p4"; mkrepo "$P4"; use_real_audit "$P4"
stub_engine "$P4" 0 0 0 0
stub_audit "$P4" scan-secrets.mjs 3
push_line "$P4" src/app.js
run_push "$P4"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '未执行 != 通过'; then
    chk 0 "secrets rc 3 降级不阻断但出声" "rc 0 且输出说「未执行 != 通过」" "rc $RC"
else
    chk 1 "secrets rc 3 降级不阻断但出声" "rc 0 且输出说「未执行 != 通过」" "rc $RC；$OUT"
fi

# ③-6 一条 ref 都没读到 → 判不出改了什么，按代码推送办（宁严勿松）
PUSH_STDIN=""
run_push "$P1"
if printf '%s' "$OUT" | grep -q '代码推送'; then
    chk 0 "读不到 ref 时按代码推送办" "输出说「代码推送」" "rc $RC；$OUT"
else
    chk 1 "读不到 ref 时按代码推送办" "输出说「代码推送」" "rc $RC；$OUT"
fi

# ③-7 node 不在 PATH 上 → SKIPPED 不阻断
push_line "$P1" src/app.js
run_push "$P1" "$FAKEBIN"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'SKIPPED'; then
    chk 0 "pre-push 缺 node 打 SKIPPED 不阻断" "rc 0 且输出含 SKIPPED" "rc $RC"
else
    chk 1 "pre-push 缺 node 打 SKIPPED 不阻断" "rc 0 且输出含 SKIPPED" "rc $RC；$OUT"
fi

# ---------------------------------------------------------------------------
# ④ install-githooks.sh 往返
# ---------------------------------------------------------------------------
echo ""
echo "--- ④ install-githooks.sh：on / status / off 往返 ---"

I1="$TMP/i1"
mkrepo "$I1"
mkdir -p "$I1/.claude/scripts" "$I1/.claude/githooks"
cp "$HOOKS/pre-commit" "$HOOKS/commit-msg" "$HOOKS/pre-push" "$I1/.claude/githooks/"
chmod 0644 "$I1/.claude/githooks"/*   # 先去掉执行位，好验 on 会不会补回来
cp "$SRC/scripts/install-githooks.sh" "$I1/.claude/scripts/"

INST="bash $I1/.claude/scripts/install-githooks.sh"
RC=0; OUT=$(cd "$I1" && $INST status 2>&1) || RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'off'; then
    pass "初始 status = off（默认不开）"
else
    fail "初始 status 不是 off（rc $RC）：$OUT"
fi

RC=0; OUT=$(cd "$I1" && $INST on 2>&1) || RC=$?
HP=$(cd "$I1" && git config --get core.hooksPath 2>/dev/null || true)
if [ "$RC" -eq 0 ] && [ "$HP" = ".claude/githooks" ]; then
    chk 0 "on 设置 core.hooksPath" ".claude/githooks" "$HP（rc $RC）"
else
    chk 1 "on 设置 core.hooksPath" ".claude/githooks" "$HP（rc $RC）；$OUT"
fi
if [ -x "$I1/.claude/githooks/pre-commit" ]; then
    pass "on 补上了 hook 的执行位（没执行位 git 不会跑它）"
else
    fail "on 之后 pre-commit 仍无执行位"
fi

RC=0; OUT=$(cd "$I1" && $INST status 2>&1) || RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'on'; then
    pass "on 之后 status = on"
else
    fail "on 之后 status 不是 on（rc $RC）：$OUT"
fi

RC=0; OUT=$(cd "$I1" && $INST off 2>&1) || RC=$?
HP=$(cd "$I1" && git config --get core.hooksPath 2>/dev/null || true)
if [ "$RC" -eq 0 ] && [ -z "$HP" ]; then
    chk 0 "off 清掉 core.hooksPath" "空" "「$HP」（rc $RC）"
else
    chk 1 "off 清掉 core.hooksPath" "空" "「$HP」（rc $RC）；$OUT"
fi

# 别人占着 hooksPath 时不许强行覆盖（覆盖 = 把别人那套 hook 全停掉）
(cd "$I1" && git config core.hooksPath .husky)
RC=0; OUT=$(cd "$I1" && $INST on 2>&1) || RC=$?
HP=$(cd "$I1" && git config --get core.hooksPath 2>/dev/null || true)
if [ "$RC" -ne 0 ] && [ "$HP" = ".husky" ]; then
    chk 0 "hooksPath 被别人占着时 on 拒绝覆盖" "rc != 0 且 .husky 原样保留" "rc $RC，hooksPath=$HP"
else
    chk 1 "hooksPath 被别人占着时 on 拒绝覆盖" "rc != 0 且 .husky 原样保留" "rc $RC，hooksPath=$HP；$OUT"
fi
(cd "$I1" && git config --unset core.hooksPath)

# ---------------------------------------------------------------------------
# ⑤ 语法
# ---------------------------------------------------------------------------
echo ""
echo "--- ⑤ 三个 hook 的语法 ---"
for h in pre-commit commit-msg pre-push; do
    if "$SH" -n "$HOOKS/$h" 2>/dev/null; then
        pass "sh -n $h"
    else
        fail "sh -n $h 不过：$("$SH" -n "$HOOKS/$h" 2>&1 || true)"
    fi
    if command -v bash >/dev/null 2>&1; then
        if bash -n "$HOOKS/$h" 2>/dev/null; then
            pass "bash -n $h"
        else
            fail "bash -n $h 不过：$(bash -n "$HOOKS/$h" 2>&1 || true)"
        fi
    fi
done

echo ""
echo "结果：PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
