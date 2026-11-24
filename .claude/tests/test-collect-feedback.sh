#!/usr/bin/env bash
# risk: medium
# test-collect-feedback.sh — collect-feedback.sh 回归：四态（new / same / updated / conflict）、
# origin 合并去重、索引不重复追加、dry-run 零写、坏路径退 1、坏选项退 2。
# 纪律：脚本按自己所在位置推本仓根，所以沙箱里造一个假 cc-base 根并把脚本拷进去跑，
#   真仓只读；每条断言打印 EXPECT / GOT。
set -u
ROOT=${CC_BASE_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
# 第一个参数可换被测脚本（验红用：指向改动前的版本）；它同目录的 collect-feedback* 一并带进沙箱
SCRIPT=${1:-$ROOT/.claude/scripts/collect-feedback.sh}
[ -f "$SCRIPT" ] && SCRIPT=$(cd "$(dirname "$SCRIPT")" && pwd)/$(basename "$SCRIPT")
echo "===== test-collect-feedback ====="
[ -f "$SCRIPT" ] || { echo "  [FAIL] 缺脚本：$SCRIPT" >&2; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
chk() {
  if [ "$1" -eq 0 ]; then PASS=$((PASS + 1)); echo "  [PASS] $2"; else FAIL=$((FAIL + 1)); echo "  [FAIL] $2"; fi
  echo "         EXPECT $3"
  echo "         GOT    $4"
}
show() { printf '%s' "${1:-空}" | tr '\n' '~' | cut -c1-300; }

# fb <文件> <description> <标题> [正文尾巴] [额外 frontmatter 行]
mk() {
  mkdir -p "$(dirname "$1")"
  printf -- '---\ntype: feedback\ndescription: %s\ngraduated: false\n%s---\n\n# %s\n\n%s\n' "$2" "${5:-}" "$3" "${4:-body}" >"$1"
}
newroot() {
  R="$TMP/$1"; rm -rf "$R"
  mkdir -p "$R/.claude/scripts" "$R/.claude/feedback/templates"
  cp "$SCRIPT" "$R/.claude/scripts/"
  cp "$(dirname "$SCRIPT")"/collect-feedback-* "$R/.claude/scripts/" 2>/dev/null || true
  printf '# Feedback Index\n\n- [旧条](old.md) — 旧\n' >"$R/.claude/feedback/FEEDBACK-INDEX.md"
  printf 'x\n' >"$R/.claude/feedback/templates/t.md"
  C="$R/.claude/scripts/$(basename "$SCRIPT")"; FB="$R/.claude/feedback"
}
snap() { (cd "$1" && find . -type f -exec cksum {} + | sort); }

P="$TMP/projA"; Q="$TMP/projB"
mk "$P/.claude/feedback/a.md" "甲描述" "甲标题"
mk "$P/.claude/feedback/b.md" "乙描述" "乙标题" "b-from-A" "skipped: true
"
mk "$P/.claude/feedback/FEEDBACK-INDEX.md" "idx" "不该被收"
mk "$P/.claude/feedback/templates/tt.md" "tpl" "不该被收"
mk "$Q/.claude/feedback/b.md" "乙描述" "乙标题" "b-from-B"
mk "$Q/.claude/feedback/a.md" "甲描述" "甲标题"

newroot r1
out=$(bash "$C" "$P" 2>&1); rc=$?
chk "$([ $rc -eq 0 ] && echo "$out" | grep -q 'new=2 updated=0 same=0 conflict=0' && echo 0 || echo 1)" "首次拉取：new=2" "rc=0 new=2" "rc=$rc $(show "$(echo "$out" | tail -1)")"
chk "$([ -f "$FB/a.md" ] && [ -f "$FB/b.md" ] && [ ! -f "$FB/tt.md" ] && ! grep -q '不该被收' "$FB/FEEDBACK-INDEX.md" && echo 0 || echo 1)" "排除 FEEDBACK-INDEX.md 与 templates/" "a/b 在，tt 不在，索引无污染" "$(ls "$FB")"
chk "$(grep -q '^origin: projA$' "$FB/a.md" && grep -q '^skipped: true$' "$FB/b.md" && grep -q '^graduated: false$' "$FB/b.md" && echo 0 || echo 1)" "origin 写入且其它字段原样保留" "origin: projA / skipped / graduated 都在" "$(show "$(head -8 "$FB/b.md")")"
chk "$(grep -qF -- '- [甲标题](a.md) — 甲描述' "$FB/FEEDBACK-INDEX.md" && grep -qF '旧条' "$FB/FEEDBACK-INDEX.md" && echo 0 || echo 1)" "索引按现有行格式追加" "含「- [甲标题](a.md) — 甲描述」且旧行在" "$(show "$(tail -3 "$FB/FEEDBACK-INDEX.md")")"

out=$(bash "$C" "$P" 2>&1)
chk "$(echo "$out" | grep -q 'new=0 updated=0 same=2 conflict=0' && [ "$(grep -c '](a.md)' "$FB/FEEDBACK-INDEX.md")" = 1 ] && echo 0 || echo 1)" "重跑：same=2，索引不重复" "same=2 且 a.md 索引一行" "$(show "$(echo "$out" | tail -1)") a.md 行数=$(grep -c '](a.md)' "$FB/FEEDBACK-INDEX.md")"

# conflict：projB 的 b.md 内容不同，本仓 b.md 来自 projA
out=$(bash "$C" "$Q" 2>&1)
chk "$(echo "$out" | grep -q 'new=0 updated=0 same=1 conflict=1' && [ -f "$FB/b.from-projB.md" ] && grep -q 'b-from-A' "$FB/b.md" && echo 0 || echo 1)" "conflict：落 b.from-projB.md，不覆盖 b.md" "same=1 conflict=1，b.md 仍是 A 版" "$(show "$(echo "$out" | tail -1)") $(cd "$FB" && printf '%s ' *)"
chk "$(grep -q '^origin: projB$' "$FB/b.from-projB.md" && grep -qF '](b.from-projB.md)' "$FB/FEEDBACK-INDEX.md" && echo 0 || echo 1)" "conflict 副本带 origin 并入索引" "origin: projB 且索引有副本行" "$(show "$(grep origin "$FB/b.from-projB.md")")"

# updated：projA 改 b.md，本仓 b.md origin 含 projA → 覆盖
printf 'extra\n' >>"$P/.claude/feedback/b.md"
out=$(bash "$C" "$P" 2>&1)
chk "$(echo "$out" | grep -q 'new=0 updated=1 same=1 conflict=0' && grep -q '^extra$' "$FB/b.md" && echo 0 || echo 1)" "updated：origin 含该项目则覆盖" "updated=1，b.md 含 extra" "$(show "$(echo "$out" | tail -1)")"

# origin 合并去重：让本仓 a.md origin 先是 projB,projA,projB 再 updated
sed -i 's/^origin: .*/origin: projB, projA,projB/' "$FB/a.md"
printf 'more\n' >>"$P/.claude/feedback/a.md"
bash "$C" "$P" >/dev/null 2>&1
chk "$(grep -q '^origin: projB,projA$' "$FB/a.md" && [ "$(grep -c '^origin:' "$FB/a.md")" = 1 ] && echo 0 || echo 1)" "origin 合并成逗号列表并去重" "origin: projB,projA 仅一行" "$(show "$(grep origin "$FB/a.md")")"

# updated 保留本仓毕业状态：本仓 b.md 标 graduated: true / skipped: false，下游再改一次后覆盖，两行仍是本仓值
sed -i 's/^graduated: .*/graduated: true  # 2026-10-30 毕业→x.md/; s/^skipped: .*/skipped: false/' "$FB/b.md"
printf 'again\n' >>"$P/.claude/feedback/b.md"
out=$(bash "$C" "$P" 2>&1)
chk "$(echo "$out" | grep -q 'updated=1' && grep -q '^again$' "$FB/b.md" && grep -q '^graduated: true  # 2026-10-30 毕业→x.md$' "$FB/b.md" && grep -q '^skipped: false$' "$FB/b.md" && echo 0 || echo 1)" "updated 保留本仓 graduated / skipped（连毕业去向注释）" "正文取下游（again），graduated: true  # 毕业→x.md / skipped: false 保留" "$(show "$(head -8 "$FB/b.md")")"

# same 合并 origin：projC 的 a 与本仓内容一致但 origin 没有 projC，应并入且统计仍为 same
R3="$TMP/projC"; mkdir -p "$R3/.claude/feedback"; cp "$P/.claude/feedback/a.md" "$R3/.claude/feedback/a.md"
out=$(bash "$C" "$R3" 2>&1)
chk "$(echo "$out" | grep -q 'new=0 updated=0 same=1 conflict=0' && grep -q '^origin: projB,projA,projC$' "$FB/a.md" && echo 0 || echo 1)" "same 时 origin 并入新项目" "same=1 且 origin: projB,projA,projC" "$(show "$(echo "$out" | tail -1)") $(show "$(grep origin "$FB/a.md")")"
bash "$C" "$R3" >/dev/null 2>&1; a1=$(cat "$FB/a.md"); bash "$C" "$R3" >/dev/null 2>&1
chk "$([ "$a1" = "$(cat "$FB/a.md")" ] && echo 0 || echo 1)" "same 且 origin 已含时不改文件" "两次重跑后 a.md 不变" "一致=$([ "$a1" = "$(cat "$FB/a.md")" ] && echo y || echo n)"

# dry-run 零写
newroot r2
before=$(snap "$R")
out=$(bash "$C" --dry-run "$P" "$Q" 2>&1); rc=$?
after=$(snap "$R")
chk "$([ $rc -eq 0 ] && [ "$before" = "$after" ] && echo "$out" | grep -q 'new=2 updated=0 same=0 conflict=2' && echo 0 || echo 1)" "dry-run 零写且计划含跨项目重名" "rc=0 前后快照一致，new=2 conflict=2（此时 A 的 a/b 已被前面步骤改过，B 的重名都不同）" "rc=$rc 一致=$([ "$before" = "$after" ] && echo y || echo n) $(show "$(echo "$out" | tail -1)")"

# CRLF 下游：Windows 侧产出的文件收进来只该有一段 frontmatter、索引描述非空、写回成 LF，第二次跑判 same
W="$TMP/projW"; mkdir -p "$W/.claude/feedback"
printf -- '---\r\ntype: feedback\r\ndescription: 换行描述\r\ngraduated: false\r\n---\r\n\r\n# 换行标题\r\n\r\nbody\r\n' >"$W/.claude/feedback/crlf.md"
newroot r4
out1=$(bash "$C" "$W" 2>&1); out2=$(bash "$C" "$W" 2>&1)
chk "$([ "$(grep -c '^---$' "$FB/crlf.md")" = 2 ] && ! grep -q $'\r' "$FB/crlf.md" && grep -q '^origin: projW$' "$FB/crlf.md" \
  && grep -qF -- '- [换行标题](crlf.md) — 换行描述' "$FB/FEEDBACK-INDEX.md" && echo "$out2" | grep -q 'new=0 updated=0 same=1 conflict=0' && echo 0 || echo 1)" \
  "CRLF 下游：一段 frontmatter、写回 LF、索引描述非空、重跑 same" "--- 两条、无 \\r、origin: projW、索引含描述、第二次 same=1" \
  "---数=$(grep -c '^---$' "$FB/crlf.md") 第一次=$(show "$(echo "$out1" | tail -1)") 第二次=$(show "$(echo "$out2" | tail -1)") 索引=$(show "$(grep crlf "$FB/FEEDBACK-INDEX.md")")"

# 模板行内注释：下游留着 `origin:   # 可选——…`，收进来 origin 只剩项目名，不带注释
T="$TMP/projT"; mk "$T/.claude/feedback/cm.md" "注释描述" "注释标题" "body" "origin:                         # 可选——下游项目名
"
newroot r5
bash "$C" "$T" >/dev/null 2>&1
chk "$(grep -q '^origin: projT$' "$FB/cm.md" && [ "$(grep -c '^origin:' "$FB/cm.md")" = 1 ] && echo 0 || echo 1)" \
  "下游 origin 行带模板注释 → 收进来 origin: projT 干净" "origin: projT 仅一行、无 #" "$(show "$(grep origin "$FB/cm.md")")"

# 项目名带空格：updated 判得出（不落 conflict），conflict 副本文件名里的空格换成 -
S="$TMP/my proj"; mk "$S/.claude/feedback/sp.md" "空格描述" "空格标题" "v1"
newroot r6
bash "$C" "$S" >/dev/null 2>&1
printf 'v2\n' >>"$S/.claude/feedback/sp.md"
out=$(bash "$C" "$S" 2>&1)
chk "$(echo "$out" | grep -q 'new=0 updated=1 same=0 conflict=0' && grep -q '^v2$' "$FB/sp.md" && grep -q '^origin: my proj$' "$FB/sp.md" && echo 0 || echo 1)" \
  "项目名带空格：第二次改动判 updated" "updated=1、sp.md 含 v2、origin: my proj" "$(show "$(echo "$out" | tail -1)") $(show "$(grep origin "$FB/sp.md")")"
S2="$TMP/other proj"; mk "$S2/.claude/feedback/sp.md" "空格描述" "空格标题" "另一版"
out=$(bash "$C" "$S2" 2>&1)
chk "$(echo "$out" | grep -q 'conflict=1' && [ -f "$FB/sp.from-other-proj.md" ] && grep -qF '](sp.from-other-proj.md)' "$FB/FEEDBACK-INDEX.md" && echo 0 || echo 1)" \
  "项目名带空格的 conflict 副本：文件名与索引链接里空格换成 -" "sp.from-other-proj.md 在且索引链接无空格" "$(show "$(echo "$out" | tail -1)") $(cd "$FB" && printf '%s ' *)"

# 本仓已毕业、下游还是 false、正文相同 → same，文件一个字节不改（毕业状态不算内容差异）
G="$TMP/projG"; mk "$G/.claude/feedback/gr.md" "毕业描述" "毕业标题" "same-body"
newroot r7
bash "$C" "$G" >/dev/null 2>&1
sed -i 's/^graduated: .*/graduated: true  # 2026-10-30 毕业→x.md/' "$FB/gr.md"
g1=$(cksum <"$FB/gr.md")
out=$(bash "$C" "$G" 2>&1)
chk "$(echo "$out" | grep -q 'new=0 updated=0 same=1 conflict=0' && [ "$g1" = "$(cksum <"$FB/gr.md")" ] && echo 0 || echo 1)" \
  "本仓 graduated: true（带注释）、下游 false、正文相同 → same 且不改写" "same=1、gr.md 校验和不变" \
  "$(show "$(echo "$out" | tail -1)") 不变=$([ "$g1" = "$(cksum <"$FB/gr.md")" ] && echo y || echo n)"

# ---- 契约 I 节第 13 条：下游的文档状态随回流一起报（I13-1..8）----
# 夹具：mktemp 里造小项目（合成建表 + 代码 + 一份 feedback），用仓库根 setup.sh 装框架，
# 再用装进去的 readable-docs.mjs init / build 起文档；每个场景拷一份，项目目录名统一 shelfy。
# 取数口径只看契约写的一行文案；快照不含 .git（git 自己会刷新索引，不算「写了下游」）。
if command -v node >/dev/null 2>&1 && [ -f "$ROOT/setup.sh" ]; then
  B="$TMP/i13base/shelfy"; mkdir -p "$B/db" "$B/app"
  printf -- '-- 书\nCREATE TABLE books (\n  id serial PRIMARY KEY,\n  title text NOT NULL\n);\n' >"$B/db/schema.sql"
  printf 'def f():\n    return 1\n' >"$B/app/main.py"; printf '# 产品\n' >"$B/Product-Spec.md"
  ( cd "$B" && git init -q . ) >/dev/null 2>&1
  mk "$B/.claude/feedback/fb.md" "合成描述" "合成标题"
  bash "$ROOT/setup.sh" "$B" >/dev/null 2>&1
  # setup 会把 feedback 重置成模板，造完再放一份
  mk "$B/.claude/feedback/fb.md" "合成描述" "合成标题"
  ( cd "$B" && node .claude/scripts/readable-docs.mjs init --root "$B" >/dev/null 2>&1 && node .claude/scripts/readable-docs.mjs build --root "$B" >/dev/null 2>&1 )
  proj() { rm -rf "$TMP/i13/$1"; mkdir -p "$TMP/i13/$1"; cp -a "$B" "$TMP/i13/$1/shelfy"; PJ="$TMP/i13/$1/shelfy"; }
  ago() { date -u -d "$1 days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-"$1"d +%Y-%m-%dT%H:%M:%SZ; }
  doc_line() { printf '%s\n' "$1" | grep -F '人读文档  shelfy：' | head -1; }
  num() { printf '%s' "$1" | sed -n "s/.*$2 \([0-9][0-9]*\) .*/\1/p" | head -1; }
  PRE='  人读文档  shelfy：'
  run13() { newroot r13; out=$(bash "$C" "$@" 2>&1); rc=$?; ln=$(doc_line "$out"); }

  proj p1; rm -f "$PJ/.claude/scripts/readable-docs.mjs"; run13 "$PJ"
  chk "$([ "$ln" = "${PRE}没有生成器（框架太旧）" ] && echo 0 || echo 1)" "I13-1 没有 readable-docs.mjs → 没有生成器（框架太旧）" "${PRE}没有生成器（框架太旧）" "$(show "$ln")"

  proj p2; rm -f "$PJ/docs/readable-src/config.json"; run13 "$PJ"
  chk "$([ "$ln" = "${PRE}未初始化" ] && echo 0 || echo 1)" "I13-2 有生成器无 config.json → 未初始化" "${PRE}未初始化" "$(show "$ln")"

  proj p3; run13 "$PJ"
  pg=$(cd "$PJ" && node .claude/scripts/project-status.mjs --json --root "$PJ" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).readable.pages)))')
  ok=1; printf '%s\n' "$ln" | grep -Eq "^  人读文档  shelfy：${pg} 页，核对不一致 0 条，没写说明的表 [0-9]+ 张、模块 [0-9]+ 个，待更新 0 段、孤儿 0 段，配置漏项 0 处，近 7 天提交前被拦 0 次\$" && ok=0
  last=$(printf '%s\n' "$out" | tail -1); case "$last" in 'collect-feedback: new='*) ;; *) ok=1 ;; esac
  chk "$ok" "I13-3 全好：两空格开头、页数取自项目自己的 status、各项 0、统计行仍是最后一行" "^  人读文档  shelfy：${pg} 页，核对不一致 0 条…配置漏项 0 处，近 7 天提交前被拦 0 次；末行 collect-feedback: new=" "$(show "$ln") | 末行=$(show "$last")"

  proj p4; sed -i 's/title text NOT NULL/title text NOT NULL,\n  author text/' "$PJ/db/schema.sql"; run13 "$PJ"
  a=$(num "$ln" 核对不一致)
  chk "$([ "${ln#'! 人读文档  shelfy：'}" != "$ln" ] && [ -n "$a" ] && [ "$a" -gt 0 ] && echo 0 || echo 1)" "I13-4 建表文件改了没重出 → 行首 ! 且不一致条数非 0" "行首「! 」，核对不一致 A 条 A>0" "A=${a:-空} $(show "$ln")"

  proj p5; mkdir -p "$PJ/db/migrations"; printf -- '-- 另一张\nCREATE TABLE extra_t (\n  id serial PRIMARY KEY\n);\n' >"$PJ/db/migrations/001_extra.sql"; run13 "$PJ"
  f=$(num "$ln" 配置漏项)
  chk "$([ "${ln#'! 人读文档  shelfy：'}" != "$ln" ] && [ -n "$f" ] && [ "$f" -gt 0 ] && echo 0 || echo 1)" "I13-5 多一个没进配置的建表文件 → 行首 ! 且配置漏项非 0" "行首「! 」，配置漏项 F 处 F>0" "F=${f:-空} $(show "$ln")"

  proj p6; mkdir -p "$PJ/.claude/evidence"
  printf '%s\tpre-commit-check\t人读文档过期：近的一次\n%s\tpre-commit-check\t人读文档过期：旧的一次\n%s\tpre-commit-check\t别的原因\n%s\tstop-gate\t人读文档 别的闸\n' "$(ago 3)" "$(ago 10)" "$(ago 2)" "$(ago 1)" >"$PJ/.claude/evidence/gate-block.log"
  run13 "$PJ"
  k1=$(printf '%s' "$ln" | sed -n 's/.*提交前被拦 \([0-9][0-9]*\) 次.*/\1/p')
  rm -f "$PJ/.claude/evidence/gate-block.log"; run13 "$PJ"; k0=$(printf '%s' "$ln" | sed -n 's/.*提交前被拦 \([0-9][0-9]*\) 次.*/\1/p')
  chk "$([ "$k1" = 1 ] && [ "$k0" = 0 ] && echo 0 || echo 1)" "I13-6 近 7 天内/外各一条 + 别的闸一条 → 只数 1；无日志文件 → 0" "有日志 K=1，无日志 K=0" "K有日志=${k1:-空} K无日志=${k0:-空}"

  proj p7; printf 'console.log("@@乱码@@"); process.exit(1);\n' >"$PJ/.claude/scripts/readable-docs.mjs"; run13 "$PJ"
  last=$(printf '%s\n' "$out" | tail -1)
  chk "$([ $rc -eq 0 ] && case "$ln" in "${PRE}取不到（"*"）") true ;; *) false ;; esac && case "$last" in 'collect-feedback: new='*) true ;; *) false ;; esac && echo 0 || echo 1)" "I13-7 取数命令坏了 → 取不到（…），统计行照出，整条命令退 0" "rc=0；${PRE}取不到（…）；末行 collect-feedback: new=" "rc=$rc $(show "$ln") | 末行=$(show "$last")"

  proj p8; s1=$(cd "$PJ" && find . -path ./.git -prune -o -type f -exec cksum {} + | sort)
  run13 --dry-run "$PJ"; s2=$(cd "$PJ" && find . -path ./.git -prune -o -type f -exec cksum {} + | sort)
  ln1=$ln; run13 "$PJ"; s3=$(cd "$PJ" && find . -path ./.git -prune -o -type f -exec cksum {} + | sort)
  chk "$(printf '%s\n' "$ln1" | grep -Eq "^  人读文档  shelfy：[0-9]+ 页，" && [ "$s1" = "$s2" ] && [ "$s1" = "$s3" ] && echo 0 || echo 1)" "I13-8 --dry-run 同样报这一行；dry-run 与正式跑前后下游文件清单+内容哈希不变" "dry-run 有「N 页，」行；s1=s2=s3" "dry-run行=$(show "$ln1") 同=$([ "$s1" = "$s2" ] && [ "$s1" = "$s3" ] && echo y || echo n)"
else
  echo "  [SKIPPED] 契约 I.13 八条：缺 node 或仓库根 setup.sh"
fi

# 坏路径 / 坏选项
bash "$C" "$TMP/nope" >/dev/null 2>&1; rc=$?
chk "$([ $rc -eq 1 ] && echo 0 || echo 1)" "路径不存在退 1" "rc=1" "rc=$rc"
touch "$TMP/afile"; bash "$C" "$TMP/afile" >/dev/null 2>&1; rc=$?
chk "$([ $rc -eq 1 ] && echo 0 || echo 1)" "不是目录退 1" "rc=1" "rc=$rc"
mkdir -p "$TMP/nofb"; bash "$C" "$TMP/nofb" >/dev/null 2>&1; rc=$?
chk "$([ $rc -eq 1 ] && echo 0 || echo 1)" "没有 .claude/feedback/ 退 1" "rc=1" "rc=$rc"
bash "$C" --dryrun "$P" >/dev/null 2>&1; rc=$?
chk "$([ $rc -eq 2 ] && echo 0 || echo 1)" "选项拼错退 2" "rc=2" "rc=$rc"
bash "$C" >/dev/null 2>&1; rc=$?
chk "$([ $rc -eq 2 ] && echo 0 || echo 1)" "不给路径退 2" "rc=2" "rc=$rc"

echo "test-collect-feedback: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
