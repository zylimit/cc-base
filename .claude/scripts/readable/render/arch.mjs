// arch.mjs —— 架构设计这一份的页面：架构首页、接口总表，模块页在 arch-module.mjs（第三期契约 docs/readable-spec/phase3-arch-contract.md D 节）。
// 为什么有它：接手的人看完数据库设计第二步就看这里——系统由哪几块组成、每一块管什么、谁用谁、对外提供什么、碰哪些表（规格 REQ-DOC-002）。
// 首页要一眼看清几块：几百行的明细（循环依赖里的文件对、没人引用的文件）一律收进可展开的区，不摊在首页上。
// 「结构上看得出的」只说是算出来的，不下判断。只读文档模型（build --facts-json 的 code、arch 与说明）、只出字符串，落盘在 publish.mjs。
// 配了 codeRoots、取得到代码文件的项目才出这一份（入口看 arch.modules 是否为空）。
import { cmp } from '../model.mjs';
import { esc, code, page, table, origin } from './layout.mjs';
import { firstPara, staleMark } from './note.mjs';
import { archView } from './arch-scrub.mjs';
import { ARCH, CSS, modFile, approxLines, crumbs, pageTitle, judgedMark, TODO, pathCode, k, row, section, none, mRef, archNote, fold, folded, pairList, redactions, LEGEND } from './arch-kit.mjs';
import { overallGraph } from './arch-graph.mjs';
import { modulePage, routeKey, routeCells } from './arch-module.mjs';

const modCell = (v, id) => (id ? mRef(v, id) : '<span class="muted">未归属</span>');
// 一句话职责（D 节）：module: 说明的第一段，标「说明」（过期的另标「待更新」）；没写的空着、标「待写」。
const duty = (m) => (m.note ? `${firstPara(m.note.text)} ${origin('note')}${staleMark(m.note)}` : TODO);

function moduleList(v) {
  const statuses = new Set(v.modules.map((m) => m.status)), mixed = statuses.size > 1, layered = v.modules.some((m) => m.layer != null);
  const rows = v.modules.map((m) => row(m.id, [
    `${mRef(v, m.id)}${mixed ? ` ${judgedMark(m.status)}` : ''}`, ...(layered ? [esc(m.layer ?? '')] : []), duty(m),
    k('files', String(m.files.length)), approxLines(m.lines), k('routes', String(m.routes.length)),
    String(m.tables.reads.length), String(m.tables.writes.length), String(m.uses.length), String(m.usedBy.length),
  ]));
  const head = ['模块', ...(layered ? ['层'] : []), '一句话职责', '文件', '规模', '接口', '读表', '写表', '依赖', '被依赖'];
  const widths = ['20%', ...(layered ? ['112px'] : []), null, '52px', '84px', '52px', '52px', '52px', '52px', '64px'];
  const basis = v.source === 'dirs'
    ? '还没有项目判断，模块是按目录分的：每个代码根目录下的每个一级子目录一个模块，直接放在根目录下的文件合成一个。'
    : '模块怎么分取自项目判断（<code>docs/readable-src/map.json</code>），按那里的先后排。';
  return section('modules', `<h2>模块清单（${v.modules.length} 个）${mixed ? '' : ` ${judgedMark([...statuses][0])}`}</h2>\n`
    + `<p class="muted">${basis}一句话职责是模块说明的第一段；后面几栏是取自来源的数：文件数、规模（约多少行，取一位有效数字）、接口数、读几张表、写几张表、依赖几个模块、被几个模块依赖。</p>\n${table(head, rows, widths)}`);
}

// 结构上看得出的（D 节第 4 条）：循环依赖每组列成员与每一对模块之间的文件对数，文件对的明细收起来；越层引用只在有层时出。
function structure(v) {
  const fileRow = (x) => [pathCode(x.file), modCell(v, x.module)]; // 超过 1000 行的那张也只列文件、不写行数（D 节）
  const cyc = v.cycles.map((c, i) => {
    const inside = new Set(c.modules);
    const links = c.modules.flatMap((a) => v.byId.get(a).uses.filter((u) => inside.has(u.module)).map((u) => [mRef(v, a, { br: false }), mRef(v, u.module, { br: false }), String(u.pairs.length)]));
    return `<h4>第 ${i + 1} 组：${c.modules.length} 个模块、${c.pairs.length} 对文件</h4>\n<p>成员：${c.modules.map((id) => mRef(v, id, { br: false })).join('、')}</p>\n`
      + `${table(['从', '到', '文件对数'], links, ['38%', '38%', null])}\n${folded(`这一组的 ${c.pairs.length} 对文件`, pairList(c.pairs))}`;
  });
  const up = v.upward.map((u) => [mRef(v, u.from, { br: false }), mRef(v, u.to, { br: false }), `${u.pairs.length} 对${u.pairs.length <= 3 ? pairList(u.pairs) : folded(`${u.pairs.length} 对文件`, pairList(u.pairs))}`]);
  return [
    `<h2>结构上看得出的 ${origin('fact')}</h2>`,
    '<p class="muted">这几张清单都是照引用关系算出来的事实，算不算问题由人判断。</p>',
    `<h3 id="cycles">循环依赖（${v.cycles.length} 组）</h3>`,
    v.cycles.length ? `<p class="muted">一组里的模块沿着引用能互相绕回来。下面写每一对模块之间各有几对文件，文件对的明细在展开的区里。</p>\n${cyc.join('\n')}` : none(),
    ...(v.layers.length ? [`<h3 id="upward">越层引用（${v.upward.length} 处）</h3>`, v.upward.length
      ? `<p class="muted">下层的模块引用了上层的模块（层从上到下：${v.layers.map(esc).join('、')}）。</p>\n${table(['下层的模块', '上层的模块', '文件对'], up, ['26%', '26%', null])}` : none()] : []),
    `<h3 id="big">超过 1000 行的文件（${v.big.length} 个）</h3>`,
    v.big.length ? fold(['文件', '模块'], v.big.map(fileRow), ['60%', null], '个') : none(),
    `<h3 id="idle">没有被项目里别的文件引用的：入口、脚本，或者真的没人用（${v.idle.length} 个）</h3>`,
    v.idle.length ? `<p class="muted">既不是入口（Python 带 <code>if __name__ == "__main__":</code> 的），也没有被项目里任何一个文件引用。JS 一族没有入口的写法可认，它的入口文件也在这里。</p>\n${fold(['文件', '模块'], v.idle.map(fileRow), ['60%', null], '个')}` : none(),
  ].join('\n');
}

// 读不出的与对不上的（D 节第 5 条）：每张清单为空时写「没有」，不整段省掉。
function unreadable(v) {
  const list = (id, title, n, unit, html) => `<h3 id="${id}">${title}（${n} ${unit}）</h3>\n${n ? html : none()}`;
  const textRow = (x) => [pathCode(x.file), code(x.text)];
  const un = v.unassigned.map((p) => row(p, [pathCode(p)]));
  return [
    `<h2>读不出的与对不上的 ${origin('fact')}</h2>`,
    section('unassigned', list('unassigned', '未归属的文件', un.length, '个',
      `<p class="muted">没有模块匹配的文件：它们不进任何模块，引用到它们或从它们发出的引用不算进模块之间的依赖。</p>\n${fold(['文件'], un, null, '个')}`)),
    list('unresolved', '没解析到的引用', v.unresolved.length, '处', `<p class="muted">像是项目里的引用，却没对上文件；这几处引用不在模块之间的依赖里。</p>\n${fold(['文件', '引用语句'], v.unresolved.map(textRow), ['40%', null])}`),
    list('dynamic', '运行时才定的引用', v.dynamic.length, '处', `<p class="muted">引用的模块名是变量、拼出来的字符串，静态看不出是哪个文件；不在模块之间的依赖里。</p>\n${fold(['文件', '原文'], v.dynamic.map(textRow), ['40%', null])}`),
    list('skipped', '没扫的文件', v.skipped.length, '种', `<p class="muted">代码根目录下这几种扩展名的文件没有读，按扩展名报数，不装作扫过。</p>\n${table(['扩展名', '个数'], v.skipped.map((s) => [code(s.ext), String(s.count)]), ['50%', null])}`),
    list('problems', '项目判断里对不上的', v.problems.length, '条', `<p class="muted"><code>docs/readable-src/map.json</code> 里模块划分写得对不上的，不拦生成，列在这里。</p>\n${table(['种类', '模块', '怎么对不上'], v.problems.map((p) => [code(p.kind), p.module == null ? '' : code(p.module), esc(p.detail)]), ['72px', '20%', null])}`),
  ].join('\n');
}

function indexPage(v) {
  const hint = v.tests ? `<div class="notice" role="note"><p>文件清单里有 ${v.tests} 个测试文件（名字带 <code>.test.</code>、<code>.spec.</code> 或在 <code>__tests__/</code> 下），它们进了模块图；可以在配置（<code>docs/readable-src/config.json</code>）的 <code>ignore</code> 里排掉，比如加 <code>**/*.test.*</code>、<code>**/*.spec.*</code>、<code>**/__tests__/**</code>。</p></div>` : '';
  const body = [
    redactions(v.hits),
    `<h1>${ARCH}</h1>`,
    `<p class="lead">${v.modules.length} 个模块、${v.files} 个代码文件、${approxLines(v.lines, 2)}；接口 ${v.routes.length} 个，全部列在<a href="routes.html">接口总表</a>；未归属的文件 ${v.unassigned.length} 个。${origin('fact')}</p>`,
    archNote('doc:arch', v.docNote, '导读', '还没有导读。先看下面的总图与模块清单，再点进模块。'),
    `<h2>总图 ${judgedMark(v.source === 'dirs' ? 'default' : v.modules.every((m) => m.status === 'confirmed') ? 'confirmed' : 'proposed')}</h2>`,
    '<p class="muted">方框怎么分是项目判断；线与线上的数取自来源（代码里的引用）。</p>',
    overallGraph(v),
    moduleList(v),
    structure(v),
    unreadable(v),
    hint,
    LEGEND,
  ].filter(Boolean).join('\n');
  return { path: 'arch/index.html', html: page({ title: pageTitle(v), depth: 1, crumbs: [['文档首页', 'index.html'], [ARCH]], body, css: CSS }) };
}

// 接口总表（D 节）：按完整路径排，拼不出完整路径的排在最后、照源码的写法显示并标「前缀是运行时定的」；带所属模块并链过去。
// 模块一格 data-k="module" 写模块 id，未归属的写「未归属」（同表页上的标记）。
function routesPage(v) {
  const list = [...v.routes].sort((a, b) => (a.fullPath == null) - (b.fullPath == null) || cmp(a.fullPath ?? a.path, b.fullPath ?? b.path)
    || cmp(a.method, b.method) || cmp(a.file, b.file) || cmp(a.handler, b.handler));
  // 模块一格只写 id（标题放在链接的提示里）：两百多行的表，标题一长每行折成三四行，整页拉长一倍（2026-11-23 真数据截图）。
  const rows = list.map((r) => row(routeKey(r), [...routeCells(r), pathCode(r.file),
    r.module ? `<a href="${modFile(r.module)}" title="${esc(v.byId.get(r.module).title)}"><code data-k="module">${esc(r.module)}</code></a>` : '<span class="muted" data-k="module">未归属</span>']));
  const body = [
    `<h1>接口总表</h1>`,
    section('routes', list.length
      ? `<p class="lead">${list.length} 个接口，按完整路径排；完整路径是一路挂载的前缀加上装饰器里写的路径，拼不出来的排在最后、照源码的写法显示。模块一栏写模块 id，指上去看标题，点了到模块页。${origin('fact')}</p>\n${table(['方法', '完整路径', '处理函数', '所在文件', '模块'], rows, ['72px', '32%', '20%', null, '15%'])}`
      : '<p>没有读出接口（只认装饰器写法的路由）。</p>'),
  ].join('\n');
  return { path: 'arch/routes.html', html: page({ title: pageTitle(v, '接口总表'), depth: 1, crumbs: crumbs(['接口总表']), body, css: CSS }) };
}

// 入口：模型 → 架构这一份的全部页面，外加首页上那一条目录项；moduleOf（原始路径 → {id, title}）给数据库设计的表页标模块。
export function renderArch(facts, { title }) {
  const v = archView(facts, title);
  const files = [indexPage(v), routesPage(v), ...v.modules.map((m) => modulePage(v, m))];
  const moduleOf = new Map([...v.owner].map(([f, id]) => [f, { id, title: v.byId.get(id).title }]));
  return {
    entry: { href: 'arch/index.html', label: ARCH, summary: `${v.modules.length} 个模块、${v.routes.length} 个接口` },
    files, moduleOf,
    stats: { pages: files.length, modules: v.modules.length, hidden: v.hits.reduce((s, h) => s + h.n, 0) },
  };
}
