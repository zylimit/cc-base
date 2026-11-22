#!/usr/bin/env bash
# risk: high
# test-readable-sql-ddl.sh — 人读文档 · 建表定义取事实器黑盒回归（docs/readable-spec/phase1-db-contract.md 的 A、B 两节）。
# 断言只从契约推导。最怕：悄悄漏掉一张表 / 一个列，或把读不出的部分装作读出来了。
# B 节末尾有输出键名清单：布尔字段按键名断言（K 取列对象），其余仍用「JSON 里含不含某段原文」。
# 夹具一律 mktemp -d + --root，手写合成 SQL。
set -eu
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
ENGINE="${1:-$REPO_ROOT/.claude/scripts/readable-docs.mjs}"
echo "===== test-readable-sql-ddl ====="
if ! command -v node >/dev/null 2>&1; then
  echo "SKIPPED: 无 node——取事实器是纯 node 脚本，一条都跑不了，未执行 != 通过。"
  exit 0
fi
[ -f "$ENGINE" ] || { echo "  [FAIL] 缺被测脚本：$ENGINE" >&2; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
chk() {  # chk <0=过/非0=不过> <标题> <EXPECT> <GOT>
  if [ "$1" = "0" ]; then PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$2"
  else FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$2"; fi
  printf '         EXPECT %s\n         GOT    %s\n' "$3" "$4"
}
eq() { local g; g=$(q "$FACTS" "$3" 2>&1 || true); if [ "$g" = "$2" ]; then chk 0 "$1" "$2" "$g"; else chk 1 "$1" "$2" "$g"; fi; }
q() {  # q <facts.json> <js 表达式，d 是整份事实，T(表)/C(表,列)/J(x) 是取用助手>
  node -e '
    const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    const T=n=>d.tables.find(t=>t.name===n), J=x=>JSON.stringify(x);
    const K=(t,c)=>T(t).columns.find(x=>x.name===c), C=(t,c)=>J(K(t,c));
    process.stdout.write(String(eval(process.argv[2])));
  ' "$1" "$2" 2>&1 || printf '<error>'
}
run() { RC=0; env -u CLAUDE_PROJECT_DIR node "$ENGINE" "$@" >"$TMP/out" 2>"$TMP/err" || RC=$?; }
mkcfg() {  # mkcfg <root> <ddl 数组 JSON>
  mkdir -p "$1/docs/readable-src"; : >"$1/Product-Spec.md"
  printf '{"version":1,"title":"t","spec":"Product-Spec.md","ddl":%s,"codeRoots":[],"ignore":[]}\n' "$2" >"$1/docs/readable-src/config.json"
}
R="$TMP/r1"; mkdir -p "$R/sql"; mkcfg "$R" '["sql/a.sql","sql/b.sql"]'
cat >"$R/sql/a.sql" <<'EOF'
/* 块注释里有分号; 不切 */
-- 表甲注释
-- 表甲第二行
CREATE TABLE IF NOT EXISTS alpha (
  id serial PRIMARY KEY,
  name text NOT NULL DEFAULT 'a;b', -- 名称行尾
  -- kind上方;含分号
  kind text CHECK (kind IN ('x','y')),
  owner_id int REFERENCES beta(id) ON DELETE CASCADE,
  code text UNIQUE
);
CREATE TABLE beta (id int PRIMARY KEY, note text);
CREATE TABLE gamma LIKE beta;
CREATE TABLE delta (a int, b int, c int, PRIMARY KEY (a), UNIQUE (a, b), CHECK (a < b), CHECK (c > 0), CONSTRAINT named_ck CHECK (a > 0));
CREATE TABLE epsilon (a int, b int, CHECK (a < b));
DO $$ BEGIN
  ALTER TABLE alpha DROP CONSTRAINT IF EXISTS x;
  ALTER TABLE beta ADD CONSTRAINT c_pos CHECK (id > 0);
END $$;
DO $fn$ BEGIN EXECUTE format('ALTER TABLE %I ADD COLUMN z int', 'alpha'); END $fn$;
DO $$ BEGIN CREATE ROLE r1; END $$;
EOF
cat >"$R/sql/b.sql" <<'EOF'
ALTER TABLE alpha ADD COLUMN IF NOT EXISTS name varchar(5);
-- 新增列说明
ALTER TABLE alpha ADD COLUMN IF NOT EXISTS extra int;
ALTER TABLE alpha ADD COLUMN extra bigint;
-- 不该归属
ALTER TABLE beta ADD COLUMN IF NOT EXISTS note text;
ALTER TABLE ONLY public.alpha DROP CONSTRAINT IF EXISTS alpha_kind_check, ADD COLUMN w int;
ALTER TABLE alpha ADD COLUMN tail int; -- 行尾tail
ALTER TABLE delta DROP CONSTRAINT delta_check;
ALTER TABLE delta DROP CONSTRAINT delta_c_check;
ALTER TABLE epsilon DROP CONSTRAINT epsilon_a_b_check;
DROP INDEX IF EXISTS ix_old;
CREATE INDEX ix_a ON alpha (name);
CREATE UNIQUE INDEX ix_old ON alpha (code);
DROP INDEX ix_old;
COMMENT ON COLUMN alpha.code IS 'code覆盖';
CREATE OR REPLACE VIEW v_a AS SELECT 1;
CREATE OR REPLACE FUNCTION f_a(x int) RETURNS int AS $$ BEGIN RETURN x; END $$ LANGUAGE plpgsql;
CREATE FUNCTION f_o(x int) RETURNS int AS $$ SELECT 1 $$ LANGUAGE sql;
CREATE FUNCTION f_o(x text) RETURNS int AS $$ SELECT 2 $$ LANGUAGE sql;
ALTER TABLE ghost ADD COLUMN q int;
ALTER TABLE alpha DROP CONSTRAINT nosuch;
EOF
run build --facts-json --root "$R"; cp "$TMP/out" "$TMP/f1.json"; FACTS="$TMP/f1.json"; RC1=$RC
chk "$RC1" "夹具能 build --facts-json 出事实（退出码 0）" "rc=0" "rc=$RC1 $(head -c 200 "$TMP/err")"
# 1 打死：按分号硬切（块注释 / 行注释 / 字符串 / $$ 里的分号会把表切碎或多出假表）
eq "切语句：表恰为 alpha,beta,delta,epsilon（gamma 读不懂不算），分号全在引号 / 注释 / \$\$ 里不切断" "alpha,beta,delta,epsilon" 'd.tables.map(t=>t.name).join()'
eq "切语句：字符串默认值里的分号原样保留" "true" 'C("alpha","name").includes("a;b")'
eq "切语句：列行尾分号后的整张表没被截断，alpha 列序是首次出现序，extra 只一次" "id,name,kind,owner_id,code,extra,w,tail" 'T("alpha").columns.map(c=>c.name).join()'
# 2 打死：重复加列 / IF NOT EXISTS 静默覆盖先前定义 / 无 IF NOT EXISTS 重复加却不报冲突
eq "IF NOT EXISTS 重申：name 保留先前的 text，不被 varchar(5) 覆盖" "true" 'C("alpha","name").includes("text")&&!C("alpha","name").includes("varchar")'
eq "无 IF NOT EXISTS 重加 extra：保留 int 不是 bigint，且进定义冲突" "true" 'C("alpha","extra").includes("int")&&!C("alpha","extra").includes("bigint")&&J(d.conflicts).includes("extra")'
eq "冲突清单恰三条：extra 重加、nosuch、epsilon_a_b_check 找不到约束（IF NOT EXISTS 与 IF EXISTS 的不记）" "3" 'd.conflicts.length+(J(d.conflicts).includes("nosuch")&&J(d.conflicts).includes("epsilon_a_b_check")?0:100)'
# 3 打死：DO 块里的 ALTER 被当成已合并；无关的 CREATE ROLE 块也被列出；多条语句的块被拆成多项
eq "unfolded 恰两项：点名 alpha+beta 的块、%I 动态表名的块（CREATE ROLE 块不进）" "2" 'd.unfolded.length+(J(d.unfolded).includes("CREATE ROLE")?100:0)'
eq "unfolded 带文件、起始行、head 前缀、表名" "true" "$(printf 'const u=d.unfolded[0]; u.file.includes("a.sql")&&u.line===%s&&u.head.startsWith("ALTER TABLE alpha")&&u.head.length<=80&&u.tables.includes("alpha")&&u.tables.includes("beta")' "$(grep -n -m1 'DO \$\$' "$R/sql/a.sql" | cut -d: -f1)")"
eq "unfolded：占位表名记成「动态表名」" "true" 'd.unfolded[1].tables.includes("动态表名")'
eq "DO 块里的 ADD CONSTRAINT / ADD COLUMN 没被合并进现行结构" "false" 'J(T("beta")).includes("c_pos")||J(T("alpha").columns).includes("\"z\"")'
# 4 打死：一处读不懂整次失败，或猜一个结构
eq "unparsed 点名 gamma 与文件，且同文件的 alpha / beta 照常取出" "1" 'd.unparsed.length+(J(d.unparsed).includes("gamma")&&J(d.unparsed).includes("a.sql")&&T("beta")?0:100)'
eq "orphanAlters 恰一条，点名 ghost，ghost 没被凭空建出" "1" 'd.orphanAlters.length+(J(d.orphanAlters).includes("ghost")&&!T("ghost")?0:100)'
# 5 打死：注释挂错对象
eq "注释：表上方连续 -- 行归表，不漏到列" "true" 'J(T("alpha")).includes("表甲注释")&&J(T("alpha")).includes("表甲第二行")&&!C("alpha","id").includes("表甲")'
eq "注释：行尾归该列、列上方整行归该列（含分号），互不串" "true" 'C("alpha","name").includes("名称行尾")&&!C("alpha","name").includes("kind上方")&&C("alpha","kind").includes("kind上方;含分号")&&!C("alpha","kind").includes("名称行尾")'
eq "改动备注：ALTER 上方的 -- 进表的 changes、addedColumns 只含真加的 extra（重加的不算），不挂到 extra / note 列上（打死把改动说明归列）" "true" 'const e=T("alpha").changes.filter(c=>String(c.comment).includes("新增列说明")); e.length===1&&e[0].addedColumns.join()==="extra"&&typeof e[0].line==="number"&&!C("alpha","extra").includes("新增列说明")&&!C("beta","note").includes("不该归属")'
eq "注释：ADD COLUMN 那一行行尾的 -- 仍归它加进来的列（打死连行尾一起不归列）" "true" 'C("alpha","tail").includes("行尾tail")'
eq "约束名：没写名字的表级约束 name 为 null、输出里不出现补的 <表>_ 名字，写了名字的照出（打死把推断的名字写进输出）" "3|2|true|false" 'const c=T("delta").constraints; [c.length,c.filter(x=>x.name===null).length,c.some(x=>x.name==="named_ck"),J(c).includes("delta_")].join("|")'
eq "补名：单列 CHECK 叫 delta_c_check、多列叫 delta_check 都能摘（delta 只剩主键 / 唯一 / named_ck，打死补错名）" "true" 'T("delta").constraints.every(x=>x.type!=="check"||x.name==="named_ck")'
eq "补名：DROP epsilon_a_b_check（列名连起来）摘不掉多列 CHECK，CHECK 还在（打死按列名连起来补名）" "1" 'T("epsilon").constraints.filter(x=>x.type==="check").length'
eq "列标志按键名：主键 / NOT NULL 的 nullable=false，主键 primaryKey、UNIQUE 的 unique，其余反之；无默认值键在且为 null" "true" 'const i=K("alpha","id"),n=K("alpha","name"),k=K("alpha","kind"),u=K("alpha","code"); i.primaryKey===true&&i.nullable===false&&n.nullable===false&&k.nullable===true&&k.primaryKey===false&&u.unique===true&&i.unique===false&&"default" in k&&k.default===null'
eq "注释：COMMENT ON COLUMN 覆盖" "true" 'C("alpha","code").includes("code覆盖")'
# 6 打死：不认自动约束名 / 不摘索引 / 丢外键
eq "外键引用表与 ON DELETE 动作都取到" "true" 'C("alpha","owner_id").includes("beta")&&C("alpha","owner_id").includes("CASCADE")'
eq "DROP CONSTRAINT IF EXISTS alpha_kind_check 摘掉 kind 的行内 CHECK（同条语句里逗号后的 ADD COLUMN w 仍生效）" "false" 'J(T("alpha")).includes("IN (")||!T("alpha").columns.some(c=>c.name==="w")'
eq "DROP INDEX 摘掉 ix_old，ix_a 仍在" "true" 'J(T("alpha")).includes("ix_a")&&!J(T("alpha")).includes("ix_old")'
# 7 视图与函数
eq "视图：anchor、name、文件、定义原文" "view:v_a|v_a|true|true" 'd.views.map(v=>[v.anchor,v.name,v.file.includes("b.sql"),v.sql.includes("SELECT 1")].join("|")).join()'
eq "函数：anchor、name、文件、签名行，且不混进视图" "function:f_a|f_a|true|true|1" 'd.functions.filter(f=>f.name==="f_a").map(f=>[f.anchor,f.name,f.file.includes("b.sql"),f.signature.includes("f_a(x int)")].join("|")).join()+"|"+d.views.length'
eq "同名重载：锚点 function:f_o#<6 位指纹> 且两个不同；单个的 f_a 不接指纹" "true" 'const a=d.functions.filter(f=>f.name==="f_o").map(f=>f.anchor); a.length===2&&a.every(x=>/^function:f_o#[0-9a-f]{6}$/.test(x))&&a[0]!==a[1]'
# 9 打死：输出含时间戳 / 无序遍历
run build --facts-json --root "$R"
cmp -s "$TMP/out" "$TMP/f1.json"; chk $? "同一输入两次 build --facts-json 逐字节相同" "字节一致" "cmp rc 见上"
# 8 init
X="$TMP/r2"; mkdir -p "$X/x/sql"; : >"$X/x/sql/002_b.sql"; : >"$X/x/sql/001_a.sql"
run init --root "$X"; RCI=$RC; CFG="$X/docs/readable-src/config.json"
G=$(node -e 'try{process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).ddl.join())}catch(e){process.stdout.write("<无配置>")}' "$CFG")
if [ "$RCI" = 0 ] && [ "$G" = "x/sql/001_a.sql,x/sql/002_b.sql" ]; then chk 0 "init 起草：找到 x/sql/*.sql（不只根下 sql/），按文件名排序" "rc=0 ddl=001,002" "rc=$RCI ddl=$G"
else chk 1 "init 起草：找到 x/sql/*.sql（不只根下 sql/），按文件名排序" "rc=0 ddl=x/sql/001_a.sql,x/sql/002_b.sql" "rc=$RCI ddl=$G"; fi
printf '{"version":1,"title":"手改","ddl":["x/sql/001_a.sql"]}' >"$CFG"; B4=$(sha256sum "$CFG")
run init --root "$X"; RCJ=$RC; AF=$(sha256sum "$CFG")
if [ "$RCJ" = 0 ] && [ "$B4" = "$AF" ] && grep -q '配置已存在' "$TMP/out" "$TMP/err" 2>/dev/null; then chk 0 "init 配置已存在：一字节不动、说「配置已存在」、退出码 0" "不动+rc=0" "rc=$RCJ"
else chk 1 "init 配置已存在：一字节不动、说「配置已存在」、退出码 0" "sha 不变 rc=0 且提示" "rc=$RCJ same=$([ "$B4" = "$AF" ] && echo y || echo n) out=$(head -c 120 "$TMP/out")"; fi
printf '{"version":1,"title":"t","spec":"Product-Spec.md","ddl":["x/sql/001_a.sql","no/such.sql"],"codeRoots":[],"ignore":[]}' >"$CFG"; : >"$X/Product-Spec.md"
run build --facts-json --root "$X"
if [ "$RC" = 2 ] && cat "$TMP/out" "$TMP/err" | grep -q 'no/such.sql'; then chk 0 "ddl 路径不存在：build 退出码 2 并点名那一条" "rc=2 点名 no/such.sql" "rc=$RC"
else chk 1 "ddl 路径不存在：build 退出码 2 并点名那一条" "rc=2 点名 no/such.sql" "rc=$RC err=$(head -c 160 "$TMP/err")"; fi
echo "===== 汇总：PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" -eq 0 ]
