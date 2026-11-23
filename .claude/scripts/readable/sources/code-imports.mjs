// code-imports.mjs —— 代码文件的清单、文件头说明与文件之间的引用（第三期契约 docs/readable-spec/phase3-arch-contract.md B 节「文件」「引用」）。
// 为什么有它：接手的人看完数据库设计，第二步看架构；模块之间谁依赖谁、循环依赖、对外提供的名字，全从这里的边汇总（需求 REQ-DOC-002）。
// 错一条边，模块图上就多一条或少一条线：把字符串里的 import 当真（多报）与漏掉括号里换行的名字、上两层的相对引用（漏报）一样贵。
// 所以只在 code-lex.mjs 切出的「代码」里认引用语句——注释、字符串、文档串的正文在那里已抹成空格；读不出的进「没解析到的引用」
// 「运行时才定的引用」，不悄悄丢。不跑被扫的代码、不调语言自带的解析器，只读文本。
// 文件头说明是「来源里的注释」：原文照搬，只去掉引号与注释记号、统一缩进，不改写、不摘要（转义不解，\n 照原样两个字）。
// 实数（2026-11-23，一个下游项目）：后端两个 Python 代码根下非测试文件 371 个，文件之间的引用 1058 对；相对写法 806 处，
// 带项目全路径的与以代码根为起点的各三百多处；服务端 336 个文件里 332 个开头有说明，中位 191 个字。前端 484 个 TypeScript 文件，引用全是相对路径。
import { readFileSync } from 'node:fs';
import { join, posix } from 'node:path';
import { cmp } from '../model.mjs';
import { Unclosed, sticky, split, lineOf } from './code-lex.mjs';
// 认语句的位置、解析到文件、标准库名单与说明的统一缩进在 code-resolve.mjs，与认接口的 code-routes.mjs 共用一份（2026-11-23 Task 3.2 搬出）
import { langOf, PY_STDLIB, PY_NAME, PY_DOTTED, PY_IMPORT, PY_FROM, dotted, pyStatements, cleandoc, resolver } from './code-resolve.mjs';

export { langOf };

// ---- Python：引用语句 ----
const PY_IMPORT_ITEM = new RegExp(`^(${PY_DOTTED})(?:\\s+as\\s+${PY_NAME})?$`);
const PY_FROM_ITEM = new RegExp(`^(${PY_NAME})(?:\\s+as\\s+${PY_NAME})?$`);
const PY_DYN = /(?<![\w.\u0080-￿])(?:importlib\s*\.\s*)?(?:import_module|__import__)\s*\(/g;
const PY_MODULE = new RegExp(`^${PY_DOTTED}$`); // import_module 的字面量实参要像一个模块名才当 import 解析

// 一条语句 → 交给 pyAbs / pyRel；认不出写法的返回 false，由调用方记进「没解析到的引用」。
// what：null 是 import a.b（整个文件），'*' 是 from a import *，数组是点了名的名字（as 之前的原名）。
function pyStatement(t, line, text, rec) {
  let m = PY_IMPORT.exec(t);
  if (m) {
    const items = m[1].split(',').map((x) => PY_IMPORT_ITEM.exec(x.trim()));
    if (items.some((x) => !x)) return false;
    for (const x of items) rec.pyAbs(line, dotted(x[1]), null, text);
    return true;
  }
  if (!(m = PY_FROM.exec(t))) return false;
  const dots = m[1].length, parts = m[2] ? dotted(m[2]) : [];
  let rest = m[3].trim();
  if (!dots && !parts.length) return false;
  let what = '*';
  if (rest !== '*') {
    if (rest.startsWith('(')) { if (!rest.endsWith(')')) return false; rest = rest.slice(1, -1).trim().replace(/,$/, ''); }
    what = rest.split(',').map((x) => PY_FROM_ITEM.exec(x.trim())?.[1]);
    if (!what.length || what.some((x) => !x)) return false;
  }
  if (dots) rec.pyRel(line, dots, parts, what, text); else rec.pyAbs(line, parts, what, text);
  return true;
}

// 调用的第一个实参是不是字符串字面量（后面紧跟 ) 或 ,）：是就返回它的原文，不是返回 null。f 串、带 ${…} 的模板是运行时拼的，不算。
function callLiteral(src, sp, p) {
  const o = sp.other, l = sp.byStart.get(p + sticky(/\s*/y, o, p).length);
  if (!l) return null;
  const v = src.slice(l.bs, l.be), pre = src.slice(l.start, l.bs).replace(/["'`]/g, '');
  if (/[fb]/i.test(pre) || (src[l.start] === '`' && v.includes('${'))) return null;
  const q = l.end + sticky(/\s*/y, o, l.end).length;
  return o[q] === ')' || o[q] === ',' ? v : null;
}
function callEnd(o, open) { // 配对的 ) 之后；配不上就到那一行的行尾
  for (let d = 0, k = open; k < o.length; k++) { if (o[k] === '(') d++; else if (o[k] === ')' && --d === 0) return k + 1; }
  const e = o.indexOf('\n', open); return e < 0 ? o.length : e;
}

function pyRefs(src, sp, rec) {
  const o = sp.other;
  for (const [s, e] of pyStatements(o)) {
    let end = e; while (end > s && /\s/.test(o[end - 1])) end--;
    const line = sp.lineAt(s), text = src.slice(s, end);
    if (!pyStatement(o.slice(s, end).replace(/\\\r?\n/g, ' '), line, text, rec)) rec.unresolved(line, text);
  }
  // importlib.import_module(…)、__import__(…)：实参是字面量的当 import <它> 解析（相对写法要看 package 实参，算运行时定的）；别的进「运行时才定的引用」。
  for (const m of o.matchAll(PY_DYN)) {
    if (/\bdef\s+$/.test(o.slice(Math.max(0, m.index - 12), m.index))) continue;
    const open = m.index + m[0].length - 1, line = sp.lineAt(m.index), text = src.slice(m.index, callEnd(o, open));
    const v = callLiteral(src, sp, open + 1);
    if (v === null || v.startsWith('.') || !PY_MODULE.test(v)) rec.dynamic(line, text);
    else rec.pyAbs(line, dotted(v), null, text);
  }
}

// 文件头说明：第一条语句是字符串字面量（前面只有空行与注释——编码声明、#! 也是注释；o 里它们已是空格）。
// b 串、f 串不是说明（同 Python 自己的口径）；紧挨着的几个字面量是隐式拼接，算一个。统一缩进照 inspect.cleandoc 的做法。
function pyHead(src, sp) {
  const o = sp.other;
  let p = sticky(/\s*/y, o, 0).length, body = '', l;
  while ((l = sp.byStart.get(p))) {
    if (/[fb]/i.test(src.slice(l.start, l.bs).replace(/["']/g, ''))) return null;
    body += src.slice(l.bs, l.be);
    p = l.end + sticky(/[ \t]*/y, o, l.end).length;
  }
  if (p === sticky(/\s*/y, o, 0).length || (p < o.length && !/[\r\n;]/.test(o[p]))) return null;
  return cleandoc(body.split(/\r?\n/), true);
}

// 入口：代码里有 if __name__ == "__main__":（两边倒过来写的也认）。
function pyEntry(src, sp) {
  const o = sp.other, isMain = (p) => { const l = sp.byStart.get(p); return !!l && src.slice(l.bs, l.be) === '__main__' ? l : null; };
  for (const m of o.matchAll(/(?:^|\n)[ \t]*if[ \t(]+__name__\s*==\s*/g)) if (isMain(m.index + m[0].length)) return true;
  for (const m of o.matchAll(/(?:^|\n)[ \t]*if[ \t(]+(?=["'])/g)) {
    const l = isMain(m.index + m[0].length);
    if (l && sticky(/\s*==\s*__name__(?![\w\u0080-￿])/y, o, l.end)) return true;
  }
  return false;
}

// ---- JS 一族：引用语句 ----
// import … from '…'、import '…'、export … from '…'、require('…')、import('…')；import.meta 与别的 import 写法（TS 的 import x = 名字）不是引用。
// 模块名必须是切词认出的字面量：JSX 标签之间的文字里写着 import x from 'y' 的，那个 'y' 不是字面量，不算。
const JS_NAME = '[A-Za-z_$\\u0080-\\uffff][\\w$\\u0080-\\uffff]*';
const JS_KW = /(?<![\w$.\u0080-￿])(?:import|export|require)(?![\w$\u0080-￿])/g;
const JS_IMPORT = new RegExp(`\\s*(?:type\\s+)?(?:(${JS_NAME})\\s*,?\\s*)?(?:\\{([^}]*)\\}|(\\*)\\s*as\\s+${JS_NAME})?\\s*from\\s*(?=["'])`, 'y');
const JS_EXPORT = new RegExp(`\\s*(?:type\\s+)?(?:(\\*)(?:\\s*as\\s+${JS_NAME})?|\\{([^}]*)\\})\\s*from\\s*(?=["'])`, 'y');
const JS_SPEC_NAME = new RegExp(`^(?:type\\s+)?(${JS_NAME})`); // { a, b as c, type D } 里的一项：取 as 之前的原名
const braceNames = (s) => s.split(',').map((x) => JS_SPEC_NAME.exec(x.trim())?.[1]).filter(Boolean);

function jsRefs(src, sp, rec) {
  const o = sp.other;
  for (const m of o.matchAll(JS_KW)) {
    const kw = m[0], at = m.index, after = at + kw.length, line = sp.lineAt(at), call = sticky(/\s*\(/y, o, after) !== null;
    if (kw === 'require' && (!call || /\bfunction\s*$/.test(o.slice(Math.max(0, at - 20), at)))) continue;
    if (kw === 'require' || (kw === 'import' && call)) {
      const open = o.indexOf('(', after), text = src.slice(at, callEnd(o, open)), v = callLiteral(src, sp, open + 1);
      if (v === null) rec.dynamic(line, text); else rec.js(line, v, [], true, text);
      continue;
    }
    if (kw === 'import' && sticky(/\s*\./y, o, after) !== null) continue;
    let p, names = [], whole = false;
    const bare = kw === 'import' ? sticky(/\s*(?=["'])/y, o, after) : null;
    if (bare !== null) { p = after + bare.length; whole = true; }
    else {
      const re = kw === 'import' ? JS_IMPORT : JS_EXPORT, c = (re.lastIndex = after, re.exec(o));
      if (!c) continue;
      p = re.lastIndex;
      if (kw === 'import') {
        if (!c[1] && c[2] === undefined && !c[3]) continue;
        if (c[1]) names.push('default');
        if (c[2] !== undefined) names.push(...braceNames(c[2]));
        whole = !!c[3];
      } else if (c[1]) whole = true;
      else names = braceNames(c[2]);
    }
    const l = sp.byStart.get(p);
    if (!l || src[l.start] === '`') continue;
    rec.js(line, src.slice(l.bs, l.be), names, whole, src.slice(at, l.end));
  }
}

// 文件头说明：第一行代码之前的第一块注释——一个 /* … */，或连着的 // 行（空行就断）。#! 那一行跳过。
function jsHead(src) {
  let i = src.charCodeAt(0) === 0xfeff ? 1 : 0;
  if (src.startsWith('#!', i)) { const e = src.indexOf('\n', i); if (e < 0) return null; i = e + 1; }
  i += sticky(/\s*/y, src, i).length;
  if (src.startsWith('/*', i)) {
    const e = src.indexOf('*/', i + 2);
    if (e < 0) return null;
    const ls = src.slice(i + 2, e).replace(/^\*+/, '').split(/\r?\n/).map((x, k) => (k ? x.replace(/^[ \t]*\*(?!\/) ?/, '') : x).trimEnd());
    return cleandoc(ls, true);
  }
  const ls = [];
  for (const x of src.slice(i).split('\n')) { const m = /^[ \t]*\/\/(.*)$/.exec(x); if (!m) break; ls.push(m[1].trimEnd()); }
  return ls.length ? cleandoc(ls, false) : null;
}

// 一个文件的记录器：边并进全项目的 edges，外部包记在这个文件上，没解析到的与运行时定的进全项目的清单。
function recorder(R, file, res, edges, externals) {
  const edge = (to, line, names, whole, star) => {
    if (to === file) return; // 文件引用自己的不算
    const k = `${file}\n${to}`;
    if (!edges.has(k)) edges.set(k, { from: file, to, lines: new Set(), names: new Set(), whole: false, star: false });
    const e = edges.get(k);
    e.lines.add(line); names.forEach((n) => e.names.add(n)); e.whole ||= whole; e.star ||= star;
  };
  const unresolved = (line, text) => res.unresolved.push({ file, line, text });
  const pyExt = (pkg) => { if (!PY_STDLIB.has(pkg)) externals.add(pkg); };
  return {
    unresolved,
    dynamic: (line, text) => res.dynamic.push({ file, line, text }),
    // 不是相对写法：取最长前缀；from a import b 而 a/b 是文件的，指向它（整个文件）。一个都对不上的是外部包，只记第一段。
    // 同一条 from 里有的名字对上了、有的没对上的，没对上的那部分算没解析到——第一段是项目里的目录，不是外部包。
    pyAbs(line, parts, what, text) {
      if (what === null || what === '*') { const h = R.longest(parts); if (h) edge(h.f, line, [], what === null, what === '*'); else pyExt(parts[0]); return; }
      let hit = false, miss = false;
      for (const n of what) {
        const h = R.longest([...parts, n]);
        if (!h) { miss = true; continue; }
        hit = true;
        if (h.j > parts.length) edge(h.f, line, [], true, false); else edge(h.f, line, [n], false, false);
      }
      if (miss) { if (hit) unresolved(line, text); else pyExt(parts[0]); }
    },
    // 相对写法：一个点是本目录，每多一个点上一层；对不上文件的进「没解析到的引用」。
    pyRel(line, dots, parts, what, text) {
      const dir = posix.dirname(file) === '.' ? [] : posix.dirname(file).split('/');
      if (dots - 1 > dir.length) { unresolved(line, text); return; }
      const base = dir.slice(0, dir.length - (dots - 1)).join('/'), mod = R.pyFile(base, parts);
      if (what === '*') { if (mod) edge(mod, line, [], false, true); else unresolved(line, text); return; }
      let miss = false;
      for (const n of what) {
        const sub = R.pyFile(base, [...parts, n]);
        if (sub) edge(sub, line, [], true, false); else if (mod) edge(mod, line, [n], false, false); else miss = true;
      }
      if (miss) unresolved(line, text);
    },
    js(line, spec, names, whole, text) {
      const t = R.jsTarget(file, spec);
      if ('ext' in t) { if (t.ext) externals.add(t.ext); return; }
      if (t.asset) return;
      if (t.to) edge(t.to, line, names, whole, false); else unresolved(line, text);
    },
  };
}

const countLines = (src) => (src === '' ? 0 : src.split('\n').length - (src.endsWith('\n') ? 1 : 0));

// files：codeRoots 下去掉 ignore 的全部文件（不只代码文件，别的扩展名在这里按扩展名报数）。routes 在这里留空，由 code-routes.mjs 填。
export function extract(config, root, files) {
  const res = { files: [], edges: [], unresolved: [], dynamic: [], skipped: [], routes: [] };
  const R = resolver(root, config), edges = new Map(), skipped = new Map();
  for (const file of files) {
    const lang = langOf(file);
    if (!lang) { const x = posix.extname(file); skipped.set(x, (skipped.get(x) ?? 0) + 1); continue; }
    const src = readFileSync(join(root, file), 'utf8'), externals = new Set();
    const f = { path: file, lang, lines: countLines(src), head: null, entry: false, externals: [] };
    res.files.push(f);
    let sp;
    try { sp = split(file, src); }
    catch (e) {
      if (!(e instanceof Unclosed)) throw e;
      const line = lineOf(src, e.at); // 切不动的文件不出半截结果，明说在「没解析到的引用」里
      res.unresolved.push({ file, line, text: `第 ${line} 行起的${e.message}没有闭合，整个文件的引用与文件头说明都没读` });
      continue;
    }
    const rec = recorder(R, file, res, edges, externals);
    if (lang === 'python') { pyRefs(src, sp, rec); f.head = pyHead(src, sp); f.entry = pyEntry(src, sp); }
    else { jsRefs(src, sp, rec); f.head = jsHead(src); }
    f.externals = [...externals].sort(cmp);
  }
  res.files.sort((a, b) => cmp(a.path, b.path));
  res.edges = [...edges.values()].map((e) => ({
    from: e.from, to: e.to, lines: [...e.lines].sort((a, b) => a - b), names: [...e.names].sort(cmp), whole: e.whole, star: e.star,
  })).sort((a, b) => cmp(a.from, b.from) || cmp(a.to, b.to));
  const byLine = (a, b) => cmp(a.file, b.file) || a.line - b.line || cmp(a.text, b.text);
  res.unresolved.sort(byLine);
  res.dynamic.sort(byLine);
  res.skipped = [...skipped].map(([ext, count]) => ({ ext, count })).sort((a, b) => cmp(a.ext, b.ext));
  return res;
}
