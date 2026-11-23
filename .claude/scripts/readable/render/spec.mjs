// spec.mjs —— 人读版需求规格的页面（契约 docs/readable-spec/phase2-spec-contract.md C 节；规格 REQ-DOC-004、006、007、011）。
// 为什么有它：需求规格是写给 AI 记录用的，一条几千字、不分段，人读不下去；接手的团队要照着开发、客户要审的是同样的字，
// 所以这一份只换排法：一个字不加、一个字不少，没有 AI 写的说明，也不连别的文档。
// 只读文档模型里的 spec（build --facts-json 那份），不回头读来源文件（架构稿 §3 禁边）；出 [{path, html}]，落盘在 publish.mjs。
// 一个二级标题一页，一级标题与第一个二级标题之前的归 s-00；首页一张章节地图、一张章节清单。
// 文件名只用序号（spec/s-<两位序号>.html）：中文章名转码之后是一长串「~529f~80fd」，谁也看不懂，贴进聊天工具里也难看（契约 C 节）。
// 块怎么排在 spec-blocks.mjs，行内记号与分句在 spec-inline.mjs，隐去在 spec-scrub.mjs。
import { esc, code, origin, page, table, diagram, DIAGRAM_MAX } from './layout.mjs';
import { renderBlocks, headId, sameTable, cut, stepFigures, SPEC_CSS } from './spec-blocks.mjs';
import { plain } from './spec-inline.mjs';
import { scrubSpec } from './spec-scrub.mjs';
import { REDACTED } from '../sensitive.mjs';

export const SPEC_DOC = '需求规格';
const LABEL_MAX = 24; // 章节地图方框里的章名最多 24 个字，全名在章节清单里
const PRE_NAME = '开头'; // 没有一级标题时 s-00 的名字
const CRUMB = ['文档首页', 'index.html'];

const flat = (s) => plain(s).replace(/\s+/g, ' ').trim();

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
    return {
      ...ch, nn, name, file: `s-${nn}.html`,
      lists: ch.blocks.filter((b) => b.kind === 'list').length,
      tables: ch.blocks.filter((b, k) => b.kind === 'table' && !sameTable(ch.blocks[k - 1], b)).length,
      steps: stepFigures(ch.blocks),
      from: h.line, to: ch.blocks.at(-1).endLine,
    };
  });
}

function chapterPage(ch, ctx) {
  const heads = ch.blocks.filter((b) => b.kind === 'heading' && b.level >= 3);
  const toc = heads.length
    ? `<nav class="toc" aria-label="本章目录"><p class="muted">本章目录</p>\n<ul>\n${heads.map((b) => `<li class="l${Math.min(b.level, 6)}"><a href="#${headId(b)}">${esc(flat(b.text))}</a></li>`).join('\n')}\n</ul></nav>`
    : '';
  const body = `<p class="src">本页内容逐块取自 ${code(ctx.file)} 第 ${ch.from}–${ch.to} 行，只是排法不同。</p>\n<div class="spec">\n${renderBlocks(ch.blocks, toc)}\n</div>`;
  return { path: `spec/${ch.file}`, html: page({ title: [ch.name, SPEC_DOC, ctx.title].join(' · '), depth: 1, crumbs: [CRUMB, [SPEC_DOC, 'spec/index.html'], [ch.name]], body, css: SPEC_CSS }) };
}

// 隐去了几处、各在第几行（契约 C 节）：只写位置，不写原文。
function redactions(hits, chs) {
  if (!hits.length) return '';
  const where = new Map(chs.flatMap((ch) => ch.blocks.map((b) => [b.n, ch])));
  const rows = hits.map((h) => { const ch = where.get(h.block); return [`第 ${h.line} 行`, `<a href="${esc(ch.file)}">${esc(`${ch.nn} ${ch.name}`)}</a>`, String(h.n)]; });
  return `<div class="notice" role="note"><p>隐去了 ${hits.reduce((s, h) => s + h.n, 0)} 处：来源里形如内网地址、带口令的地址或密钥的字样，页面上换成了「${REDACTED}」，原文只在来源里。</p>\n${table(['来源的行', '在哪一章', '处数'], rows, ['120px', null, '64px'])}</div>`;
}

function indexPage(chs, spec, ctx) {
  const h1 = spec.blocks.find((b) => b.kind === 'heading' && b.level === 1), name = (h1 && flat(h1.text)) || SPEC_DOC;
  const nodes = chs.map((ch, i) => ({ name: String(i).padStart(6, '0'), label: `${ch.nn} ${cut(ch.name, LABEL_MAX)}`, lines: [`${ch.blocks.length} 块，列表项 ${ch.lists} 条`], parents: [], href: ch.file }));
  const rows = chs.map((ch) => [`<a href="${esc(ch.file)}">${esc(`${ch.nn} ${ch.name}`)}</a>`, `第 ${ch.from}–${ch.to} 行`, String(ch.blocks.length), String(ch.lists), String(ch.tables)]);
  // 导读里提步骤图的那半句，只在这份规格里真画了步骤图时才写（契约 C 节）。
  const steps = chs.some((ch) => ch.steps.length) ? '，标题下面三步以上的有序列表前面加了一张步骤图' : '';
  const body = [
    redactions(spec.hits, chs),
    `<h1>${esc(name)}</h1>`,
    `<p>来源：${code(ctx.file)} ${origin('fact')}，共 ${spec.blocks.length} 块，分 ${chs.length} 章：一个二级标题一章，一级标题与第一个二级标题之前的内容归第 00 章。</p>`,
    `<p class="lead">这份页面只是把来源换一种排法：一个字不加、一个字不少，没有另写的说明。长条目按句断行，开头的粗体词当小标题，引用收进可展开的区（打印时展开）${steps}——这些只改显示、不改文字，以来源为准。</p>`,
    ...(chs.length ? [
      '<h2>章节地图</h2>',
      '<p class="muted">一个方框一章，写章名与这一章有几块、其中列表项几条。点方框到那一章。</p>',
      `<div class="scroll">${diagram(nodes, `${SPEC_DOC}的章节地图`, Math.max(DIAGRAM_MAX, nodes.length))}</div>`,
      '<h2>章节清单</h2>',
      table(['章', '来源的行', '块', '其中列表项', '表格'], rows, [null, '150px', '72px', '104px', '72px']),
    ] : ['<p class="muted">规格里没有内容。</p>']),
  ].filter(Boolean).join('\n');
  return { path: 'spec/index.html', html: page({ title: `${SPEC_DOC} · ${ctx.title}`, depth: 1, crumbs: [CRUMB, [SPEC_DOC]], body, css: SPEC_CSS }) };
}

// 入口：模型里的 spec → 需求规格的全部页面，外加首页上那一条目录项；title 是文档集的标题（已隐去）。stats 给命令行报数用。
export function renderSpec(source, { title }) {
  const spec = scrubSpec(source), chs = chapters(spec.blocks), ctx = { title, file: spec.file };
  return {
    entry: { href: 'spec/index.html', label: SPEC_DOC, summary: `${chs.length} 章、${spec.blocks.length} 块，取自 ${spec.file}` },
    files: [indexPage(chs, spec, ctx), ...chs.map((ch) => chapterPage(ch, ctx))],
    stats: { pages: chs.length, blocks: spec.blocks.length, hidden: spec.hits.reduce((s, h) => s + h.n, 0), perPage: chs.map((ch) => ({ file: ch.file, blocks: ch.blocks.length })) },
  };
}
