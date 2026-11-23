// check-spec.mjs —— 核对的一项：需求规格一块不少、一字不差（第二期契约 docs/readable-spec/phase2-spec-contract.md D 节；规格 REQ-DOC-004、007）。
// 为什么单独一个文件：check.mjs 管数据库设计那几项已经够长；这一项的对齐算法自成一体，放在一起谁也读不完。
// 不信出页面的代码：入口重新切的块（facts.spec）与 check-read.mjs 从 spec/ 下各页读回的 data-block 逐块比。
// 架构稿 §3 禁边：这里不 import render/ 下的任何东西；去记号、认有序列表的规矩照契约自己写一份。
// 两边都压空白、去行内记号（plainMarks，核对器自己的一份）、过隐去规则之后比；围栏页面上原样显示，不去记号；表格行按格比；
// 有序列表的项连序号一起比——序号从页面上 data-k="marker" 读回来，与重新切块得到的 marker 比，无序的两边都没有序号。
// 认块靠文字不靠序号：来源里删了一条而没重出，后面几百块的序号全挪一位，按序号比会报几百条，按文字对齐只报多出来的那一块。
// 对齐用最长公共子序列（两头相同的先剥掉）；没对上的，别的空隙里有同样文字的是先后不对，同一段空隙里的一一配成文字不同，
// 配剩下的是缺的或多的。分句的断行是空标记、步骤图与打印用的那份引用不带 data-block，读回来的字不因排法变。
import { cmp } from './model.mjs';
import { redact } from './sensitive.mjs';
import { squash, specBlocks, plainMarks } from './check-read.mjs';

const SPEC_PAGE = /^spec\/s-(\d+)\.html$/; // 契约 C 节：文件名只用序号
const KIND = { heading: '标题', list: '列表项', table: '表格行', quote: '引用', fence: '围栏', hr: '分隔线', paragraph: '段落' };
const LCS_CAP = 4e6; // 中间对不上的两段块数之积超过它就不求公共子序列（四百万格约 16MB），按位置一一配
const ORDERED = /^\d{1,9}[.)]$/; // 有序列表的记号：数字加「.」或「)」（契约 B 节）；页面上只有它们显示序号
const specNorm = (s) => squash(redact(squash(s)).text);
const srcNorm = (kind, s) => { const r = redact(s).text; return specNorm(kind === 'fence' ? r : plainMarks(r)); };
const specKey = (text, cells, marker) => `${cells ? `T\u0001${cells.join('\u0001')}` : `B\u0001${text}`}${marker == null ? '' : `\u0002${marker}`}`;
const clip = (s, n = 30) => { const a = Array.from(s); return a.length > n ? `${a.slice(0, n).join('')}…` : s; };
function cpDiff(got, want) {
  const g = Array.from(got), w = Array.from(want);
  let i = 0;
  while (i < g.length && i < w.length && g[i] === w[i]) i++;
  const cut = (a) => `${i > 12 ? '…' : ''}${a.slice(Math.max(0, i - 12), i + 24).join('')}${a.length > i + 24 ? '…' : ''}`;
  return `第 ${i + 1} 个字起不同，页面上「${cut(g)}」，来源「${cut(w)}」`;
}
function lcs(a, b) {
  const pairs = [];
  let s = 0, e = 0;
  while (s < a.length && s < b.length && a[s] === b[s]) { pairs.push([s, s]); s++; }
  while (e < a.length - s && e < b.length - s && a[a.length - 1 - e] === b[b.length - 1 - e]) e++;
  const A = a.length - s - e, B = b.length - s - e;
  if (A && B && A * B <= LCS_CAP) {
    const W = B + 1, L = new Uint32Array((A + 1) * W);
    for (let i = A - 1; i >= 0; i--) for (let j = B - 1; j >= 0; j--) L[i * W + j] = a[s + i] === b[s + j] ? L[(i + 1) * W + j + 1] + 1 : Math.max(L[(i + 1) * W + j], L[i * W + j + 1]);
    for (let i = 0, j = 0; i < A && j < B;) {
      if (a[s + i] === b[s + j]) { pairs.push([s + i, s + j]); i++; j++; } else if (L[(i + 1) * W + j] >= L[i * W + j + 1]) i++; else j++;
    }
  }
  for (let k = e; k > 0; k--) pairs.push([a.length - k, b.length - k]);
  return pairs;
}
const range = (from, to) => Array.from({ length: Math.max(0, to - from) }, (_, k) => from + k);

// 一对配上的块哪里不同：序号不同先说序号，文字也不同再接着说文字；表格行点到第几格。
function what(s, p) {
  const mk = s.marker === p.marker ? '' : `序号：页面上是「${p.marker ?? '（没有）'}」，来源是「${s.marker ?? '（没有）'}」`;
  const same = s.cells && p.cells ? s.cells.length === p.cells.length && s.cells.every((c, x) => c === p.cells[x]) : s.text === p.text;
  if (same) return mk;
  let t;
  if (!s.cells || !p.cells) t = cpDiff(p.text, s.text);
  else if (s.cells.length !== p.cells.length) t = `页面上 ${p.cells.length} 格，来源 ${s.cells.length} 格`;
  else { const k = s.cells.findIndex((c, x) => c !== p.cells[x]); t = `第 ${k + 1} 格${cpDiff(p.cells[k], s.cells[k])}`; }
  return mk ? `${mk}；${t}` : t;
}

// rd：核对器的目录读取器（check.mjs 的 reader）；spec：重新切的块，没配需求规格的是 null；label：给人看的位置前缀。
export function specFacts(rd, spec, label) {
  const out = [];
  if (!spec) return { problems: out, read: 0 };
  const num = (rel) => { const m = SPEC_PAGE.exec(rel); return m ? Number(m[1]) : Infinity; };
  const rels = rd.html.filter((r) => r.startsWith('spec/')).sort((a, b) => num(a) - num(b) || cmp(a, b));
  const seen = new Map(), P = [];
  let read = 0;
  for (const rel of rels) {
    for (const b of specBlocks(rd.tree(rel))) {
      read++;
      const where = `${label}${rel} · 第 ${b.n} 块`;
      if (seen.has(b.n)) { out.push({ kind: 'spec-duplicate', where, detail: `第 ${b.n} 块在页面上不止一处（${seen.get(b.n)} 里已经有它）` }); continue; }
      seen.set(b.n, rel);
      const cells = b.cells ? b.cells.map(specNorm) : null, text = cells ? cells.join(' | ') : specNorm(b.text), marker = b.marker ?? null;
      P.push({ where, text, cells, marker, key: specKey(text, cells, marker) });
    }
  }
  const S = spec.blocks.map((b) => {
    const cells = b.kind === 'table' ? b.cells.map((c) => srcNorm(b.kind, c)) : null, text = cells ? cells.join(' | ') : srcNorm(b.kind, b.text);
    const marker = b.kind === 'list' && ORDERED.test(b.marker ?? '') ? b.marker : null;
    return { where: `${label}spec/ · 来源 ${spec.file} 第 ${b.line} 行`, at: `来源 ${spec.file} 第 ${b.line} 行的${KIND[b.kind] ?? b.kind}`, text, cells, marker, key: specKey(text, cells, marker) };
  });
  const gaps = [];
  let i0 = -1, j0 = -1;
  for (const [i, j] of [...lcs(S.map((x) => x.key), P.map((x) => x.key)), [S.length, P.length]]) { gaps.push({ s: range(i0 + 1, i), p: range(j0 + 1, j) }); i0 = i; j0 = j; }
  const loose = new Map(), moved = new Set();
  for (const g of gaps) for (const j of g.p) { if (!loose.has(P[j].key)) loose.set(P[j].key, []); loose.get(P[j].key).push(j); }
  for (const g of gaps) {
    g.s = g.s.filter((i) => {
      const j = loose.get(S[i].key)?.find((x) => !moved.has(x));
      if (j === undefined) return true;
      moved.add(j);
      out.push({ kind: 'spec-order', where: P[j].where, detail: `${S[i].at}在页面上的先后与来源不一致（「${clip(S[i].text)}」）` });
      return false;
    });
  }
  for (const g of gaps) {
    const p = g.p.filter((j) => !moved.has(j));
    g.s.forEach((i, k) => {
      if (k < p.length) out.push({ kind: 'spec-mismatch', where: P[p[k]].where, detail: `${S[i].at}，文字与页面上的不同：${what(S[i], P[p[k]])}` });
      else out.push({ kind: 'spec-missing', where: S[i].where, detail: `${S[i].at}页面上没有（「${clip(S[i].text)}」）` });
    });
    for (const j of p.slice(g.s.length)) out.push({ kind: 'spec-extra', where: P[j].where, detail: `页面上的这一块来源里没有（「${clip(P[j].text)}」）：来源改了没重出，或者有人手改了页面` });
  }
  return { problems: out, read };
}
