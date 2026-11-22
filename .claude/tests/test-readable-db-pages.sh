#!/usr/bin/env bash
# risk: high
# test-readable-db-pages.sh — 人读文档 · 数据库设计页面黑盒回归（docs/readable-spec/phase1-db-contract.md C 节）。
# 断言只从契约推导：每表一页、确定性、原子落盘、离线自成一体、动态定义提示、分组与切页。夹具合成表名，mktemp -d + --root。
set -eu
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
ENGINE="${1:-$REPO_ROOT/.claude/scripts/readable-docs.mjs}"
echo "===== test-readable-db-pages ====="
if ! command -v node >/dev/null 2>&1; then echo "SKIPPED: 无 node，未执行 != 通过。"; exit 0; fi
[ -f "$ENGINE" ] || { echo "  [FAIL] 缺被测脚本：$ENGINE" >&2; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
eq() {  # eq <标题> <EXPECT> <GOT>
  if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; else FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$1"; fi
  printf '         EXPECT %s\n         GOT    %s\n' "$2" "$3"
}
run() { RC=0; env -u CLAUDE_PROJECT_DIR ${2:+"$2"} node "$ENGINE" build --root "$1" >"$TMP/out" 2>"$TMP/err" || RC=$?; }
mk() {  # mk <root>：13 张互不引用的 big_NN、solo_one、orders、order_items（引用 orders），一个 DO 块点到 orders
  mkdir -p "$1/docs/readable-src" "$1/sql"; : >"$1/Product-Spec.md"
  printf '{"version":1,"title":"t","spec":"Product-Spec.md","ddl":["sql/s.sql"],"codeRoots":[],"ignore":[]}\n' >"$1/docs/readable-src/config.json"
  { for i in $(seq -w 1 13); do echo "CREATE TABLE big_$i (id int PRIMARY KEY, note text);"; done
    echo "CREATE TABLE solo_one (id int PRIMARY KEY);"; echo "CREATE TABLE orders (id int PRIMARY KEY);"
    echo "CREATE TABLE order_items (id int PRIMARY KEY, order_id int REFERENCES orders(id));"
    echo 'DO $$ BEGIN ALTER TABLE orders DROP CONSTRAINT IF EXISTS x; END $$;'; } >"$1/sql/s.sql"
}
tree() { (cd "$1" && find . -type f | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -c1-16); }
A="$TMP/p1"; mk "$A"; run "$A"; D="$A/docs/readable/db"
eq "夹具能 build（退出码 0）" "0" "$RC"
# 1 打死：漏表 / 多出表页 / 缺首页
EXP=$({ printf 'big_%s\n' $(seq -w 1 13); printf '%s\n' solo_one orders order_items; } | LC_ALL=C sort | tr '\n' ,)
GOT=$(ls "$D" 2>/dev/null | sed -n 's/^t-\(.*\)\.html$/\1/p' | LC_ALL=C sort | tr '\n' ,)
IDX=$(for f in index.html db/index.html; do [ -f "$A/docs/readable/$f" ] && printf y || printf n; done)
eq "每张表恰有一页 db/t-<表>.html、无多出来的表页，index.html 与 db/index.html 都在" "$EXP|yy" "$GOT|$IDX"
# 2 打死：页面写时间 / 机器名 / 绝对路径（不同目录名、不同时刻生成两遍）
B="$TMP/p2"; mk "$B"; sleep 1; run "$B"
DR=0; diff -r "$A/docs/readable" "$B/docs/readable" >"$TMP/diff" 2>&1 || DR=$?
eq "同一夹具放进两个不同目录各生成一遍，docs/readable 逐字节无差异" "0" "$DR$([ "$DR" = 0 ] || head -c 200 "$TMP/diff")"
# 4 打死：引外部资源 / 页面写夹具绝对路径（内联 SVG 的 xmlns 命名空间串不是联网，先剔掉）
EXT=$(find "$A/docs/readable" -type f -exec sed 's#xmlns="http://www.w3.org/2000/svg"##g' {} + | grep -ciE 'https?://|<link |<script src' || true)
ABS=$(grep -rlF "$TMP" "$A/docs/readable" | wc -l | tr -d ' ')
eq "产物里没有 http(s):// / <link / <script src，也没有夹具根目录的绝对路径" "0|0" "$EXT|$ABS"
# 5 打死：提示没挂、挂错表、或每页都挂
H=$(for t in orders order_items big_01 solo_one; do grep -q '这张表有' "$D/t-$t.html" 2>/dev/null && printf y || printf n; done)
eq "被未合并 DO 块点到的 orders 页有「这张表有」提示；order_items / big_01 / solo_one 没有" "ynnn" "$H"
# 6 打死：不切页 / 切出超过 12 张 / 切得不均 / 单表前缀不并进其它
cnt() { grep -oE 't-big_[0-9]+\.html' "$1" 2>/dev/null | sort -u | wc -l | tr -d ' '; }
a=$(cnt "$D/g-big-1.html"); b=$(cnt "$D/g-big-2.html"); u=$(cat "$D/g-big-1.html" "$D/g-big-2.html" 2>/dev/null | grep -oE 't-big_[0-9]+\.html' | sort -u | wc -l | tr -d ' ')
O=$([ -f "$D/g-_other.html" ] && grep -q 't-solo_one.html' "$D/g-_other.html" && ! ls "$D"/g-solo* >/dev/null 2>&1 && printf y || printf n)
eq "13 张表的前缀切成 g-big-1 / -2 两页：每页 ≤12、均分（差不超过 1）、合起来 13；单表前缀 solo 进 g-_other.html" "ok|y" "$([ "$a" -le 12 ] && [ "$b" -le 12 ] && [ "$u" = 13 ] && [ $((a + b)) = 13 ] && printf ok || printf "a=$a,b=$b,u=$u")|$O"
# 3 打死：边写边覆盖 / 失败留临时目录（先改来源让重出一遍会变，再注入失败；对照组不注入则整目录哈希确实变）
H0=$(tree "$A/docs/readable"); L0=$(ls -A "$A/docs"); echo 'CREATE TABLE zeta_new (id int);' >>"$A/sql/s.sql"
run "$A" READABLE_FAIL_AT=render; R3=$RC; H1=$(tree "$A/docs/readable"); L1=$(ls -A "$A/docs")
run "$A"; H2=$(tree "$A/docs/readable")
eq "READABLE_FAIL_AT=render：退出码 3、docs/readable 总哈希不变、docs 下无多出来的临时目录；对照组不注入则哈希会变" "3|same|same|differs" "$R3|$([ "$H0" = "$H1" ] && echo same || echo changed)|$([ "$L0" = "$L1" ] && echo same || echo "$L1")|$([ "$H1" != "$H2" ] && echo differs || echo same)"
echo "===== 汇总：PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" -eq 0 ]
