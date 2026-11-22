// db.mjs —— 数据库设计的页面（契约 docs/readable-spec/phase1-db-contract.md C 节；架构稿 §2 render）。
// 为什么有它：接手团队第一步就看数据库设计，要能只看文档、不问原作者，说清任意一张表存的是什么（规格 SC-1）。
// 只读文档模型（build --facts-json 那份），不回头读来源文件；出 [{path, html}]，落盘在入口。
// 没有注释的地方留空，不编；views / functions / unfolded[].tables 缺字段时当空处理（取事实器分批补齐）。
import { cmp } from '../model.mjs';
import { esc, code, multi, at, origin, fileSlug, page, table, diagram, LEGEND, DIAGRAM_MAX } from './layout.mjs';

export const GROUP_MAX = DIAGRAM_MAX; // 契约 C 节：一组超过 12 张表的切成几页，每页的关系图最多 12 张表
const OTHER = '其它', OTHER_SLUG = '_other';
const DOC = '数据库设计';
const CON_TYPE = { 'primary key': '主键', unique: '唯一', 'foreign key': '外键', check: 'CHECK' };
// 契约 C 节「不带出去的东西」：第一期原样照出，只在 db/index.html 顶上警告，隐不隐去待用户裁定。
const LEAKS = [
  ['内网地址', /\b(?:10\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])|192\.168)\.\d{1,3}\.\d{1,3}\b/g],
  ['疑似密钥', /-----BEGIN [A-Z ]*PRIVATE KEY-----|\bAKIA[0-9A-Z]{16}\b|\bsk-[A-Za-z0-9_-]{16,}|\b(?:password|passwd|secret|api[_-]?key|access[_-]?key|token)\s*[:=]\s*['"]?[^\s'",;)]{6,}/gi],
];

export const tableFile = (name) => `t-${fileSlug(name)}.html`;

// 分组（契约 C 节）：按表名第一个下划线之前的那一段；只有一张表的组并进「其它」，排最后；
// 超过 12 张的按名字顺序均分成几页（15 张 → 8 + 7），免得最后一页只剩一两张。
// 「其它」的文件名用 _other：真组名是第一个下划线之前的那段，不会含下划线，撞不上。
export function groupTables(names) {
  const by = new Map();
  for (const n of [...names].sort(cmp)) {
    const i = n.indexOf('_'), k = i > 0 ? n.slice(0, i) : n;
    (by.get(k) || by.set(k, []).get(k)).push(n);
  }
  const groups = [...by.keys()].filter((k) => by.get(k).length > 1).sort(cmp).map((k) => [k, fileSlug(k), by.get(k)]);
  const other = [...by.values()].filter((v) => v.length === 1).flat().sort(cmp);
  if (other.length) groups.push([OTHER, OTHER_SLUG, other]);
  return groups.flatMap(([base, slug, list]) => {
    const parts = Math.ceil(list.length / GROUP_MAX), small = Math.floor(list.length / parts), extra = list.length % parts;
    let from = 0;
    return Array.from({ length: parts }, (_, i) => {
      const size = small + (i < extra ? 1 : 0), suf = parts > 1 ? `-${i + 1}` : '';
      const g = { label: base + suf, base, part: i + 1, parts, file: `g-${slug}${suf}.html`, tables: list.slice(from, from + size) };
      from += size;
      return g;
    });
  });
}

// 外键两处来：列上的 REFERENCES 与表级 FOREIGN KEY，统一成 {from, cols, to, toCols, onDelete, onUpdate}。
function outRefs(t) {
  const col = t.columns.filter((c) => c.references).map((c) => [[c.name], c.references]);
  const con = t.constraints.filter((c) => c.type === 'foreign key' && c.references).map((c) => [c.columns || [], c.references]);
  return [...col, ...con].map(([cols, r]) => ({
    from: t.name, cols, to: r.table, toCols: r.columns || (r.column ? [r.column] : []), onDelete: r.onDelete, onUpdate: r.onUpdate,
  }));
}

const firstSentence = (s) => {
  if (!s) return '';
  const line = s.split('\n')[0], k = line.indexOf('。'), t = Array.from(k >= 0 ? line.slice(0, k + 1) : line);
  return t.length > 120 ? `${t.slice(0, 119).join('')}…` : t.join('');
};
const unfoldedHead = (u) => u.head ?? u.text ?? '';
const unfoldedTables = (u) => (Array.isArray(u.tables) ? u.tables : []);

function index(model, cfg) {
  const tables = new Map(model.tables.map((t) => [t.name, t]));
  const groups = groupTables([...tables.keys()]), groupOf = new Map();
  for (const g of groups) for (const n of g.tables) groupOf.set(n, g);
  const out = new Map(), inc = new Map(), unfoldedBy = new Map();
  for (const t of model.tables) {
    out.set(t.name, outRefs(t));
    for (const r of out.get(t.name)) (inc.get(r.to) || inc.set(r.to, []).get(r.to)).push(r);
  }
  for (const u of model.unfolded || []) {
    for (const n of new Set(unfoldedTables(u))) if (tables.has(n)) (unfoldedBy.get(n) || unfoldedBy.set(n, []).get(n)).push(u);
  }
  for (const list of inc.values()) list.sort((a, b) => cmp(a.from, b.from) || cmp(a.cols.join(','), b.cols.join(',')));
  return { cfg, tables, groups, groupOf, out, inc, unfoldedBy };
}

const tLink = (name, ctx) => (ctx.tables.has(name) ? `<a href="${tableFile(name)}">${esc(name)}</a>` : esc(name));
const cols = (list) => list.map(esc).join(', ');
const refText = (r, ctx) => `${tLink(r.to, ctx)}${r.toCols.length ? ` (${cols(r.toCols)})` : ''}${r.onDelete ? ` · ON DELETE ${esc(r.onDelete)}` : ''}${r.onUpdate ? ` · ON UPDATE ${esc(r.onUpdate)}` : ''}`;
const crumbs = (...rest) => [['文档首页', 'index.html'], [DOC, 'db/index.html'], ...rest];
const title = (ctx, ...parts) => [...parts, DOC, ctx.cfg.title].join(' · ');

function tablePage(t, ctx) {
  const g = ctx.groupOf.get(t.name), unf = ctx.unfoldedBy.get(t.name) || [];
  const hint = unf.length
    ? `<div class="notice" role="note"><p>这张表有 ${unf.length} 处要到库里运行时才生效的改动没有并进来，下面的约束可能与库里不一致</p>\n<ul>${unf.map((u) => `<li>${at(u.file, u.line)}：${code(unfoldedHead(u))}</li>`).join('\n')}</ul></div>\n`
    : '';
  const fields = t.columns.map((c, i) => [
    String(i + 1), code(c.name), code(c.type), c.nullable ? '是' : '否', c.default == null ? '' : code(c.default),
    [c.primaryKey && '主键', c.unique && '唯一', c.check && code(c.check)].filter(Boolean).join('<br>'),
    c.references ? `<span class="nw">${refText({ to: c.references.table, toCols: c.references.column ? [c.references.column] : [], onDelete: c.references.onDelete, onUpdate: c.references.onUpdate }, ctx)}</span>` : '',
    c.comment ? multi(c.comment) : '',
  ]);
  // 约束与索引多半和表写在同一个文件里，同文件只写行号，不同才写全。
  const near = (file, line) => (file === t.file ? `第 ${esc(line)} 行` : at(file, line));
  const cons = t.constraints.map((c) => [esc(CON_TYPE[c.type] || c.type), c.name ? code(c.name) : '', cols(c.columns || []), code(c.raw ?? c.check ?? ''), near(c.file, c.line)]);
  const idx = t.indexes.map((x) => [code(x.name ?? ''), code(x.columns ?? '') + (x.options ? ` ${code(x.options)}` : ''), x.unique ? '是' : '', esc(x.method ?? ''), x.where ? code(x.where) : '', near(x.file, x.line)]);
  const outs = ctx.out.get(t.name), ins = ctx.inc.get(t.name) || [];
  const body = [
    hint,
    `<h1>${esc(t.name)}</h1>`,
    `<p>出处：${at(t.file, t.line)} ${origin('fact')}<br>所在的组：<a href="${g.file}">${esc(g.label)}</a></p>`,
    `<h2>注释 ${origin('comment')}</h2>`,
    t.comment ? `<p>${multi(t.comment)}</p>` : '<p class="muted">来源里没写这张表的注释。</p>',
    `<h2>字段（${t.columns.length} 个）${origin('fact')}</h2>`,
    table(['#', '名字', '类型', '可空', '默认', '键与约束', '引用', `注释 ${origin('comment')}`], fields),
    cons.length ? `<h2>表级约束 ${origin('fact')}</h2>\n${table(['类型', '名字', '列', '原文', '出处'], cons)}` : '',
    `<h2>索引 ${origin('fact')}</h2>`,
    idx.length ? table(['名字', '列', '唯一', '方法', '条件', '出处'], idx) : '<p class="muted">没有索引。</p>',
    `<h2>它引用了谁 ${origin('fact')}</h2>`,
    outs.length ? `<ul>${outs.map((r) => `<li>${cols(r.cols)} → ${refText(r, ctx)}</li>`).join('\n')}</ul>` : '<p class="muted">不引用别的表。</p>',
    `<h2>谁引用了它 ${origin('fact')}</h2>`,
    ins.length ? `<ul>${ins.map((r) => `<li>${tLink(r.from, ctx)} 的 ${cols(r.cols)}${r.toCols.length ? ` → 本表 ${cols(r.toCols)}` : ''}${r.onDelete ? ` · ON DELETE ${esc(r.onDelete)}` : ''}</li>`).join('\n')}</ul>` : '<p class="muted">没有别的表引用它。</p>',
    `<h2>说明 ${origin('note')}</h2>`,
    '<p class="muted">说明：未写</p>',
  ].filter(Boolean).join('\n');
  return { path: `db/${tableFile(t.name)}`, html: page({ title: title(ctx, t.name), depth: 1, crumbs: crumbs([g.label, `db/${g.file}`], [t.name]), body }) };
}

function groupPage(g, ctx) {
  const set = new Set(g.tables);
  // 方框里主键一行、每条外键一行：组合外键（session_id, batch_id）按一条写，不拆到各列上重复列目标表。
  const nodes = g.tables.map((name) => {
    const t = ctx.tables.get(name), refs = ctx.out.get(name), pk = t.columns.filter((c) => c.primaryKey).map((c) => c.name);
    const fk = refs.map((r) => `FK ${r.cols.join(', ')}${r.to === name ? ' → 本表' : set.has(r.to) ? '' : ` → ${r.to}`}`);
    const lines = [...(pk.length ? [`PK ${pk.join(', ')}`] : []), ...new Set(fk)];
    const parents = [...new Set(refs.map((r) => r.to))].filter((x) => x !== name && set.has(x)).sort(cmp);
    return { name, href: tableFile(name), lines, parents };
  });
  const sib = ctx.groups.filter((x) => x.base === g.base);
  const parts = g.parts > 1
    ? `<p>${esc(g.base)} 组共 ${sib.reduce((s, x) => s + x.tables.length, 0)} 张表，按名字顺序分成 ${g.parts} 页：${sib.map((x) => (x === g ? `<strong>${esc(x.label)}</strong>` : `<a href="${x.file}">${esc(x.label)}</a>`)).join('、')}</p>`
    : '';
  const rows = g.tables.map((n) => {
    const t = ctx.tables.get(n), to = [...new Set(ctx.out.get(n).map((r) => r.to))].sort(cmp), ins = new Set((ctx.inc.get(n) || []).map((r) => r.from));
    return [`<a href="${tableFile(n)}">${esc(n)}</a>`, String(t.columns.length), to.map((x) => tLink(x, ctx)).join(', '), ins.size ? `<span class="nw">${ins.size} 张表</span>` : '', esc(firstSentence(t.comment))];
  });
  const body = [
    `<h1>${esc(g.label)}</h1>`,
    `<p class="lead">${DOC}的一个分组，${g.tables.length} 张表。${g.base === OTHER ? '这里是表名前缀只有一张表的那些。' : `表名都以 <code>${esc(g.base)}_</code> 开头。`}</p>`,
    parts,
    `<h2>关系图 ${origin('fact')}</h2>`,
    '<p class="muted">一个方框是一张表，写主键（PK）与外键（FK）列；连线是组内的外键，箭头指向被引用的表；「→ 表名」指向组外的表。点方框看那张表。</p>',
    `<div class="scroll">${diagram(nodes, `${g.label} 组的关系图`)}</div>`,
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
  for (const v of model.views || []) scan(`视图 ${v.name}`, v);
  for (const f of model.functions || []) scan(`函数 ${f.name}`, f);
  for (const key of ['unfolded', 'unparsed', 'conflicts', 'orphanAlters']) for (const x of model[key] || []) scan(`${x.file ?? ''} 第 ${x.line ?? '?'} 行`, x);
  return hits;
}

// 四张问题清单的形状不尽相同，按已知的键出列，其余简单值并进「其它」，不丢。
const KNOWN = new Set(['file', 'line', 'head', 'text', 'tables', 'table', 'column', 'reason']);
function issues(list, ctx) {
  const rows = list.map((x) => {
    const tabs = x.tables ? unfoldedTables(x).map((n) => tLink(n, ctx)).join(', ') : x.table ? tLink(x.table, ctx) + (x.column ? `.${esc(x.column)}` : '') : '';
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

function indexPage(model, ctx) {
  const ncol = model.tables.reduce((s, t) => s + t.columns.length, 0), nidx = model.tables.reduce((s, t) => s + t.indexes.length, 0);
  const extra = [Array.isArray(model.views) && `${model.views.length} 个视图`, Array.isArray(model.functions) && `${model.functions.length} 个数据库函数`].filter(Boolean);
  const hits = leaks(model, ctx.cfg);
  const warn = hits.length
    ? `<div class="notice" role="note"><p>来源与配置里有 ${hits.length} 处形如内网地址或密钥的字样，下面的页面原样照出了；要不要隐去还没定。</p>\n${table(['在哪', '像什么', '字样'], hits)}</div>`
    : '';
  const groups = ctx.groups.map((g) => `<h3><a href="${g.file}">${esc(g.label)}</a> <span class="muted">${g.tables.length} 张表</span></h3>\n${table(['表', `注释的第一句 ${origin('comment')}`], g.tables.map((n) => [`<a href="${tableFile(n)}">${esc(n)}</a>`, esc(firstSentence(ctx.tables.get(n).comment))]))}`);
  const objs = (key, label, none, head, row) => {
    if (!Array.isArray(model[key])) return '';
    const list = model[key];
    return `<h2>${label} ${origin('fact')}</h2>\n${list.length ? table(head, list.map(row)) : `<p class="muted">${none}</p>`}`;
  };
  const body = [
    warn,
    `<h1>${DOC}</h1>`,
    `<p>来源（按执行顺序）：${ctx.cfg.ddl.map(code).join('、')} ${origin('fact')}</p>`,
    `<p class="lead">${[`${model.tables.length} 张表`, `${ncol} 列`, `${nidx} 个索引`, ...extra].join('、')}。一张表一页，下面先按表名前缀分组列出。</p>`,
    `<h2>分组 ${origin('fact')}</h2>`,
    '<p class="muted">按表名第一个下划线之前的那一段分组；只有一张表的前缀并进「其它」；一组超过 12 张的按名字顺序分成几页。每组一页，有关系图。</p>',
    ...groups,
    objs('views', '视图', '建表定义里没有视图。', ['名字', '出处', '定义原文'], (v) => [`<span id="${esc(v.anchor)}">${code(v.name)}</span>`, at(v.file, v.line), `<pre>${esc(v.sql)}</pre>`]),
    objs('functions', '数据库函数', '建表定义里没有数据库函数。', ['名字', '出处', '签名'], (f) => [`<span id="${esc(f.anchor)}">${code(f.name)}</span>`, at(f.file, f.line), code(f.signature)]),
    ...ISSUES.filter(([k]) => (model[k] || []).length).map(([k, label, what]) => `<h2>${label}（${model[k].length} 处）${origin('fact')}</h2>\n<p class="muted">${what}</p>\n${issues(model[k], ctx)}`),
    LEGEND,
  ].filter(Boolean).join('\n');
  return { path: 'db/index.html', html: page({ title: title(ctx), depth: 1, crumbs: [['文档首页', 'index.html'], [DOC]], body }) };
}

// 入口：模型 → 数据库设计的全部页面，外加首页上那一条目录项。stats 给命令行报数用。
export function renderDb(model, cfg) {
  const ctx = index(model, cfg);
  const files = [indexPage(model, ctx), ...ctx.groups.map((g) => groupPage(g, ctx)), ...model.tables.map((t) => tablePage(t, ctx))];
  const bases = new Set(ctx.groups.map((g) => g.base));
  return {
    entry: { href: 'db/index.html', label: DOC, summary: `${model.tables.length} 张表，按表名前缀分成 ${bases.size} 组` },
    files,
    stats: { tables: model.tables.length, groups: bases.size, groupPages: ctx.groups.length, largest: Math.max(0, ...ctx.groups.map((g) => g.tables.length)) },
  };
}
