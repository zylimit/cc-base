// db.mjs —— 数据库设计的页面（契约 docs/readable-spec/phase1-db-contract.md C 节、F 节「页面」；架构稿 §2 render）。
// 为什么有它：接手团队第一步就看数据库设计，要能只看文档、不问原作者，说清任意一张表存的是什么、谁写谁读（规格 SC-1）。
// 只读文档模型（build --facts-json 那份），不回头读来源文件；出 [{path, html}]，落盘在 publish.mjs。表页在 db-table.mjs。
// 没有注释的地方留空，不编。
import { cmp } from '../model.mjs';
import { esc, code, at, origin, judged, fileSlug, page, table, diagram, LEGEND, DIAGRAM_MAX } from './layout.mjs';
import { DOC, tableFile, tLink, crumbs, title, outRefs, erNode, tablePage } from './db-table.mjs';

export { tableFile };
export const GROUP_MAX = DIAGRAM_MAX; // 契约 C 节：一组超过 12 张表的切成几页，每页的关系图最多 12 张表
// 契约 C 节「不带出去的东西」：第一期原样照出，只在 db/index.html 顶上警告，隐不隐去待用户裁定。
const LEAKS = [
  ['内网地址', /\b(?:10\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])|192\.168)\.\d{1,3}\.\d{1,3}\b/g],
  ['疑似密钥', /-----BEGIN [A-Z ]*PRIVATE KEY-----|\bAKIA[0-9A-Z]{16}\b|\bsk-[A-Za-z0-9_-]{16,}|\b(?:password|passwd|secret|api[_-]?key|access[_-]?key|token)\s*[:=]\s*['"]?[^\s'",;)]{6,}/gi],
];

// 分组在文档模型里只有一份 groups（契约 F 节），成员以它为准；这里只管怎么切页：
// 超过 12 张的按组内顺序（模型里已按表名排好）均分成几页（15 张 → 8 + 7），免得最后一页只剩一两张；文件名 g-<组 id>，切页的接 -1、-2。
export function groupPages(groups) {
  return groups.flatMap((grp) => {
    const list = grp.tables, parts = Math.max(1, Math.ceil(list.length / GROUP_MAX)), small = Math.floor(list.length / parts), extra = list.length % parts;
    let from = 0;
    return Array.from({ length: parts }, (_, i) => {
      const size = small + (i < extra ? 1 : 0), suf = parts > 1 ? `-${i + 1}` : '';
      const pg = { label: grp.title + suf, grp, status: grp.status, part: i + 1, parts, file: `g-${fileSlug(grp.id)}${suf}.html`, tables: list.slice(from, from + size) };
      from += size;
      return pg;
    });
  });
}

const firstSentence = (s) => {
  if (!s) return '';
  const line = s.split('\n')[0], k = line.indexOf('。'), t = Array.from(k >= 0 ? line.slice(0, k + 1) : line);
  return t.length > 120 ? `${t.slice(0, 119).join('')}…` : t.join('');
};
// 组名后面的档位：项目判断的组标「AI 提议」/「人已确认」，按前缀分出来的（default）不标。
const withStatus = (html, status) => (judged(status) ? `${html} ${judged(status)}` : html);

function index(model, cfg) {
  const tables = new Map(model.tables.map((t) => [t.name, t]));
  const pages = groupPages(model.groups), groupOf = new Map();
  for (const g of pages) for (const n of g.tables) if (!groupOf.has(n)) groupOf.set(n, g);
  const out = new Map(), inc = new Map(), unfoldedBy = new Map();
  for (const t of model.tables) {
    out.set(t.name, outRefs(t));
    for (const r of out.get(t.name)) (inc.get(r.to) || inc.set(r.to, []).get(r.to)).push(r);
  }
  for (const u of model.unfolded) {
    for (const n of new Set(u.tables)) if (tables.has(n)) (unfoldedBy.get(n) || unfoldedBy.set(n, []).get(n)).push(u);
  }
  for (const list of inc.values()) list.sort((a, b) => cmp(a.from, b.from) || cmp(a.cols.join(','), b.cols.join(',')));
  // 没归属的运行时表名：表页上「没有找到写（读）这张表的代码」后面补一句「另有 N 处……见清单」（契约 F 节）。
  const dynamicOpen = model.dynamic.filter((d) => !d.assigned).length;
  return { cfg, tables, pages, groupOf, out, inc, unfoldedBy, usage: model.usage, dynamicOpen };
}

function groupPage(g, ctx) {
  const set = new Set(g.tables);
  const nodes = g.tables.map((name) => erNode(name, ctx, set));
  const sib = ctx.pages.filter((x) => x.grp === g.grp);
  const parts = g.parts > 1
    ? `<p>${esc(g.grp.title)} 组共 ${g.grp.tables.length} 张表，按名字顺序分成 ${g.parts} 页：${sib.map((x) => (x === g ? `<strong>${esc(x.label)}</strong>` : `<a href="${x.file}">${esc(x.label)}</a>`)).join('、')}</p>`
    : '';
  const why = g.status !== 'default' ? '这一组是项目判断分的，组名后面标着是谁的判断。'
    : g.grp.id === '_other' ? '这里是表名前缀只有一张表的那些。'
      : g.grp.id === '_ungrouped' ? '项目判断的分组没有收进去的表。'
        : `表名都以 <code>${esc(g.grp.id)}_</code> 开头。`;
  const rows = g.tables.map((n) => {
    const t = ctx.tables.get(n), to = [...new Set(ctx.out.get(n).map((r) => r.to))].sort(cmp), ins = new Set((ctx.inc.get(n) || []).map((r) => r.from));
    return [tLink(n, ctx), String(t.columns.length), to.map((x) => tLink(x, ctx)).join(', '), ins.size ? `<span class="nw">${ins.size} 张表</span>` : '', esc(firstSentence(t.comment))];
  });
  const body = [
    `<h1>${withStatus(esc(g.label), g.status)}</h1>`,
    `<p class="lead">${DOC}的一个分组，${g.tables.length} 张表。${why}</p>`,
    parts,
    `<h2>关系图 ${origin('fact')}</h2>`,
    nodes.length
      ? '<p class="muted">一个方框是一张表，写主键（PK）与外键（FK）列，每条外键后面写着「→ 被引用的表」；被引用的表也在这一页的，另画一条连线，箭头指向它。点方框看那张表。</p>\n'
        + `<div class="scroll">${diagram(nodes, `${g.label} 组的关系图`)}</div>`
      : '<p class="muted">这一组没有表。</p>',
    `<h2>组内各表 ${origin('fact')}</h2>`,
    table(['表', '列数', '它引用了', '被引用', `注释的第一句 ${origin('comment')}`], rows),
  ].filter(Boolean).join('\n');
  return { path: `db/${g.file}`, html: page({ title: title(ctx, g.label), depth: 1, crumbs: crumbs([g.label]), body }) };
}

// 页面上会出现的文字里，形如内网地址或密钥的字样（契约 C 节）。只扫模型与配置，不回头读来源文件。
function leaks(model, cfg) {
  const hits = [], seen = new Set();
  const scan = (where, v) => {
    if (typeof v === 'string') {
      for (const [kind, re] of LEAKS) for (const m of v.matchAll(re)) {
        const k = `${where}\u0000${m[0]}`;
        if (!seen.has(k)) { seen.add(k); hits.push([esc(where), esc(kind), code(m[0])]); }
      }
    } else if (Array.isArray(v)) v.forEach((x) => scan(where, x));
    else if (v && typeof v === 'object') for (const k of Object.keys(v).sort(cmp)) scan(where, v[k]);
  };
  scan('配置', cfg);
  for (const t of model.tables) scan(`表 ${t.name}`, t);
  for (const v of model.views) scan(`视图 ${v.name}`, v);
  for (const f of model.functions) scan(`函数 ${f.name}`, f);
  for (const key of ['unfolded', 'unparsed', 'conflicts', 'orphanAlters', 'dynamic']) for (const x of model[key]) scan(`${x.file ?? ''} 第 ${x.line ?? '?'} 行`, x);
  return hits;
}

// 建表定义的四张问题清单形状不尽相同，按已知的键出列，其余简单值并进「原因」，不丢。
const KNOWN = new Set(['file', 'line', 'head', 'text', 'tables', 'table', 'column', 'reason']);
function issues(list, ctx) {
  const rows = list.map((x) => {
    const tabs = x.tables ? x.tables.map((n) => tLink(n, ctx)).join(', ') : x.table ? tLink(x.table, ctx) + (x.column ? `.${esc(x.column)}` : '') : '';
    const rest = Object.keys(x).filter((k) => !KNOWN.has(k) && x[k] != null && typeof x[k] !== 'object').sort(cmp).map((k) => `${esc(k)}：${esc(x[k])}`);
    return [at(x.file, x.line), tabs, code(x.head ?? x.text ?? ''), [x.reason ? esc(x.reason) : '', ...rest].filter(Boolean).join('<br>')];
  });
  const withWhy = rows.some((r) => r[3]);
  return table(['出处', '涉及的表', '原文开头', ...(withWhy ? ['原因'] : [])], withWhy ? rows : rows.map((r) => r.slice(0, 3)));
}

const ISSUES = [
  ['unfolded', '未合并的动态定义', '写在 DO 块里、要到库里运行时才生效的改动，静态读不出结果，没有并进上面的表结构。被点到的表，表页顶上有提示。'],
  ['unparsed', '未解析的语句', '形状是建表定义、却解析不了的语句。没有猜，原文开头列在这里。'],
  ['conflicts', '定义冲突', '同一样东西定义了两遍，或要删的约束找不到名字；文档保留先前的定义。'],
  ['orphanAlters', '改了不存在的表', '修改的是一张在建表定义里从没建过的表。'],
];

// 谁写谁读这一侧的四张清单（契约 F 节），空的不显示。每项 [模型里的键, 页内锚点, 标题, 说明, 表头, 一行]。
const CODE_LISTS = [
  ['dynamic', 'dynamic', '表名是运行时拼的', '代码里的 SQL 动词后面跟的是占位（如 <code>{table}</code>、<code>%s</code>），或字符串到动词就结束、后面接着拼接，或写表接口的第一个实参不是字符串——静态看不出是哪张表，表页上「取自来源」的写读里没有这几处。项目判断（<code>docs/readable-src/map.json</code> 的 <code>dynamicTables</code>）把这个文件归到具体表上的标「已归属」，那些表的页面上列着这个文件。',
    ['出处', '动作', '原文开头', '归属'], (d) => [at(d.file, d.line), esc(String(d.verb ?? '').toUpperCase()), code(d.head), d.assigned ? '<span class="o">已归属</span>' : '']],
  ['codeTables', 'code-tables', '代码里建的表', '代码的字符串里出现的 <code>CREATE TABLE</code>（带 <code>TEMP</code> 的不算），没有并进上面的表结构。配置的 <code>ddl</code> 列了的代码文件，里面的建表语句会并进来，不在这里。',
    ['出处', '表名'], (c, ctx) => [at(c.file, c.line), ctx.tables.has(c.name) ? tLink(c.name, ctx) : code(c.name)]],
  ['mapProblems', 'map-problems', '项目判断里对不上的', '<code>docs/readable-src/map.json</code> 里点到不存在的表或文件、一张表进了两个组、档位写错的，不拦生成，列在这里。',
    ['在哪', '怎么对不上'], (p) => [code(p.where), esc(p.problem)]],
  ['unscanned', 'unscanned', '没扫成的文件', '切到末尾还有没闭合的字符串，整个文件没扫，不出半截结果；这些文件里的写读不在任何一张表的页面上。',
    ['文件', '原因'], (u) => [code(u.file), esc(u.reason)]],
];

function indexPage(model, ctx) {
  const ncol = model.tables.reduce((s, t) => s + t.columns.length, 0), nidx = model.tables.reduce((s, t) => s + t.indexes.length, 0);
  const extra = [`${model.views.length} 个视图`, `${model.functions.length} 个数据库函数`];
  const hits = leaks(model, ctx.cfg);
  const warn = hits.length
    ? `<div class="notice" role="note"><p>来源与配置里有 ${hits.length} 处形如内网地址或密钥的字样，下面的页面原样照出了；要不要隐去还没定。</p>\n${table(['在哪', '像什么', '字样'], hits)}</div>`
    : '';
  const judgedGroups = model.groups.some((g) => g.status !== 'default' || g.id === '_ungrouped');
  const basis = judgedGroups
    ? '按项目判断（<code>docs/readable-src/map.json</code>）分组，组名后面标着是谁的判断；没被收进任何组的表在「未分组」。一组超过 12 张的按名字顺序分成几页。每组一页，有关系图。'
    : '按表名第一个下划线之前的那一段分组；只有一张表的前缀并进「其它」；一组超过 12 张的按名字顺序分成几页。每组一页，有关系图。';
  const groups = model.groups.map((grp) => {
    const pgs = ctx.pages.filter((p) => p.grp === grp);
    const split = pgs.length > 1 ? `<p class="muted">分成 ${pgs.length} 页：${pgs.map((p) => `<a href="${p.file}">${esc(p.label)}</a>`).join('、')}</p>\n` : '';
    return `<h3>${withStatus(`<a href="${pgs[0].file}">${esc(grp.title)}</a>`, grp.status)} <span class="muted">${grp.tables.length} 张表</span></h3>\n${split}`
      + table(['表', `注释的第一句 ${origin('comment')}`], grp.tables.map((n) => [tLink(n, ctx), esc(firstSentence(ctx.tables.get(n)?.comment))]));
  });
  const objs = (list, label, none, head, row) => `<h2>${label} ${origin('fact')}</h2>\n${list.length ? table(head, list.map(row)) : `<p class="muted">${none}</p>`}`;
  const body = [
    warn,
    `<h1>${DOC}</h1>`,
    `<p>来源（按执行顺序）：${ctx.cfg.ddl.map(code).join('、')} ${origin('fact')}</p>`,
    `<p class="lead">${[`${model.tables.length} 张表`, `${ncol} 列`, `${nidx} 个索引`, ...extra].join('、')}。一张表一页，下面先分组列出。</p>`,
    `<h2>分组${judgedGroups ? '' : ` ${origin('fact')}`}</h2>`, // 项目判断的组各自在组名后面标档位
    `<p class="muted">${basis}</p>`,
    ...groups,
    objs(model.views, '视图', '建表定义里没有视图。', ['名字', '出处', '定义原文'], (v) => [`<span id="${esc(v.anchor)}">${code(v.name)}</span>`, at(v.file, v.line), `<pre>${esc(v.sql)}</pre>`]),
    objs(model.functions, '数据库函数', '建表定义里没有数据库函数。', ['名字', '出处', '签名'], (f) => [`<span id="${esc(f.anchor)}">${code(f.name)}</span>`, at(f.file, f.line), code(f.signature)]),
    ...ISSUES.filter(([k]) => model[k].length).map(([k, label, what]) => `<h2>${label}（${model[k].length} 处）${origin('fact')}</h2>\n<p class="muted">${what}</p>\n${issues(model[k], ctx)}`),
    ...CODE_LISTS.filter(([k]) => model[k].length).map(([k, id, label, what, head, row]) => {
      const n = model[k].length, unit = k === 'mapProblems' ? '条' : k === 'unscanned' ? '个' : '处';
      const tail = k === 'dynamic' ? `，已归属 ${model[k].filter((d) => d.assigned).length} 处` : '';
      return `<h2 id="${id}">${label}（${n} ${unit}${tail}）${origin(k === 'mapProblems' ? 'fact' : 'code')}</h2>\n<p class="muted">${what}</p>\n${table(head, model[k].map((x) => row(x, ctx)))}`;
    }),
    LEGEND,
  ].filter(Boolean).join('\n');
  return { path: 'db/index.html', html: page({ title: title(ctx), depth: 1, crumbs: [['文档首页', 'index.html'], [DOC]], body }) };
}

// 入口：模型 → 数据库设计的全部页面，外加首页上那一条目录项。stats 给命令行报数用。
export function renderDb(model, cfg) {
  const ctx = index(model, cfg);
  const files = [indexPage(model, ctx), ...ctx.pages.map((g) => groupPage(g, ctx)), ...model.tables.map((t) => tablePage(t, ctx))];
  return {
    entry: { href: 'db/index.html', label: DOC, summary: `${model.tables.length} 张表，分成 ${model.groups.length} 组` },
    files,
    stats: { tables: model.tables.length, groups: model.groups.length, groupPages: ctx.pages.length, largest: Math.max(0, ...ctx.pages.map((g) => g.tables.length)) },
  };
}
