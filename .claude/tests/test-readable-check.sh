#!/usr/bin/env bash
# risk: high
# test-readable-check.sh — 人读文档 · 核对器 check 黑盒回归（docs/readable-spec/phase1-db-contract.md H 节，C 节「机器读得回来」）。
# 断言只从契约推导：生成后即一致；手改页面 / 来源变了没重出 / 缺页 / 多页 / 说明过期孤儿手改 / 指向不存在的；每个「该报」配「不该报」的对照。夹具合成表名，mktemp -d + --root。
# 未测：build 落盘前自检（契约没写死注入点名字，READABLE_FAIL_AT=render 是写盘失败而非自检失败，不猜）。
set -eu
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
ENGINE="${1:-$REPO_ROOT/.claude/scripts/readable-docs.mjs}"
echo "===== test-readable-check ====="
if ! command -v node >/dev/null 2>&1; then echo "SKIPPED: 无 node，未执行 != 通过。"; exit 0; fi
[ -f "$ENGINE" ] || { echo "  [FAIL] 缺被测脚本：$ENGINE" >&2; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
eq() {  # eq <标题> <EXPECT> <GOT>
  if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; else FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$1"; fi
  printf '         EXPECT %s\n         GOT    %s\n' "$2" "$3"
}
nd() { env -u CLAUDE_PROJECT_DIR node "$ENGINE" "$@"; }
bd() { RB=0; nd build --root "$1" >/dev/null 2>&1 || RB=$?; }                       # 生成，退出码进 RB
ck() { RC=0; nd check --json --root "$1" >"$TMP/f.json" 2>/dev/null || RC=$?; }     # 核对，JSON 进 f.json，退出码进 RC
jf() { node -e 'try{const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const v=eval(process.argv[2]);console.log(typeof v==="object"?JSON.stringify(v):String(v))}catch(e){console.log("NOJSON")}' "$TMP/f.json" "$1"; }
hp() { [ "$(jf "j.problems.some(p=>p.kind=='$1'&&(p.where+' '+p.detail).includes('$2'))")" = true ] && printf y || printf n; }   # hp <kind> <点名子串>
kinds() { jf "[...new Set(j.problems.map(p=>p.kind))].sort().join(',')"; }
last() { nd check --root "$1" 2>&1 | tail -1; }                                      # 人读输出末行
put() { printf '%s' "$2" | nd note put --root "$1" >/dev/null 2>&1 || true; }
mk() {  # mk <root>：customers、orders（外键、默认值、来源注释）、order_items；map.json 一个组 order
  mkdir -p "$1/docs/readable-src" "$1/sql"; : >"$1/Product-Spec.md"
  printf '{"version":1,"title":"t","spec":"Product-Spec.md","ddl":["sql/s.sql"],"codeRoots":[],"ignore":[]}\n' >"$1/docs/readable-src/config.json"
  printf '{"version":1,"tableGroups":[{"id":"order","title":"订单与明细","tables":["orders","order_items"],"status":"proposed"}],"dynamicTables":[]}\n' >"$1/docs/readable-src/map.json"
  cat >"$1/sql/s.sql" <<'EOF'
CREATE TABLE customers (id int PRIMARY KEY, name text);
CREATE TABLE orders (
  id int PRIMARY KEY,
  customer_id int REFERENCES customers(id),
  status text DEFAULT 'new',
  memo text -- 备注
);
CREATE TABLE order_items (id int PRIMARY KEY, order_id int, qty int);
CREATE INDEX orders_status_idx ON orders (status);
EOF
}
T() { echo "$1/docs/readable/db/$2"; }
NOTE='## table:orders
订单主表，一行一张订单。
'

# 1 对照：生成后什么都不动 → 0 条（所有后面各臂的对照）；假绿的另一面是误报，这条挡误报
A="$TMP/a1"; mk "$A"; bd "$A"; ck "$A"
eq "生成后不动：build 0、check 退出码 0、ok=true、problems 为空数组、summary 是对象；人读末行「不一致 0 条」" \
  "0|0|true|0|object|不一致 0 条" "$RB|$RC|$(jf j.ok)|$(jf j.problems.length)|$(jf 'typeof j.summary')|$(last "$A")"
# 6 没写说明的表不算不一致，摘要报数；写了一张后数字少一
N0=$(nd check --root "$A" 2>&1 | grep -oE '没写说明[^0-9]*[0-9]+' | grep -oE '[0-9]+$' | head -1 || true)
put "$A" "$NOTE"; bd "$A"; ck "$A"; N1=$(nd check --root "$A" 2>&1 | grep -oE '没写说明[^0-9]*[0-9]+' | grep -oE '[0-9]+$' | head -1 || true)
eq "没写说明的表不算不一致：摘要里报了「没写说明」的数（N0>0），写一张并生成后少 1，ok 仍 true、退出码 0" "y|y|0|true" \
  "$([ "${N0:-0}" -gt 0 ] && echo y || echo n)|$([ "${N0:-0}" -gt 0 ] && [ "${N1:-x}" = "$((N0 - 1))" ] && echo y || echo n)|$RC|$(jf j.ok)"

# 2 手改页面上类型 / 可空 / 默认三格之一：退出码 1，stale-page 点到那页，fact-mismatch 点到那一列；别的列不被点
G=""
for c in 'type|<code>text</code>|<code>varchar</code>' 'nullable|是|否' 'default|<code>\&#39;new\&#39;</code>|<code>\&#39;old\&#39;</code>'; do
  IFS='|' read -r k f t <<<"$c"; R="$TMP/b$k"; mk "$R"; bd "$R"
  sed -i "/data-anchor=\"column:orders.status\"/s|data-k=\"$k\">$f|data-k=\"$k\">$t|" "$(T "$R" t-orders.html)"; ck "$R"
  G="$G$RC$(hp stale-page t-orders)$(hp fact-mismatch column:orders.status)$(hp fact-mismatch column:orders.id),"
done
eq "手改一列的类型格 / 可空格 / 默认格：各退出码 1、stale-page 点到 t-orders、fact-mismatch 点到 column:orders.status、没改的 column:orders.id 不被点（只做逐文件比、不独立读页面的实现过不了）" \
  "1yyn,1yyn,1yyn," "$G"

# 3 来源变了没重出 → stale-page；重出后回到 0 条
R="$TMP/c"; mk "$R"; bd "$R"; echo 'ALTER TABLE orders ADD COLUMN extra int;' >>"$R/sql/s.sql"; ck "$R"; S1="$RC$(hp stale-page t-orders)"
bd "$R"; ck "$R"
eq "建表定义里给 orders 加一列不重出：退出码 1 且 stale-page 点到 t-orders；重出后退出码 0、problems 为空" "1y|0|0" "$S1|$RC|$(jf j.problems.length)"

# 4 缺页 / 多页：删一张表页 → missing-page；放一个多余的 t-ghost.html → extra-page（对照：重出后都消失）
R="$TMP/d"; mk "$R"; bd "$R"; rm "$(T "$R" t-customers.html)"; ck "$R"; M1="$RC$(hp missing-page t-customers)"
bd "$R"; printf '<!doctype html><title>x</title>' >"$(T "$R" t-ghost.html)"; ck "$R"; M2="$RC$(hp extra-page t-ghost)$(hp missing-page t-ghost)"
rm "$(T "$R" t-ghost.html)"; ck "$R"
eq "删 t-customers.html：退出码 1 且 missing-page 点到它；多放 t-ghost.html：extra-page 点到它、不被报成 missing-page；清掉后 0 条" "1y|1yn|0" "$M1|$M2|$RC"

# 5 说明：落说明并生成 → 0 条；改列让说明过期、重出 → note-stale；删表重出 → note-orphan；手改页面说明一个字 → note-mismatch
R="$TMP/e"; mk "$R"; put "$R" "$NOTE"; bd "$R"; ck "$R"; E0="$RC"
sed -i "s/memo text -- 备注/memo text, extra int -- 备注/;s/status text DEFAULT 'new'/status varchar DEFAULT 'new'/" "$R/sql/s.sql"; bd "$R"; ck "$R"; E1="$RC$(hp note-stale table:orders)"
sed -i '/^CREATE TABLE orders (/,/^);/d;/orders_status_idx/d' "$R/sql/s.sql"; bd "$R"; ck "$R"; E2="$RC$(hp note-orphan table:orders)$(hp note-stale table:orders)"
R="$TMP/f"; mk "$R"; put "$R" "$NOTE"; bd "$R"; ck "$R"; F0=$RC; sed -i 's/一行一张订单/一行一张订车/' "$(T "$R" t-orders.html)"; ck "$R"
eq "有说明且生成：0 条；改 orders 的列后重出：note-stale 点到 table:orders；删掉 orders 重出：note-orphan 点到它、不再报 stale（孤儿不是过期）；手改页面说明的一个字：note-mismatch 点到 table:orders" \
  "0|1y|1yn|0|1y" "$E0|$E1|$E2|$F0|$RC$(hp note-mismatch table:orders)"

# 7 map.json 一个组点到不存在的表：生成照常，check 有 dangling 且只有这一类（来源与页面都没变）
R="$TMP/g"; mk "$R"; sed -i 's/"order_items"\]/"order_items","ghost_tbl"]/' "$R/docs/readable-src/map.json"; bd "$R"; ck "$R"
eq "组里点到不存在的表 ghost_tbl：build 退出码 0；check 退出码 1，dangling 点到 ghost_tbl，别的类一个都没有" "0|1|y|dangling" "$RB|$RC|$(hp dangling ghost_tbl)|$(kinds)"

# 9 未合并的动态定义、运行时拼的表名：文档已明说读不出，不算不一致（先确认夹具里真有这两样）
R="$TMP/h"; mk "$R"; mkdir -p "$R/app"; sed -i 's/"codeRoots":\[\]/"codeRoots":["app"]/' "$R/docs/readable-src/config.json"
printf 'def f(t):\n    return "SELECT count(*) FROM " + t\n' >"$R/app/x.py"
printf 'DO $$ BEGIN ALTER TABLE orders DROP CONSTRAINT IF EXISTS x; END $$;\n' >>"$R/sql/s.sql"
bd "$R"; nd build --facts-json --root "$R" >"$TMP/f.json" 2>/dev/null || true; FX="$(jf 'j.unfolded.length')|$(jf 'j.dynamic.length')"; ck "$R"
eq "夹具里有 1 处未合并的动态定义与 1 处运行时拼的表名；check 仍退出码 0、ok=true、problems 为空" "1|1|0|true|0" "$FX|$RC|$(jf j.ok)|$(jf j.problems.length)"
echo "===== 汇总：PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" -eq 0 ]
