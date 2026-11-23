// code-routes.mjs —— 代码里的 HTTP 接口：方法、路径、一路拼出来的完整路径、处理函数与它的说明（第三期契约 docs/readable-spec/phase3-arch-contract.md B 节「接口」）。
// 为什么有它：前端的人拿着页面上调的地址来找是哪个文件哪个函数，测试的人拿它列用例（需求 REQ-DOC-002）。
// 最贵的错是完整路径少一段前缀而不自知——照着地址去调是 404，照着清单以为没有这个接口。所以拼不准的记 null，
// 找不到乙又会少前缀的挂载进「没解析到的引用」，不给猜的地址。其次是漏接口：隔着别的装饰器、路径写成 path=、async def 都照认。
// 只认装饰器写法（FastAPI 与同样写法的框架），只在 code-lex.mjs 切出的「代码」里认——字符串、注释、文档串里长得像的不算；不跑被扫的代码。
// 乙是哪个文件里的路由器，用 code-resolve.mjs 解析引用，与引用边同一个口径。
// 实数（2026-11-23，一个下游后端）：路由装饰器 226 处、分在 60 个文件里；include_router 61 处、都不带前缀；路径不是字面量的 17 处，
// 其中 15 处用的是同文件只赋过一次的字符串常量、2 处是从别的文件引进来的这种常量（或它加字面量）——都按值算（契约 B 节），别的记 null。
import { readFileSync } from 'node:fs';
import { join, posix } from 'node:path';
import { cmp } from '../model.mjs';
import { Unclosed, sticky, split } from './code-lex.mjs';
import { langOf, resolver, PY_NAME, PY_DOTTED, PY_IMPORT, PY_FROM, dotted, pyStatements, cleandoc } from './code-resolve.mjs';

const N = PY_NAME, W = '[\\w\\u0080-\\uffff]';
// @<名字>.<方法>( ——行首（缩进照认）才是装饰器；<名字>可以带点（@api.router.get）。
const DECO = new RegExp(`(?:^|\\n)[ \\t]*@[ \\t]*(${PY_DOTTED})[ \\t]*\\.[ \\t]*(get|post|put|delete|patch|head|options|api_route|websocket)[ \\t]*\\(`, 'g');
// <名字> = APIRouter( / FastAPI(（可带类型标注、可写成 fastapi.APIRouter）。else: / try: 这类关键字后面紧跟冒号的不是标注。
const DEF = new RegExp(`(?:^|\\n)([ \\t]*)(${N})[ \\t]*(?::[^=\\n]*)?=(?!=)[ \\t]*(?:${N}[ \\t]*\\.[ \\t]*)*(?:APIRouter|FastAPI)[ \\t]*\\(`, 'g');
const MOUNT = new RegExp(`(?<![\\w.\\u0080-\\uffff])(${PY_DOTTED})[ \\t]*\\.[ \\t]*include_router[ \\t]*\\(`, 'g');
const CONST = new RegExp(`(?:^|\\n)(${N})[ \\t]*(?::[^=\\n]*)?=(?!=)[ \\t]*`, 'g'); // 模块级（不缩进）的赋值
const HANDLER = new RegExp(`(?:async[ \\t]+)?def[ \\t]+(${N})[ \\t]*\\(`, 'y');
const KWARG = new RegExp(`(${N})\\s*=(?!=)\\s*`, 'y');
const AS_IMPORT = new RegExp(`^(${PY_DOTTED})(?:\\s+as\\s+(${N}))?$`);
const AS_FROM = new RegExp(`^(${N})(?:\\s+as\\s+(${N}))?$`);
const NAME_CHAIN = new RegExp(`^${N}(?:\\.${N})*$`);
const KW = new Set(['else', 'try', 'finally', 'except']);

// ---- 切分：配对的括号、顶层的逗号与加号 ----
function matchClose(o, open) {
  for (let d = 0, k = open; k < o.length; k++) { const c = o[k]; if (c === '(' || c === '[' || c === '{') d++; else if ((c === ')' || c === ']' || c === '}') && --d === 0) return k; }
  return o.length;
}
function splitTop(o, s, e, sep) { // [[起, 止]]，两头的空白已去掉
  const out = [];
  const push = (a, b) => { a += sticky(/\s*/y, o, a).length; while (b > a && /\s/.test(o[b - 1])) b--; out.push([a, b]); };
  let d = 0, a = s;
  for (let k = s; k < e; k++) {
    const c = o[k];
    if (c === '(' || c === '[' || c === '{') d++; else if (c === ')' || c === ']' || c === '}') d--;
    else if (c === sep && d === 0) { push(a, k); a = k + 1; }
  }
  push(a, e);
  return out;
}
function callArgs(o, open) { // 调用的实参：{ kw: 关键字名 | null（位置参数）| '*'（*args、**kw）, s, e }，s 是值的起点
  const close = matchClose(o, open), args = [];
  for (const [s, e] of splitTop(o, open + 1, close, ',')) {
    if (s >= e) continue;
    KWARG.lastIndex = s;
    const k = KWARG.exec(o);
    args.push(k && KWARG.lastIndex <= e ? { kw: k[1], s: KWARG.lastIndex, e } : { kw: o[s] === '*' ? '*' : null, s, e });
  }
  return { args, close };
}

// ---- 值：字面量、同文件模块级只赋过一次的字符串常量、它们用 + 拼起来的 ----
function litOf({ src, sp }, a, b) { // 正好是一个字符串字面量（f 串、b 串不算）时返回原文，否则 null
  const l = sp.byStart.get(a);
  if (!l || l.end !== b || /[fb]/i.test(src.slice(l.start, l.bs).replace(/["']/g, ''))) return null;
  return src.slice(l.bs, l.be);
}
function strVal(ctx, s, e) {
  let out = '';
  for (const [a, b] of splitTop(ctx.o, s, e, '+')) {
    const v = a < b ? litOf(ctx, a, b) ?? constOf(ctx, ctx.o.slice(a, b)) : undefined;
    if (v == null) return null;
    out += v;
  }
  return out;
}
// 同文件的常量；不是的话，从别的文件引进来的跟一层：那个文件里它是模块级只赋过一次的字符串字面量才算，那边又是引进来的不再跟（契约 B 节）。
function constOf(ctx, n) {
  if (ctx.consts.has(n)) return ctx.consts.get(n);
  const t = one(ctx.bind.get(n));
  return t?.file ? ctx.info.get(t.file)?.consts.get(t.name) : undefined;
}
// 契约 B 节：模块级只赋值过一次、赋的是一个字符串字面量。别处（函数里、关键字实参、+=、global 里）再出现「名字 =」的算不准——宁可记 null；
// 由 import 引进来的不算本文件的常量，由 constOf 跟到那个文件去查。
function constsOf(ctx) {
  const { o, sp } = ctx, seen = new Map(), res = new Map();
  for (const m of o.matchAll(CONST)) {
    if (KW.has(m[1])) continue;
    const p = m.index + m[0].length, l = sp.byStart.get(p);
    const v = l && sticky(/[ \t]*(?:\r?\n|;|$)/y, o, l.end) !== null ? litOf(ctx, p, l.end) : null;
    seen.set(m[1], [...(seen.get(m[1]) ?? []), v]);
  }
  for (const [n, vs] of seen) {
    if (vs.length !== 1 || vs[0] === null || ctx.bind.has(n)) continue;
    const assigns = o.match(new RegExp(`(?<![\\w.\\u0080-\\uffff])${n}[ \\t]*(?::[^=\\n]*)?(?:[-+*/%@&|^]|//|\\*\\*|>>|<<)?=(?!=)`, 'g')) ?? [];
    if (assigns.length !== 1 || new RegExp(`(?:^|\\n)[ \\t]*global[ \\t][^\\n]*(?<!${W})${n}(?!${W})`).test(o)) continue;
    res.set(n, vs[0]);
  }
  return res;
}

// ---- 引进来的名字：本地名 → { mod: 文件 } | { file, name } | { pkg: [import a.b 的各段] } | {}（外部的、没对上的）----
// 解析的口径同 code-imports.mjs 的 pyAbs / pyRel：from 包 import 子模块时指向子模块文件。
function bindingsOf(file, o, R) {
  const bind = new Map(), put = (n, t) => bind.set(n, [...(bind.get(n) ?? []), t]);
  const dir = posix.dirname(file) === '.' ? [] : posix.dirname(file).split('/');
  for (const [s, e] of pyStatements(o)) {
    const t = o.slice(s, e).replace(/\\\r?\n/g, ' ').trim();
    let m = PY_IMPORT.exec(t);
    if (m) {
      for (const x of m[1].split(',')) {
        const i = AS_IMPORT.exec(x.trim()); if (!i) continue;
        const parts = dotted(i[1]), h = i[2] && R.longest(parts);
        if (!i[2]) put(parts[0], { pkg: parts }); else put(i[2], h && h.j === parts.length ? { mod: h.f } : {});
      }
      continue;
    }
    if (!(m = PY_FROM.exec(t))) continue;
    const dots = m[1].length, parts = m[2] ? dotted(m[2]) : [];
    if (dots - 1 > dir.length) continue;
    const base = dots ? dir.slice(0, dir.length - (dots - 1)).join('/') : null;
    for (const x of m[3].trim().replace(/^\(|\)$/g, '').split(',')) {
      const i = AS_FROM.exec(x.trim()); if (!i) continue;
      let to = {};
      if (base !== null) { const sub = R.pyFile(base, [...parts, i[1]]), mod = R.pyFile(base, parts); to = sub ? { mod: sub } : mod ? { file: mod, name: i[1] } : {}; }
      else { const h = R.longest([...parts, i[1]]); to = !h ? {} : h.j > parts.length ? { mod: h.f } : h.j === parts.length ? { file: h.f, name: i[1] } : {}; }
      put(i[2] ?? i[1], to);
    }
  }
  return bind;
}
const one = (ts) => ts && (ts.every((t) => JSON.stringify(t) === JSON.stringify(ts[0])) ? ts[0] : {}); // try / except 两路引进同一个才算数

// 缩进进去的路由器（写在函数里的）只管到它所在的块结束：其后第一行缩进比它浅的代码。字符串整段抹掉再数，免得多行串的收尾引号被当成缩进。
function blockEnd(ctx, from, indent) {
  if (ctx.flat === undefined) { let r = '', p = 0; for (const l of ctx.sp.lits) { r += ctx.o.slice(p, l.start) + ctx.o.slice(l.start, l.end).replace(/[^\n]/g, ' '); p = l.end; } ctx.flat = r + ctx.o.slice(p); }
  const o = ctx.flat;
  for (let d = 0, k = from; k < o.length; k++) {
    const c = o[k];
    if (c === '(' || c === '[' || c === '{') d++; else if (c === ')' || c === ']' || c === '}') d = Math.max(0, d - 1);
    else if (c === '\\' && o[k + 1] === '\n') k++;
    else if (c === '\n' && d === 0) { const w = sticky(/[ \t]*/y, o, k + 1), n = o[k + 1 + w.length]; if (n !== undefined && n !== '\n' && n !== '\r' && w.length < indent) return k + 1; }
  }
  return o.length;
}

// 装饰器之后（隔着别的装饰器照跳）的 def / async def：{ name, body: 函数体起点 }；不是函数的返回 null。
function handlerAfter(o, close) {
  let k = o.indexOf('\n', close);
  for (;;) {
    if (k < 0) return null;
    k += sticky(/\s*/y, o, k).length;
    if (o[k] !== '@') break;
    for (let d = 0; k < o.length; k++) { const c = o[k]; if (c === '(' || c === '[' || c === '{') d++; else if (c === ')' || c === ']' || c === '}') d--; else if (c === '\n' && d <= 0) break; }
  }
  HANDLER.lastIndex = k;
  const m = HANDLER.exec(o);
  if (!m) return null;
  let p = matchClose(o, HANDLER.lastIndex - 1) + 1;
  for (let d = 0; p < o.length && !(o[p] === ':' && d === 0); p++) { const c = o[p]; if (c === '(' || c === '[' || c === '{') d++; else if (c === ')' || c === ']' || c === '}') d--; }
  return { name: m[1], body: p + 1 };
}
// 函数体第一条语句是字符串字面量时的说明：与文件头说明同一个取法（紧挨着的字面量算一个，f 串、b 串不算，统一缩进同 inspect.cleandoc）。
function docAt({ src, sp, o }, p) {
  p += sticky(/[ \t]*/y, o, p).length;
  if (o[p] === '\n' || o[p] === '\r') p += sticky(/\s*/y, o, p).length;
  let body = '', q = p, l;
  while ((l = sp.byStart.get(q))) {
    if (/[fb]/i.test(src.slice(l.start, l.bs).replace(/["']/g, ''))) return null;
    body += src.slice(l.bs, l.be);
    q = l.end + sticky(/[ \t]*/y, o, l.end).length;
  }
  if (q === p || (q < o.length && !/[\r\n;]/.test(o[q]))) return null;
  return cleandoc(body.split(/\r?\n/), true);
}

function parseFile(file, src, sp, R) { // 第一遍：引进来的名字与模块级字符串常量——第二遍算值时要跟到别的文件去查
  const o = sp.other, ctx = { file, src, sp, o, defs: [], decos: [], mounts: [] };
  ctx.bind = bindingsOf(file, o, R);
  ctx.consts = constsOf(ctx);
  return ctx;
}
function readRoutes(ctx, info) { // 第二遍：路由器、装饰器、挂载
  const { file, src, sp, o } = ctx;
  ctx.info = info;
  for (const m of o.matchAll(DEF)) {
    if (KW.has(m[2])) continue;
    const at = m.index + m[0].length - m[0].trimStart().length, open = m.index + m[0].length - 1, { args } = callArgs(o, open);
    const pf = args.find((x) => x.kw === 'prefix');
    const prefix = pf ? strVal(ctx, pf.s, pf.e) : args.some((x) => x.kw === '*') ? null : '';
    ctx.defs.push({ file, name: m[2], at, line: sp.lineAt(at), mod: !m[1], end: m[1] ? blockEnd(ctx, open, m[1].length) : Infinity, prefix, mount: null });
  }
  for (const m of o.matchAll(DECO)) {
    const at = m.index + m[0].indexOf('@'), kind = m[2], { args, close } = callArgs(o, m.index + m[0].length - 1);
    const pa = args[0]?.kw === null ? args[0] : args.find((x) => x.kw === 'path'), h = pa && handlerAfter(o, close);
    if (!h) continue;
    const value = strVal(ctx, pa.s, pa.e), ma = args.find((x) => x.kw === 'methods');
    // api_route 没写 methods 的是框架默认的 GET（契约 B 节，核过 FastAPI 源码）；写了而不是字面量清单的记 ANY
    let methods = [kind === 'websocket' ? 'WS' : kind === 'api_route' ? 'GET' : kind.toUpperCase()];
    if (kind === 'api_route' && ma) {
      const items = /^[[(]/.test(o[ma.s]) && matchClose(o, ma.s) === ma.e - 1 ? splitTop(o, ma.s + 1, ma.e - 1, ',').filter(([a, b]) => a < b) : [];
      const vs = items.map(([a, b]) => litOf(ctx, a, b));
      methods = vs.length && vs.every((v) => v !== null) ? [...new Set(vs.map((v) => v.toUpperCase()))] : ['ANY'];
    }
    ctx.decos.push({ at, line: sp.lineAt(at), recv: m[1].replace(/\s+/g, ''), methods, value, handler: h.name, doc: docAt(ctx, h.body),
      path: value ?? src.slice(pa.s, pa.e).replace(/\s*\r?\n\s*/g, ' ') });
  }
  for (const m of o.matchAll(MOUNT)) {
    const { args, close } = callArgs(o, m.index + m[0].length - 1);
    const ya = args[0]?.kw === null ? args[0] : args.find((x) => x.kw === 'router'), pf = args.find((x) => x.kw === 'prefix');
    const y = ya ? o.slice(ya.s, ya.e).replace(/\s+/g, '') : '';
    ctx.mounts.push({ file, at: m.index, line: sp.lineAt(m.index), parent: m[1].replace(/\s+/g, ''), child: NAME_CHAIN.test(y) ? y : null,
      prefix: pf ? strVal(ctx, pf.s, pf.e) : args.some((x) => x.kw === '*') ? null : '', text: src.slice(m.index, close + 1) });
  }
  return ctx;
}

// ---- 名字 → 路由器 ----
function exported(info, file, name, depth = 0) { // 别的文件模块级的路由器；那边也是引进来的就再跟一层（最多 5 层）
  const f = info.get(file);
  if (!f || depth > 5) return null;
  const ds = f.defs.filter((d) => d.mod && d.name === name);
  if (ds.length) return ds[ds.length - 1];
  const t = one(f.bind.get(name));
  return t?.file ? exported(info, t.file, t.name, depth + 1) : null;
}
function lookup(info, R, file, expr, at) {
  const f = info.get(file), parts = expr.split('.');
  const ds = f.defs.filter((d) => d.name === parts[0]);
  if (parts.length === 1) {
    const near = ds.filter((d) => d.at <= at && at < d.end).pop() ?? ds.find((d) => d.mod);
    if (near) return near;
  }
  if (ds.length) return null;
  const t = one(f.bind.get(parts[0]));
  if (parts.length === 1) return t?.file ? exported(info, t.file, t.name) : null;
  if (t?.mod && parts.length === 2) return exported(info, t.mod, parts[1]);
  if (!t?.pkg) return null;
  const chain = parts.slice(0, -1), h = R.longest(chain);
  return h && h.j === chain.length ? exported(info, h.f, parts[parts.length - 1]) : null;
}
// 一路挂载的前缀（从最外层起）+ 自己的前缀；哪一段算不准（不是字面量、挂到的甲认不出、挂成了环）就是 null。
function full(d, seen = new Set()) {
  if (d.prefix === null || seen.has(d)) return null;
  if (!d.mount) return d.prefix;
  seen.add(d);
  const m = d.mount, pp = m.p ? full(m.p, seen) : null;
  return pp === null || m.prefix === null ? null : pp + m.prefix + d.prefix;
}

// 填 code.routes；挂载没解析到、同一个路由器挂了多次的并进 code.unresolved（契约 B 节）。files 同 code-imports.mjs 的 extract。
export function addRoutes(code, config, root, files) {
  const R = resolver(root, config), info = new Map(), unresolved = [], lost = [];
  for (const file of files) {
    if (langOf(file) !== 'python') continue;
    const src = readFileSync(join(root, file), 'utf8');
    let sp;
    try { sp = split(file, src); } catch (e) { if (!(e instanceof Unclosed)) throw e; continue; } // 切不动的整个文件 code-imports.mjs 已在「没解析到的引用」里明说
    info.set(file, parseFile(file, src, sp, R));
  }
  for (const f of info.values()) readRoutes(f, info);
  const mounts = [...info.values()].flatMap((f) => f.mounts).sort((a, b) => cmp(a.file, b.file) || a.at - b.at);
  for (const m of mounts) {
    m.p = lookup(info, R, m.file, m.parent, m.at);
    const y = m.child && lookup(info, R, m.file, m.child, m.at);
    if (!y) lost.push(m);
    else if (y.mount) unresolved.push({ file: m.file, line: m.line, text: `${m.text}（同一个路由器挂了多次，只取第一处：${y.mount.file} 第 ${y.mount.line} 行）` });
    else y.mount = m;
  }
  // 乙找不到：这处挂载给它下面加的前缀（甲一路的前缀 + 挂载自己的）确定是空的才不报，别的都报——甲带前缀时同样会少一段。
  for (const m of lost) {
    if (m.prefix === '' && m.p && full(m.p) === '') continue;
    unresolved.push({ file: m.file, line: m.line, text: `${m.text}（有一处挂载没解析到，它下面的完整路径可能少一段前缀）` });
  }
  const routes = [];
  for (const f of info.values()) for (const x of f.decos) {
    const d = lookup(info, R, f.file, x.recv, x.at); // 主人不是 APIRouter / FastAPI 定义的路由器的（cache.get 一类）不是接口
    if (!d) continue;
    const fp = x.value === null ? null : full(d);
    for (const method of x.methods) routes.push({ file: f.file, line: x.line, method, path: x.path, fullPath: fp === null ? null : fp + x.value, handler: x.handler, doc: x.doc });
  }
  code.routes = routes.sort((a, b) => cmp(a.file, b.file) || a.line - b.line || cmp(a.method, b.method));
  code.unresolved = [...code.unresolved, ...unresolved].sort((a, b) => cmp(a.file, b.file) || a.line - b.line || cmp(a.text, b.text));
  return code;
}
