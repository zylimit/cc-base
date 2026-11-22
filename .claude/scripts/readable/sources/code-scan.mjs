// code-scan.mjs —— 代码里的 SQL：谁写谁读、表名是运行时拼的、代码里建的表（契约 docs/readable-spec/phase1-db-contract.md F 节）。
// 先把源码切成字符串字面量与其它，只在字面量里认 SQL：注释、import 行里碰巧出现的表名不算——读者会照着去改一个不相干的文件，
// 这是这一层最贵的错之一；另一种是悄悄漏掉一类写法，所以切不动的文件整个进「没扫成的文件」，不出半截结果。
// 只出事实（文件、行、动作、名字）；写读归到哪张表、同名的别处的表怎么标、项目判断怎么套，在 links.mjs。
// 实数（2026-11-23，conflation 后端非测试代码）：SQL 全写在字符串里、关键字全大写——INSERT INTO 161 处、FROM 约 1287 处、
// JOIN 447 处，copy_records_to_table( 写表 11 处（表名常在下一行），表名运行时拼的 18 处。
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { excerpt } from '../model.mjs';
import { lex, statements } from './sql-lex.mjs'; // 只给 ddlSegments 切语句用，同建表定义的取事实器一个切法

export const isCodeFile = (f) => /\.(?:py|tsx?|jsx?|mjs)$/.test(f);
const isPy = (f) => /\.py$/.test(f);

class Unclosed extends Error { constructor(at, what) { super(what); this.at = at; } }
const sticky = (re, s, i) => { re.lastIndex = i; const m = re.exec(s); return m ? m[0] : null; };

// ---- 切字面量：Python ----
// 认单引号、双引号、三引号与 r / b / f / u 前缀（及 rb、fr 一类两字母组合），# 注释不算。
// 反斜杠在 r 串里也挡住紧跟的引号（r"\"" 是合法的一个串），所以两种串都跳过反斜杠后的那个字符。
// f 串的 {…} 数到配对的 }，里面的字符串照切（3.12 起可以复用外层的引号）；{{ 是字面的花括号。
const PY_ID = /[A-Za-z_\u0080-￿][\w\u0080-￿]*/y;
const PY_PREFIX = /^(?:[rRbBuUfF]|[rR][bBfF]|[bBfF][rR])$/;
function pyString(src, start, q, pre, out) {
  const ch = src[q], triple = src.startsWith(ch.repeat(3), q), close = triple ? ch.repeat(3) : ch;
  const fmt = /f/i.test(pre), bs = q + close.length;
  let k = bs;
  for (;;) {
    if (k >= src.length) throw new Unclosed(start, triple ? '三引号字符串' : '引号字符串');
    const c = src[k];
    if (c === '\\') { k += 2; continue; }
    if (!triple && c === '\n') throw new Unclosed(start, '引号字符串（到行尾还没闭合）');
    if (src.startsWith(close, k)) break;
    if (fmt && c === '{') { if (src[k + 1] === '{') k += 2; else k = pyExpr(src, k + 1, start); continue; }
    k++;
  }
  if (out) { out.lits.push({ start, bs, be: k, end: k + close.length }); out.mask.push([bs, k]); }
  return k + close.length;
}
function pyExpr(src, k, start) {
  for (let depth = 1; k < src.length;) {
    const c = src[k];
    if (c === '"' || c === "'") { k = pyString(src, k, k, '', null); continue; }
    if (c === '{') depth++;
    else if (c === '}' && --depth === 0) return k + 1;
    k++;
  }
  throw new Unclosed(start, 'f 串里的 {…}');
}
function lexPy(src) {
  const out = { lits: [], mask: [] }, n = src.length;
  for (let i = 0; i < n;) {
    const c = src[i];
    if (c === '#') { let e = src.indexOf('\n', i); if (e < 0) e = n; out.mask.push([i, e]); i = e; continue; }
    if (c === '"' || c === "'") { i = pyString(src, i, i, '', out); continue; }
    const w = sticky(PY_ID, src, i);
    if (!w) { i++; continue; }
    const q = src[i + w.length];
    if ((q === '"' || q === "'") && PY_PREFIX.test(w)) i = pyString(src, i, i + w.length, w, out);
    else i += w.length;
  }
  return out;
}

// ---- 切字面量：JS 一族（.js / .jsx / .mjs / .ts / .tsx）----
// 认单引号、双引号、反引号模板（${…} 里照切），// 与 /* */ 注释不算。正则字面量 /…/ 必须认出来，
// 否则 /'/ 这种会被当成一个没闭合的串：前一个记号是值（名字、数、右括号、串）时 / 是除号，否则试着按正则读到行尾，读不成再当除号。
// JSX 的闭合标签 </p> 里那个 / 不是正则的开头（JS 里 < 后面紧跟 / 只有这一种写法）——不认这条，组件文件的串全会切错位。
const JS_ID = /[A-Za-z_$\u0080-￿][\w$\u0080-￿]*/y;
const REGEX_AFTER = new Set(['return', 'typeof', 'instanceof', 'in', 'of', 'new', 'delete', 'void', 'throw', 'case', 'do', 'else', 'yield', 'await']);
function jsComment(src, i) {
  if (src[i + 1] === '/') { const e = src.indexOf('\n', i); return e < 0 ? src.length : e; }
  const e = src.indexOf('*/', i + 2); if (e < 0) throw new Unclosed(i, '块注释'); return e + 2;
}
function jsString(src, i, out) {
  const q = src[i];
  let k = i + 1;
  for (;;) {
    if (k >= src.length) throw new Unclosed(i, q === '`' ? '反引号模板' : '引号字符串');
    const c = src[k];
    if (c === '\\') { k += 2; continue; }
    if (c === q) break;
    if (q !== '`' && c === '\n') throw new Unclosed(i, '引号字符串（到行尾还没闭合）');
    if (q === '`' && c === '$' && src[k + 1] === '{') { k = jsScan(src, k + 2, null, i); continue; }
    k++;
  }
  if (out) { out.lits.push({ start: i, bs: i + 1, be: k, end: k + 1 }); out.mask.push([i + 1, k]); }
  return k + 1;
}
function jsRegex(src, i) { // 读成正则返回结尾，读不成（遇到换行或到头）返回 -1
  for (let k = i + 1, cls = false; k < src.length; k++) {
    const c = src[k];
    if (c === '\n') return -1;
    if (c === '\\') k++;
    else if (c === '[') cls = true;
    else if (c === ']') cls = false;
    else if (c === '/' && !cls) { k++; while (/[A-Za-z]/.test(src[k] ?? '')) k++; return k; }
  }
  return -1;
}
// 主循环；tpl 不为 null 时是在模板的 ${…} 里（tpl 是那个模板的起点），读到配对的 } 返回其后的位置。
// ${…} 里的串、注释、正则同样要认（真数据里有 ${s.replace(/[."]/g, …)} 这种），所以与外层共用一个循环；里面的字面量不单记。
function jsScan(src, i, out, tpl) {
  let prevVal = false, depth = 0, lastOp = '';
  while (i < src.length) {
    const c = src[i], d = src[i + 1];
    if (c === '/' && (d === '/' || d === '*')) { const e = jsComment(src, i); if (out) out.mask.push([i, e]); i = e; continue; }
    if (c === '"' || c === "'" || c === '`') { i = jsString(src, i, out); prevVal = true; continue; }
    if (c === '/' && !prevVal && lastOp !== '<') { const e = jsRegex(src, i); if (e > 0) { i = e; prevVal = true; continue; } }
    const w = sticky(JS_ID, src, i);
    if (w) { i += w.length; prevVal = !REGEX_AFTER.has(w); lastOp = ''; continue; }
    if (c >= '0' && c <= '9') { i += sticky(/[\w.]+/y, src, i).length; prevVal = true; lastOp = ''; continue; }
    if (c === '{') depth++;
    else if (c === '}' && tpl !== null && depth-- === 0) return i + 1;
    if (c === ')' || c === ']' || c === '}') prevVal = true;
    else if (c > ' ') prevVal = false;
    if (c > ' ') lastOp = c;
    i++;
  }
  if (tpl !== null) throw new Unclosed(tpl, '反引号模板里的 ${…}');
  return i;
}
function lexJs(src) {
  const out = { lits: [], mask: [] };
  jsScan(src, 0, out, null);
  return out;
}

// 切好的文件：字面量清单、把注释与字面量正文抹成空格的「其它」、按偏移查行号。切不动抛 Unclosed。
function split(file, src) {
  const { lits, mask } = isPy(file) ? lexPy(src) : lexJs(src);
  let other = '', p = 0;
  for (const [s, e] of mask) { other += src.slice(p, s) + src.slice(s, e).replace(/[^\n]/g, ' '); p = e; }
  other += src.slice(p);
  const nl = []; for (let k = src.indexOf('\n'); k >= 0; k = src.indexOf('\n', k + 1)) nl.push(k);
  const lineAt = (off) => { let lo = 0, hi = nl.length; while (lo < hi) { const m = (lo + hi) >> 1; if (nl[m] < off) lo = m + 1; else hi = m; } return lo + 1; };
  return { lits, other, lineAt, byStart: new Map(lits.map((l) => [l.start, l])) };
}
const lineOf = (src, off) => src.slice(0, off).split('\n').length;

// ---- 字面量里的 SQL ----
// 一个正则认全部动词，交替的先后让 DELETE FROM 先于 FROM 被认走（DELETE FROM 里的 FROM 不算读）。关键字不分大小写（别的项目的 SQL 可能是小写）。
const VERB = /\b(?:(INSERT\s+INTO)|(UPDATE)|(DELETE\s+FROM)|(TRUNCATE(?:\s+TABLE)?)|(COPY)|(MERGE\s+INTO)|(FROM)|(JOIN)|CREATE\s+(?:(?:GLOBAL|LOCAL)\s+)?(?:(TEMP|TEMPORARY)\s+|UNLOGGED\s+)?TABLE(?:\s+IF\s+NOT\s+EXISTS)?)(?![\w$])/gi;
const VERBS = ['insert', 'update', 'delete', 'truncate', 'copy', 'merge', 'select', 'select'];
// UPDATE 前面是这些词时不是「改表」：FOR [NO KEY] UPDATE 是加锁、ON CONFLICT … DO UPDATE SET 后面是 SET、ON UPDATE 是外键动作、触发器的 BEFORE / AFTER / OR / OF UPDATE。
const NOT_UPDATE = new Set(['FOR', 'KEY', 'DO', 'ON', 'BEFORE', 'AFTER', 'OR', 'OF']);
const NOT_FROM = new Set(['DISTINCT']); // IS [NOT] DISTINCT FROM 是比较，不是读表
const prevWord = (s, i) => /([A-Za-z_]+)\s*$/.exec(s.slice(Math.max(0, i - 40), i))?.[1].toUpperCase() ?? '';
const NAME_PART = /\\?"([^"\\]+)\\?"|([A-Za-z_\u0080-￿][\w$\u0080-￿]*)/y;
const DOT = /\s*\.\s*/y;
const fold = (s) => s.replace(/[A-Z]+/g, (x) => x.toLowerCase()); // 同 PostgreSQL：不带引号的名字只折 ASCII 字母

// 名字（可带双引号与模式前缀，前缀丢弃）：返回 {name, p}，不是名字返回 null。
function qname(s, p) {
  let name = null;
  for (;;) {
    NAME_PART.lastIndex = p; const m = NAME_PART.exec(s); if (!m) return name && { name, p };
    name = m[1] ?? fold(m[2]); p = NAME_PART.lastIndex;
    DOT.lastIndex = p; if (!DOT.exec(s)) return { name, p };
    p = DOT.lastIndex;
  }
}
// 占位：{…}（f 串与 .format）、${…}（模板）、%s、%(名)s。返回占位之后的位置，不是占位返回 -1。
function placeholder(s, p) {
  const b = s.startsWith('${', p) ? p + 1 : s[p] === '{' ? p : -1;
  if (b >= 0) { for (let k = b, d = 0; k < s.length; k++) { if (s[k] === '{') d++; else if (s[k] === '}' && --d === 0) return k + 1; } return s.length; }
  const m = sticky(/%(?:\([^)\s]*\))?s/y, s, p);
  return m ? p + m.length : -1;
}
// 动词后面的东西：{kind:'name',name,p} / {kind:'ph',p}（占位；占位后面紧跟 .名字 的是运行时的模式前缀，名字照认）/ {kind:'end'} / null
function target(s, p) {
  p += sticky(/\s*/y, s, p).length;
  const only = sticky(/ONLY\s+/iy, s, p); if (only) p += only.length;
  if (p >= s.length) return { kind: 'end' };
  const ph = placeholder(s, p);
  if (ph >= 0) {
    const dot = sticky(DOT, s, ph), r = dot && qname(s, ph + dot.length);
    return r ? { kind: 'name', ...r } : { kind: 'ph', p: ph };
  }
  const r = qname(s, p);
  return r && { kind: 'name', ...r };
}
const LIST_ALIAS = /\s*(?:(?:AS\s+)?(?!(?:WHERE|JOIN|INNER|LEFT|RIGHT|FULL|CROSS|NATURAL|ON|USING|GROUP|ORDER|LIMIT|OFFSET|UNION|EXCEPT|INTERSECT|WINDOW|HAVING|FOR|RETURNING|SET|VALUES|LATERAL)\b)[A-Za-z_][\w$]*)?\s*,/iy;
const COPY_FROM = /\s*(?:\([^)]*\)\s*)?FROM\b/iy;

// 一个文件的事实：refs（已知表的写读）、dynamic（表名运行时拼的）、creates（字面量里的 CREATE TABLE，带 temp 标记）。
function scanSplit(file, src, sp, known) {
  const refs = [], dynamic = [], creates = [];
  const flat = (a, b) => excerpt(src.slice(a, Math.min(b, a + 400)).replace(/\s+/g, ' ').trim());
  const ref = (off, verb, name, read) => { const t = known.get(name.toLowerCase()); if (t) refs.push({ file, line: sp.lineAt(off), verb, table: t, read }); };
  const dyn = (off, verb, lit) => dynamic.push({ file, line: sp.lineAt(off), verb, head: flat(lit.start, lit.end) });
  for (const lit of sp.lits) {
    const s = src.slice(lit.bs, lit.be);
    if (!/[A-Za-z]/.test(s)) continue;
    for (const m of s.matchAll(VERB)) {
      const k = m.slice(1, 9).findIndex((g) => g !== undefined), off = lit.bs + m.index, after = m.index + m[0].length;
      if (k < 0) { const t = target(s, after); if (t?.kind === 'name') creates.push({ file, line: sp.lineAt(off), name: t.name, temp: m[9] !== undefined }); continue; }
      const verb = VERBS[k], read = k >= 6;
      if (k === 1 && NOT_UPDATE.has(prevWord(s, m.index))) continue;
      if (k === 6 && NOT_FROM.has(prevWord(s, m.index))) continue;
      let t = target(s, after);
      if (t?.kind === 'end') {
        // 字面量到动词就结束：后面接 + 或紧挨着另一个字面量（Python 的隐式拼接）才算拼接；接的是字面量就接着在它开头认名字。
        // 别的（比如整个串就是 'update'、或者 … FOR UPDATE 收尾）不是在拼表名，不记。
        let p = lit.end + sticky(/(?:\s|\\\n)*/y, sp.other, lit.end).length;
        const plus = sp.other[p] === '+';
        if (plus) p += 1 + sticky(/(?:\s|\\\n)*/y, sp.other, p + 1).length;
        const nx = sp.byStart.get(p);
        if (!plus && !nx) continue;
        t = nx ? target(src.slice(nx.bs, nx.be), 0) : { kind: 'ph' };
        if (t?.kind === 'end') t = { kind: 'ph' };
        if (t) t.p = Infinity; // 名字在下一个字面量里：逗号续表、COPY 后面的 FROM 都不往下追
      }
      if (!t) continue;
      if (k === 4 && Number.isFinite(t.p) && !sticky(COPY_FROM, s, t.p)) continue; // 只认 COPY 表 FROM；COPY 表 TO 是导出
      if (t.kind === 'ph') { dyn(off, verb, lit); continue; }
      ref(off, verb, t.name, read);
      // FROM 后面逗号连着的几张表都算；TRUNCATE 可以一次清几张
      if (k !== 3 && k !== 6) continue;
      for (let p = t.p; p < s.length;) {
        const sep = k === 6 ? sticky(LIST_ALIAS, s, p) : sticky(/\s*,/y, s, p); if (!sep) break;
        const nt = target(s, p + sep.length); if (!nt || nt.kind === 'end') break;
        if (nt.kind === 'ph') { dyn(off, verb, lit); break; }
        ref(off, verb, nt.name, read); p = nt.p;
      }
    }
  }
  // 接口调用（写在代码里，不在字面量里）：第一个实参是字面量的算对那张表的写（copy_from_table 算读），不是字面量的进「运行时拼的」。
  for (const m of sp.other.matchAll(/\b(copy_records_to_table|copy_to_table|copy_from_table)\s*\(/g)) {
    let p = m.index + m[0].length;
    p += sticky(/\s*(?:table_name\s*=\s*)?/y, sp.other, p).length;
    const lit = sp.byStart.get(p), read = m[1] === 'copy_from_table', off = m.index;
    const t = lit && target(src.slice(lit.bs, lit.be), 0);
    if (t?.kind === 'name') ref(off, read ? 'select' : 'copy', t.name, read);
    else dynamic.push({ file, line: sp.lineAt(off), verb: read ? 'select' : 'copy', head: flat(off, src.indexOf(')', off) + 1 || src.length) });
  }
  return { refs, dynamic, creates };
}

// 架构稿 §2 的 extract：files 是 codeRoots 下去掉 ignore 的代码文件（入口列好），names 是建表定义里有的表名与视图名。
export function extract(config, root, files, names) {
  const known = new Map(names.map((n) => [n.toLowerCase(), n]));
  const res = { refs: [], dynamic: [], creates: [], unscanned: [] };
  for (const file of files) {
    const src = readFileSync(join(root, file), 'utf8');
    let sp;
    try { sp = split(file, src); }
    catch (e) {
      if (!(e instanceof Unclosed)) throw e;
      res.unscanned.push({ file, reason: `第 ${lineOf(src, e.at)} 行起的${e.message}没有闭合，整个文件没扫` });
      continue;
    }
    const r = scanSplit(file, src, sp, known);
    res.refs.push(...r.refs); res.dynamic.push(...r.dynamic); res.creates.push(...r.creates);
  }
  return res;
}

// 配置的 ddl 列了代码文件时（契约 F 节）：含 CREATE TABLE / ALTER TABLE / CREATE INDEX 的字面量切成语句，
// 只把以 CREATE TABLE / ALTER TABLE / CREATE [UNIQUE] INDEX 开头的语句交给建表定义的取事实器——一段说明文字里顺口提到这几个词的，
// 整段交过去只会在「未解析的语句」里平添一条噪声。别的语句原地换成空格（换行与分号留着）：行号、上方注释的归属与整段交时一样。
// 每段带上它在代码文件里起始的行号。切不动返回 error，由调用方记进「未解析的语句」。
const DDL_IN = /\b(?:CREATE\s+(?:UNIQUE\s+)?INDEX|CREATE\s+TABLE|ALTER\s+TABLE)\b/i;
const DDL_HEAD = [['CREATE', 'TABLE'], ['CREATE', 'INDEX'], ['CREATE', 'UNIQUE', 'INDEX'], ['ALTER', 'TABLE']];
export function ddlSegments(file, text) {
  let sp;
  try { sp = split(file, text); }
  catch (e) {
    if (!(e instanceof Unclosed)) throw e;
    const line = lineOf(text, e.at);
    return { segments: [], error: { line, text: excerpt(text.slice(e.at)), reason: `第 ${line} 行起的${e.message}没有闭合，这个代码文件里的建表定义都没读` } };
  }
  const segments = [];
  for (const l of sp.lits) {
    const s = text.slice(l.bs, l.be);
    if (!DDL_IN.test(s)) continue;
    const { toks, bad } = lex(s), sts = statements(toks);
    const isDdl = (st) => DDL_HEAD.some((h) => h.every((w, j) => st.a + j < st.b && toks[st.a + j].up === w));
    // 切词在一个没闭合的引号上停住、后面还有建表的字样：拿不准哪段是语句，整段照旧交过去，让「未解析的语句」露出来，不悄悄丢。
    if (bad && DDL_IN.test(s.slice(bad.s))) { segments.push({ file, text: s, startLine: sp.lineAt(l.bs) }); continue; }
    if (!sts.some(isDdl)) continue;
    let body = '', p = 0;
    for (const st of sts.filter((x) => !isDdl(x))) {
      const a = toks[st.a].s, b = toks[st.b - 1].e;
      body += s.slice(p, a) + s.slice(a, b).replace(/[^\n]/g, ' '); p = b;
    }
    segments.push({ file, text: body + s.slice(p), startLine: sp.lineAt(l.bs) });
  }
  return { segments, error: null };
}
