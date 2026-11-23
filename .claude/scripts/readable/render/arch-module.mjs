// arch-module.mjs —— 架构这一份的模块页 arch/m-<id>.html（第三期契约 docs/readable-spec/phase3-arch-contract.md D 节）。
// 为什么有它：架构师点进一个模块，要看到它管什么、有哪些文件（每个文件干什么——文件头说明是这一页上最有用的原文）、
// 对外提供哪些接口、依赖谁、谁依赖它、碰哪些表（规格 FLOW-1 第 3 步）。自成一体，自上而下：
// 说明 → 邻居图 → 接口 → 文件 → 它依赖的模块 → 对外提供的名字 → 读写的表 → 用到的外部包；哪一段没有内容就写「没有」。
// 文件头说明与处理函数的说明是「来源里的注释」，原文完整上页面，不截断、不改写；代码文件的行号不上页面。
// 读回标记照 D 节末尾那张表（各段 data-section，一行一条 data-row，要比的格子 data-k）。
// 测试注入点 READABLE_FAIL_AT=arch-render：第一个有文件的模块页上漏掉第一个文件那一行，模拟出页面的代码漏了一行；
// 落盘前的自检（check-arch.mjs）该拦下，build 退出码 3、原有页面不动。
import { esc, code, codeBreak, fileSlug, page, table, origin } from './layout.mjs';
import { CSS, crumbs, pageTitle, judgedMark, pathCode, k, row, section, none, mRef, archNote, folded, pairList, modFile, sizeBand, approxLines } from './arch-kit.mjs';
import { neighbors } from './arch-graph.mjs';

const PAIRS_INLINE = 3; // 文件对不超过 3 对的直接列出，多的收进可展开的区

// 接口这一行的键与路径（D 节那张表）：方法加空格加完整路径，拼不出完整路径的用源码里的写法。模块页与接口总表同一个写法。
export const routeKey = (r) => `${r.method} ${r.fullPath ?? r.path}`;
const urlCode = (p) => `<code>${esc(p).replace(/\//g, '/<wbr>')}</code>`;
// 路径那一格：data-k="path" 只包着路径本身；拼不出完整路径的另起一行标「前缀是运行时定的」，不算进要比的字。
export const routePath = (r) => `<span data-k="path">${urlCode(r.fullPath ?? r.path)}</span>${r.fullPath == null ? '<br><span class="muted">前缀是运行时定的</span>' : ''}`;
export const routeCells = (r) => [k('method', esc(r.method)), routePath(r), k('handler', codeBreak(r.handler))];

// 读写的表：每张表一行，rw 写「读」「写」或「读写」（D 节那张表）；表名链到数据库设计里那张表的页面（文件名照第一期的推法）。
// 不在建表定义里的（视图等）没有表页，只写名字。
const rwOf = (t, m) => (m.tables.reads.includes(t) ? '读' : '') + (m.tables.writes.includes(t) ? '写' : '');
const tableRef = (v, t) => (v.tables.has(t) ? `<a href="../db/t-${fileSlug(t)}.html">${codeBreak(t)}</a>` : codeBreak(t));

function pairsCell(pairs) {
  const n = pairs.length;
  return n <= PAIRS_INLINE ? `${n} 对${pairList(pairs)}` : folded(`${n} 对文件`, pairList(pairs));
}

export function modulePage(v, m) {
  let files = m.files;
  if (process.env.READABLE_FAIL_AT === 'arch-render' && m === v.modules.find((x) => x.files.length)) files = files.slice(1);
  const tables = [...new Set([...m.tables.reads, ...m.tables.writes])].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  const head = (title, n, mark) => `<h2>${title}${n == null ? '' : `（${n}）`} ${mark}</h2>`;
  const routes = m.routes.map((r) => row(routeKey(r), [...routeCells(r), pathCode(r.file),
    r.doc == null ? '<span class="muted">没有说明</span>' : `<span class="pre">${esc(r.doc)}</span>`]));
  // 规模一格写四档之一（D 节「确切的行数不上页面」），读回用 data-k="size"。
  const fileRows = files.map((f) => row(f.path, [pathCode(f.path), k('size', sizeBand(f.lines)), f.entry ? '是' : '',
    f.head == null ? '<span class="muted">没有文件头说明</span>' : `<span class="pre">${esc(f.head)}</span>`]));
  const uses = m.uses.map((u) => row(u.module, [mRef(v, u.module), pairsCell(u.pairs), u.names.map(code).join(', ')]));
  const provides = m.provides.map((p) => row(`${p.file}#${p.name}`, [code(p.name), pathCode(p.file),
    k('by', p.by.map((id) => `<a href="${modFile(id)}">${esc(id)}</a>`).join(' '))]));
  const body = [
    `<h1>${esc(m.title)}</h1>`,
    `<p>模块 ${code(m.id)}${m.layer ? ` · 所在的层：${esc(m.layer)}` : ''} ${judgedMark(m.status)}</p>`,
    `<p class="lead">${m.files.length} 个文件、${approxLines(m.lines)}；${m.routes.length} 个接口；依赖 ${m.uses.length} 个模块、被 ${m.usedBy.length} 个模块依赖；读 ${m.tables.reads.length} 张表、写 ${m.tables.writes.length} 张表。${origin('fact')}</p>`,
    archNote(`module:${m.id}`, m.note, '说明', '还没有说明。这个模块管什么，先看下面的文件与它们的文件头说明。'),
    `<h2>它与别的模块 ${origin('fact')}</h2>`,
    neighbors(v, m),
    section('routes', `${head('接口', m.routes.length, origin('fact'))}\n${routes.length
      ? `<p class="muted">处理函数的说明是函数开头那一段，原文照录${origin('comment')}。完整路径是一路挂载的前缀加上装饰器里写的路径。</p>\n${table(['方法', '完整路径', '处理函数', '所在文件', '处理函数的说明'], routes, ['72px', '24%', '16%', '20%', null])}`
      : none('没有（只认装饰器写法的路由）')}`),
    section('files', `${head('文件', files.length, origin('fact'))}\n${fileRows.length
      ? `<p class="muted">文件头说明是文件开头的那一段注释或文档字符串，原文完整照录${origin('comment')}；入口是带 <code>if __name__ == "__main__":</code> 的文件。</p>\n${table(['文件', '规模', '入口', '文件头说明'], fileRows, ['26%', '112px', '48px', null])}`
      : none()}`),
    section('uses', `${head('它依赖的模块', m.uses.length, origin('fact'))}\n${uses.length
      ? `<p class="muted">本模块的文件引用了对方模块的文件。文件对写成「本模块的文件 → 对方的文件」；名字是引用到的名字，<code>*</code> 是引用了整个文件。</p>\n${table(['模块', '通过哪几对文件', '用了哪些名字'], uses, ['22%', '38%', null])}`
      : none()}`),
    m.usedBy.length ? `<p>依赖它的模块：${m.usedBy.map((id) => mRef(v, id, { br: false })).join('、')}</p>` : '',
    section('provides', `${head('对外提供的名字', m.provides.length, origin('fact'))}\n${provides.length
      ? `<p class="muted">本模块的文件里被别的模块引用到的名字；<code>*</code> 是整个文件被引用。</p>\n${table(['名字', '在哪个文件', '被哪几个模块用'], provides, ['26%', '38%', null])}`
      : none()}`),
    section('tables', `${head('读写的表', tables.length, origin('code'))}\n${tables.length
      ? table(['表', '读写'], tables.map((t) => row(t, [tableRef(v, t), k('rw', rwOf(t, m))])), ['50%', null])
      : none()}`),
    `<h2>用到的外部包 ${origin('fact')}</h2>`,
    m.externals.length ? `<p>${m.externals.map(code).join('、')}</p>` : none(),
  ].filter(Boolean).join('\n');
  return { path: `arch/${modFile(m.id)}`, html: page({ title: pageTitle(v, m.title), depth: 1, crumbs: crumbs([m.title]), body, main: { 'data-anchor': `module:${m.id}` }, css: CSS }) };
}
