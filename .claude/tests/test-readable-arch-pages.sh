#!/usr/bin/env bash
# risk: high
# test-readable-arch-pages.sh — 人读文档 · 架构页面与核对黑盒回归（phase3-arch-contract.md D、E 节；沿用 phase1 C、H 节）。
# 断言只从契约推导：页面按 data-anchor / data-row / 去标签后的文字读回，事实取 build --facts-json，不手抄期望。夹具全是合成项目，mktemp -d + --root。
set -eu
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
ENGINE="${1:-$REPO_ROOT/.claude/scripts/readable-docs.mjs}"
echo "===== test-readable-arch-pages ====="
if ! command -v node >/dev/null 2>&1; then echo "SKIPPED: 无 node，未执行 != 通过。"; exit 0; fi
[ -f "$ENGINE" ] || { echo "  [FAIL] 缺被测脚本：$ENGINE" >&2; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
eq() { if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; else FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$1"; fi; printf '         EXPECT %s\n         GOT    %s\n' "$2" "$3"; }
nd() { env -u CLAUDE_PROJECT_DIR node "$ENGINE" "$@"; }
bd() { RB=0; nd build --root "$1" >/dev/null 2>&1 || RB=$?; }
ck() { RC=0; nd check --json --root "$1" >"$TMP/c.json" 2>/dev/null || RC=$?; }
last() { nd check --root "$1" 2>&1 | tail -1; }
yn() { if "$@" >/dev/null 2>&1; then printf y; else printf n; fi; }
pk() { node -e 'try{const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const a=j.problems.filter(p=>p.kind.startsWith("arch-"));console.log([...new Set(a.map(p=>p.kind))].join()+"|"+a.some(p=>(p.where+" "+p.detail).includes(process.argv[2])))}catch(e){console.log("NOJSON")}' "$TMP/c.json" "$1"; }
hs() { (cd "$1/docs/readable" 2>/dev/null && find . -type f | sort | xargs sha256sum | sha256sum) || echo none; }
cat >"$TMP/h.js" <<'EOF'
const fs=require('fs');
const dec=s=>s.replace(/&lt;/g,'<').replace(/&gt;/g,'>').replace(/&quot;/g,'"').replace(/&#0?39;/g,"'").replace(/&amp;/g,'&');
const txt=h=>dec(h.replace(/<(script|style)[\s\S]*?<\/\1>/g,' ').replace(/<\/?(br|td|th|tr|li|p|div|section|ul|ol|table|thead|tbody|h[1-6]|main|header|footer|article|details|summary|svg|text|g|rect|line|path|title)\b[^>]*>/g,' ').replace(/<[^>]+>/g,'')).replace(/\s+/g,' ').trim();
const spans=(h,at)=>{const o=[],re=new RegExp('<(\\w+)[^>]*\\s'+at+'=[^>]*>','g');let m;while((m=re.exec(h))){const re2=new RegExp('<(/?)'+m[1]+'(?=[\\s>/])[^>]*>','g');re2.lastIndex=m.index+m[0].length;let d=1,x;while(d&&(x=re2.exec(h)))d+=x[1]?-1:1;o.push([m.index,d?h.length:re2.lastIndex,m[0]])}return o};
const val=(t,at)=>(t.match(new RegExp(at+'="([^"]*)"'))||[])[1];
const rows=h=>{const S=spans(h,'data-section');return spans(h,'data-row').map(([a,b,t])=>{const s=S.filter(([c,d])=>c<=a&&d>=b).sort((p,q)=>(p[1]-p[0])-(q[1]-q[0]))[0];return{k:dec(val(t,'data-row')||''),sec:s?val(s[2],'data-section'):null,html:h.slice(a,b),text:txt(h.slice(a,b))}})};
const cellRe=k=>new RegExp('<(\\w+)([^>]*\\sdata-k="'+k+'"[^>]*)>([\\s\\S]*?)<\\/\\1>');
const cv=(r,k,v)=>{const m=r.html.match(cellRe(k));return !!m&&(txt(m[3])===v||dec(m[2]).includes('="'+v+'"'))};
const delRow=(h,k)=>{const s=spans(h,'data-row').filter(([a,b,t])=>dec(val(t,'data-row')||'')===k)[0];return s?h.slice(0,s[0])+h.slice(s[1]):null};
const cells=(r,k)=>spans(r.html,'data-k').filter(s=>val(s[2],'data-k')===k).map(s=>txt(r.html.slice(s[0],s[1])));
const same=(a,b)=>JSON.stringify([...a].sort())==JSON.stringify([...b].sort());
const sz=n=>n<100?'不到 100 行':n<500?'100–500 行':n<1000?'500–1000 行':'1000 行以上';
module.exports={fs,txt,rows,cv,cells,cellRe,delRow,same,sz};
EOF
nj() { node -e "const H=require('$TMP/h.js'),fs=H.fs;try{$1}catch(e){console.log('THROW '+String(e.message).slice(0,90))}" "${@:2}"; }
w() { mkdir -p "$(dirname "$R/$1")"; local f=$1; shift; printf '%s\n' "$@" >"$R/$f"; }
mm() { printf '{"id":"%s","title":"%s","layer":"%s","paths":["app/%s/**"],"status":"proposed"}' "$1" "$2" "$3" "$1"; }
mkfx() { R=$1; mkdir -p "$R/docs/readable-src" "$R/sql"; : >"$R/Product-Spec.md"
  printf 'CREATE TABLE orders (id int PRIMARY KEY);\nCREATE TABLE items (id int PRIMARY KEY);\nCREATE TABLE logs (id int PRIMARY KEY);\n' >"$R/sql/s.sql"
  printf '{"version":1,"title":"t","spec":"Product-Spec.md","ddl":["sql/s.sql"],"codeRoots":["app"],"ignore":[]}\n' >"$R/docs/readable-src/config.json"
  printf '{"version":1,"tableGroups":[],"dynamicTables":[],"layers":["接口","业务","数据"],"modules":[%s,%s,%s]}\n' "$(mm api 甲层网关 接口)" "$(mm core 乙层业务 业务)" "$(mm store 丙层存储 数据)" >"$R/docs/readable-src/map.json"
  w app/api/web.py '"""Web entry point.' 'Second line of head.' 'Third line of head."""' 'from fastapi import APIRouter, FastAPI' 'from ..core.svc import run' 'router = APIRouter(prefix="/v1")' 'Q = "SELECT a FROM orders"' '@router.get("/orders")' 'def list_orders():' '    """Lists the orders."""' '    return 1' '@router.post("/orders")' 'def make_order(): return run()' 'def ping(): pass' 'app = FastAPI()' 'app.include_router(router)'
  w app/api/a2.py 'A = 1'; w app/api/a3.py 'A = 3'; w app/core/svc.py 'from ..store.db import save' 'def run(): save()' 'W = "INSERT INTO items (a) VALUES (1)"'; w app/core/util.py 'U = 1'
  w app/store/db.py 'def save(): pass' 'Q = "INSERT INTO orders (x) VALUES (1)"' 'R = "SELECT a FROM logs"'; w app/misc/stray.py 'S = "SELECT a FROM logs"'; }
B="$TMP/b"; mkfx "$B"; bd "$B"; FJ="$TMP/f.json"; nd build --facts-json --root "$B" >"$FJ" 2>/dev/null || true; ck "$B"; D="$B/docs/readable"; AD="$D/arch"

# 1 打死：漏出页面（总览 / 某模块页 / 接口总表）/ 多出页面 / 文档清单不列架构 / 干净夹具上核对误报
eq "页面齐全：arch/index、三个 m-<id>、routes 都在且 m-*.html 恰三个；文档首页有「架构设计」；未动过 check 退出码 0、末行「不一致 0 条」" "yyyyy|3|y|0|不一致 0 条" \
  "$(yn test -f "$AD/index.html")$(yn test -f "$AD/m-api.html")$(yn test -f "$AD/m-core.html")$(yn test -f "$AD/m-store.html")$(yn test -f "$AD/routes.html")|$(ls "$AD"/m-*.html 2>/dev/null | wc -l | tr -d ' ')|$(yn grep -qF 架构设计 "$D/index.html")|$RC|$(last "$B")"

# 2 打死：页面上文件 / 接口 / 依赖 / 提供 / 读写表漏项或串位、行数不对、文件头说明与处理函数说明被截断
eq "模块页事实：每个模块页各段（data-section）的 data-row 键集与 facts.arch 相同——文件（size 规模档，由事实里的行数按四档算出）、接口（method、path、handler）、依赖（模块 id，名字与文件对在行内）、对外提供（by）、读写的表（每表一行，rw 为读 / 写 / 读写）——格子值逐项相同；文件头三行与处理函数说明全文在 api 页" "" \
  "$(nj 'const [R,F]=process.argv.slice(1),f=JSON.parse(fs.readFileSync(F)),A=f.arch,L={},bad=[];f.code.files.forEach(x=>L[x.path]=x.lines);
for(const m of A.modules){const h=fs.readFileSync(R+"/docs/readable/arch/m-"+m.id+".html","utf8"),rs=H.rows(h),n=(s,x)=>bad.push(m.id+":"+s+":"+x),rk=r=>r.method+" "+(r.fullPath??r.path);
const chk=(s,keys,fn)=>{const x=rs.filter(r=>r.sec==s);if(!H.same(x.map(r=>r.k),keys))n(s,"keys="+x.map(r=>r.k).join(",").slice(0,70));else x.forEach(fn)};
chk("files",m.files,r=>{if(!H.cv(r,"size",H.sz(L[r.k])))n("lines",r.k)});
chk("routes",m.routes.map(rk),r=>{const q=m.routes.find(x=>rk(x)==r.k);if(!H.cv(r,"method",q.method)||!(H.cv(r,"path",q.fullPath)||H.cv(r,"path",q.path))||!H.cv(r,"handler",q.handler))n("route",r.k)});
chk("uses",m.uses.map(u=>u.module),r=>{const u=m.uses.find(x=>x.module==r.k);u.names.concat(u.pairs.flat()).forEach(x=>{if(!r.text.includes(x))n("uses",r.k+":"+x)})});
chk("provides",m.provides.map(p=>p.file+"#"+p.name),r=>{const q=m.provides.find(x=>x.file+"#"+x.name==r.k);if(!H.cv(r,"by",q.by.join(" ")))n("by",r.k)});
const rd=new Set(m.tables.reads),wr=new Set(m.tables.writes);chk("tables",[...new Set([...rd,...wr])],r=>{if(!H.cv(r,"rw",(rd.has(r.k)?"读":"")+(wr.has(r.k)?"写":"")))n("rw",r.k)})}
const AT=H.txt(fs.readFileSync(R+"/docs/readable/arch/m-api.html","utf8"));["Web entry point.","Second line of head.","Third line of head.","Lists the orders."].forEach(x=>{if(!AT.includes(x))bad.push("text:"+x)});console.log(bad.join(";"))' "$B" "$FJ")"

# 3 打死：模块页的表名链不到表页 / 表页文件后没标模块或标错、链到不存在的页 / 未归属的文件被硬塞进模块
eq "两份互连：模块页 tables 段每个表名行链到存在的表页；三张表页每个 writer / reader 行的 module 格是文件所属模块 id 并链到存在的 m-<id> 页，stray 是「未归属」且无模块链接（且这样的行不是空集）" "|5|1" \
  "$(nj 'const [R,F]=process.argv.slice(1),A=JSON.parse(fs.readFileSync(F)).arch,M={},bad=[],D=R+"/docs/readable/";let nrow=0,nun=0;A.modules.forEach(m=>m.files.forEach(p=>M[p]=m.id));
for(const m of A.modules){const rs=H.rows(fs.readFileSync(D+"arch/m-"+m.id+".html","utf8")).filter(r=>r.sec=="tables");m.tables.reads.concat(m.tables.writes).forEach(t=>{const r=rs.find(x=>x.k==t);if(!r||!r.html.includes("t-"+t+".html")||!fs.existsSync(D+"db/t-"+t+".html"))bad.push(m.id+"->"+t)})}
for(const t of ["orders","items","logs"]){const rs=H.rows(fs.readFileSync(D+"db/t-"+t+".html","utf8")).filter(r=>/^(writer|reader)$/.test(r.k));for(const r of rs){const p=(r.text.match(/app\/[\w\/]+\.py/)||[])[0],id=M[p];if(!p){bad.push(t+":nopath");continue}nrow++;
if(!id){nun++;if(!H.cv(r,"module","未归属")||/m-\w+\.html/.test(r.html))bad.push(t+":"+p+":un")}else if(!H.cv(r,"module",id)||!r.html.includes("m-"+id+".html")||!fs.existsSync(D+"arch/m-"+id+".html"))bad.push(t+":"+p+":mod")}}
console.log(bad.join(";")+"|"+nrow+"|"+nun)' "$B" "$FJ")"

# 4 打死：首页清单行数 / 文件数 / 接口数与事实不符、未归属文件被藏、环不列成员、没有环时整段消失（带环夹具对照）
ix() { nj 'const [R,F]=process.argv.slice(1),A=JSON.parse(fs.readFileSync(F)).arch,h=fs.readFileSync(R+"/docs/readable/arch/index.html","utf8"),T=H.txt(h),rs=H.rows(h),b=[],S=s=>rs.filter(r=>r.sec==s);
if(!H.same(S("modules").map(r=>r.k),A.modules.map(m=>m.id)))b.push("mods="+S("modules").map(r=>r.k).join(","));else S("modules").forEach(r=>{const m=A.modules.find(x=>x.id==r.k);if(!H.cv(r,"files",String(m.files.length))||!H.cv(r,"routes",String(m.routes.length)))b.push("cell:"+m.id)});
if(!H.same(S("unassigned").map(r=>r.k),A.unassigned))b.push("un="+S("unassigned").map(r=>r.k).join(","));
const i=T.indexOf("循环依赖");if(A.cycles.length){A.cycles[0].modules.forEach(id=>{if(!T.slice(i,i+600).includes(A.modules.find(m=>m.id==id).title))b.push("cyc:"+id)})}else if(!T.slice(i,i+200).includes("没有"))b.push("nocycle-none");
console.log(A.cycles.length+"|"+b.join(";"))' "$1" "$2"; }
C="$TMP/cy"; cp -r "$B" "$C"; R=$C; w app/store/back.py 'from ..api.web import ping'; nd build --facts-json --root "$C" >"$TMP/fc.json" 2>/dev/null || true; bd "$C"
eq "首页：data-section=modules 的行键恰为模块 id、文件数 / 接口数格子与事实相同，未归属文件各一行；无环夹具循环依赖段写「没有」；带环夹具（store 回引 api）成员模块列在循环依赖段" "0|1|" "$(ix "$B" "$FJ")$(ix "$C" "$TMP/fc.json")"

# 5 打死：核对器只比整页哈希、不读页面（手改后点不到模块 / 点不到那一项）；每种只动一处
mut() { rm -rf "$TMP/mu"; cp -r "$B" "$TMP/mu"; nj "$2" "$TMP/mu"; ck "$TMP/mu"; echo "$RC|$(pk "$3")"; }
eq "手改核对·删掉 m-core 页上 util.py 那一行：退出码 1，arch- 类问题只有 arch-mismatch 且点到 core" "1|arch-mismatch|true" "$(mut x 'const p=process.argv[1]+"/docs/readable/arch/m-core.html",r=H.delRow(fs.readFileSync(p,"utf8"),"app/core/util.py");if(r)fs.writeFileSync(p,r);else console.log("NOROW")' core)"
eq "手改核对·删掉 m-api 页上 make_order 那条接口行：同上，点到 api" "1|arch-mismatch|true" "$(mut x 'const p=process.argv[1]+"/docs/readable/arch/m-api.html",r=H.delRow(fs.readFileSync(p,"utf8"),"POST /v1/orders");if(r)fs.writeFileSync(p,r);else console.log("NOROW")' api)"
eq "手改核对·把 orders 表页上 store/db.py 那行的 module 格改成 api：同上，点到 orders" "1|arch-mismatch|true" "$(mut x 'const p=process.argv[1]+"/docs/readable/db/t-orders.html",h=fs.readFileSync(p,"utf8"),r=H.rows(h).find(x=>x.k=="writer"&&x.text.includes("app/store/db.py"));if(!r)console.log("NOROW");else fs.writeFileSync(p,h.replace(r.html,()=>r.html.replace(H.cellRe("module"),c=>c.replaceAll("丙层存储","甲层网关").replaceAll("store","api"))))' orders)"
eq "手改核对·把首页 api 那一行 files 格的 3 改成 9：同上，点到 api" "1|arch-mismatch|true" "$(mut x 'const p=process.argv[1]+"/docs/readable/arch/index.html",h=fs.readFileSync(p,"utf8"),r=H.rows(h).find(x=>x.sec=="modules"&&x.k=="api");if(!r)console.log("NOROW");else fs.writeFileSync(p,h.replace(r.html,()=>r.html.replace(H.cellRe("files"),c=>c.replace(/>\s*3\s*</,">9<").replace("=\"3\"","=\"9\""))))' api)"

# 6 打死：加文件不重出时 check 仍绿（假绿）/ 重出后还有残留
S="$TMP/s"; cp -r "$B" "$S"; R=$S; w app/core/more.py 'M = 1'; ck "$S"; S1=$RC; bd "$S"; ck "$S"
eq "事实变了没重出：core 加一个文件不重出 → check 退出码 1；重出后退出码 0、末行「不一致 0 条」" "1|0|不一致 0 条" "$S1|$RC|$(last "$S")"

# 7 打死：没写说明不标待写 / 说明只出一半（首页取第一段、模块页全文）/ 缺草稿标记 / 加文件后说明不显过期、check 不报
N="$TMP/n"; cp -r "$B" "$N"; R=$N
T0=$(nj 'const D=process.argv[1]+"/docs/readable/arch/",r=H.rows(fs.readFileSync(D+"index.html","utf8")).find(x=>x.sec=="modules"&&x.k=="core");console.log(H.txt(fs.readFileSync(D+"m-core.html","utf8")).includes("待写")+"|"+(!!r&&r.text.includes("待写")))' "$N")
printf '## module:core\n第一段职责一句话。\n\n第二段说明细节展开。\n' >"$TMP/in.md"; nd note put --file "$TMP/in.md" --root "$N" >/dev/null 2>&1 || true; bd "$N"
T1=$(nj 'const D=process.argv[1]+"/docs/readable/arch/",r=H.rows(fs.readFileSync(D+"index.html","utf8")).find(x=>x.sec=="modules"&&x.k=="core"),T=H.txt(fs.readFileSync(D+"m-core.html","utf8"));console.log((!!r&&r.text.includes("第一段职责一句话。"))+"|"+(T.includes("第一段职责一句话。")&&T.includes("第二段说明细节展开。"))+"|"+T.includes("草稿"))' "$N")
w app/core/more.py 'M = 1'; bd "$N"; ck "$N"
T2=$(nj 'console.log(H.txt(fs.readFileSync(process.argv[1]+"/docs/readable/arch/m-core.html","utf8")).includes("过期")+"|"+JSON.parse(fs.readFileSync(process.argv[2])).problems.filter(p=>p.kind=="note-stale"&&(p.where+p.detail).includes("module:core")).length)' "$N" "$TMP/c.json")
eq "说明：没写时 core 页与首页那一行有「待写」；note put 两段后首页那行有第一段、模块页有全文与「草稿」；core 再加文件重出 → 页上带「过期」、check 恰一条 note-stale 点到 module:core" "true|true|true|true|true|true|1" "$T0|$T1|$T2"

# 8 打死：文件头说明里的内网地址原样带上页面 / 隐去了却没写「已隐去」/ 隐去后 check 误报
V="$TMP/v"; cp -r "$B" "$V"; sed -i 's/^Second line of head\./Second line of head. Host 10.1.2.3 here./' "$V/app/api/web.py"; bd "$V"; RB8=$RB
eq "隐去：文件头说明里的 10.1.2.3 在 arch/ 下搜不到、搜得到「已隐去」，build 退出码 0，check 末行「不一致 0 条」" "0|n|y|不一致 0 条" "$RB8|$(yn grep -rqF 10.1.2.3 "$V/docs/readable/arch")|$(yn grep -rqF 已隐去 "$V/docs/readable/arch")|$(last "$V")"

# 9 打死：codeRoots 为空仍出架构页 / 文档首页列架构 / 数据库页与旧代码不逐字节相同；对照：有架构时表页确实与旧代码不同（防比较空转）
mkdir -p "$TMP/old"; (cd "$REPO_ROOT" && git archive f79fc5c .claude/scripts | tar -x -C "$TMP/old")
Z="$TMP/z"; cp -r "$B" "$Z"; rm -rf "$Z/docs/readable"; node -e 'const fs=require("fs"),f=process.argv[1]+"/docs/readable-src/config.json",c=JSON.parse(fs.readFileSync(f));c.codeRoots=[];fs.writeFileSync(f,JSON.stringify(c))' "$Z"
Y="$TMP/y"; cp -r "$Z" "$Y"; W="$TMP/w"; cp -r "$B" "$W"; rm -rf "$W/docs/readable"; bd "$Z"; RB9=$RB; ORC=0; env -u CLAUDE_PROJECT_DIR node "$TMP/old/.claude/scripts/readable-docs.mjs" build --root "$Y" >/dev/null 2>&1 || ORC=$?; env -u CLAUDE_PROJECT_DIR node "$TMP/old/.claude/scripts/readable-docs.mjs" build --root "$W" >/dev/null 2>&1 || true
# 新契约给第一期表页加了读回标记 data-k="name" / "file"（所有项目都有，与有没有架构无关）：比之前把这两个属性剔掉，其余一个字节不许变
rm -rf "$TMP/zn"; cp -r "$Z/docs/readable/db" "$TMP/zn"; find "$TMP/zn" -name '*.html' -exec sed -i -E 's/ data-k="(name|file)"//g' {} +
DRC=0; diff -r "$TMP/zn" "$Y/docs/readable/db" >/dev/null 2>&1 || DRC=$?; ck "$Z"
eq "无架构一切照旧：codeRoots 为空 → build 0、arch 目录不在、文档首页无「架构设计」、check 0 条；db/ 剔掉 data-k=name/file 两个新读回属性后与提交 f79fc5c 的代码生成的逐字节相同（旧代码 build 也是 0）；表页上没有 data-k=\"module\"" "0|n|n|0|不一致 0 条|0|0|n" "$RB9|$(yn test -d "$Z/docs/readable/arch")|$(yn grep -qF 架构设计 "$Z/docs/readable/index.html")|$RC|$(last "$Z")|$DRC|$ORC|$(yn grep -rqF 'data-k="module"' "$Z/docs/readable/db")"
eq "对照（防上一臂空转）：有架构时 orders 表页与旧代码生成的不同（多了模块标记）" "differ" "$(cmp -s "$D/db/t-orders.html" "$W/docs/readable/db/t-orders.html" && echo same || echo differ)"

# 10 打死：落盘前自检失败仍替换页面 / 退出码不是 3 / 两次生成不逐字节相同
F="$TMP/fa"; cp -r "$B" "$F"; R=$F; w app/core/more2.py 'M = 2'; H0=$(hs "$F"); FRC=0; READABLE_FAIL_AT=arch-render nd build --root "$F" >/dev/null 2>&1 || FRC=$?; H1=$(hs "$F")
cp -r "$D" "$TMP/snap" 2>/dev/null || mkdir -p "$TMP/snap"; bd "$B"; DET=$(diff -r "$TMP/snap" "$D" >/dev/null 2>&1 && echo same || echo differ)
eq "落盘前自检：READABLE_FAIL_AT=arch-render 时 build 退出码 3、原有页面哈希不变；同一输入再 build 一次整个 docs/readable 逐字节相同" "3|same|same" "$FRC|$([ "$H0" = "$H1" ] && echo same || echo differ)|$DET"

# 11 打死：接口总表漏行 / 方法或完整路径与事实不符 / 缺所属模块链接；没有接口的项目这一页消失或留空
rt=$(nj 'const [R,F]=process.argv.slice(1),f=JSON.parse(fs.readFileSync(F)),rs=H.rows(fs.readFileSync(R+"/docs/readable/arch/routes.html","utf8")),b=[],rk=r=>r.method+" "+(r.fullPath??r.path);if(!H.same(rs.map(r=>r.k),f.code.routes.map(rk)))b.push("keys="+rs.map(r=>r.k).join(","));
else rs.forEach(x=>{const r=f.code.routes.find(y=>rk(y)==x.k),m=f.arch.modules.find(y=>y.files.includes(r.file));if(!H.cv(x,"method",r.method)||!H.cv(x,"path",r.fullPath)&&!H.cv(x,"path",r.path)||!H.cv(x,"handler",r.handler)||!H.cv(x,"module",m.id)||!x.html.includes("m-"+m.id+".html"))b.push("cell:"+r.handler)});console.log(f.code.routes.length+"|"+b.join(";"))' "$B" "$FJ")
E="$TMP/e"; cp -r "$B" "$E"; R=$E; w app/api/web.py 'X = 1'; bd "$E"
eq "接口总表：行数等于接口数（2）、每行 data-row 为「方法 完整路径」、method / path / handler / module 格与事实相同并链到所属模块页；接口总表的行没有 data-k=doc（0 个），模块页上有说明的 list_orders 行恰一个 doc 格、没说明的 make_order 行没有；没有接口的项目 routes.html 照出且写「没有读出接口（只认装饰器写法的路由）」" "2||y|0|1|0" "$rt|$(nj 'console.log(H.txt(fs.readFileSync(process.argv[1]+"/docs/readable/arch/routes.html","utf8")).includes("没有读出接口（只认装饰器写法的路由）")?"y":"n")' "$E")|$(nj 'const D=process.argv[1]+"/docs/readable/arch/",rr=H.rows(fs.readFileSync(D+"routes.html","utf8")).filter(r=>r.sec=="routes"),mr=H.rows(fs.readFileSync(D+"m-api.html","utf8")).filter(r=>r.sec=="routes"),dc=h=>{const r=mr.find(x=>H.cells(x,"handler").join()==h);return r?H.cells(r,"doc").length:"norow"};console.log(rr.reduce((a,r)=>a+H.cells(r,"doc").length,0)+"|"+dc("list_orders")+"|"+dc("make_order"))' "$B")"
# 12 打死：模块页写确切行数 / 四档边界差一（99、100、1000）/ 模块规模写成确切数而非「约 N 行」
Q="$TMP/q"; cp -r "$B" "$Q"; R=$Q; for n in 99 100 1000; do seq 1 $n | sed 's/^/x=/' >"$Q/app/core/s$n.py"; done; mkdir -p "$Q/app/huge"; seq 1 4893 | sed 's/^/x=/' >"$Q/app/huge/h.py"
mapedit() { node -e 'const fs=require("fs"),f=process.argv[1]+"/docs/readable-src/map.json",m=JSON.parse(fs.readFileSync(f));m.modules.push({id:process.argv[2],title:process.argv[3],layer:"业务",paths:[process.argv[4]],status:"proposed"});fs.writeFileSync(f,JSON.stringify(m))' "$@"; }
mapedit "$Q" huge 丁层巨大 'app/huge/**'; nd build --facts-json --root "$Q" >"$TMP/fq.json" 2>/dev/null || true; bd "$Q"
eq "规模档与约数：文件恰 99 / 100 / 1000 行的 size 分别是「不到 100 行」「100–500 行」「1000 行以上」（事实里行数也确是这三个数）；4893 行的模块页与首页写「约 5 千行」、两处都没有 4893" "" \
  "$(nj 'const [R,F]=process.argv.slice(1),f=JSON.parse(fs.readFileSync(F)),L={},b=[],D=R+"/docs/readable/arch/";f.code.files.forEach(x=>L[x.path]=x.lines);const rs=H.rows(fs.readFileSync(D+"m-core.html","utf8")).filter(r=>r.sec=="files");
[[99,"不到 100 行"],[100,"100–500 行"],[1000,"1000 行以上"]].forEach(([n,e])=>{const r=rs.find(x=>x.k=="app/core/s"+n+".py");if(L["app/core/s"+n+".py"]!=n)b.push("fx"+n);if(!r||!H.cv(r,"size",e))b.push("size"+n)});
if(L["app/huge/h.py"]!=4893)b.push("fxhuge");const T=H.txt(fs.readFileSync(D+"m-huge.html","utf8")),I=H.txt(fs.readFileSync(D+"index.html","utf8"));if(!T.includes("约 5 千行")||!I.includes("约 5 千行")||T.includes("4893")||I.includes("4893"))b.push("huge");console.log(b.join(";"))' "$Q" "$TMP/fq.json")"

# 13 打死：改一个文件顶上加三行（不跨档）页面就变 / 跨档不变 / 跨档没重出 check 不报
G="$TMP/g"; cp -r "$B" "$G"; R=$G; seq 1 98 | sed 's/^/x=/' >"$G/app/core/s98.py"; seq 1 2000 | sed 's/^/x=/' >"$G/app/core/pad.py"; bd "$G"; H0=$(hs "$G"); P0=$(sha256sum "$G/docs/readable/arch/m-core.html" 2>/dev/null || echo none0)
sed -i '1i # c1\n# c2\n# c3' "$G/app/core/pad.py"; bd "$G"; H1=$(hs "$G"); printf 'y=1\ny=2\ny=3\n' >>"$G/app/core/s98.py"; ck "$G"; G1=$RC; bd "$G"; P1=$(sha256sum "$G/docs/readable/arch/m-core.html" 2>/dev/null || echo none1)
eq "行数不上页面：core/pad.py（2000 行，使模块与全库的「约 N 行」不在进位边上）顶上加三行（不跨档）重出后整个 docs/readable 逐字节相同；s98.py 从 98 加到 101 行（跨档）不重出 check 退出码 1、重出后 m-core 页变了" "same|1|differ" "$([ "$H0" = "$H1" ] && echo same || echo differ)|$G1|$([ "$P0" = "$P1" ] && echo same || echo differ)"

# 14 打死：对不上的项目判断与页面对不上事实混成一个 kind / 干净 map.json 也报 arch-map
M2="$TMP/m2"; cp -r "$B" "$M2"; mapedit "$M2" ghost 空模块 'nowhere/**'; bd "$M2"; ck "$M2"
kd() { node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")),k=j.problems.map(p=>p.kind);console.log(k.includes("arch-map")+"|"+k.includes("arch-mismatch"))' "$TMP/c.json" 2>/dev/null || echo NOJSON; }
K2=$(kd); ck "$B"
eq "arch-map：map.json 里 paths 匹配不到文件的模块 → check --json 有 arch-map、无 arch-mismatch；对照：干净的 map.json 没有 arch-map" "true|false|false|false" "$K2|$(kd)"
# 15–17 打死：出页面的代码把显示的字写错 / 整段漏掉，落盘前的自检看不见（原先只比 data-row）——三个注入点各被拦下：build 退出码 3、报错点到那一页、原有页面一个字节不动、docs 下无残留；对照：不注入同一输入 build 0 且页面确实会变（否则「不变」是空话）
inj() { local P=$1 F="$TMP/in_$1"; cp -r "$B" "$F"; R=$F; w "app/core/zz_$P.py" 'M = 1'; H0=$(hs "$F"); L0=$(ls -A "$F/docs"); IRC=0; READABLE_FAIL_AT=$P nd build --root "$F" >"$TMP/o_$P" 2>&1 || IRC=$?
  H1=$(hs "$F"); L1=$(ls -A "$F/docs"); bd "$F"; H2=$(hs "$F")
  echo "$IRC|$([ "$H0" = "$H1" ] && echo same || echo changed)|$([ "$L0" = "$L1" ] && echo same || echo "$L1")|$(grep -qE "$2" "$TMP/o_$P" && echo y || echo n)|$RB|$([ "$H1" != "$H2" ] && echo differs || echo same)"; }
eq "注入 arch-show-key（模块页上第一个文件显示的路径写错、data-row 不动）：退出码 3、输出点到 m-api 页、页面哈希不变、无残留；对照组不注入退出码 0、哈希变" "3|same|same|y|0|differs" "$(inj arch-show-key 'm-api')"
eq "注入 arch-show-head（第一条文件头说明少最后一个字）：同上，点到 m-api 页" "3|same|same|y|0|differs" "$(inj arch-show-head 'm-api')"
eq "注入 arch-drop-section（架构首页「没有被别的文件引用的」整段不出）：同上，点到架构首页 arch/index" "3|same|same|y|0|differs" "$(inj arch-drop-section 'arch/index')"

# 18 打死：注入点找不到可下手的地方（项目里没有任何文件头说明）时悄悄成功——测试以为自检拦住了，其实压根没注入
NH="$TMP/nh"; cp -r "$B" "$NH"; R=$NH; sed -i '1,3d' "$NH/app/api/web.py"; bd "$NH"; RB18=$RB; nd build --facts-json --root "$NH" >"$TMP/fnh.json" 2>/dev/null || true
w app/core/zz_nh.py 'M = 1'; H0=$(hs "$NH"); NRC=0; READABLE_FAIL_AT=arch-show-head nd build --root "$NH" >"$TMP/o_nh" 2>&1 || NRC=$?; H1=$(hs "$NH")
# 没有架构这一份的项目（Z：codeRoots 为空，已 build）设 arch-show-key：同样报错、退出码 3、页面不动（E 节末句）。源头多一张表，让「不拦」时页面确实会变
NZ="$TMP/nz"; cp -r "$Z" "$NZ"; echo 'CREATE TABLE zeta_n (id int);' >>"$NZ/sql/s.sql"; HZ0=$(hs "$NZ"); ZRC=0; READABLE_FAIL_AT=arch-show-key nd build --root "$NZ" >/dev/null 2>&1 || ZRC=$?; HZ1=$(hs "$NZ"); NA="$ZRC|$([ "$HZ0" = "$HZ1" ] && echo same || echo changed)"
eq "没有文件头说明的项目（夹具里 head 非空的文件数为 0，不带注入 build 退出码 0）跑 arch-show-head：退出码非 0、有报错输出、页面哈希不变；没配 codeRoots（没有架构）的小项目设 arch-show-key：同样退出码 3、页面哈希不变——不是悄悄成功" "0|0|y|y|same|3|same" \
  "$(nj 'console.log(JSON.parse(fs.readFileSync(process.argv[1])).code.files.filter(x=>x.head!=null).length)' "$TMP/fnh.json")|$RB18|$([ "$NRC" != 0 ] && echo y || echo "rc=$NRC")|$([ -s "$TMP/o_nh" ] && echo y || echo n)|$([ "$H0" = "$H1" ] && echo same || echo changed)|$NA"

# 19（含 headAt 子项）打死：模块页文件段的行没有 data-k=key 格 / 显示的路径与 data-row 不同 / 有说明的行缺 head 格 / 没说明的行硬塞 head 格 / head 格的字不是全文
JA="$TMP/ja"; cp -r "$B" "$JA"; R=$JA; w app/core/ui.js "import React from 'react'" '/* Panel component notes. */' 'export function Panel() {}'; w app/core/top.js '/* Top of file note. */' "import x from 'y'" 'export const a = 1'; w app/core/plain.js 'export const b = 2'
bd "$JA"; nd build --facts-json --root "$JA" >"$TMP/fja.json" 2>/dev/null || true
eq "模块页 files 段每一行（共 6 行）恰一个 data-k=key 格、显示的字等于 data-row；facts 里有文件头说明的行（web.py）恰一个 data-k=head 格且字等于说明全文（空白归一），没有说明的行没有 head 格；子项 headAt：夹具再加三个 JS 文件（先引用后注释的 ui.js、注释在最前面的 top.js、没注释的 plain.js），事实里 headAt 为 after-imports 的 1 个、top 的 2 个（web.py 与 top.js），页面上 after-imports 的行恰一个 data-k=headAt 格、字含「写在引用语句之后的第一块注释」，top 与没说明的行没有这一格" "|6|1|1|2|" \
  "$(nj 'const [R,F]=process.argv.slice(1),f=JSON.parse(fs.readFileSync(F)),HD={},bad=[];f.code.files.forEach(x=>HD[x.path]=x.head);let n=0,nh=0;
for(const m of f.arch.modules){H.rows(fs.readFileSync(R+"/docs/readable/arch/m-"+m.id+".html","utf8")).filter(r=>r.sec=="files").forEach(r=>{n++;const k=H.cells(r,"key"),h=H.cells(r,"head");if(k.length!=1||k[0]!=r.k)bad.push("key:"+r.k+"="+k.join("/"));const want=HD[r.k];if(want==null){if(h.length)bad.push("head+:"+r.k)}else{nh++;if(h.length!=1||h[0]!=want.replace(/\s+/g," ").trim())bad.push("head:"+r.k)}})}
console.log(bad.join(";")+"|"+n+"|"+nh)' "$B" "$FJ")|$(nj 'const [R,F]=process.argv.slice(1),f=JSON.parse(fs.readFileSync(F)),bad=[],c=x=>f.code.files.filter(y=>y.headAt===x).length;
for(const m of f.arch.modules){H.rows(fs.readFileSync(R+"/docs/readable/arch/m-"+m.id+".html","utf8")).filter(r=>r.sec=="files").forEach(r=>{const x=f.code.files.find(y=>y.path==r.k),a=H.cells(r,"headAt");if(x.headAt==="after-imports"){if(a.length!=1||!a[0].includes("写在引用语句之后的第一块注释"))bad.push("at:"+r.k+"="+a.join("/"))}else if(a.length)bad.push("at+:"+r.k)})}
console.log(c("after-imports")+"|"+c("top")+"|"+bad.join(";"))' "$JA" "$TMP/fja.json")"

# 首页 modules 行 lines 格（data-k=lines）：显示的字照 D 节取整规矩（不到 100 行；模块取一位有效数字，约 N 行 / 约 N 千行 / 约 N 万行）从事实里该模块的行数算出，不手抄期望
lc() { nj 'const [R,F]=process.argv.slice(1),A=JSON.parse(fs.readFileSync(F)).arch,h=fs.readFileSync(R+"/docs/readable/arch/index.html","utf8"),bad=[];
const fm=n=>{if(n<100)return"不到 100 行";const e=Math.pow(10,Math.floor(Math.log10(n))),v=Math.round(n/e)*e;return v>=1e4?"约 "+v/1e4+" 万行":v>=1e3?"约 "+v/1e3+" 千行":"约 "+v+" 行"};
H.rows(h).filter(r=>r.sec=="modules").forEach(r=>{const m=A.modules.find(x=>x.id==r.k),c=H.cells(r,"lines");if(!m||c.length!=1||c[0]!=fm(m.lines))bad.push(r.k+":"+c.join("/")+"!="+(m?fm(m.lines):"?"))});console.log(bad.length?bad.join(";"):"ok")' "$1" "$2"; }
# 20 打死：首页某一段为空时整个容器不出（核对器读不到、分不清「没有」与「页面把这段丢了」）/ 首页模块行与未归属、没人引用的文件行显示的字与 data-row 不同
eq "架构首页（无环、无运行时引用的夹具）有 data-section 为 cycles / big / idle / unresolved / dynamic / skipped / problems 的容器，空的照样在；modules 行显示的 id（data-k=module）、unassigned 与 idle 行显示的路径（data-k=key）都等于 data-row（idle 非空）；modules 行 data-k=lines 格显示的字等于照取整规矩由事实里模块行数算出的写法（夹具 B 全是「不到 100 行」，夹具 Q 里有 约 1 千行 与 约 5 千行）" "|3|1|y|ok|ok" \
  "$(nj 'const R=process.argv[1],h=fs.readFileSync(R+"/docs/readable/arch/index.html","utf8"),have=new Set([...h.matchAll(/data-section="(\w+)"/g)].map(m=>m[1])),miss=["cycles","big","idle","unresolved","dynamic","skipped","problems"].filter(s=>!have.has(s)),rs=H.rows(h),bad=[],S=s=>rs.filter(r=>r.sec==s);
S("modules").forEach(r=>{if(H.cells(r,"module").join()!=r.k)bad.push("mod:"+r.k)});["unassigned","idle"].forEach(s=>S(s).forEach(r=>{if(H.cells(r,"key").join()!=r.k)bad.push(s+":"+r.k)}));
console.log(miss.join(",")+(bad.length?"!"+bad.join(";"):"")+"|"+S("modules").length+"|"+S("unassigned").length+"|"+(S("idle").length>0?"y":"n"))' "$B")""|$(lc "$B" "$FJ")|$(lc "$Q" "$TMP/fq.json")"

# 21 打死：拼不出完整路径的接口没带 why 格（读者与核对器看不到原因）/ 两种原因的话说串 / 拼得出的也带 why / 接口总表与模块页只标一处
W="$TMP/wy"; cp -r "$B" "$W"; R=$W
w app/api/extra.py 'from fastapi import FastAPI, APIRouter' 'lone = APIRouter(prefix="/lone")' '@lone.get("/a")' 'def lone_h(): pass' 'app = FastAPI()' 'rr = APIRouter(prefix="/r")' '@rr.get(f"/dyn/{KIND}")' 'def dyn_h(): pass' 'app.include_router(rr)' '@app.get("/ok")' 'def ok_h(): pass'
bd "$W"; nd build --facts-json --root "$W" >"$TMP/fw.json" 2>/dev/null || true
eq "没挂载的路由器上的 lone_h（完整路径 null）、前缀是 f 串的 dyn_h（完整路径 null）：模块页 api 与接口总表上，lone_h 行的 data-k=why 格含「没找到它挂在哪，前面可能还有一段前缀」、dyn_h 行的含「前缀是运行时定的」、拼得出的 ok_h 行没有 why 格（两页共 6 行）" "lone_h:null,dyn_h:null,ok_h:/ok|6|" \
  "$(nj 'const [R,F]=process.argv.slice(1),f=JSON.parse(fs.readFileSync(F)),D=R+"/docs/readable/arch/",bad=[];let n=0;const hs=["lone_h","dyn_h","ok_h"],pre=f.code.routes.filter(r=>hs.includes(r.handler)).sort((a,b)=>hs.indexOf(a.handler)-hs.indexOf(b.handler)).map(r=>r.handler+":"+r.fullPath).join();
const want={lone_h:"没找到它挂在哪，前面可能还有一段前缀",dyn_h:"前缀是运行时定的",ok_h:null};
for(const pg of ["m-api.html","routes.html"]){const rs=H.rows(fs.readFileSync(D+pg,"utf8")).filter(r=>r.sec=="routes");for(const hn of hs){const r=rs.find(x=>H.cells(x,"handler").join()==hn);if(!r){bad.push(pg+":"+hn+":norow");continue}n++;const y=H.cells(r,"why");if(want[hn]===null){if(y.length)bad.push(pg+":"+hn+":why+")}else if(y.length!=1||!y[0].includes(want[hn]))bad.push(pg+":"+hn+":"+y.join("/"))}}
console.log(pre+"|"+n+"|"+bad.join(";"))' "$W" "$TMP/fw.json")"

# 22 打死：任一代码文件的行号漏进页面（词法切不动的文件、挂了两次的路由器、定义写在代码文件里的表，各是一条已知的漏口）
LN="$TMP/ln"; cp -r "$B" "$LN"; R=$LN
w app/api/odd.py 'x = 1' 's = """never closed' 'more'
w app/api/main2.py 'from fastapi import FastAPI, APIRouter' 'app = FastAPI()' 'r1 = APIRouter()' '@r1.get("/x")' 'def x(): pass' 'app.include_router(r1, prefix="/a")' 'app.include_router(r1, prefix="/b")'
w app/store/emb.py 'def f(cur):' '    cur.execute("CREATE TABLE emb_tbl (id int PRIMARY KEY)")'
sed -i 's#"ddl":\["sql/s.sql"\]#"ddl":["sql/s.sql","app/store/emb.py"]#' "$LN/docs/readable-src/config.json"
bd "$LN"; RB22=$RB; nd build --facts-json --root "$LN" >"$TMP/fl0.json" 2>/dev/null || true; HL0=$(hs "$LN")
for f in $(cd "$LN" && find app -name '*.py'); do { printf '\n\n\n'; cat "$LN/$f"; } >"$TMP/pad.tmp"; cp "$TMP/pad.tmp" "$LN/$f"; done
bd "$LN"; RB22b=$RB; nd build --facts-json --root "$LN" >"$TMP/fl1.json" 2>/dev/null || true; HL1=$(hs "$LN")
eq "夹具里有切不动的 odd.py（进没扫成）、挂了两次的路由器（第二处进没解析到的引用）、ddl 里列了的 emb.py 里定义的 emb_tbl；全部代码文件顶上各加三个空行重出：两次 build 都 0、事实里的行号确实变了、整个 docs/readable 逐字节不变（夹具总行数加完仍不到 90，不挨着「约 N 行」的进位边）" "0|0|y|y|y|differs|same|y" \
  "$RB22|$RB22b|$(nj 'const f=JSON.parse(fs.readFileSync(process.argv[1]));console.log(f.unscanned.some(e=>e.file=="app/api/odd.py")?"y":"n")' "$TMP/fl0.json")|$(nj 'const f=JSON.parse(fs.readFileSync(process.argv[1]));console.log(f.code.unresolved.some(e=>e.file=="app/api/main2.py")?"y":"n")' "$TMP/fl0.json")|$(nj 'const f=JSON.parse(fs.readFileSync(process.argv[1]));console.log(f.tables.some(t=>t.name=="emb_tbl")?"y":"n")' "$TMP/fl0.json")|$([ "$(sha256sum <"$TMP/fl0.json")" != "$(sha256sum <"$TMP/fl1.json")" ] && echo differs || echo same)|$([ "$HL0" = "$HL1" ] && echo same || echo changed)|$(nj 'const f=JSON.parse(fs.readFileSync(process.argv[1]));console.log(f.code.files.reduce((a,x)=>a+x.lines,0)<90?"y":"n")' "$TMP/fl1.json")"

# 23 打死：核对器只比 data-row、不比显示的字（审查用三处突变实测：显示的路径写错，check 照报 0 条）
eq "手改核对·m-core 页 util.py 那一行显示的路径改一个字、data-row 不动：退出码 1、arch- 类问题只有 arch-mismatch 且点到 core（stale-page 另报，不算在内）" "1|arch-mismatch|true" "$(mut x 'const p=process.argv[1]+"/docs/readable/arch/m-core.html",h=fs.readFileSync(p,"utf8"),r=H.rows(h).find(x=>x.sec=="files"&&x.k=="app/core/util.py");if(!r)console.log("NOROW");else{const c=r.html.match(H.cellRe("key"));if(!c)console.log("NOKEY");else{const nr=r.html.replace(c[0],()=>c[0].replace(c[3],()=>c[3].replace("util","utix")));if(nr===r.html)console.log("NOMUT");else fs.writeFileSync(p,h.replace(r.html,()=>nr))}}' core)"
echo "===== 汇总：PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" -eq 0 ]
