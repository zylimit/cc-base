#!/usr/bin/env bash
# test-skills-lint-wording.sh — B3a 红锁：把 skill description 的「措辞」规则从
#   已退役的 bash 措辞门搬进引擎 `harness.mjs skills-lint`。
#
# red-locks-the-bug：本文件写的是**搬完之后应该成立的行为**，不是「现状能复现」。
#   今天引擎只管 180 字预算（rules.mjs 里只有 LONG_DESCRIPTION），
#   所以 W-2 必然 FAIL——那是它的成功状态。搬完它是永久防线：
#   谁把触发式判定放宽、谁让流程总结词的 description 蒙混过关，W-2 立刻红；
#   谁把规则写得过严误伤合规写法，W-1/W-3/W-4 立刻红。
#
# 契约来源（从退役前那个 bash 措辞门的规则原文来，不从引擎实现反推）：
#     ③ 触发式开头：description 含「当…时」或「由…调用」
#     ④ 禁流程总结词作主体：通篇 生成/通过/分阶段/输出/支持…… 而**无**触发条件才追究
#   引擎侧退出码沿用 skills-lint 现行契约：findings>0 → 1；仅 degraded → 3；干净 → 0。
#
# 本文件写死的两处口径假设（B3a 派单没写到字段级，如主 Agent 另有裁定改这里、别改实现）：
#   ① 违规 finding 的 code 取 `DESCRIPTION_NOT_TRIGGER_SHAPED`（派单指定）。
#   ② 「finding 指向该 skill 目录」两种写法都算数：finding 带 `skill` 字段等于目录名，
#      或沿用现有 findings 家族的 `at`（`.claude/skills/<dir>/SKILL.md:<line>`）。
#      不强求新增 `skill` 字段——LONG_DESCRIPTION 等同族 finding 都只有 at，
#      发明一个同族没有的字段是给实现挖坑。
#
# 纪律：一切写操作只落 mktemp 沙箱（真仓根不碰）；对本仓只读（W-5/W-6 只跑不写）。
#   每条断言打印 EXPECT / GOT，判定不看措辞、只看 rc 与 findings 的 code。
#
# 组号：W-1..W-4 沙箱四条措辞样本 / W-5 形状半与措辞半同出 / W-6 引擎在本仓不得误伤
set -eu

# CC_BASE_ROOT 覆盖是给「拿候选实现验修得好」留的口子：把本脚本拷去 /tmp、
# 指向打过补丁的仓库副本跑同一批断言，零改动本仓。
ROOT=${CC_BASE_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
HARNESS="$ROOT/.claude/harness/harness.mjs"

echo "===== test-skills-lint-wording ====="

if ! command -v node >/dev/null 2>&1; then
    echo "SKIPPED: 无 node——引擎是 .mjs，跑不起来；未执行 != 通过。" >&2
    exit 1
fi
if ! command -v git >/dev/null 2>&1; then
    echo "SKIPPED: 无 git——沙箱仓造不出来；未执行 != 通过。" >&2
    exit 1
fi
[ -f "$HARNESS" ] || { echo "  [FAIL] 缺 harness.mjs：$HARNESS" >&2; exit 1; }

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

# ---- 沙箱骨架：拷引擎 + hooks/lib，去掉 state（运行态，沙箱要干净），git init ----
SKEL="$TMP/skel"
mkdir -p "$SKEL/.claude/hooks" "$SKEL/.claude/skills"
cp -R "$ROOT/.claude/harness" "$SKEL/.claude/harness"
rm -rf "$SKEL/.claude/harness/state"
[ -d "$ROOT/.claude/hooks/lib" ] && cp -R "$ROOT/.claude/hooks/lib" "$SKEL/.claude/hooks/lib"
printf 'sandbox\n' > "$SKEL/README.md"
git -C "$SKEL" init -q
git -C "$SKEL" add -A >/dev/null 2>&1 || true
git -C "$SKEL" -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1 || true

# codes_of <stdout 文件> —— 取最后一行可解析 JSON 的 findings[].code，空格分隔
codes_of() {
    node -e '
        const fs = require("fs");
        const lines = fs.readFileSync(process.argv[1], "utf8").trim().split("\n").filter(Boolean);
        let j = null;
        for (let i = lines.length - 1; i >= 0; i--) { try { j = JSON.parse(lines[i]); break; } catch (e) {} }
        if (!j) { console.log("PARSE_ERROR"); process.exit(0); }
        const codes = (j.findings || []).map((f) => String(f.code));
        console.log(codes.length ? codes.join(" ") : "(none)");
    ' "$1"
}

# points_at <stdout 文件> <code> <目录名> —— 该 code 的 finding 是否指向该 skill 目录
# （skill 字段 == 目录名，或 at 含 /<目录名>/SKILL.md）；打印 yes/no + 依据
points_at() {
    node -e '
        const fs = require("fs");
        const lines = fs.readFileSync(process.argv[1], "utf8").trim().split("\n").filter(Boolean);
        let j = null;
        for (let i = lines.length - 1; i >= 0; i--) { try { j = JSON.parse(lines[i]); break; } catch (e) {} }
        if (!j) { console.log("no PARSE_ERROR"); process.exit(0); }
        const code = process.argv[2], dir = process.argv[3];
        const hit = (j.findings || []).filter((f) => String(f.code) === code);
        if (!hit.length) { console.log("no 无该 code 的 finding"); process.exit(0); }
        const ok = hit.some((f) => String(f.skill || "") === dir
            || String(f.at || "").includes("/" + dir + "/SKILL.md"));
        console.log((ok ? "yes " : "no ") + hit.map((f) => "skill=" + (f.skill === undefined ? "-" : f.skill)
            + " at=" + (f.at === undefined ? "-" : f.at)).join(" | "));
    ' "$1" "$2" "$3"
}

# run_case <用例号> <skill 目录名> <description> —— 造沙箱 + 跑 skills-lint
# 结果写 $CASE_RC / $CASE_OUT（stdout 文件）/ $CASE_ERR（stderr 文件）
run_case() {
    local id="$1" dir="$2" desc="$3" box
    box="$TMP/$id"
    rm -rf "$box"
    cp -R "$SKEL" "$box"
    mkdir -p "$box/.claude/skills/$dir"
    {
        printf -- '---\n'
        printf 'name: %s\n' "$dir"
        printf 'description: %s\n' "$desc"
        printf -- '---\n\n'
        printf '# %s\n\n沙箱样本正文。\n' "$dir"
    } > "$box/.claude/skills/$dir/SKILL.md"
    CASE_OUT="$TMP/$id.out"
    CASE_ERR="$TMP/$id.err"
    set +e
    ( cd "$box" && CLAUDE_PROJECT_DIR="$box" node "$box/.claude/harness/harness.mjs" skills-lint ) \
        > "$CASE_OUT" 2> "$CASE_ERR"
    CASE_RC=$?
    set -e
}

# ---------------------------------------------------------------------------
# W-1 触发式（当…时使用）——合规，不该被判
# ---------------------------------------------------------------------------
run_case W1 wording-trigger-ok "当用户说要审查代码时使用。"
codes=$(codes_of "$CASE_OUT")
[ "$CASE_RC" -eq 0 ] && [ "$codes" = "(none)" ] && r=0 || r=1
chk $r "W-1 「当…时使用」是触发式：rc 0 且无措辞类 finding" \
    "rc=0 findings=(none)" \
    "rc=$CASE_RC findings=$codes ; stderr尾: $(tail -n 1 "$CASE_ERR" 2>/dev/null || true)"

# ---------------------------------------------------------------------------
# W-2 流程总结词作主体、无触发条件——必须判 DESCRIPTION_NOT_TRIGGER_SHAPED
# ---------------------------------------------------------------------------
run_case W2 wording-summary-bad "生成完整项目架构文档，分阶段输出并支持多种格式。"
codes=$(codes_of "$CASE_OUT")
case " $codes " in *" DESCRIPTION_NOT_TRIGGER_SHAPED "*) hasCode=0 ;; *) hasCode=1 ;; esac
[ "$CASE_RC" -eq 1 ] && [ $hasCode -eq 0 ] && r=0 || r=1
chk $r "W-2 无触发条件的流程总结 description：rc 1 且有 DESCRIPTION_NOT_TRIGGER_SHAPED" \
    "rc=1 findings 含 DESCRIPTION_NOT_TRIGGER_SHAPED" \
    "rc=$CASE_RC findings=$codes"

where=$(points_at "$CASE_OUT" DESCRIPTION_NOT_TRIGGER_SHAPED wording-summary-bad)
case "$where" in yes*) r=0 ;; *) r=1 ;; esac
chk $r "W-2b 该 finding 指向出问题的 skill 目录（skill 字段或 at 路径）" \
    "skill=wording-summary-bad 或 at 含 /wording-summary-bad/SKILL.md" \
    "$where"

# ---------------------------------------------------------------------------
# W-3 「由…调用」也是触发式——不该被判
# ---------------------------------------------------------------------------
run_case W3 wording-invoked-ok "由 feedback-observer sub-agent 调用。"
codes=$(codes_of "$CASE_OUT")
[ "$CASE_RC" -eq 0 ] && [ "$codes" = "(none)" ] && r=0 || r=1
chk $r "W-3 「由…调用」是触发式：rc 0 且无措辞类 finding" \
    "rc=0 findings=(none)" \
    "rc=$CASE_RC findings=$codes ; stderr尾: $(tail -n 1 "$CASE_ERR" 2>/dev/null || true)"

# ---------------------------------------------------------------------------
# W-4 同 W-2 文案 + 触发前缀——触发条件在就不追流程总结词（对照 W-2 锁语义）
# ---------------------------------------------------------------------------
run_case W4 wording-trigger-prefixed "当需要架构文档时使用。生成完整项目架构文档，分阶段输出并支持多种格式。"
codes=$(codes_of "$CASE_OUT")
[ "$CASE_RC" -eq 0 ] && [ "$codes" = "(none)" ] && r=0 || r=1
chk $r "W-4 加了触发前缀的同一文案：rc 0（流程总结词只在无触发条件时才追究）" \
    "rc=0 findings=(none)" \
    "rc=$CASE_RC findings=$codes"

# ---------------------------------------------------------------------------
# W-5 两半同居：措辞规则搬进引擎后，形状半（≤180 字）与措辞半（触发式）归同一条
#     命令且互不吞并——同时违规就同时出两条 finding，少一条说明有一半被吃了
# ---------------------------------------------------------------------------
LONG_DESC=""
n=0
while [ $n -lt 12 ]; do
    LONG_DESC="$LONG_DESC生成完整项目架构文档，分阶段输出并支持多种格式。"
    n=$((n + 1))
done
run_case W5 wording-long-and-summary "$LONG_DESC"
codes=$(codes_of "$CASE_OUT")
case " $codes " in *" LONG_DESCRIPTION "*) hasLong=0 ;; *) hasLong=1 ;; esac
case " $codes " in *" DESCRIPTION_NOT_TRIGGER_SHAPED "*) hasCode=0 ;; *) hasCode=1 ;; esac
[ "$CASE_RC" -eq 1 ] && [ $hasLong -eq 0 ] && [ $hasCode -eq 0 ] && r=0 || r=1
chk $r "W-5 超长 + 无触发条件：rc 1 且两半的 finding 都在" \
    "rc=1 findings 同时含 LONG_DESCRIPTION 与 DESCRIPTION_NOT_TRIGGER_SHAPED" \
    "rc=$CASE_RC findings=$codes"

# ---------------------------------------------------------------------------
# W-6 引擎在本仓不得误伤：搬进措辞规则后 skills-lint 对本仓仍须 rc 0
# ---------------------------------------------------------------------------
set +e
( cd "$ROOT" && CLAUDE_PROJECT_DIR="$ROOT" node "$HARNESS" skills-lint ) > "$TMP/w6.out" 2> "$TMP/w6.err"
rc6=$?
set -e
codes6=$(codes_of "$TMP/w6.out")
[ "$rc6" -eq 0 ] && [ "$codes6" = "(none)" ] && r=0 || r=1
chk $r "W-6 引擎 skills-lint 在本仓 rc 0（规则搬过去也不得误伤存量 skill）" \
    "rc=0 findings=(none)" \
    "rc=$rc6 findings=$codes6 ; stderr尾: $(tail -n 1 "$TMP/w6.err" 2>/dev/null || true)"

echo "==== test-skills-lint-wording：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ] || exit 1
