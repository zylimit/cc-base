// check.mjs —— 核对：逐项比对文档与来源，出一份不一致清单（契约 docs/readable-spec/phase1-db-contract.md H 节；规格 REQ-DOC-007）。
// 为什么有它：接手的人没有 AI 编程工具、拿文档当真，字段类型写错一个，他们会照着错的去写代码；清单为空才算同步
// （FLOW-2：AI 改了来源、重出、重写过期的说明之后，核对报不一致 0 条，这次改动才算完）。四项：
//   1 页面是不是现行的：入口用出页面的函数在内存里重出一遍交进来，这里与 docs/readable/ 逐文件逐字节比；
//   2 页面上显示的与事实一致：不信出页面的代码，用 check-read.mjs 自带的读取器把磁盘上的页面读回来，与重新取的事实比——
//     出页面的代码吞了字、串了行，第 1 项两边错得一样看不出来，靠这一项；
//   3 说明：指纹对不上的、锚点已经不存在的；4 指向不存在的东西：map.json 里对不上的、站内链接的目标文件不在的。
// 配了需求规格的再多一项（第二期契约 D 节，check-spec.mjs 的 specFacts）：重新切的块与 spec/ 下各页读回的 data-block 一块不少、一字不差。
// 架构稿 §3 禁边：这里不 import render/ 下的任何东西；第 1 项要的重出结果由入口交进来（与 build 落盘用的是同一个出页面的函数）。
// build 落盘前对临时目录跑第 2 项，再把每一页的文字过一遍隐去规则（selfCheck），不过就抛 CheckFailed，
// publish 删掉临时目录、原有页面不动，入口报退出码 3。
// 测试注入点：READABLE_FAIL_AT=selfcheck 时，自检拿到的事实里第一张表多一个列，模拟「出页面的代码少出了一个列」；
// READABLE_FAIL_AT=leak 在出页面那一侧（render/db-scrub.mjs），模拟某个上页面的字段忘了过隐去，由这里的兜底拦下；
// READABLE_FAIL_AT=spec-render 也在出页面那一侧（render/spec.mjs），由这里跑的需求规格那一项（check-spec.mjs）拦下。
import { readdirSync, readFileSync, existsSync } from 'node:fs';
import { join, posix } from 'node:path';
import { cmp } from './model.mjs';
import { redact } from './sensitive.mjs';
import { parse, findAll, textOf, squash, segments } from './check-read.mjs';
import { specFacts } from './check-spec.mjs';

export class CheckFailed extends Error {
  constructor(problems) {
    super(`build 落盘前的自检不过（核对第 2 项「页面上显示的与事实一致」，以及隐去的兜底），新页面没有换上，原有页面一个字节没动：\n${lines(problems).join('\n')}`);
    this.problems = problems;
  }
}

// 文件名由表名推出（契约 C 节）：小写字母、数字、下划线、连字符以外的字符（大写字母也算）写成「~十六进制码点」。
// 照契约自己推，不借出页面的代码。
const slug = (name) => String(name).replace(/[^a-z0-9_-]/gu, (c) => `~${c.codePointAt(0).toString(16)}`);
const tablePath = (name) => `db/t-${slug(name)}.html`;
const TABLE_PAGE = /^db\/t-[^/]*\.html$/;
const GROUP_MAX = 12; // 契约 C 节：一组超过 12 张表的切成几页
// 页面上显示的是隐去后的文字（契约 G 节「不带出去的东西」）：契约点名要隐去的默认值与说明正文，比对前事实一侧也过一遍。
const shown = (s) => squash(redact(s).text);
// 说明正文显示成的纯文字（契约 G 节「存放」的写法）：「- 」开头的行是列表项，前缀不显示；反引号里的是等宽字，反引号不显示。
const notePlain = (text) => squash(redact(text).text.replace(/\r\n?/g, '\n').split('\n')
  .map((l) => (l.startsWith('- ') ? l.slice(2) : l)).join('\n').replace(/`([^`\n]+)`/g, '$1'));
// 说明区的读回标记（契约 C 节）：没有说明是 none，过期的是 stale，其余是侧车里记的 draft / reviewed。
const wantState = (n) => (!n ? 'none' : n.state === 'stale' ? 'stale' : n.status);
const groupBy = (xs, key) => { const m = new Map(); for (const x of xs) { const k = key(x); if (!m.has(k)) m.set(k, []); m.get(k).push(x); } return m; };
// 两段文字从哪里开始不同，各取一小截给人看。
function diffAt(got, want) {
  let i = 0;
  while (i < got.length && i < want.length && got[i] === want[i]) i++;
  const cut = (s) => `${i > 12 ? '…' : ''}${s.slice(Math.max(0, i - 12), i + 24)}${s.length > i + 24 ? '…' : ''}`;
  return `第 ${i + 1} 个字起不同，页面上「${cut(got)}」，侧车「${cut(want)}」`;
}
function firstDiffLine(got, want) {
  const a = got.split('\n'), b = want.split('\n');
  let i = 0;
  while (i < a.length && i < b.length && a[i] === b[i]) i++;
  return `第 ${i + 1} 行起`;
}

// 目录下的文件（相对路径、/ 分隔、按名字定序）与按需读成树的页面。
function reader(dir) {
  const files = [];
  const visit = (d, rel) => {
    for (const e of readdirSync(d, { withFileTypes: true }).sort((a, b) => cmp(a.name, b.name))) {
      const r = rel ? `${rel}/${e.name}` : e.name;
      if (e.isDirectory()) visit(join(d, e.name), r);
      else if (e.isFile()) files.push(r);
    }
  };
  if (existsSync(dir)) visit(dir, '');
  const cache = new Map();
  const tree = (rel) => { if (!cache.has(rel)) cache.set(rel, parse(readFileSync(join(dir, rel), 'utf8'))); return cache.get(rel); };
  return { dir, files, html: files.filter((f) => f.endsWith('.html')), tree };
}

// 第 1 项：重出的与磁盘上的逐文件逐字节比。
function pagesCurrent(rd, rendered, label) {
  const out = [], want = new Map(rendered.map((f) => [f.path, f.html])), disk = new Set(rd.files);
  for (const rel of [...want.keys()].sort(cmp)) {
    if (!disk.has(rel)) { out.push({ kind: 'missing-page', where: label + rel, detail: '重出有这一页，磁盘上没有（改了来源或配置之后没重出，或者这一页被删了）' }); continue; }
    const got = readFileSync(join(rd.dir, rel)), html = want.get(rel);
    if (!got.equals(Buffer.from(html))) out.push({ kind: 'stale-page', where: label + rel, detail: `与重出的不同（${firstDiffLine(got.toString('utf8'), html)}）：来源、配置、项目判断或说明改了没重出，或者有人手改了这一页` });
  }
  for (const rel of rd.files) if (!want.has(rel)) out.push({ kind: 'extra-page', where: label + rel, detail: '磁盘上有这一页，重出没有它（表删了或改名了没重出，或者是别处放进来的）' });
  return out;
}

// 一个说明区：状态与侧车一致；有说明时正文的纯文字与侧车的一致，没有说明时不该有正文。
// 正文在哪：说明区里带 data-k="note" 的那一块（表页、组页、清单页顶上的说明区，字段表「含义」格里的说明都是）——
// 只认契约 C 节的读回标记，不认样式类名；格子里并排的「来源里的注释」带的是 data-k="comment"，不算说明的正文。
function noteRegion(r, anchor, n, add) {
  const state = r.attrs['data-state'], want = wantState(n);
  if (state !== want) { add('note-mismatch', anchor, `说明的状态：页面上是「${state ?? '（没标）'}」，侧车是「${want}」`); return; }
  const bodies = findAll(r, (x) => x.attrs['data-k'] === 'note');
  if (!n) { if (bodies.length) add('note-mismatch', anchor, '侧车里没有这段说明，页面上却有说明的正文'); return; }
  if (bodies.length !== 1) { add('note-mismatch', anchor, bodies.length ? `说明的正文出现了 ${bodies.length} 处` : '页面上看不到说明的正文'); return; }
  const got = textOf(bodies[0]), plain = notePlain(n.text);
  if (got !== plain) add('note-mismatch', anchor, `说明的正文与侧车不同：${diffAt(got, plain)}`);
}

// 一页上的说明区恰好是 anchors 这几个，各一处。
function noteRegions(tree, anchors, notes, add) {
  const regions = groupBy(findAll(tree, (n) => n.attrs['data-note'] !== undefined), (n) => n.attrs['data-note']);
  for (const a of regions.keys()) if (!anchors.includes(a)) add('note-mismatch', a, '这一页不该有这个锚点的说明区');
  for (const a of anchors) {
    const list = regions.get(a) || [];
    if (list.length !== 1) add('note-mismatch', a, list.length ? `说明区出现了 ${list.length} 处` : '页面上没有这个锚点的说明区');
    else noteRegion(list[0], a, notes[a], add);
  }
}

// 字段行里六格应显示的文字（契约 C 节「机器读得回来」）。照契约与页面的显示约定自己写一份，不借出页面的代码：
// 键与约束是「主键」「唯一」、CHECK 原文、GENERATED 原文依次各占一行；引用是「表 (列) · ON DELETE 动作 · ON UPDATE 动作」；
// 来源注释是注释原文，没有注释的列这一块不出（读回为空）。取自来源的文字页面上显示的是隐去后的，这里也先过一遍。
function cellWants(c) {
  const r = c.references;
  return [
    ['type', '类型', shown(c.type)],
    ['nullable', '可空', c.nullable ? '是' : '否'],
    ['default', '默认', c.default == null ? '' : shown(c.default)],
    ['key', '键与约束', squash([c.primaryKey && '主键', c.unique && '唯一', c.check && shown(c.check), c.generated && shown(c.generated)].filter(Boolean).join(' '))],
    ['ref', '引用', r ? squash(`${r.table}${r.column ? ` (${r.column})` : ''}${r.onDelete ? ` · ON DELETE ${r.onDelete}` : ''}${r.onUpdate ? ` · ON UPDATE ${r.onUpdate}` : ''}`) : ''],
  ];
}

// 表级约束、索引、写它的文件、读它的文件：页面上带 data-row 的行数与事实一致（写读按文件算，一个文件一行）。
function rowCounts(tree, t, usage, add) {
  const files = (kind) => new Set((usage?.[t.name]?.[kind] || []).map((e) => e.file)).size;
  const want = [['constraint', '表级约束', (t.constraints || []).length], ['index', '索引', (t.indexes || []).length], ['writer', '写它的文件', files('writes')], ['reader', '读它的文件', files('reads')]];
  for (const [kind, what, n] of want) {
    const got = findAll(tree, (x) => x.attrs['data-row'] === kind).length;
    if (got !== n) add('fact-mismatch', null, `${what}：页面上 ${got} 行，来源里 ${n} 条${got < n ? `，少了 ${n - got} 条` : `，多了 ${got - n} 条`}`);
  }
}

// 表页：表锚点与文件名对得上；每个列恰有一行，六格与事实一致，没有事实里没有的列；四张表的行数一致；说明区一致。
function tablePage(tree, t, notes, usage, add) {
  const anchors = findAll(tree, (n) => n.tag === 'main').map((m) => m.attrs['data-anchor']).filter((a) => a !== undefined);
  if (anchors.length !== 1 || anchors[0] !== t.anchor) add('fact-mismatch', null, `页里的表锚点是${anchors.length ? anchors.map((a) => `「${a}」`).join('、') : '（没有）'}，按文件名应是「${t.anchor}」`);
  const rows = groupBy(findAll(tree, (n) => String(n.attrs['data-anchor'] ?? '').startsWith('column:')), (n) => n.attrs['data-anchor']);
  const mine = new Set(t.columns.map((c) => c.anchor));
  for (const a of rows.keys()) if (!mine.has(a)) add('fact-mismatch', a, '页面上有这一列，来源里这张表没有它');
  for (const c of t.columns) {
    const list = rows.get(c.anchor) || [];
    if (list.length !== 1) { add('fact-mismatch', c.anchor, list.length ? `页面上这一列出现了 ${list.length} 行` : '页面上少了这一列'); continue; }
    for (const [k, what, want] of cellWants(c)) {
      const found = findAll(list[0], (n) => n.attrs['data-k'] === k);
      if (found.length !== 1) { add('fact-mismatch', c.anchor, `${what}格${found.length ? `出现了 ${found.length} 个` : '不见了'}`); continue; }
      const got = textOf(found[0]);
      if (got !== want) add('fact-mismatch', c.anchor, `${what}：页面上是「${got}」，来源是「${want}」`);
    }
    // 来源注释：有注释的列恰有一块，没有的一块都没有；块里的文字就是注释原文（隐去后）。
    const com = findAll(list[0], (n) => n.attrs['data-k'] === 'comment'), want = c.comment == null || c.comment === '' ? '' : shown(c.comment);
    if (com.length > 1) add('fact-mismatch', c.anchor, `来源注释出现了 ${com.length} 处`);
    else if ((com.length ? textOf(com[0]) : '') !== want) add('fact-mismatch', c.anchor, `来源注释：页面上是「${com.length ? textOf(com[0]) : '（没有）'}」，来源是「${want || '（没有）'}」`);
  }
  rowCounts(tree, t, usage, add);
  // 少了的列上面已经报过，它的说明区不再另报一条「没有」。
  noteRegions(tree, [t.anchor, ...t.columns.filter((c) => rows.has(c.anchor)).map((c) => c.anchor)], notes, add);
}

// 第 2 项：把 dir 下的页面读回来与事实比。label 是给人看的位置前缀。
function pageFacts(rd, facts, label) {
  const out = [], notes = facts.notes || {};
  const at = (rel, anchor) => `${label}${rel}${anchor ? ` · ${anchor}` : ''}`;
  const has = new Set(rd.html), expected = new Map();
  for (const t of facts.tables) {
    const p = tablePath(t.name);
    if (expected.has(p)) out.push({ kind: 'fact-mismatch', where: at(p), detail: `表 ${expected.get(p).name} 与 ${t.name} 推出的文件名相同，只有一页` });
    else expected.set(p, t);
  }
  for (const rel of rd.html) if (TABLE_PAGE.test(rel) && !expected.has(rel)) out.push({ kind: 'extra-page', where: at(rel), detail: '这一页对不上任何一张现行的表' });
  for (const [rel, t] of expected) {
    if (!has.has(rel)) { out.push({ kind: 'missing-page', where: at(rel), detail: `表 ${t.name} 没有页面` }); continue; }
    tablePage(rd.tree(rel), t, notes, facts.usage, (kind, anchor, detail) => out.push({ kind, where: at(rel, anchor), detail }));
  }
  // 别的页上的说明区：数据库设计清单页一个 doc:db；组页每页一个本组的（契约 C、F 节：g-<组 id>.html，超过 12 张表的均分成几页、接 -1、-2）。
  const hosts = new Map([['db/index.html', ['doc:db']]]);
  for (const g of facts.groups) {
    const parts = Math.max(1, Math.ceil(g.tables.length / GROUP_MAX));
    for (let i = 1; i <= parts; i++) {
      const p = `db/g-${slug(g.id)}${parts > 1 ? `-${i}` : ''}.html`;
      hosts.set(p, [...(hosts.get(p) || []), `group:${g.id}`]);
    }
  }
  for (const [rel, anchors] of hosts) {
    if (!has.has(rel)) { out.push({ kind: 'missing-page', where: at(rel), detail: `${anchors.join('、')} 的说明区所在的页不在` }); continue; }
    noteRegions(rd.tree(rel), anchors, notes, (kind, anchor, detail) => out.push({ kind, where: at(rel, anchor), detail }));
  }
  for (const rel of rd.html) {
    if (TABLE_PAGE.test(rel) || hosts.has(rel)) continue;
    if (/^db\/g-[^/]*\.html$/.test(rel)) { out.push({ kind: 'extra-page', where: at(rel), detail: '这一页对不上任何一个现行的组' }); continue; }
    for (const r of findAll(rd.tree(rel), (n) => n.attrs['data-note'] !== undefined)) out.push({ kind: 'note-mismatch', where: at(rel, r.attrs['data-note']), detail: '这一页不该有这个锚点的说明区' });
  }
  return out;
}

// 第 4 项的后一半：站内链接的目标文件不在的。带协议的、只有 # 的不是站内的页。
function danglingLinks(rd, label) {
  const out = [], files = new Set(rd.files);
  for (const rel of rd.html) {
    for (const a of findAll(rd.tree(rel), (n) => n.tag === 'a' && n.attrs.href !== undefined)) {
      const href = a.attrs.href.trim(), path = href.split('#')[0].split('?')[0];
      if (!path || href.startsWith('//') || /^[A-Za-z][A-Za-z0-9+.-]*:/.test(href)) continue;
      const add = (detail) => out.push({ kind: 'dangling', where: label + rel, detail });
      let dec;
      try { dec = decodeURIComponent(path); } catch (e) { if (!(e instanceof URIError)) throw e; add(`链接「${href}」的写法读不懂`); continue; }
      const target = posix.normalize(posix.join(posix.dirname(rel), dec));
      if (posix.isAbsolute(dec) || target === '..' || target.startsWith('../')) add(`链接「${href}」指到了文档集外面`);
      else if (!files.has(target)) add(`链接「${href}」指向的 ${target} 不存在`);
    }
  }
  return out;
}

// 同一处同一类只留一条：第 1、2 项都会点到缺的页与多的页，留第 1 项的说法。
function dedupe(list) {
  const seen = new Set();
  return list.filter((p) => {
    const k = ['missing-page', 'extra-page'].includes(p.kind) ? `${p.kind}\0${p.where}` : `${p.kind}\0${p.where}\0${p.detail}`;
    if (seen.has(k)) return false;
    seen.add(k);
    return true;
  });
}

// 外键列：列上的 REFERENCES，或表级 FOREIGN KEY 里点到它（契约 G 节：外键列的含义由引用关系给出，不算缺含义）。
const isFk = (t, c) => !!c.references || t.constraints.some((k) => k.type === 'foreign key' && (k.columns || []).includes(c.name));

function summarize(facts, rd, rendered, problems, specRead) {
  const notes = facts.notes || {}, byKind = {};
  for (const p of problems) byKind[p.kind] = (byKind[p.kind] || 0) + 1;
  // 需求规格这一项只在配了 spec 时报数；没配的项目摘要与加这一项之前逐字相同。
  const spec = facts.spec ? { spec: { blocks: facts.spec.blocks.length, read: specRead } } : {};
  return {
    ...spec,
    pages: rendered.length,
    pagesOnDisk: rd.files.length,
    tables: facts.tables.length,
    columns: facts.tables.reduce((s, t) => s + t.columns.length, 0),
    notes: { written: Object.keys(notes).length, stale: Object.values(notes).filter((n) => n.state === 'stale').length, orphans: facts.orphanNotes.length },
    // 没写说明不算不一致（H 节第 3 项），只在这里报数；缺含义的列同 pending：既没有来源注释也没有说明、又不是外键的。
    unwritten: {
      tables: facts.tables.filter((t) => !notes[t.anchor]).length,
      columns: facts.tables.reduce((s, t) => s + t.columns.filter((c) => !c.comment && !notes[c.anchor] && !isFk(t, c)).length, 0),
      groups: facts.groups.filter((g) => !notes[`group:${g.id}`]).length,
      doc: !notes['doc:db'],
    },
    // 文档自己已经明说了的，不算不一致（H 节），只报数。
    declared: { unfolded: facts.unfolded.length, unparsed: facts.unparsed.length, dynamic: facts.dynamic.length, dynamicUnassigned: facts.dynamic.filter((d) => !d.assigned).length },
    byKind,
  };
}

// 整套核对。dir：docs/readable/ 的绝对路径；label：给人看的位置前缀；facts：入口重新取的文档模型（带说明）；
// rendered：入口用出页面的函数在内存里重出的 [{path, html}]。
export function runCheck({ dir, label, facts, rendered }) {
  const rd = reader(dir), spec = specFacts(rd, facts.spec, label);
  const problems = dedupe([
    ...pagesCurrent(rd, rendered, label),
    ...pageFacts(rd, facts, label),
    ...spec.problems,
    ...Object.keys(facts.notes || {}).sort(cmp).filter((a) => facts.notes[a].state === 'stale')
      .map((a) => ({ kind: 'note-stale', where: a, detail: '说明的指纹对不上：写于来源的旧版本，要按现在的来源重写后 note put' })),
    ...facts.orphanNotes.map((x) => ({ kind: 'note-orphan', where: x.anchor, detail: '说明的锚点已经不存在：改挂到新锚点（note put）或删掉（note drop）' })),
    ...facts.mapProblems.map((x) => ({ kind: 'dangling', where: `docs/readable-src/map.json ${x.where}`, detail: x.problem })),
    ...danglingLinks(rd, label),
  ]);
  return { ok: problems.length === 0, problems, summary: summarize(facts, rd, rendered, problems, spec.read) };
}

// 隐去的兜底（契约 G 节末段）：逐个字段点名去隐总会漏字段，漏了的那一处两边都没隐、第 2 项比对一致，看不出来。
// 所以落盘前把每一页连着显示的每段文字与每个属性值再过一遍隐去规则，有命中就点名那一页、在哪一节。
// 只报位置与处数，不把命中的原文打出来——标准错误进日志，日志也是带出去的地方；点名用的标题与锚点同样先隐去。
function leaks(rd, label) {
  const out = [];
  for (const rel of rd.html) {
    const at = new Map();
    for (const s of segments(rd.tree(rel))) {
      const n = redact(s.text).hits;
      if (!n) continue;
      const k = redact([s.heading ? `「${s.heading}」一节` : '页首', s.anchor].filter(Boolean).join(' · ')).text;
      at.set(k, (at.get(k) || 0) + n);
    }
    if (!at.size) continue;
    const total = [...at.values()].reduce((a, b) => a + b, 0);
    out.push({ kind: 'leak', where: label + rel, detail: `页面上有 ${total} 处形如内网地址、带口令的地址或密钥的字样没有隐去（${[...at].map(([k, n]) => `${k} ${n} 处`).join('；')}）：出页面时有一个字段没过隐去，要在 render/${rel.startsWith('spec/') ? 'spec' : 'db'}-scrub.mjs 里补上` });
  }
  return out;
}

// build 落盘前的自检：跑第 2 项，再过一遍隐去的兜底，对的是写好的临时目录。
export function selfCheck(dir, facts) {
  const rd = reader(dir);
  const problems = dedupe([...pageFacts(rd, injected(facts), '新出的 '), ...specFacts(rd, facts.spec, '新出的 ').problems, ...leaks(rd, '新出的 ')]);
  if (problems.length) throw new CheckFailed(problems);
}

// READABLE_FAIL_AT=selfcheck：第一张表多一个列（没有表就多一张表），页面上自然没有它。
function injected(facts) {
  if (process.env.READABLE_FAIL_AT !== 'selfcheck') return facts;
  const name = '__selfcheck_injected__', [t, ...rest] = facts.tables;
  if (!t) return { ...facts, tables: [{ anchor: `table:${name}`, name, columns: [], constraints: [] }] };
  return { ...facts, tables: [{ ...t, columns: [...t.columns, { anchor: `column:${t.name}.${name}`, name, type: 'TEXT', nullable: true, default: null }] }, ...rest] };
}

// 给人看的：一条一行「在哪：怎么不一致」，末行「不一致 N 条」（H 节「输出」）。
// pageCap 给了时（check 的人读输出给 10），不是现行的页（第 1 项：内容不同、缺的、多的）超过这个数只列前几张，
// 接一行「另有 N 页」与先重出再核对的提示——建表文件靠前处加一行，后面几十张表的出处行号都变，清单会很长，淹掉别的几条。
// --json 与 build 自检的报错照旧全列。末行的条数始终是全部。
export const PAGE_KINDS = new Set(['stale-page', 'missing-page', 'extra-page']);
export function lines(problems, pageCap = Infinity) {
  const pagesAll = problems.filter((p) => PAGE_KINDS.has(p.kind)), keep = new Set(pagesAll.slice(0, pageCap));
  const out = [];
  for (const p of problems) {
    if (PAGE_KINDS.has(p.kind) && !keep.has(p)) continue;
    out.push(`${p.where}：${p.detail}`);
    if (p === pagesAll[keep.size - 1] && pagesAll.length > keep.size) {
      out.push(`另有 ${pagesAll.length - keep.size} 页不是现行的，没有逐条列出（--json 里全有）：先 build 重出一遍再核对，剩下的才是要查的`);
    }
  }
  return [...out, `不一致 ${problems.length} 条`];
}

export function summaryLine(s) {
  const u = s.unwritten, d = s.declared;
  return `核对了 ${s.pages} 页（磁盘上 ${s.pagesOnDisk} 个文件）、表 ${s.tables} 张、列 ${s.columns} 个；说明 ${s.notes.written} 段（待更新 ${s.notes.stale}、孤儿 ${s.notes.orphans}）；`
    + `没写说明的（不算不一致）：表 ${u.tables} 张、缺含义的列 ${u.columns} 个、组 ${u.groups} 个、doc:db ${u.doc ? '没写' : '已写'}；`
    + `文档已明说、不算不一致的：未合并的动态定义 ${d.unfolded}、未解析的语句 ${d.unparsed}、表名运行时拼的 ${d.dynamic}（未归属 ${d.dynamicUnassigned}）`
    + (s.spec ? `；需求规格 ${s.spec.blocks} 块，页面上读回 ${s.spec.read} 块` : '');
}
