// spec.mjs —— 人读版需求规格的页面（契约 docs/readable-spec/phase2-spec-contract.md C 节；规格 REQ-DOC-004、006、007、011）。
// 为什么有它：需求规格是写给 AI 记录用的，一条几千字、不分段，人读不下去；接手的团队要照着开发、客户要审的是同样的字，
// 所以这一份只换排法：一个字不加、一个字不少，没有 AI 写的说明，也不连别的文档。
// 只读文档模型里的 spec（build --facts-json 那份），不回头读来源文件（架构稿 §3 禁边）；出 [{path, html}]，落盘在 publish.mjs。
// 一个二级标题一页，一级标题与第一个二级标题之前的归 s-00；首页一张章节地图、一张章节清单。
// 文件名只用序号（spec/s-<两位序号>.html）：中文章名转码之后是一长串「~529f~80fd」，谁也看不懂，贴进聊天工具里也难看（契约 C 节）。
// 块怎么排在 spec-blocks.mjs，行内记号与分句在 spec-inline.mjs，隐去在 spec-scrub.mjs。
import { esc, code, origin, page, table, diagram, DIAGRAM_MAX } from './layout.mjs';
import { renderBlocks, sameTable, stepFigures, SPEC_CSS } from './spec-blocks.mjs';
import { flat, cut, blockIds, chainCount } from './spec-figures.mjs';
import { leadTerm } from './spec-inline.mjs';
import { scrubSpec } from './spec-scrub.mjs';
import { REDACTED } from '../sensitive.mjs';

export const SPEC_DOC = '需求规格';
const LABEL_MAX = 24; // 章节地图方框里的章名最多 24 个字，全名在章节清单里
const PRE_NAME = '开头'; // 没有一级标题时 s-00 的名字
const CRUMB = ['文档首页', 'index.html'];
const ITEM_MIN = 5, ITEM_CUT = 28; // 契约 C 节「本章条目」：顶层 5 条以上开头是粗体词才列；超过 28 个字的截断加「…」
const MAP_ROW_GAP = 16; // 章节地图没有连线，行与行之间只留普通的间距（关系图的行距是给连线留的）

// 分章：遇到二级标题起新的一章，别的块（包括后面再出现的一级标题）跟着当前这一章。
function chapters(blocks) {
  const pre = { no: 0, blocks: [] }, out = [];
  let cur = pre;
  for (const b of blocks) {
    if (b.kind === 'heading' && b.level === 2) { cur = { no: out.length + 1, blocks: [] }; out.push(cur); }
    cur.blocks.push(b);
  }
  return (pre.blocks.length ? [pre, ...out] : out).map((ch) => {
    const h = ch.blocks[0], titled = h.kind === 'heading' && (ch.no > 0 || h.level === 1);
    const name = (titled && flat(h.text)) || (ch.no ? '（无题）' : PRE_NAME), nn = String(ch.no).padStart(2, '0');
    // 画进步骤图的那几步不各自画流程链图（spec-blocks.mjs 的 listHtml），数流程链图时同样除开。
    const steps = stepFigures(ch.blocks), inSteps = new Set(steps.flat().map((b) => b.n));
    return {
      ...ch, nn, name, file: `s-${nn}.html`,
      lists: ch.blocks.filter((b) => b.kind === 'list').length,
      tables: ch.blocks.filter((b, k) => b.kind === 'table' && !sameTable(ch.blocks[k - 1], b)).length,
      steps, chains: chainCount(ch.blocks.filter((b) => !inSteps.has(b.n))), ids: blockIds(ch.blocks),
      from: h.line, to: ch.blocks.at(-1).endLine,
    };
  });
}

// 本章目录：三级以下的标题；顶层列表项里有 5 条以上开头是粗体词的，再按来源的先后列出这些粗体词（本章条目），
// 挂在各自所属的三级标题下面，在第一个三级标题之前的直接列。点了跳到那一条（条目的 id）。粗体词取自条目自己，已过隐去。
function tocHtml(ch) {
  const heads = ch.blocks.filter((b) => b.kind === 'heading' && b.level >= 3);
  const terms = ch.blocks.filter((b) => b.kind === 'list' && b.parent == null).map((b) => ({ b, t: leadTerm(b.text).replace(/\s+/g, ' ').trim() })).filter((x) => x.t);
  const items = terms.length >= ITEM_MIN ? new Map(terms.map((x) => [x.b.n, x])) : new Map();
  if (!heads.length && !items.size) return '';
  const href = (b) => `#${esc(ch.ids.get(b.n))}`;
  const direct = [], under = new Map();
  let h3 = null;
  for (const b of ch.blocks) {
    if (b.kind === 'heading' && b.level <= 3) h3 = b.level === 3 ? b.n : null;
    else if (items.has(b.n)) { const into = h3 == null ? direct : (under.get(h3) ?? under.set(h3, []).get(h3)); into.push(items.get(b.n)); }
  }
  const list = (xs) => (xs?.length ? `\n<ul class="it">\n${xs.map((x) => `<li><a href="${href(x.b)}">${esc(cut(x.t, ITEM_CUT))}</a></li>`).join('\n')}\n</ul>` : '');
  const lead = `<p class="muted">本章目录${items.size ? ` · 本章条目 ${items.size} 条（开头是粗体词的顶层条目）` : ''}</p>`;
  const tree = heads.length ? `\n<ul>\n${heads.map((b) => `<li class="l${Math.min(b.level, 6)}"><a href="${href(b)}">${esc(flat(b.text))}</a>${list(under.get(b.n))}</li>`).join('\n')}\n</ul>` : '';
  return `<nav class="toc" aria-label="本章目录">${lead}${list(direct)}${tree}</nav>`;
}

function chapterPage(ch, ctx) {
  const body = `<p class="src">本页内容逐块取自 ${code(ctx.file)} 第 ${ch.from}–${ch.to} 行，只是排法不同。</p>\n<div class="spec">\n${renderBlocks(ch.blocks, tocHtml(ch), ch.ids)}\n</div>`;
  return { path: `spec/${ch.file}`, html: page({ title: [ch.name, SPEC_DOC, ctx.title].join(' · '), depth: 1, crumbs: [CRUMB, [SPEC_DOC, 'spec/index.html'], [ch.name]], body, css: SPEC_CSS }) };
}

// 隐去了几处、各在第几行、换掉了多少个字（契约 C 节）：只写位置与字数，不写原文。
// 字数写在明处：零丢失的比对按隐去后的文字比，规则要是多吞了后面的话，两边换得一样、核对看不出来，读者看这一栏才知道这一行少了多少。
function redactions(hits, chs) {
  if (!hits.length) return '';
  const where = new Map(chs.flatMap((ch) => ch.blocks.map((b) => [b.n, ch])));
  const rows = hits.map((h) => { const ch = where.get(h.block); return [`第 ${h.line} 行`, `<a href="${esc(`${ch.file}#${ch.ids.get(h.block)}`)}">${esc(`${ch.nn} ${ch.name}`)}</a>`, String(h.n), String(h.chars)]; });
  const n = hits.reduce((s, h) => s + h.n, 0), chars = hits.reduce((s, h) => s + h.chars, 0);
  return `<div class="notice" role="note"><p>隐去了 ${n} 处、共换掉 ${chars} 个字：来源里形如内网地址、带口令的地址或密钥的字样，页面上换成了「${REDACTED}」，原文只在来源里。</p>\n${table(['来源的行', '在哪一章', '处数', '换掉的字'], rows, ['120px', null, '64px', '96px'])}</div>`;
}

function indexPage(chs, spec, ctx) {
  const h1 = spec.blocks.find((b) => b.kind === 'heading' && b.level === 1), name = (h1 && flat(h1.text)) || SPEC_DOC;
  const nodes = chs.map((ch, i) => ({ name: String(i).padStart(6, '0'), label: `${ch.nn} ${cut(ch.name, LABEL_MAX)}`, lines: [`${ch.blocks.length} 块，列表项 ${ch.lists} 条`], parents: [], href: ch.file }));
  const rows = chs.map((ch) => [`<a href="${esc(ch.file)}">${esc(`${ch.nn} ${ch.name}`)}</a>`, `第 ${ch.from}–${ch.to} 行`, String(ch.blocks.length), String(ch.lists), String(ch.tables)]);
  // 导读里提步骤图、流程链图的那半句，只在这份规格里真画了这种图时才写（契约 C 节）。
  const steps = (chs.some((ch) => ch.steps.length) ? '，三步以上的有序列表前面加了一张步骤图' : '')
    + (chs.some((ch) => ch.chains) ? '，用「→」连着三段以上的短句后面加了一条流程链图' : '')
    + (chs.some((ch) => ch.steps.length || ch.chains) ? '（图里的字都取自它旁边的条目）' : '');
  const body = [
    redactions(spec.hits, chs),
    `<h1>${esc(name)}</h1>`,
    // 「归第 00 章」那半句只在真有第 00 章时才写。
    `<p>来源：${code(ctx.file)} ${origin('fact')}，共 ${spec.blocks.length} 块，分 ${chs.length} 章：一个二级标题一章${chs[0]?.no === 0 ? '，一级标题与第一个二级标题之前的内容归第 00 章' : ''}。</p>`,
    `<p class="lead">这份页面只是把来源换一种排法：一个字不加、一个字不少，没有另写的说明。长条目按句断行，开头的粗体词当小标题，引用收进可展开的区（打印时展开）${steps}——这些只改显示、不改文字，以来源为准。</p>`,
    ...(chs.length ? [
      '<h2>章节地图</h2>',
      '<p class="muted">一个方框一章，写章名与这一章有几块、其中列表项几条。点方框到那一章。</p>',
      `<div class="scroll">${diagram(nodes, `${SPEC_DOC}的章节地图`, Math.max(DIAGRAM_MAX, nodes.length), { rowGap: MAP_ROW_GAP })}</div>`,
      '<h2>章节清单</h2>',
      table(['章', '来源的行', '块', '其中列表项', '表格'], rows, [null, '150px', '72px', '104px', '72px']),
    ] : ['<p class="muted">规格里没有内容。</p>']),
  ].filter(Boolean).join('\n');
  return { path: 'spec/index.html', html: page({ title: `${SPEC_DOC} · ${ctx.title}`, depth: 1, crumbs: [CRUMB, [SPEC_DOC]], body, css: SPEC_CSS }) };
}

// 测试注入点 READABLE_FAIL_AT=spec-render（契约 D 节）：出页面的代码把第一条带字的列表项的最后一个字丢掉，
// 落盘前的自检应当拦下（build 退出码 3、原有页面不动）。规格里没有带字的列表项就没有字可丢，直接报错——注入点不许悄悄什么都不做。
function injectRender(spec) {
  if (process.env.READABLE_FAIL_AT !== 'spec-render') return spec;
  const k = spec.blocks.findIndex((b) => b.kind === 'list' && b.text !== '');
  if (k < 0) throw new Error('READABLE_FAIL_AT=spec-render：规格里没有带字的列表项可丢一个字，按要求模拟失败');
  const blocks = spec.blocks.slice();
  blocks[k] = { ...blocks[k], text: Array.from(blocks[k].text).slice(0, -1).join('') };
  return { ...spec, blocks };
}

// 入口：模型里的 spec → 需求规格的全部页面，外加首页上那一条目录项；title 是文档集的标题（已隐去）。stats 给命令行报数用。
export function renderSpec(source, { title }) {
  const spec = injectRender(scrubSpec(source)), chs = chapters(spec.blocks), ctx = { title, file: spec.file };
  return {
    entry: { href: 'spec/index.html', label: SPEC_DOC, summary: `${chs.length} 章、${spec.blocks.length} 块，取自 ${spec.file}` },
    files: [indexPage(chs, spec, ctx), ...chs.map((ch) => chapterPage(ch, ctx))],
    stats: { pages: chs.length, blocks: spec.blocks.length, hidden: spec.hits.reduce((s, h) => s + h.n, 0), perPage: chs.map((ch) => ({ file: ch.file, blocks: ch.blocks.length })) },
  };
}
