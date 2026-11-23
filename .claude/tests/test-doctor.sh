#!/usr/bin/env bash
# risk: low
# test-doctor.sh — doctor.sh 的 FRAMEWORK-MANIFEST 校验：全量逐条比对 + 逐条点名 + 判失败。
# 留两条（2026-09-10 预算表）：① 未篡改时 rc 0（分辨力来源）；② 篡改抽样窗口之外的一条 →
#   点名该文件且 rc 非 0（旧实现只抽前 20 行里的 3 个，窗口外改了不报）。确定性、只点不一致的、
#   多条同时篡改那批退休。
# 沙箱：整棵 .claude/ 拷进 mktemp、**跳过 worktrees/**；补 make-release.sh 桩（doctor 只判 -f，
#   缺了基线就 rc=1）；清单用沙箱里真正的 gen-manifest.sh 重生成——仓里那份天然会陈。本仓只读。
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
chk() {
    if [ "$1" -eq 0 ]; then PASS=$((PASS + 1)); echo "  [PASS] $2"; else FAIL=$((FAIL + 1)); echo "  [FAIL] $2"; fi
    echo "         EXPECT $3"
    echo "         GOT    $4"
}

SB="$TMP/proj"; mkdir -p "$SB"
for entry in "$REPO/.claude"/* "$REPO/.claude"/.[!.]*; do
    [ -e "$entry" ] || continue
    case "$(basename "$entry")" in worktrees) continue ;; esac
    mkdir -p "$SB/.claude"
    cp -r "$entry" "$SB/.claude/" || { echo "test-doctor: 拷贝失败 $entry" >&2; exit 1; }
done
[ -d "$SB/.claude" ] || { echo "test-doctor: 沙箱 .claude 没搭起来" >&2; exit 1; }
printf '#!/usr/bin/env bash\necho stub\n' > "$SB/make-release.sh"
# 被测实现落位必须在重生成清单**之前**——否则清单记的是旧 doctor 的 sha，控制断言会因它而红。
cp "$DOCTOR" "$SB/.claude/scripts/doctor.sh"
chmod +x "$SB/.claude/scripts/doctor.sh"
bash "$SB/.claude/scripts/gen-manifest.sh" >/dev/null 2>&1 \
    || { echo "test-doctor: 沙箱里跑 gen-manifest.sh 失败" >&2; exit 1; }

DATA="$TMP/manifest.data"
grep -v '^#' "$SB/.claude/FRAMEWORK-MANIFEST.txt" > "$DATA"
TOTAL=$(wc -l < "$DATA" | tr -d ' ')
# 旧实现的抽样窗口是 `head -20 | shuf | head -3`。20 写死是故意的：它正是要废掉的东西，
# 改了实现这里也不该跟着改（跟着改就等于放弃这条锁）。篡改目标取在窗口之外。
WINDOW=20
[ "$TOTAL" -gt $((WINDOW + 5)) ] || { echo "test-doctor: 清单只有 $TOTAL 条，测不出窗口外——夹具失效" >&2; exit 1; }
TARGET=$(sed -n "${TOTAL}p" "$DATA" | cut -f1)
[ -n "$TARGET" ] || { echo "test-doctor: 取不到篡改目标" >&2; exit 1; }

DOC_RC=0; DOC_OUT=""
run_doctor() { DOC_RC=0; DOC_OUT=$(bash "$SB/.claude/scripts/doctor.sh" "$SB" 2>&1) || DOC_RC=$?; }
digest() { printf '%s\n' "$1" | grep -E '✗|^!|MANIFEST|manifest|清单' | head -8 | tr '\n' '|'; }
echo "-- ① 控制组：清单与文件一致 --"
run_doctor
BASE_OUT="$DOC_OUT"; BASE_RC=$DOC_RC
[ "$DOC_RC" -eq 0 ] && r=0 || r=1
chk "$r" "① 未篡改时 doctor rc = 0" "rc=0" "rc=${DOC_RC}；相关行：$(digest "$BASE_OUT")"
echo "-- ② 篡改抽样窗口之外的一条（第 $TOTAL 条：${TARGET}）--"
cp "$SB/.claude/$TARGET" "$TMP/target.bak"
printf '\n# tampered by test-doctor\n' >> "$SB/.claude/$TARGET"
run_doctor
case "$DOC_OUT" in *"$TARGET"*) r=0 ;; *) r=1 ;; esac
chk "$r" "② 逐条点名：输出含被改的 ${TARGET}（旧实现抽样漏判，这条红）" \
    "输出含 $TARGET" "相关行：$(digest "$DOC_OUT")"
[ "$DOC_RC" -ne 0 ] && r=0 || r=1
chk "$r" "② 有不一致时 doctor rc 非 0（不是 note 级告警）" \
    "rc != 0（基线已验 rc=0，差异只有清单篡改）" "rc=$DOC_RC"

cp "$TMP/target.bak" "$SB/.claude/$TARGET"  # 还原 ② 的篡改，下面两条要在「基线 rc=0」上比
# 没配置的项目：自检输出里不许出现人读文档的话（契约 I 节第 11 条「没有配置的项目输出与加这一步之前相同」；逐字比对旧版见回执，这里守「不提」）
case "$BASE_OUT" in *人读文档*) r=1 ;; *) r=0 ;; esac
chk "$r" "③ 没有 docs/readable-src/config.json 的项目：自检输出不提「人读文档」" "输出不含「人读文档」" "含=$(printf '%s\n' "$BASE_OUT" | grep -c '人读文档' || true) 行"
# 有配置：页面现行不提示；手改一页后提示且整份自检退出码不变（只提示、不判红）。生成器用沙箱里那份，页面现出来再比。
mkdir -p "$SB/sql"; : >"$SB/Product-Spec.md"; echo 'CREATE TABLE a1 (id int);' >"$SB/sql/s.sql"; mkdir -p "$SB/docs/readable-src"
printf '{"version":1,"title":"t","spec":"Product-Spec.md","ddl":["sql/s.sql"],"codeRoots":[],"ignore":[]}\n' >"$SB/docs/readable-src/config.json"
env -u CLAUDE_PROJECT_DIR node "$SB/.claude/scripts/readable-docs.mjs" build --root "$SB" >/dev/null 2>&1
run_doctor; CFG_RC=$DOC_RC; CFG_OUT="$DOC_OUT"
printf '\n<!-- 手改 -->\n' >>"$SB/docs/readable/db/index.html"
run_doctor; EDIT_RC=$DOC_RC; EDIT_OUT="$DOC_OUT"
ok=1; case "$CFG_OUT" in *人读文档*) : ;; *) case "$EDIT_OUT" in *人读文档*build*|*build*人读文档*) [ "$CFG_RC" = "$BASE_RC" ] && [ "$EDIT_RC" = "$CFG_RC" ] && ok=0 ;; esac ;; esac
chk "$ok" "④ 有配置：页面现行时不提示；手改 docs/readable/db/index.html 之后提示「人读文档……build」，整份自检退出码与不手改时相同（不判红）" \
    "现行：无提示 rc=$BASE_RC；手改：有提示、rc 同 $BASE_RC" "现行 rc=$CFG_RC 提示行=$(printf '%s\n' "$CFG_OUT" | grep -c '人读文档' || true)；手改 rc=$EDIT_RC 提示行=$(printf '%s\n' "$EDIT_OUT" | grep '人读文档' | head -2 | tr '\n' '|')"
rm -rf "$SB/docs" "$SB/sql" "$SB/Product-Spec.md"
echo ""
echo "==== test-doctor：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ]
