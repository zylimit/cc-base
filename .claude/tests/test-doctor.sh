#!/usr/bin/env bash
# test-doctor.sh — doctor.sh 的 FRAMEWORK-MANIFEST 校验必须「全量逐条比对 + 逐条点名 + 判失败」。
#
# 锁的行为（批 4 · L4a，断言写「修好后应成立」，不是「缺陷能复现」）：
#   ① 比对面 = 整份清单，不是前 20 行里随机抽 3 个。窗口外的条目改了也必须被抓到。
#   ② 不一致逐条点名：文件名 + 期望 sha 前 8 位 + 实际 sha 前 8 位，一条都不许并成计数。
#   ③ 有不一致 → 该项标 ✗ 且 doctor 退出码非 0（不是 note 级告警）。
#   ④ 结果确定：同一棵树连跑 3 次输出逐字节一致（旧实现的 shuf 让它每次抖）。
#   ⑤ 只点不一致的：未篡改的条目不许出现在报告里。
#
# 为什么选「rc 非 0」而不是「输出含 MANIFEST MISMATCH 关键字」：doctor.sh 本来就有非零约定
#   （bad() 置 fail=1 → 末尾 exit 1），恒 0 的前提不成立，所以按 ✗ + rc 非 0 判。
#   为了让 rc 断言真的有分辨力，沙箱基线先断言 rc=0——否则「rc 非 0」会被别的项的红冒充。
#
# 沙箱怎么搭（决定了这些断言到底有没有分辨力）：
#   · 整棵 .claude/ 拷进 mktemp，**跳过 worktrees/**——主树里那是各 agent 的完整工作树副本，
#     `cp -r` 进去会把整个仓拷 N 遍。本仓只读，一个字节都不写。
#   · 补一个 make-release.sh 桩：doctor 只判 `-f`，缺了它基线就 rc=1，rc 断言当场失去分辨力。
#   · 清单用沙箱里**真正的** gen-manifest.sh 重生成，不沿用仓里那份。仓里那份天然会陈
#     （改 tests/ 或 agent-memory/ 就陈了，没有机器闸守新鲜度），沿用它会让「未篡改时不报」
#     这条控制断言变成随机红，把实现者送去修一个不存在的 bug。
#
# 用法：bash test-doctor.sh [doctor.sh 路径]
#   带参数是给突变/修复验证用的——把候选实现放 /tmp，跑同一份断言看它转不转绿。
#   （注意：doctor.sh 用的是位置参数 `${1:-.}` 定位仓根，不读 CLAUDE_PROJECT_DIR。）
set -u

SRC=$(cd "$(dirname "$0")/.." && pwd)
REPO=$(cd "$SRC/.." && pwd)
DOCTOR=${1:-"$SRC/scripts/doctor.sh"}
GEN="$SRC/scripts/gen-manifest.sh"

echo "===== test-doctor ====="
command -v sha256sum >/dev/null 2>&1 || {
    echo "SKIPPED: 无 sha256sum——doctor 的清单校验与 gen-manifest 都靠它，一条都验不了，未执行 != 通过。"
    exit 0
}
[ -f "$DOCTOR" ] || { echo "test-doctor: 找不到被测 doctor.sh：$DOCTOR" >&2; exit 1; }
[ -f "$GEN" ]    || { echo "test-doctor: 找不到 $GEN" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  [PASS] $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }
# chk <0=过/1=不过> <标题> <EXPECT> <GOT> —— 过不过都把期望与实际打出来，
# 主 Agent 复核只看这两行，不必重跑。
chk() {
    if [ "$1" -eq 0 ]; then pass "$2"; else fail "$2"; fi
    echo "         EXPECT $3"
    echo "         GOT    $4"
}

# ---------------------------------------------------------------------------
# 沙箱
# ---------------------------------------------------------------------------
SB="$TMP/proj"
mkdir -p "$SB"

# worktrees/ 必须跳过：主树里它装着各 agent 的完整工作树，整拷会把仓复制 N 遍。
for entry in "$REPO/.claude"/* "$REPO/.claude"/.[!.]*; do
    [ -e "$entry" ] || continue
    case "$(basename "$entry")" in worktrees) continue ;; esac
    mkdir -p "$SB/.claude"
    cp -r "$entry" "$SB/.claude/" || { echo "test-doctor: 拷贝失败 $entry" >&2; exit 1; }
done
[ -d "$SB/.claude" ] || { echo "test-doctor: 沙箱 .claude 没搭起来" >&2; exit 1; }

# doctor 只判 make-release.sh 在不在，桩文件足够；没有它基线必红，rc 断言就废了。
printf '#!/usr/bin/env bash\necho stub\n' > "$SB/make-release.sh"

# 被测实现落位必须在重生成清单**之前**——否则清单记的是旧 doctor 的 sha，
# 「未篡改时不报」的控制断言会因为 doctor 自己而红。
cp "$DOCTOR" "$SB/.claude/scripts/doctor.sh"
chmod +x "$SB/.claude/scripts/doctor.sh"

bash "$SB/.claude/scripts/gen-manifest.sh" >/dev/null 2>&1 \
    || { echo "test-doctor: 沙箱里跑 gen-manifest.sh 失败" >&2; exit 1; }

MAN="$SB/.claude/FRAMEWORK-MANIFEST.txt"
DATA="$TMP/manifest.data"
grep -v '^#' "$MAN" > "$DATA"
TOTAL=$(wc -l < "$DATA" | tr -d ' ')

# 旧实现的抽样窗口：`head -20 | shuf | head -3`。20 这个数字写死是故意的——
# 它就是本次要废掉的东西，改了实现这里也不该跟着改（跟着改就等于放弃这条锁）。
WINDOW=20

# ---------------------------------------------------------------------------
# ⓪ 脚手架自证（这一段必须全绿；它红了说明夹具没搭起来，不是实现的错）
# ---------------------------------------------------------------------------
echo "-- ⓪ 脚手架自证 --"
if [ "$TOTAL" -gt $((WINDOW + 5)) ]; then
    pass "⓪a 清单条数 $TOTAL > 窗口 $WINDOW + 5（够长，测得出窗口外）"
else
    fail "⓪a 清单只有 $TOTAL 条，不足以区分「全量」与「前 $WINDOW 条抽样」——夹具失效，下面的红不作数"
    echo ""
    echo "==== test-doctor：PASS=$PASS FAIL=$FAIL ===="
    exit 1
fi

IDX1=$(( (WINDOW + TOTAL) / 2 ))
IDX2=$TOTAL
T1=$(sed -n "${IDX1}p" "$DATA" | cut -f1)
T2=$(sed -n "${IDX2}p" "$DATA" | cut -f1)

WINDOW_PATHS=$(head -n "$WINDOW" "$DATA" | cut -f1)
in_window() { printf '%s\n' "$WINDOW_PATHS" | grep -qxF "$1"; }

if [ -n "$T1" ] && [ -n "$T2" ] && [ "$T1" != "$T2" ]; then
    pass "⓪b 取到两个互不相同的篡改目标：#$IDX1=$T1 / #$IDX2=$T2"
else
    fail "⓪b 篡改目标取失败（#$IDX1=[$T1] #$IDX2=[$T2]）"
fi
if in_window "$T1" || in_window "$T2"; then
    fail "⓪c 篡改目标落在旧抽样窗口（前 $WINDOW 条）内，测不出「全量」——夹具失效"
else
    pass "⓪c 两个篡改目标都在旧抽样窗口（前 $WINDOW 条）之外"
fi

actual_sha() { tr -d '\r' < "$SB/.claude/$1" | sha256sum | awk '{print $1}'; }

# 独立于 doctor 的全量比对，只用来自证夹具状态（不是在测 doctor）。
full_compare() {
    local rel sha act n=0
    while IFS=$(printf '\t') read -r rel sha; do
        case "$rel" in ''|\#*) continue ;; esac
        [ -f "$SB/.claude/$rel" ] || continue
        act=$(actual_sha "$rel")
        [ "$act" = "$sha" ] || { printf '%s\n' "$rel"; n=$((n + 1)); }
    done < "$DATA"
}

BASE_MISMATCH=$(full_compare | wc -l | tr -d ' ')
if [ "$BASE_MISMATCH" -eq 0 ]; then
    pass "⓪d 重生成后的清单与沙箱文件全量一致（$TOTAL 条，0 处不符）——基线干净"
else
    fail "⓪d 重生成后仍有 $BASE_MISMATCH 处不符，基线不干净，控制断言不作数：$(full_compare | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# 跑 doctor 的助手
# ---------------------------------------------------------------------------
DOC_RC=0
DOC_OUT=""
run_doctor() {
    DOC_RC=0
    DOC_OUT=$(bash "$SB/.claude/scripts/doctor.sh" "$SB" 2>&1) || DOC_RC=$?
}
# doctor 输出 250 行没法塞进 GOT，只抽与判定相关的行。
digest() {
    printf '%s\n' "$1" | grep -E '✗|^!|MANIFEST|manifest|清单' | head -8 | tr '\n' '|'
}
contains() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

# ---------------------------------------------------------------------------
# ① 控制组：未篡改 → rc 0，不报任何 ✗
#    写死期望 rc=0（不从别处探测），它是「rc 非 0」那条断言的分辨力来源。
# ---------------------------------------------------------------------------
echo "-- ① 控制组：清单与文件一致 --"
run_doctor
BASE_OUT="$DOC_OUT"
if [ "$DOC_RC" -eq 0 ]; then r=0; else r=1; fi
chk "$r" "① 未篡改时 doctor rc = 0" "rc=0" "rc=$DOC_RC；相关行：$(digest "$BASE_OUT")"

if printf '%s\n' "$BASE_OUT" | grep -q '✗'; then r=1; else r=0; fi
chk "$r" "① 未篡改时输出无 ✗" "输出里没有任何 ✗ 行" "✗ 行：[$(printf '%s\n' "$BASE_OUT" | grep '✗' | tr '\n' '|')]"

# 对照用的未篡改条目：挑一个基线输出里本来就不出现的路径，
# 这样「它不该出现在报告里」才是个有分辨力的断言。
CONTROL=""
while IFS= read -r rel; do
    [ "$rel" = "$T1" ] && continue
    [ "$rel" = "$T2" ] && continue
    contains "$rel" "$BASE_OUT" && continue
    CONTROL="$rel"
    break
done < <(cut -f1 "$DATA")
if [ -n "$CONTROL" ]; then
    pass "⓪e 对照条目取到：$CONTROL（基线输出里本就不出现）"
else
    fail "⓪e 找不到一个基线输出里不出现的未篡改条目，④ 那条断言没有分辨力"
fi

# ---------------------------------------------------------------------------
# ② 篡改窗口外的两条 → 全量比对必须抓到、逐条点名、判失败
# ---------------------------------------------------------------------------
echo "-- ② 篡改旧窗口之外的两条清单项 --"
BOGUS1='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
BOGUS2='fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210'
tamper() {
    awk -F'\t' -v OFS='\t' -v r="$1" -v s="$2" '$1==r{$2=s} {print}' "$MAN" > "$MAN.tmp" \
        && mv "$MAN.tmp" "$MAN"
}
tamper "$T1" "$BOGUS1"
tamper "$T2" "$BOGUS2"
grep -v '^#' "$MAN" > "$DATA"

TAMPERED=$(full_compare)
TAMPERED_N=$(printf '%s\n' "$TAMPERED" | sed '/^$/d' | wc -l | tr -d ' ')
if [ "$TAMPERED_N" -eq 2 ] && contains "$T1" "$TAMPERED" && contains "$T2" "$TAMPERED"; then
    pass "⓪f 篡改后独立全量比对恰好 2 处不符且就是这两条——夹具就位"
else
    fail "⓪f 篡改后独立比对得到 $TAMPERED_N 处：[$(printf '%s' "$TAMPERED" | tr '\n' ' ')]，夹具没就位，下面的红不作数"
fi

A1=$(actual_sha "$T1"); A2=$(actual_sha "$T2")
E1P=$(printf '%s' "$BOGUS1" | cut -c1-8); A1P=$(printf '%s' "$A1" | cut -c1-8)
E2P=$(printf '%s' "$BOGUS2" | cut -c1-8); A2P=$(printf '%s' "$A2" | cut -c1-8)

run_doctor
T_OUT="$DOC_OUT"
T_RC="$DOC_RC"

# ②a/②b 逐条点名：文件名 + 期望/实际 sha 前 8 位。两条分开断言，
#        只抓到一条时看得出是「只点了第一条」还是「压根没点」。
for pair in "1|$T1|$E1P|$A1P" "2|$T2|$E2P|$A2P"; do
    n=$(printf '%s' "$pair" | cut -d'|' -f1)
    p=$(printf '%s' "$pair" | cut -d'|' -f2)
    ep=$(printf '%s' "$pair" | cut -d'|' -f3)
    ap=$(printf '%s' "$pair" | cut -d'|' -f4)
    r=1
    if contains "$p" "$T_OUT" && contains "$ep" "$T_OUT" && contains "$ap" "$T_OUT"; then r=0; fi
    chk "$r" "②$n 点名第 $n 条不一致：路径 + 期望/实际 sha 前 8 位" \
        "输出同时含 [$p]、期望前 8 [$ep]、实际前 8 [$ap]" \
        "含路径=$(contains "$p" "$T_OUT" && echo yes || echo no) 含期望=$(contains "$ep" "$T_OUT" && echo yes || echo no) 含实际=$(contains "$ap" "$T_OUT" && echo yes || echo no)；相关行：$(digest "$T_OUT")"
done

# ②c 判失败：✗ 而不是 ! 告警。控制组已断言基线 rc=0，所以这里的非 0 只能来自清单不一致。
if [ "$T_RC" -ne 0 ]; then r=0; else r=1; fi
chk "$r" "②c 有不一致时 doctor rc 非 0" "rc != 0（基线已验 rc=0，差异只有清单篡改）" "rc=$T_RC"

XLINES=$(printf '%s\n' "$T_OUT" | grep '✗' || true)
r=1
if [ -n "$XLINES" ]; then
    case "$XLINES" in
        *MANIFEST*|*manifest*|*清单*|*"$T1"*|*"$T2"*) r=0 ;;
    esac
fi
chk "$r" "②d 清单不一致标 ✗（不是 ! 告警）" \
    "存在 ✗ 行且它讲的是清单/被篡改的文件" "✗ 行：[$(printf '%s' "$XLINES" | tr '\n' '|')]"

# ---------------------------------------------------------------------------
# ③ 结果确定：连跑 3 次逐字节一致，且每次都点名两条
#    旧实现每次 shuf 重新抽样，同一棵树能给出不同结论；这条把「抖」锁死。
# ---------------------------------------------------------------------------
echo "-- ③ 连跑 3 次 --"
R_OUT_1=""; R_OUT_2=""; R_OUT_3=""; R_RC_1=0; R_RC_2=0; R_RC_3=0
run_doctor; R_OUT_1="$DOC_OUT"; R_RC_1="$DOC_RC"
run_doctor; R_OUT_2="$DOC_OUT"; R_RC_2="$DOC_RC"
run_doctor; R_OUT_3="$DOC_OUT"; R_RC_3="$DOC_RC"

H1=$(printf '%s' "$R_OUT_1" | sha256sum | awk '{print $1}' | cut -c1-12)
H2=$(printf '%s' "$R_OUT_2" | sha256sum | awk '{print $1}' | cut -c1-12)
H3=$(printf '%s' "$R_OUT_3" | sha256sum | awk '{print $1}' | cut -c1-12)

r=1
if [ "$R_OUT_1" = "$R_OUT_2" ] && [ "$R_OUT_2" = "$R_OUT_3" ] \
   && [ "$R_RC_1" = "$R_RC_2" ] && [ "$R_RC_2" = "$R_RC_3" ]; then r=0; fi
chk "$r" "③a 连跑 3 次输出与 rc 逐字节一致（防回归位：旧实现在窗口外篡改时三次一致地漏，本条偶然绿）" \
    "三次输出摘要相同、rc 相同" "摘要 $H1 / $H2 / $H3；rc $R_RC_1 / $R_RC_2 / $R_RC_3"

# ③b 单看一致性会被「三次都同样抓不到」骗过去（旧实现在窗口外篡改时正是这样），
#     所以一致性必须和「三次都点名」绑在一起判。
miss=""
i=1
for o in "$R_OUT_1" "$R_OUT_2" "$R_OUT_3"; do
    contains "$T1" "$o" || miss="$miss 第${i}次缺[$T1]"
    contains "$T2" "$o" || miss="$miss 第${i}次缺[$T2]"
    i=$((i + 1))
done
if [ -z "$miss" ]; then r=0; else r=1; fi
chk "$r" "③b 三次运行都点名了这两条（一致地对，不是一致地漏）" \
    "三次输出各自都含 $T1 与 $T2" "缺漏：[${miss:-无}]"

# ---------------------------------------------------------------------------
# ④ 只点不一致的：未篡改条目不许进报告
# ---------------------------------------------------------------------------
echo "-- ④ 未篡改条目不入报告 --"
if [ -n "$CONTROL" ]; then
    if contains "$CONTROL" "$T_OUT"; then r=1; else r=0; fi
    chk "$r" "④ 未篡改的 $CONTROL 不出现在输出里（防回归位：旧实现什么都不点名，本条偶然绿）" \
        "输出不含 [$CONTROL]" "含=$(contains "$CONTROL" "$T_OUT" && echo yes || echo no)"
else
    fail "④ 无对照条目可用（见 ⓪e）"
fi

echo ""
echo "==== test-doctor：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ]
