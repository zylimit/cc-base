// spec-blocks.mjs —— 需求规格的块怎么排（契约 docs/readable-spec/phase2-spec-contract.md C 节）：一块一个带 data-block 的元素，照来源的先后；
// 列表照树嵌套、表格行成表、引用收进可展开的区、围栏原样等宽、标题下面三步以上的有序列表前面加一张步骤图。
// 核对器按 data-block 把每块读回来（文字不含嵌在里面的子块），所以块里只放这一块的字：另加的导读——步骤图、目录、
// 引用的标题、打印用的那一份引用——都不带 data-block，也不放进带 data-block 的元素里。
// 引用为什么另备一份打印用的：合着的 <details> 打印时里面的字不出，不用脚本又没有各家浏览器都认的办法让它打印时自己展开
// （::details-content 太新，内网的旧浏览器不认）；两份是同一个字符串，只有屏幕上那份带 data-block，同一块读回来只有一次。
import { esc, attrs, textW } from './layout.mjs';
import { inline, plain, SPLIT_OVER } from './spec-inline.mjs';

const STEP_MIN = 3, STEP_HEAD = 24; // 契约 C 节：三步以上画步骤图；方框里写这一步的开头，到第一个标点为止、最多 24 个字
const QUOTE_HEAD = 60; // 引用的标题后面接它的第一行，屏幕上一行放得下的长度；全文在展开的区里
// 这一步的开头到哪儿为止：中英文的逗号、句号、顿号、分号、冒号、问号、感叹号与左括号；半角句点后面跟空白才算。
// 引号与书名号不算：它们框的是按钮名、文件名（「点「开始」」截在引号前只剩一个「点」字）。
const HEAD_END = /[，。、；：？！,;:?!（(【]|\.(?=\s|$)/u;

const mark = (b, extra) => attrs({ ...extra, 'data-block': String(b.n), 'data-anchor': b.anchor });
export const headId = (b) => `b-${b.n}`;
const flat = (s) => plain(s).replace(/\s+/g, ' ').trim();
export const cut = (s, n) => { const cs = Array.from(s); return cs.length > n ? `${cs.slice(0, n).join('')}…` : s; };
const long = (s) => Array.from(s).length > SPLIT_OVER;
// 列表项的记号（模型的 marker，如「-」「3.」「2)」）：数字加「.」或「)」的是有序的。没有 marker 的一律按无序排。
const ordered = (b) => /^\d+[.)]$/.test(String(b.marker ?? '').trim());
// 同一张表：紧挨着上一行表格行；表头那一行下面隔着分隔行。
export const sameTable = (prev, b) => prev?.kind === 'table' && b.kind === 'table' && (b.line === prev.endLine + 1 || (prev.header && b.line === prev.line + 2));

// 一串连着的列表项照树嵌套：parent 指向的项在这一串里就挂在它下面，否则是这一串的顶层。
// 同一层里有序与无序连着的各成一段。有序的项把记号原文显示在前面（data-k="marker"，核对器连序号一起比），
// 不用浏览器自动编的号：来源里偷懒写成三个「1.」的，页面上照原文是三个「1.」，不替人改成 1、2、3（契约 C 节）。
function listHtml(run) {
  const inRun = new Set(run.map((b) => b.n)), kids = new Map(), roots = [];
  for (const b of run) {
    if (b.parent != null && inRun.has(b.parent)) { if (!kids.has(b.parent)) kids.set(b.parent, []); kids.get(b.parent).push(b); }
    else roots.push(b);
  }
  const item = (b) => {
    const mk = ordered(b) ? `<span class="mk" data-k="marker">${esc(b.marker)}</span>` : '';
    return `<li${mark(b)}>${mk}${inline(b.text, { split: long(b.text), term: true })}${kids.has(b.n) ? `\n${group(kids.get(b.n))}` : ''}</li>`;
  };
  const group = (list) => {
    const out = [];
    for (let k = 0; k < list.length;) {
      const ord = ordered(list[k]);
      let e = k;
      while (e < list.length && ordered(list[e]) === ord) e++;
      out.push(ord ? `<ol class="om">\n${list.slice(k, e).map(item).join('\n')}\n</ol>` : `<ul>\n${list.slice(k, e).map(item).join('\n')}\n</ul>`);
      k = e;
    }
    return out.join('\n');
  };
  return group(roots);
}

// 步骤：这一串开头连着的、同一层的有序项（子项不算一步），够三步才画。
function stepItems(run) {
  const first = run[0], out = [];
  if (!ordered(first)) return out;
  for (const b of run) {
    if (b.parent !== first.parent) continue;
    if (!ordered(b)) break;
    out.push(b);
  }
  return out.length >= STEP_MIN ? out : [];
}
// 一串列表 blocks[i..j) 前面画不画步骤图：紧跟在标题后面，开头三步以上的有序项。
const stepsAt = (blocks, i, j) => (blocks[i - 1]?.kind === 'heading' ? stepItems(blocks.slice(i, j)) : []);
// 一页的块里画了几张步骤图、各几步：清单页的导读只在真有步骤图时才提它。
export function stepFigures(blocks) {
  const out = [];
  for (let i = 0; i < blocks.length;) {
    let j = i + 1;
    if (blocks[i].kind === 'list') {
      while (j < blocks.length && blocks[j].kind === 'list') j++;
      const s = stepsAt(blocks, i, j);
      if (s.length) out.push(s.length);
    }
    i = j;
  }
  return out;
}
function stepHead(text) {
  const p = flat(text), m = HEAD_END.exec(p.slice(1));
  return cut(m ? p.slice(0, m.index + 1) : p, STEP_HEAD);
}

// 步骤图：一个方框一步，从左到右排，一行放不下折到下一行；箭头从上一步指到下一步，折行的从上一行末尾绕到下一行开头。
// 方框里的序号同列表，写记号的原文。
const ROW_W = 1040, S_PAD = 12, S_H = 40, S_GX = 36, S_GY = 36, S_M = 8, S_FONT = 14;
function stepsSvg(items) {
  const labels = items.map((b) => ({ no: String(b.marker).trim(), head: stepHead(b.text) }));
  const w = Math.ceil(Math.min(ROW_W - 2 * S_M, Math.max(120, ...labels.map((l) => textW(`${l.no}  ${l.head}`, S_FONT))) + S_PAD * 2));
  const per = Math.max(1, Math.floor((ROW_W - 2 * S_M + S_GX) / (w + S_GX))), rows = Math.ceil(items.length / per);
  const W = Math.min(per, items.length) * (w + S_GX) - S_GX + 2 * S_M, H = rows * (S_H + S_GY) - S_GY + 2 * S_M;
  const at = (i) => ({ x: S_M + (i % per) * (w + S_GX), y: S_M + Math.floor(i / per) * (S_H + S_GY) });
  const id = `sa-${items[0].n}`, label = `${items.length} 步的步骤图`;
  const paths = items.slice(1).map((_, k) => {
    const a = at(k), b = at(k + 1);
    const d = a.y === b.y ? `M${a.x + w} ${a.y + S_H / 2}H${b.x - 2}` : `M${a.x + w / 2} ${a.y + S_H}V${a.y + S_H + S_GY / 2}H${b.x + w / 2}V${b.y - 2}`;
    return `<path class="e" d="${d}" marker-end="url(#${id})"/>`;
  });
  const boxes = labels.map((l, i) => {
    const { x, y } = at(i);
    return `<rect x="${x}" y="${y}" width="${w}" height="${S_H}" rx="4"/><text x="${x + S_PAD}" y="${y + S_H / 2 + 5}"><tspan class="no">${esc(l.no)}</tspan><tspan dx="8">${esc(l.head)}</tspan></text>`;
  });
  return `<svg class="steps" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" role="img" aria-label="${label}">\n<title>${label}</title>\n<defs><marker id="${id}" viewBox="0 0 8 8" refX="7.5" refY="4" markerWidth="8" markerHeight="8" orient="auto"><path class="ah" d="M0 0L8 4L0 8z"/></marker></defs>\n${paths.join('\n')}\n${boxes.join('\n')}\n</svg>`;
}
const stepsFigure = (items) => `<figure class="steps"><div class="scroll">${stepsSvg(items)}</div>\n<figcaption>下面 ${items.length} 步的示意：一个方框一步，写序号与这一步的开头；每一步的全文在图下面的列表里。</figcaption></figure>`;

function tableHtml(rows) {
  const tr = (b, cell) => `<tr${mark(b)}>${b.cells.map((c) => `<${cell}>${inline(c)}</${cell}>`).join('')}</tr>`;
  const head = rows.filter((b) => b.header), body = rows.filter((b) => !b.header);
  return `<div class="scroll"><table class="st">\n${head.length ? `<thead>${head.map((b) => tr(b, 'th')).join('\n')}</thead>\n` : ''}${body.length ? `<tbody>\n${body.map((b) => tr(b, 'td')).join('\n')}\n</tbody>` : ''}</table></div>`;
}

// 引用：屏幕上收进 <details>，标题写「引用（N 行）」加它的第一行；行与行照原文分开（样式 pre-line），所以块里的 HTML 不许多出换行。
// 超过 200 个字的行各自分句（契约 C 节「引用里的每一行都算」），短的行照原样。
function quoteHtml(b) {
  const label = `引用（${b.endLine - b.line + 1} 行）`, head = cut(flat(b.text.split('\n')[0]), QUOTE_HEAD), body = inline(b.text, { split: 'line' });
  return `<details class="q"><summary>${label}${head ? `<span class="qt">：${esc(head)}</span>` : ''}</summary><div class="qb"${mark(b)}>${body}</div></details>\n`
    + `<div class="print-only"><p class="qt">${label}</p><div class="qb">${body}</div></div>`;
}

const ONE = {
  heading: (b) => { const L = Math.min(6, Math.max(1, b.level ?? 1)); return `<h${L}${mark(b, { id: headId(b) })}>${inline(b.text)}</h${L}>`; },
  quote: quoteHtml,
  fence: (b) => `<pre${mark(b)}><code>${esc(b.text)}</code></pre>`,
  hr: (b) => `<hr${mark(b)}>`,
  paragraph: (b) => `<p${mark(b)}>${inline(b.text, { split: long(b.text) })}</p>`,
};

// 一页的块 → HTML，照来源的先后。toc（本章目录）放在第一块是标题时它的后面，否则放最前面。认不得的种类按段落排，不丢。
export function renderBlocks(blocks, toc = '') {
  const out = toc && blocks[0]?.kind !== 'heading' ? [toc] : [];
  for (let i = 0; i < blocks.length;) {
    const b = blocks[i];
    let j = i + 1;
    if (b.kind === 'list') {
      while (j < blocks.length && blocks[j].kind === 'list') j++;
      const steps = stepsAt(blocks, i, j);
      if (steps.length) out.push(stepsFigure(steps));
      out.push(listHtml(blocks.slice(i, j)));
    } else if (b.kind === 'table') {
      while (j < blocks.length && sameTable(blocks[j - 1], blocks[j])) j++;
      out.push(tableHtml(blocks.slice(i, j)));
    } else out.push((ONE[b.kind] || ONE.paragraph)(b));
    if (i === 0 && toc && b.kind === 'heading') out.push(toc);
    i = j;
  }
  return out.join('\n');
}

// 需求规格的页面多要的样式，接在共用样式后面（layout.mjs 的 page 的 css）。
// 有序列表不要浏览器的号，记号原文挂在每一项左边的留白里、对齐第一行，序号长了往左伸，不挤正文。
export const SPEC_CSS = `
.src{color:var(--muted);font-size:14px;border-left:3px solid var(--line);padding:2px 10px;margin:12px 0 20px}
.spec h1{font-size:26px}
.spec ul,.spec ol{padding-left:24px;margin:8px 0}
.spec ol.om{list-style:none;padding-left:40px}
.spec ol.om>li{position:relative}
.spec ol.om>li>.mk{position:absolute;right:calc(100% + 8px);top:0;white-space:nowrap;font-weight:600;color:var(--accent);font-variant-numeric:tabular-nums}
.spec li{margin:8px 0}
.spec li>ul,.spec li>ol{margin:6px 0}
.term{display:block;margin-bottom:2px}
.sb{display:block;height:4px}
details.q{margin:2px 0;padding:0 10px;border-left:3px solid var(--line)}
details.q summary{cursor:pointer;color:var(--fg)}
.qt{color:var(--muted)}
.qb{white-space:pre-line;font-size:15px;padding:2px 0 8px}
table.st th,table.st td:first-child{white-space:normal}
table.st th{color:var(--fg);background:var(--soft)}
nav.toc{border:1px solid var(--line);border-radius:4px;padding:6px 16px;margin:12px 0 20px;font-size:15px}
nav.toc ul{list-style:none;padding-left:0;margin:4px 0}
nav.toc li.l4{padding-left:16px}
nav.toc li.l5,nav.toc li.l6{padding-left:32px}
figure.steps{margin:12px 0 4px}
figure.steps figcaption{font-size:13px;color:var(--muted)}
svg.steps{display:block}
svg.steps rect{fill:var(--soft);stroke:var(--accent);stroke-width:1.2}
svg.steps text{font:14px system-ui,-apple-system,"Segoe UI","PingFang SC","Microsoft YaHei","Noto Sans CJK SC",sans-serif;fill:var(--fg)}
svg.steps .no{font-weight:700;fill:var(--accent)}
svg.steps path.e{fill:none;stroke:var(--muted);stroke-width:1.2}
svg.steps path.ah{fill:var(--muted)}
@media print{details.q{display:none}.print-only .qb{border-left:3px solid var(--line);padding-left:10px}svg.steps{max-width:100%;height:auto}}
`.trim();
