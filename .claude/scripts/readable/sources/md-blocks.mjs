// md-blocks.mjs —— 需求规格的切块：把一份 Markdown 按先后切成一列块（契约 docs/readable-spec/phase2-spec-contract.md A、B 两节；架构稿 §6 场景 2）。
// 为什么自己切、不用现成的 Markdown 解析库：这一层最贵的错是悄悄丢字或串块。现成的库按渲染的口径归并空白、吃掉转义、
// 把认不出的写法折进别处，丢了什么不会告诉我们；这里只认契约里那七种块，别的写法一律按段落原样收下，宁可排得朴素也不少一个字。
// 切完当场跑还原自检（restore）：每块的文字连同切块时去掉的记号放回原位，必须逐行等于原文，对不上抛 SpecLoss（入口给退出码 3）。
// 自检只防丢字与串位；「把子项认成了续行」这类认错一个字没少，它看不出来，归测试夹具管。
import { existsSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { excerpt, fingerprint, nthAnchor, reqAnchor, specBoldAnchor, specSeqAnchor } from '../model.mjs';

// 切块对不上原文、或文件不是合法的 UTF-8：宁可整次不出，也不出半份（契约 B 节「切块不许丢字」）。
export class SpecLoss extends Error {}

const TAB = 4; // 制表符按 CommonMark 的口径推到下一个 4 的倍数列，「缩进更深」才比得出来
// 带 s 标志：. 不认 U+2028 之类的行内分隔符，不带的话含这种字符的标题、列表项会整行认不出来。
const HEADING = /^(#{1,6})([ \t]+)(.*)$/s;
// 契约：记号后面加空格。记号就在行尾的（「- 」被编辑器去掉了行尾空格只剩「-」）也认成空的列表项，同 CommonMark；
// 不认的话它成了一块文字是「-」的段落，还会把下面子项的树打断。
const LIST = /^([ \t]*)((?:[-*+]|\d{1,9}[.)])(?:[ \t]+|$))(.*)$/s;
const HR = /^[ \t]*(?:-{3,}|\*{3,})[ \t]*$/;
const TABLE = /^[ \t]*\|/;
const SEP = /^[ \t]*\|[|\-: \t]*$/;
const FENCE = /^[ \t]*(`{3,}|~{3,})(.*)$/s;
const FENCE_END = /^[ \t]*(`{3,}|~{3,})[ \t]*$/;
const REQ = /^\[(REQ-[^\]\s]+)\]/;
const BOLD = /^\*\*([^\n]+?)\*\*/; // 只看第一行：粗体词跨行的不当小标题

const blank = (s) => /^[ \t]*$/.test(s);
const lead = (s) => /^[ \t]*/.exec(s)[0];
function trail(s) { let e = s.length; while (e > 0 && (s[e - 1] === ' ' || s[e - 1] === '\t')) e--; return s.slice(e); }
function width(ws) { let w = 0; for (const ch of ws) w = ch === '\t' ? w + TAB - (w % TAB) : w + 1; return w; }

// 反引号围栏的起始行后面不许再有反引号（CommonMark 的规矩）：正文里一行以 ```a``` 开头的行内代码不是围栏。
function fenceOpen(s) {
  const m = FENCE.exec(s);
  if (!m || (m[1][0] === '`' && m[2].includes('`'))) return null;
  return { ch: m[1][0], len: m[1].length };
}
const fenceClose = (s, f) => { const m = FENCE_END.exec(s); return !!m && m[1][0] === f.ch && m[1].length >= f.len; };
const isSep = (s) => SEP.test(s) && s.includes('-');
const starts = (s) => !!fenceOpen(s) || HEADING.test(s) || HR.test(s) || LIST.test(s) || TABLE.test(s) || s[0] === '>';

// 一行表格：去掉行首缩进与第一根竖线，按没转义的竖线分格。格子两边的空白、行尾那根竖线记进 lay，格子文字里的 \| 换回 |。
// 竖线前面紧挨着反斜杠就是转义（\\| 也算），所以原文的格子里没有裸竖线，「\| 换 |、| 换回 \|」一来一回逐字相同。
function row(s) {
  const ind = lead(s), body = s.slice(ind.length + 1), parts = [];
  let from = 0;
  for (let k = 0; k < body.length; k++) if (body[k] === '|' && body[k - 1] !== '\\') { parts.push(body.slice(from, k)); from = k + 1; }
  parts.push(body.slice(from));
  const tail = parts.length > 1 && blank(parts.at(-1)) ? `|${parts.pop()}` : '';
  const seg = [], cells = [];
  for (const p of parts) {
    const l = lead(p), r = l.length === p.length ? '' : trail(p);
    seg.push({ l, r });
    cells.push(p.slice(l.length, p.length - r.length).replace(/\\\|/g, '|'));
  }
  return { cells, lay: { pre: `${ind}|`, seg, tail } };
}
const rowLine = (cells, lay) => lay.pre + cells.map((c, k) => lay.seg[k].l + c.replace(/\|/g, '\\|') + lay.seg[k].r).join('|') + lay.tail;

// 切块：一遍扫完，每块带 lay（被去掉的结构记号，只给还原自检用，不进输出）。行号在这里从 0 起，收尾时换成从 1 起。
function cut(lines) {
  const raw = [], heads = [], items = [];
  let i = 0;
  const add = (b) => { raw.push(b); if (b.kind !== 'list') items.length = 0; };
  while (i < lines.length) {
    const s = lines[i];
    if (blank(s)) { i++; continue; } // 空行不断列表的树：隔着空行的子项仍挂在上面那条下
    const path = heads.map((h) => h.title);
    const f = fenceOpen(s);
    let m;
    if (f) {
      // 没收尾的围栏一直算到文件末尾（同 CommonMark），里面的 # 与 - 都是围栏的原文。
      let j = i + 1;
      while (j < lines.length && !fenceClose(lines[j], f)) j++;
      const closed = j < lines.length;
      add({ kind: 'fence', line: i, endLine: closed ? j : j - 1, level: null, path, text: lines.slice(i + 1, j).join('\n'), lay: { open: s, close: closed ? lines[j] : null } });
      i = closed ? j + 1 : j;
    } else if ((m = HEADING.exec(s))) {
      const level = m[1].length;
      while (heads.length && heads.at(-1).level >= level) heads.pop();
      add({ kind: 'heading', line: i, endLine: i, level, path: heads.map((h) => h.title), text: m[3], lay: { pre: [m[1] + m[2]] } });
      heads.push({ level, title: m[3].trim() });
      i++;
    } else if (HR.test(s)) {
      add({ kind: 'hr', line: i, endLine: i, level: null, path, text: '', lay: { pre: [s] } });
      i++;
    } else if ((m = LIST.exec(s))) {
      // 续行：紧跟其后、缩进比这一条的记号更深、又不是新列表项（也不是围栏起始）的行；行首的缩进记进 lay，文字用换行接上。
      const w = width(m[1]), pre = [m[1] + m[2]], text = [m[3]];
      let j = i + 1;
      while (j < lines.length && !blank(lines[j]) && width(lead(lines[j])) > w && !LIST.test(lines[j]) && !fenceOpen(lines[j])) {
        const l = lead(lines[j]);
        pre.push(l); text.push(lines[j].slice(l.length)); j++;
      }
      while (items.length && items.at(-1).w >= w) items.pop();
      const b = { kind: 'list', line: i, endLine: j - 1, level: w, path, text: text.join('\n'), up: items.length ? items.at(-1).b : null, lay: { pre } };
      add(b); items.push({ w, b });
      i = j;
    } else if (TABLE.test(s)) {
      let j = i;
      while (j < lines.length && TABLE.test(lines[j])) j++;
      const head = j - i >= 2 && isSep(lines[i + 1]); // 只有第二行是分隔行才有表头；分隔行不成块，原文挂在表头那块的 lay 上
      for (let k = i; k < j; k++) {
        if (head && k === i + 1) continue;
        const r = row(lines[k]);
        add({ kind: 'table', line: k, endLine: k, level: null, path, text: r.cells.join(' | '), cells: r.cells, header: head && k === i, lay: { ...r.lay, sep: head && k === i ? lines[i + 1] : null } });
      }
      i = j;
    } else if (s[0] === '>') {
      const pre = [], text = [];
      let j = i;
      for (; j < lines.length && lines[j][0] === '>'; j++) { const p = lines[j][1] === ' ' ? '> ' : '>'; pre.push(p); text.push(lines[j].slice(p.length)); }
      add({ kind: 'quote', line: i, endLine: j - 1, level: null, path, text: text.join('\n'), lay: { pre } });
      i = j;
    } else {
      // 段落：别的非空行，连到空行或别的块开头为止；原文照收，缩进也是文字的一部分。
      let j = i + 1;
      while (j < lines.length && !blank(lines[j]) && !starts(lines[j])) j++;
      add({ kind: 'paragraph', line: i, endLine: j - 1, level: null, path, text: lines.slice(i, j).join('\n'), lay: { pre: Array(j - i).fill('') } });
      i = j;
    }
  }
  return raw;
}

// 指纹的规范形（契约 B 节）：种类加文字，换行统一、行尾空白去掉；出处与锚点不进，同第一期的口径。
const norm = (t) => t.replace(/\r\n?/g, '\n').split('\n').map((l) => l.trimEnd()).join('\n');

// 收尾：编号、锚点、指纹、章节。锚点按序取第一种能用的：[REQ-…] 编号 → 列表项开头的粗体词 → 本章里的序号；重了接 ~2、~3。
// 「本章里的序号」按章节路径数：路径相同的块共用一个计数，标题自己算在它上一级那章里。
function finalize(raw) {
  const seen = new Map(), ord = new Map();
  const blocks = raw.map((b, k) => {
    b.n = k + 1;
    const key = JSON.stringify(b.path), o = (ord.get(key) ?? 0) + 1;
    ord.set(key, o);
    const id = REQ.exec(b.text.trimStart()), bold = b.kind === 'list' ? BOLD.exec(b.text) : null, word = bold ? bold[1].trim() : '';
    const a = id ? reqAnchor(id[1]) : word ? specBoldAnchor(b.path, word) : specSeqAnchor(b.path, o);
    const c = (seen.get(a) ?? 0) + 1;
    seen.set(a, c);
    const out = { n: b.n, kind: b.kind, line: b.line + 1, endLine: b.endLine + 1, level: b.level, path: b.path, text: b.text };
    if (b.kind === 'table') { out.cells = b.cells; out.header = b.header; }
    out.parent = b.up ? b.up.n : null;
    out.anchor = nthAnchor(a, c);
    out.fingerprint = fingerprint({ kind: b.kind, text: norm(b.text) });
    return out;
  });
  // 章节：一个标题一章；blocks 是这一章里的块的序号（标题本身不算，下级标题连同它的内容都算），到下一个同级或更高级的标题为止。
  const sections = [], open = [];
  for (const b of blocks) {
    if (b.kind === 'heading') while (open.length && open.at(-1).level >= b.level) open.pop();
    for (const s of open) s.blocks.push(b.n);
    if (b.kind === 'heading') { const s = { title: b.text.trim(), level: b.level, n: b.n, blocks: [] }; sections.push(s); open.push(s); }
  }
  return { blocks, sections };
}

// 还原自检：只用输出里的 line / endLine / text / cells 加 lay 里的记号把原文拼回去，逐行比。
// 没落进任何一块的只许是空行（契约「空行的多少不计」）；一行被两块占、块的先后与行号对不上，都算错。
export function restore(lines, blocks, lays, label) {
  const out = new Array(lines.length).fill(null);
  let last = -1;
  const lose = (msg) => { throw new SpecLoss(`${label}切块对不上原文：${msg}`); };
  const put = (ln, s, b) => {
    const k = ln - 1;
    if (k <= last || k >= lines.length) lose(`第 ${b.n} 块（${b.kind}）落到第 ${ln} 行，与前面的块重叠、乱序或越出文件`);
    last = k; out[k] = s;
  };
  blocks.forEach((b, x) => {
    const lay = lays[x];
    if (b.n !== x + 1 || b.endLine < b.line) lose(`第 ${b.n} 块（${b.kind}）的序号或起止行不对（第 ${b.line}–${b.endLine} 行）`);
    if (b.kind === 'table') {
      if (b.cells.length !== lay.seg.length || b.text !== b.cells.join(' | ')) lose(`第 ${b.line} 行的表格行，格数或文字与分格对不上`);
      put(b.line, rowLine(b.cells, lay), b);
      if (lay.sep !== null) put(b.line + 1, lay.sep, b);
    } else if (b.kind === 'fence') {
      const inner = b.endLine - b.line - (lay.close === null ? 0 : 1), body = inner ? b.text.split('\n') : [];
      if (body.length !== inner || (!inner && b.text !== '')) lose(`第 ${b.line} 行起的围栏，里面的行数与起止行对不上`);
      put(b.line, lay.open, b);
      body.forEach((t, k) => put(b.line + 1 + k, t, b));
      if (lay.close !== null) put(b.endLine, lay.close, b);
    } else {
      const text = b.text.split('\n');
      if (text.length !== lay.pre.length || text.length !== b.endLine - b.line + 1) lose(`第 ${b.line} 行起的${b.kind}，文字的行数与起止行对不上`);
      text.forEach((t, k) => put(b.line + k, lay.pre[k] + t, b));
    }
  });
  lines.forEach((s, k) => {
    if (out[k] === null) { if (!blank(s)) lose(`第 ${k + 1} 行没有落进任何一块：「${excerpt(s)}」`); }
    else if (out[k] !== s) lose(diff(k + 1, Array.from(out[k]), Array.from(s)));
  });
}

// 点到第几个字开始不同：长行的开头往往一样，只给开头看不出丢在哪。按码点数，前面留 10 个字的上下文。
function diff(ln, got, want) {
  let d = 0;
  while (d < got.length && d < want.length && got[d] === want[d]) d++;
  const at = (a) => excerpt(a.slice(Math.max(0, d - 10)).join(''));
  return `第 ${ln} 行从第 ${d + 1} 个字起对不上（还原出 ${got.length} 个字，原文 ${want.length} 个字）：还原出来是「${at(got)}」，原文是「${at(want)}」`;
}

// 一份 Markdown 文本 → { blocks, sections }，还原自检过了才返回。开头的 BOM 不是字，先去掉；CRLF 与 LF 一样分行；
// 文件末尾的换行不另算一行，不然没收尾的围栏会多吞一个并不存在的空行。
export function chunk(src, label = '需求规格') {
  const lines = src.replace(/^﻿/, '').split(/\r?\n/);
  if (lines.length > 1 && lines.at(-1) === '') lines.pop();
  const raw = cut(lines), { blocks, sections } = finalize(raw);
  restore(lines, blocks, raw.map((b) => b.lay), label);
  return { blocks, sections };
}

// 取事实（契约 A 节）：配置的 spec 为 null 或文件不存在时没有这份文档，返回 null，不算错。
// 按严格的 UTF-8 解：坏字节默认会被换成替换符，那就是悄悄丢了字，宁可报错。
export function extract(cfg, root) {
  if (cfg.spec == null) return null;
  const abs = join(root, cfg.spec);
  if (!existsSync(abs) || !statSync(abs).isFile()) return null;
  let src;
  try { src = new TextDecoder('utf-8', { fatal: true }).decode(readFileSync(abs)); }
  catch (e) { if (e instanceof TypeError) throw new SpecLoss(`需求规格 ${cfg.spec} 不是合法的 UTF-8，不切块（${e.message}）`); throw e; }
  return { file: cfg.spec, ...chunk(src, `需求规格 ${cfg.spec} `) };
}
