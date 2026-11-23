// check-arch.mjs —— 核对的一项：架构这一份的页面上显示的与重新取的事实逐项相同（第三期契约 docs/readable-spec/phase3-arch-contract.md E 节；规格 REQ-DOC-007）。
// 为什么有它：这一步最贵的错是页面上的模块事实与汇总的事实对不上而看不出来——架构师照着错的依赖去改，
// 开发照着表页上标错的模块去改了别的模块的文件。所以不信出页面的代码：架构稿 §3 禁边，这里不 import render/ 下的任何东西，
// 页面靠 check-read.mjs 照 D 节末尾那张表读回来（data-section 里一行一条的 data-row，要比的格子 data-k），与 facts.arch、facts.code 比。
// 比的项（E 节）：架构首页的模块（id、文件数、接口数）与未归属的文件；每个模块页的文件（路径、规模档）、接口（方法、路径、处理函数）、
// 它依赖的模块、对外提供的名字（连同被哪几个模块用）、读写的表；接口总表的每一条（连同所属模块）；表页上每个文件标的模块。
// 对不上的 kind 都是 arch-mismatch，点到哪一页、哪个模块、哪一项。说明区（module:<id>、doc:arch）的读回借 check.mjs 的 noteRegions，
// 由调用方交进来——两边一份规矩，也免得这里反过来 import check.mjs。说明的过期与孤儿由 check.mjs 照第一期的办法逐段报。
// 项目判断里对不上的（arch.problems）各算一条、kind 是 arch-map，只在 check 里报，不拦 build 的落盘（不拦生成，契约 A 节）。
import { cmp } from './model.mjs';
import { redact } from './sensitive.mjs';
import { findAll, textOf, squash, sectionRows } from './check-read.mjs';

const INDEX = 'arch/index.html', ROUTES = 'arch/routes.html', MOD_PAGE = /^arch\/m-[^/]*\.html$/, TABLE_PAGE = /^db\/t-[^/]*\.html$/;
const UNASSIGNED = '未归属';
// 文件的规模档（D 节「确切的行数不上页面」）：照契约自己写一份，不借出页面的代码——四档，恰好 100、500、1000 行的归上面一档。
const band = (n) => (n < 100 ? '不到 100 行' : n < 500 ? '100–500 行' : n < 1000 ? '500–1000 行' : '1000 行以上');
const FIELD = { size: '规模', method: '方法', path: '路径', handler: '处理函数', by: '被哪几个模块用', rw: '读写', files: '文件数', routes: '接口数', module: '模块' };
// 文件名由 id 推出（同第一期的推法，照契约自己推，不借出页面的代码）；模块 id 只许小写字母、数字与连字符，推出来就是它自己。
const slug = (s) => String(s).replace(/[^a-z0-9_-]/gu, (c) => `~${c.codePointAt(0).toString(16)}`);
const modPage = (id) => `arch/m-${slug(id)}.html`;
// 页面上显示的是隐去后的字（D 节末段）：键（data-row 的值）照原样比，格子里的字空白归一后比。
const key = (s) => redact(String(s)).text;
const shown = (s) => squash(redact(String(s)).text);
const clip = (list) => `${list.slice(0, 5).map((x) => `「${x}」`).join('、')}${list.length > 5 ? ` 等 ${list.length} 条` : ''}`;
const group = (xs) => { const m = new Map(); for (const x of xs) (m.get(x.key) ?? m.set(x.key, []).get(x.key)).push(x); return m; };

// 一段里的行与事实比：键少了的、多了的各报一条（举头几个）；键对上的再逐格比 fields。同一个键可以有几行（同方法同路径的接口），按多重集比。
function compare(got, want, fields, what, add) {
  const g = group(got), w = group(want), tup = (x) => fields.map((f) => x.k[f] ?? '（没有这一格）');
  const missing = [], extra = [];
  for (const [k, list] of w) {
    const have = g.get(k) || [];
    for (let i = have.length; i < list.length; i++) missing.push(k);
    const ws = list.map(tup).sort((a, b) => cmp(a.join('\u0001'), b.join('\u0001'))), gs = have.map(tup).sort((a, b) => cmp(a.join('\u0001'), b.join('\u0001')));
    for (let i = 0; i < Math.min(ws.length, gs.length); i++) {
      const diff = fields.map((f, j) => (gs[i][j] === ws[i][j] ? null : `${FIELD[f] ?? f}：页面上是「${gs[i][j]}」，来源是「${ws[i][j]}」`)).filter(Boolean);
      if (diff.length) add(`${what}「${k}」的${diff.join('；')}`);
    }
  }
  for (const [k, list] of g) for (let i = w.get(k)?.length ?? 0; i < list.length; i++) extra.push(k);
  if (missing.length) add(`${what}少了 ${missing.length} 条：${clip(missing)}`);
  if (extra.length) add(`${what}多了 ${extra.length} 条，来源里没有：${clip(extra)}`);
}

function section(tree, name, want, fields, what, add) {
  const s = sectionRows(tree, name);
  if (s.sections !== 1) add(`「${what}」这一段（data-section="${name}"）${s.sections ? `出现了 ${s.sections} 处` : '不见了'}`);
  if (s.sections) compare(s.rows, want, fields, what, add);
}

const routeWant = (r, extra = {}) => ({ key: key(`${r.method} ${r.fullPath ?? r.path}`), k: { method: shown(r.method), path: shown(r.fullPath ?? r.path), handler: shown(r.handler), ...extra } });

function modulePage(tree, m, lines, add) {
  const anchors = findAll(tree, (n) => n.tag === 'main').map((n) => n.attrs['data-anchor']);
  if (anchors.length !== 1 || anchors[0] !== `module:${m.id}`) add(`页里的模块锚点是${anchors.length ? anchors.map((a) => `「${a ?? '（没有）'}」`).join('、') : '（没有）'}，按文件名应是「module:${m.id}」`);
  const tables = [...new Set([...m.tables.reads, ...m.tables.writes])].sort(cmp);
  const rw = (t) => (m.tables.reads.includes(t) ? '读' : '') + (m.tables.writes.includes(t) ? '写' : '');
  section(tree, 'files', m.files.map((f) => ({ key: key(f), k: { size: band(lines.get(f)) } })), ['size'], '文件', add);
  section(tree, 'routes', m.routes.map((r) => routeWant(r)), ['method', 'path', 'handler'], '接口', add);
  section(tree, 'uses', m.uses.map((u) => ({ key: u.module, k: {} })), [], '它依赖的模块', add);
  section(tree, 'provides', m.provides.map((p) => ({ key: key(`${p.file}#${p.name}`), k: { by: p.by.join(' ') } })), ['by'], '对外提供的名字', add);
  section(tree, 'tables', tables.map((t) => ({ key: t, k: { rw: rw(t) } })), ['rw'], '读写的表', add);
}

// 表页上「谁在写、谁在读」的每个文件标的模块（D 节）：沿用第一期的行（data-row="writer" / "reader"），行里多一格 data-k="module"，
// 文字是模块 id、未归属的写「未归属」；标了模块的还要链到那个模块页。文件取这一行显示的第一个等宽块（第一期表页的路径就写在那里）。
// 没有架构这一份的项目，表页上不该有这一格。
function tableMarks(rd, owner, label, out) {
  for (const rel of rd.html.filter((r) => TABLE_PAGE.test(r))) {
    for (const r of sectionRows(rd.tree(rel), null).rows.filter((x) => x.key === 'writer' || x.key === 'reader')) {
      const c = findAll(r.node, (n) => n.tag === 'code')[0], file = c ? textOf(c) : '（读不出文件）', who = `谁在${r.key === 'writer' ? '写' : '读'}这张表的 ${file}`;
      const add = (detail) => out.push({ kind: 'arch-mismatch', where: label + rel, detail: `${who}：${detail}` });
      if (!owner) { if (r.k.module !== undefined) add(`这个项目没有架构这一份，却标了模块「${r.k.module}」`); continue; }
      const want = owner.get(file) ?? UNASSIGNED;
      if (r.k.module === undefined) { add(`没有标模块，应是「${want}」`); continue; }
      if (r.k.module !== want) { add(`标的模块是「${r.k.module}」，应是「${want}」`); continue; }
      const href = `../${modPage(want)}`;
      if (want !== UNASSIGNED && !findAll(r.node, (n) => n.tag === 'a' && n.attrs.href === href).length) add(`标了模块 ${want}，却没有链到 ${href}`);
    }
  }
}

// 整项。rd：check-read 的 reader；facts：重新取的文档模型（带说明）；noteRegions：check.mjs 的说明区读回（交进来，见文件头）。
export function archFacts(rd, facts, label, noteRegions) {
  const out = [], mods = facts.arch?.modules ?? [], notes = facts.notes || {}, has = new Set(rd.html);
  const owner = mods.length ? new Map(mods.flatMap((m) => m.files.map((f) => [f, m.id]))) : null;
  tableMarks(rd, owner, label, out);
  if (!mods.length) return out;
  const at = (rel, anchor) => `${label}${rel}${anchor ? ` · ${anchor}` : ''}`;
  const page = (rel, anchor, notesHere, fn) => {
    if (!has.has(rel)) { out.push({ kind: 'missing-page', where: at(rel), detail: `${anchor ?? '架构这一份'}的页不在` }); return; }
    const tree = rd.tree(rel);
    fn(tree, (detail) => out.push({ kind: 'arch-mismatch', where: at(rel, anchor), detail }));
    noteRegions(tree, notesHere, notes, (kind, a, detail) => out.push({ kind, where: at(rel, a), detail }));
  };
  page(INDEX, null, ['doc:arch'], (tree, add) => {
    section(tree, 'modules', mods.map((m) => ({ key: m.id, k: { files: String(m.files.length), routes: String(m.routes.length) } })), ['files', 'routes'], '模块清单', add);
    section(tree, 'unassigned', facts.arch.unassigned.map((p) => ({ key: key(p), k: {} })), [], '未归属的文件', add);
  });
  page(ROUTES, null, [], (tree, add) => section(tree, 'routes',
    facts.code.routes.map((r) => routeWant(r, { module: owner.get(r.file) ?? UNASSIGNED })), ['method', 'path', 'handler', 'module'], '接口总表', add));
  const lines = new Map(facts.code.files.map((f) => [f.path, f.lines])), want = new Set();
  for (const m of mods) {
    want.add(modPage(m.id));
    page(modPage(m.id), `module:${m.id}`, [`module:${m.id}`], (tree, add) => modulePage(tree, m, lines, add));
  }
  for (const rel of rd.html) if (MOD_PAGE.test(rel) && !want.has(rel)) out.push({ kind: 'extra-page', where: at(rel), detail: '这一页对不上任何一个现行的模块' });
  return out;
}

// 项目判断里对不上的（E 节）：各算一条，kind 是 arch-map——要人去改 map.json，与「页面对不上事实、要重出或查出页面的代码」的
// arch-mismatch 分开。描述先过隐去——标准错误进日志，日志也是带出去的地方。
export const archProblems = (facts) => (facts.arch?.problems ?? []).map((p) => ({
  kind: 'arch-map', where: `docs/readable-src/map.json${p.module ? ` modules · ${redact(p.module).text}` : ''}`, detail: `项目判断里对不上（${p.kind}）：${redact(p.detail).text}`,
}));

// 摘要里架构的几个数（没写说明不算不一致，只报数）；没有模块的项目不出这个键，摘要与加这一项之前逐字相同。
export function archSummary(facts) {
  const mods = facts.arch?.modules ?? [], notes = facts.notes || {};
  if (!mods.length) return {};
  return { arch: { modules: mods.length, routes: facts.code.routes.length, problems: facts.arch.problems.length, unwrittenModules: mods.filter((m) => !notes[`module:${m.id}`]).length, doc: !notes['doc:arch'] } };
}
export const archLine = (s) => (s.arch ? `；架构：模块 ${s.arch.modules} 个、接口 ${s.arch.routes} 个、项目判断里对不上的 ${s.arch.problems} 条；没写说明的（不算不一致）：模块 ${s.arch.unwrittenModules} 个、doc:arch ${s.arch.doc ? '没写' : '已写'}` : '');
