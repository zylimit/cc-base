#!/usr/bin/env bash
# risk: high
# test-readable-code-routes.sh — 人读文档 · 接口（装饰器路由）黑盒回归（docs/readable-spec/phase3-arch-contract.md B 节「接口」与 code.routes 形状）。
# 断言只从契约推导，入口 build --facts-json 的 code.routes / code.unresolved。夹具全是合成项目，mktemp -d + --root。
set -eu
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
ENGINE="${1:-$REPO_ROOT/.claude/scripts/readable-docs.mjs}"
echo "===== test-readable-code-routes ====="
if ! command -v node >/dev/null 2>&1; then echo "SKIPPED: 无 node，未执行 != 通过。"; exit 0; fi
[ -f "$ENGINE" ] || { echo "  [FAIL] 缺被测脚本：$ENGINE" >&2; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
eq() {  # eq <标题> <EXPECT> <GOT>
  if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; else FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$1"; fi
  printf '         EXPECT %s\n         GOT    %s\n' "$2" "$3"
}
facts() { RC=0; env -u CLAUDE_PROJECT_DIR node "$ENGINE" build --facts-json --root "$1" >"$2" 2>"$TMP/err" || RC=$?; }
jf() { node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const r=eval(process.argv[2]);console.log(typeof r==="string"?r:JSON.stringify(r))' "$1" "$2" 2>/dev/null || echo JSONERR; }
w() { local f=$1; shift; mkdir -p "$(dirname "$R/$f")"; printf '%s\n' "$@" >"$R/$f"; }
mkcfg() { mkdir -p "$1/docs/readable-src" "$1/sql"; : >"$1/Product-Spec.md"; echo 'CREATE TABLE t1 (id int PRIMARY KEY);' >"$1/sql/s.sql"
  printf '{"version":1,"title":"t","spec":"Product-Spec.md","ddl":["sql/s.sql"],"codeRoots":%s,"ignore":["**/tests/**"]}\n' "$2" >"$1/docs/readable-src/config.json"; }
X="d.code.routes.find(r=>r.handler=="   # 按处理函数名取一条（用法：$X'名')）
N() { echo "v=>v===null?'N':v"; }                                  # null 显成 N，undefined 不会

R="$TMP/m"; mkcfg "$R" '["app/api"]'
w app/api/orphan.py 'from fastapi import APIRouter' 'router = APIRouter(prefix="/api/jobs")' 'def deco(f): return f' '@router.post("/{id}/retry")' '@deco' 'async def retry_job(id):' '    """Retry the job once."""' '    return 1'
w app/api/jobs.py 'from fastapi import APIRouter' 'router = APIRouter(prefix="/api/jobs")' '@router.get("/list")' 'def list_jobs(): pass'
w app/api/users.py 'from fastapi import APIRouter' 'router = APIRouter(prefix="/users")' '@router.get("/me")' 'def me(): pass'
w app/api/main.py 'from fastapi import FastAPI' 'from . import jobs' 'from .users import router as users_router' 'app = FastAPI()' 'app.include_router(jobs.router, prefix="/v2")' 'app.include_router(users_router, prefix="/u")' 'app.include_router(mystery(), prefix="/x")' 'app.include_router(other())' '@app.get("/health")' 'def health(): pass'
w app/api/dyn.py 'from fastapi import APIRouter' 'router = APIRouter(prefix=API_PREFIX)' 'r2 = APIRouter(prefix="/lit")' '@router.get("/a")' 'def dyn_a(): pass' '@r2.get(PATH_VAR)' 'def dyn_b(): pass' '@r2.get("/ok")' 'def dyn_c(): pass'
w app/api/twice.py 'from fastapi import APIRouter' 'router = APIRouter(prefix="/tw")' '@router.get("/t")' 'def tw(): pass'
w app/api/main2.py 'from fastapi import FastAPI' 'from . import twice' 'app2 = FastAPI()' 'app2.include_router(twice.router, prefix="/first")' 'app2.include_router(twice.router, prefix="/second")'
w app/api/others.py 'from fastapi import APIRouter' 'router = APIRouter()' '@router.api_route("/x", methods=["GET", "POST"])' 'def multi(): pass' '@router.websocket("/ws")' 'async def sock(ws): pass' '@router.get(path="/kw")' 'def kw_one(): pass' '@router.api_route("/any", methods=METHODS)' 'def anyone(): pass' '@router.api_route("/dflt")' 'def dflt(): pass'
w app/api/fakes.py 'from fastapi import APIRouter' 'router = APIRouter(prefix="/f")' 'other = Thing()' 'cache = Cache()' 'X = """' '@router.get("/fake1")' '"""' '# @router.get("/fake2")' "S = '@router.get(\"/fake3\")'" 'cache.get("/k")' '@other.get("/x")' 'def not_a_route(): pass' '@router.get("/real")' 'def real(): pass'
w app/api/consts.py 'IMPORTED = "/imp"'
w app/api/vals.py 'from fastapi import APIRouter' 'from .consts import IMPORTED' 'BASE = "/sessions/{sid}"' 'TWICE = "/a"' 'TWICE = "/b"' 'PRE = "/pre"' 'BAD = make()' 'router = APIRouter(prefix=PRE)' 'r3 = APIRouter(prefix="/lit3")' 'def helper():' '    LOC = "/loc"' '@router.get(BASE + "/map")' 'def v_map(): pass' '@router.get(BASE)' 'def v_base(): pass' '@router.get("/lit")' 'def v_lit(): pass' '@r3.get(TWICE)' 'def v_twice(): pass' '@r3.get(BAD)' 'def v_call(): pass' '@r3.get(IMPORTED)' 'def v_imp(): pass' '@r3.get(LOC)' 'def v_loc(): pass'
w app/api/consts2.py 'from .consts import IMPORTED'
w app/api/consts3.py 'DUP = "/d"' 'DUP = "/e"'
w app/api/hop.py 'from fastapi import APIRouter' 'from .consts2 import IMPORTED' 'from .consts3 import DUP' 'router = APIRouter(prefix="/hop")' '@router.get(IMPORTED)' 'def v_hop(): pass' '@router.get(DUP)' 'def v_dup(): pass'
w app/api/child.py 'from fastapi import APIRouter' 'router = APIRouter(prefix="/leaf")' '@router.get("/x")' 'def nested_x(): pass'
w app/api/nest.py 'from fastapi import APIRouter, FastAPI' 'from . import child' 'parent = APIRouter(prefix="/p")' 'parent.include_router(child.router, prefix="/c")' 'app4 = FastAPI()' 'app4.include_router(parent, prefix="/v1")'
w app/api/nest2.py 'from fastapi import APIRouter, FastAPI' 'parent2 = APIRouter(prefix="/p2")' 'parent2.include_router(mystery())' 'app3 = FastAPI()' 'app3.include_router(mystery())'
w app/api/sjobs.py 'from fastapi import APIRouter' 'router = APIRouter(prefix="/sj")' '@router.get("/q")' 'def v_setup(): pass'
w app/api/setup.py 'from . import sjobs' 'def setup(app):' '    app.include_router(sjobs.router, prefix="/api")'
F="$TMP/m.json"; facts "$R" "$F"
eq "夹具能 build --facts-json（退出码 0，code.routes 是数组）" "0|true" "$RC|$(jf "$F" 'Array.isArray(d.code.routes)')"

# 1 打死：隔装饰器 / async def 的漏掉；方法不大写；path 与 fullPath 混；前缀没拼；doc 丢或带引号；file 错
eq "基本一条：orphan.py 的 retry_job（隔一个装饰器、async）→ 仅 1 条，POST、path、fullPath 拼上路由器前缀 /api/jobs、doc 原文、file" "1|POST|/{id}/retry|/api/jobs/{id}/retry|retry_job|Retry the job once.|app/api/orphan.py" "$(jf "$F" "(x=>x.length+'|'+x.map(r=>[r.method,r.path,r.fullPath,r.handler,r.doc,r.file].join('|')).join())(d.code.routes.filter(r=>r.handler=='retry_job'))")"
# 2 打死：include_router 前缀不拼 / 模块属性与 as 别名只认一种 / 没被挂的路由器也吃别人的前缀（orphan 与 jobs 同前缀同名 router）
eq "挂载带前缀：jobs.router 挂 /v2 → /v2/api/jobs/list；from .users import router as users_router 挂 /u → /u/users/me；对照 orphan 没被挂，仍是 /api/jobs/{id}/retry" "/v2/api/jobs/list /u/users/me /api/jobs/{id}/retry" "$(jf "$F" "['jobs','users','orphan'].map(f=>d.code.routes.filter(r=>r.file=='app/api/'+f+'.py').map(r=>r.fullPath).join()).join(' ')")"
# 3 打死：直接挂在应用对象上的路由漏掉或被拼上别的前缀
eq "@app.get(\"/health\") → GET /health" "GET /health" "$(jf "$F" "d.code.routes.filter(r=>r.handler=='health').map(r=>r.method+' '+r.fullPath).join()")"
# 4 打死：前缀 / 路径是变量时给一个猜的地址（或丢掉接口、或 path 不照写）；对照字面量的照常拼
eq "拼不出的记 null：前缀是从没赋过值的变量 → fullPath null、path 照写 /a；路径是变量 → fullPath null 且接口在；对照同文件字面量 /lit + /ok → /lit/ok" "N|/a|N|/lit/ok" "$(jf "$F" "[$X'dyn_a').fullPath,$X'dyn_a').path,$X'dyn_b').fullPath,$X'dyn_c').fullPath].map($(N)).join('|')")"
# 10 打死：同文件只赋一次的字符串常量不算（当成 null）/ 常量前缀不按值算 / + 拼接不认；以及见名字就硬算（赋两次、调用、别的文件引进来、只在函数里赋过）
eq "算得准的照算（含别的文件引进来跟一层的 IMPORTED → /imp）：BASE + \"/map\"、BASE、字面量 /lit 在 prefix=PRE（常量）的路由器下 → path 记算出的值，fullPath 拼上 /pre" "/sessions/{sid}/map>/pre/sessions/{sid}/map /sessions/{sid}>/pre/sessions/{sid} /lit>/pre/lit /imp>/lit3/imp" "$(jf "$F" "['v_map','v_base','v_lit','v_imp'].map(h=>$X h).path+'>'+$X h).fullPath).join(' ')")"
eq "算不准的仍 null：赋了两次 / 函数调用 / 转了两道手引进来 / 被引文件里赋了两次 / 只在函数里赋过 → fullPath null、path 含源码里的名字；对照同文件 v_map 的 fullPath 照常拼出" "N|true N|true N|true N|true N|true /pre/sessions/{sid}/map" "$(jf "$F" "['v_twice:TWICE','v_call:BAD','v_hop:IMPORTED','v_dup:DUP','v_loc:LOC'].map(s=>{const[h,n]=s.split(':'),r=$X h);return ($(N))(r.fullPath)+'|'+r.path.includes(n)}).join(' ')+' '+$X'v_map').fullPath")"
eq "挂载一路前缀：child（/leaf）→ parent 挂 /c（甲自己前缀 /p）→ app 挂 /v1 → /v1/p/c/leaf/x；甲是函数参数（setup(app)）→ 下面接口 fullPath null、path 照写" "/v1/p/c/leaf/x|N|/q" "$(jf "$F" "$X'nested_x').fullPath+'|'+($(N))($X'v_setup').fullPath)+'|'+$X'v_setup').path")"
eq "乙找不到：甲带前缀的 parent2.include_router(mystery())（nest2.py 第 3 行）要报；对照 app3.include_router(mystery())（第 5 行，确定为空）不报" "1|3" "$(jf "$F" "(u=>u.length+'|'+u.map(e=>e.line).join())(d.code.unresolved.filter(e=>e.file=='app/api/nest2.py'))")"
# 5 打死：挂载没解析到却悄悄吞掉；不带前缀的未解析挂载也报（多报）
eq "unresolved：mystery() 带前缀的挂载（main.py 第 7 行）进一条；other() 不带前缀的不多报一条" "1|7" "$(jf "$F" "(u=>u.length+'|'+u.map(e=>e.line).join())(d.code.unresolved.filter(e=>e.file=='app/api/main.py'))")"
# 6 打死：同一路由器挂两次拼了第二处 / 取最后一处 / 不报另一处
eq "挂两次：取先出现的 /first → /first/tw/t；第二处（main2.py 第 5 行）进 unresolved 且只此一条" "/first/tw/t|1|5" "$(jf "$F" "$X'tw').fullPath+'|'+d.code.unresolved.filter(e=>e.file=='app/api/main2.py').length+'|'+d.code.unresolved.filter(e=>e.file=='app/api/main2.py').map(e=>e.line).join()")"
# 7 打死：api_route 只出一条 / methods 非字面量不记 ANY / websocket 漏或方法不是 WS / path= 取不到
eq "别的写法：api_route methods=[GET,POST] → 两条各 /x；websocket → WS；methods=变量 → ANY；不写 methods → 恰一条 GET（不是 ANY）" "GET,POST|/x,/x|WS|ANY|1GET" "$(jf "$F" "(m=>m.map(r=>r.method).sort().join()+'|'+m.map(r=>r.fullPath).join()+'|'+$X'sock').method+'|'+$X'anyone').method+'|'+(q=>q.length+q[0].method)(d.code.routes.filter(r=>r.handler=='dflt')))(d.code.routes.filter(r=>r.handler=='multi'))")"
eq "path= 关键字取到 /kw；普通 def 照认；没有文档串 doc 为 null（不是空串）；对照 retry_job 的 doc 在" "/kw|N|1|Retry the job once." "$(jf "$F" "[$X'kw_one').path,$X'kw_one').doc].map($(N)).join('|')+'|'+d.code.routes.filter(r=>r.handler=='kw_one').length+'|'+$X'retry_job').doc")"
# 8 打死：文档串 / # 注释 / 字符串里的装饰器当真；非路由器对象的同名方法、调用当真
eq "不该算的：fakes.py 只有真的 /f/real 一条（文档串 / 注释 / 字符串 / cache.get / @other.get 都不算）；全项目共 26 条（对照：别处的真路由都在）" "/f/real|26" "$(jf "$F" "d.code.routes.filter(r=>r.file=='app/api/fakes.py').map(r=>r.fullPath).join()+'|'+d.code.routes.length")"
# 9 打死：乱序 / 方法小写 / 输出带时间；没路由的项目 routes 缺席或不是空数组
eq "清单形状：routes 按文件、行排序；方法全大写；共 26 条（非空转）" "true|true|26" "$(jf "$F" "(r=>r.every((x,i)=>i==0||r[i-1].file<x.file||(r[i-1].file==x.file&&r[i-1].line<=x.line))+'|'+r.every(x=>/^[A-Z]+\$/.test(x.method))+'|'+r.length)(d.code.routes)")"
facts "$R" "$TMP/m2.json"
eq "同一份输入两次 --facts-json 逐字节相同（且 routes 非空，非空转）" "same|true" "$(cmp -s "$F" "$TMP/m2.json" && echo same || echo differs)|$(jf "$F" 'd.code.routes.length>10')"
R="$TMP/e"; mkcfg "$R" '["app/api"]'; w app/api/plain.py 'cache = {}' 'cache.get("/z")' 'def f(): pass'; facts "$R" "$TMP/e.json"
eq "没有装饰器路由的项目：退出码 0，routes 是空数组（code.files 有 1 个文件，代码确实扫过）" "0|true|1" "$RC|$(jf "$TMP/e.json" "(Array.isArray(d.code.routes)&&d.code.routes.length==0)")|$(jf "$TMP/e.json" 'd.code.files.length')"
echo "===== 汇总：PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" -eq 0 ]
