#!/usr/bin/env node
// readable-docs.mjs —— 「人读文档」生成器的入口：串起 取事实 → 连关联绑说明 → 出页面 → 核对（架构稿 §2 cli）。
// 为什么有它：conflation 约两周后交接，接手的 10 人没有 AI 编程工具，第一步就看数据库设计，而那约一百张表没有任何说明
// （需求 REQ-DOC-001；契约 docs/readable-spec/phase1-db-contract.md；2026-11-22 Task 1.1 先做 init 与 build --facts-json）。
// 用法：node .claude/scripts/readable-docs.mjs <子命令> [--root <目录>] [--json]
//   init                 起草 docs/readable-src/config.json；已存在则一个字节不动、报「配置已存在」
//   build --facts-json   只取事实、不出页面：文档模型（一份 JSON）打到标准输出，提示走标准错误
//   build                出页面到 docs/readable/（2026-11-23 Task 1.2 先出数据库设计，Task 2.2 加需求规格）：先写同级临时目录，写完核对再整目录换上
//   pending [--json]     按表列出要补的说明（2026-11-23 Task 1.4）；--json 时每张表附一份上下文，退出码恒为 0
//   note put [--file <文件>]                  交若干段「## <锚点>」加正文（不给文件读标准输入），全过才落盘、盖指纹、记 draft
//   note confirm <锚点…> | --all  --by <名字>  指纹对得上的记成 reviewed；对不上的不改、列出来，退出码 1
//   note drop <锚点…>                         删掉这几段说明
//   check [--json]       逐项比对文档与来源（2026-11-23 Task 1.5，契约 H 节），一条一行「在哪：怎么不一致」，末行「不一致 N 条」；摘要走标准错误
//   --root   目标目录，默认 $CLAUDE_PROJECT_DIR，再默认当前目录
//   --json   init、pending 与 check 的结果只出一份 JSON（标准输出只有它）
// 退出码：0 成功；1 有不一致（check 的清单不空、note confirm 遇到指纹对不上的）；2 用法或配置错（含 note put 整批被拒）；3 脚本自身出错（含页面落盘失败、build 落盘前的自检不过）
// 测试注入点：READABLE_FAIL_AT=render 时，build 在写完一半页面时模拟失败（契约 C 节「原子落盘」）；
// READABLE_FAIL_AT=selfcheck 时，build 落盘前的自检拿到的事实多一个列，模拟出页面的代码少出了一个列（在 check.mjs）；
// READABLE_FAIL_AT=leak 时，第一张表的表页上多出一个没隐去的内网地址，模拟某个字段忘了过隐去，落盘前的兜底拦下（在 render/db-scrub.mjs）。
// READABLE_FAIL_AT=spec-cut 时，需求规格切出来的第一块带字的少一个字，还原自检拦下：build、check、build --facts-json 都退出码 3、
// 什么都不出（在 sources/md-blocks.mjs，第二期契约 B 节）；READABLE_FAIL_AT=spec-render 时，出页面的代码把第一条带字的列表项的
// 最后一个字丢掉，落盘前的自检拦下、原有页面不动（在 render/spec.mjs，第二期契约 D 节）。
// 配置与项目判断的读取与校验在 notes.mjs（架构稿把 docs/readable-src/ 的读写归 notes，2026-11-23 Task 1.3 从这里搬过去）；init 起草配置仍在这里。
import { existsSync, writeFileSync, mkdirSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { join, resolve, basename, dirname } from 'node:path';
import { cmp } from './readable/model.mjs';
import { extract as extractDdl } from './readable/sources/sql-ddl.mjs';
import { extract as extractCode, isCodeFile } from './readable/sources/code-scan.mjs';
import { extract as extractSpec, SpecLoss } from './readable/sources/md-blocks.mjs';
import { extract as extractImports } from './readable/sources/code-imports.mjs';
import { addRoutes } from './readable/sources/code-routes.mjs';
import { CONFIG, ConfigError, loadConfig, loadMap, bindNotes, putNotes, confirmNotes, dropNotes, pendingList } from './readable/notes.mjs';
import { link } from './readable/links.mjs';
import { buildArch } from './readable/links-arch.mjs';
import { globRe } from './readable/arch-map.mjs'; // ignore 与模块的 paths 同一套通配（第三期契约 A 节）
import { renderDb } from './readable/render/db.mjs';
import { renderHome } from './readable/render/layout.mjs';
import { renderSpec } from './readable/render/spec.mjs';
import { OUT, publish } from './readable/render/publish.mjs'; // 原子落盘归 render 模块（契约 C 节），入口只调用它
import { CheckFailed, runCheck, selfCheck, lines, summaryLine } from './readable/check.mjs';
const USAGE = 'readable-docs.mjs <init | build [--facts-json] | check | pending | note put [--file <文件>] | note confirm <锚点…>|--all --by <名字> | note drop <锚点…>> [--root <目录>] [--json]';
const NOTE_ACTIONS = ['put', 'confirm', 'drop'];
// 后三条是测试文件与代码放在一起的写法（第三期契约 A 节）：不排掉，模块图上全是测试库。已有的配置不替人改。
const DEFAULT_IGNORE = ['**/tests/**', '**/node_modules/**', '**/*.test.*', '**/*.spec.*', '**/__tests__/**'];
const ARCH_DOC_FILE = 'Architecture-Design.md'; // init 在根目录有它时填进 archDocs
const CHECK_PAGE_CAP = 10; // 契约 H 节：check 的人读输出里不是现行的页超过 10 张只列前 10 张
const CODE_EXT = /\.(py|ts|tsx)$/;
// 契约 A 节：ddl 依次找这三类，同一目录按文件名排序；三类都收、按这个先后排、去重——
// 只取先找到的一类会漏掉排在后面的迁移文件，漏表是这一层最贵的错；多收的在配置里一眼看得见、可删。
// sql/ 与 migrations/ 在任意深度都认：有的项目的建表文件在 <项目名>/sql/ 下按编号排（001_*.sql、002_*.sql…），只找根目录下的 sql/ 一张表都找不到。
const DDL_PATTERNS = [
  ['**/schema.sql', (f) => f.split('/').pop() === 'schema.sql'],
  ['**/sql/*.sql', (f) => /(?:^|\/)sql\/[^/]+\.sql$/.test(f)],
  ['**/migrations/*.sql', (f) => /(?:^|\/)migrations\/[^/]+\.sql$/.test(f)],
];

function die(code, msg) { console.error(`readable-docs: ${msg}`); process.exit(code); }
const usage = (msg) => die(2, `${msg}（用法：${USAGE}）`);

function parseArgs(argv) {
  const sub = argv[0];
  if (!sub || sub.startsWith('-')) usage('缺子命令');
  if (!Object.hasOwn(COMMANDS, sub)) usage(`未知子命令：${sub}`);
  const o = { sub, root: process.env.CLAUDE_PROJECT_DIR || process.cwd(), json: false, factsJson: false, action: null, file: null, by: null, all: false, anchors: [] };
  const value = (i, flag) => { if (argv[i] === undefined) usage(`${flag} 缺值`); return argv[i]; };
  for (let i = 1; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--root') o.root = value(++i, '--root');
    else if (a === '--json') o.json = true;
    else if (a === '--facts-json' && sub === 'build') o.factsJson = true;
    else if (sub === 'note' && !o.action && NOTE_ACTIONS.includes(a)) o.action = a;
    else if (o.action === 'put' && a === '--file') o.file = value(++i, '--file');
    else if (o.action === 'confirm' && a === '--by') o.by = value(++i, '--by').trim();
    else if (o.action === 'confirm' && a === '--all') o.all = true;
    else if ((o.action === 'confirm' || o.action === 'drop') && !a.startsWith('-')) o.anchors.push(a);
    else usage(`未知参数：${a}`);
  }
  if (sub === 'note' && !o.action) usage('note 后面要跟 put、confirm 或 drop');
  if (o.action === 'confirm') {
    if (!o.by) usage('note confirm 要用 --by <名字> 写明谁抽审的');
    if (/[<>\r\n]/.test(o.by)) usage('--by 的名字里不许有尖括号与换行');
    if (o.all === (o.anchors.length > 0)) usage('note confirm 要么点名锚点，要么 --all，二者取一');
  }
  if (o.action === 'drop' && !o.anchors.length) usage('note drop 后面要跟要删的锚点');
  if (o.file !== null && !(existsSync(o.file) && statSync(o.file).isFile())) usage(`--file 不是文件：${o.file}`);
  if (!existsSync(o.root) || !statSync(o.root).isDirectory()) usage(`--root 不是目录：${o.root}`);
  return o;
}

// 项目里的文件（相对路径、/ 分隔、按名字定序）。点开头的目录不进：.git、.venv、.claude 里的不是项目的来源
// （cc-base 自己的 .claude/tests 里就有 SQL 夹具）。符号链接不跟，免得绕圈。sub 给了就只走那个子目录，路径仍相对 root。
function walk(root, ignore, sub = '') {
  const res = ignore.map(globRe), skip = (rel) => res.some((r) => r.test(rel)), out = [];
  const visit = (dir, rel) => {
    for (const d of readdirSync(dir, { withFileTypes: true }).sort((a, b) => cmp(a.name, b.name))) {
      if (d.name.startsWith('.')) continue;
      const r = rel ? `${rel}/${d.name}` : d.name;
      if (d.isDirectory()) { if (!skip(`${r}/`)) visit(join(dir, d.name), r); }
      else if (d.isFile() && !skip(r)) out.push(r);
    }
  };
  const start = sub.replace(/\\/g, '/').replace(/^\.?\/+|\/+$/g, '');
  visit(start ? join(root, start) : root, start);
  return out;
}

// 扫谁写谁读的文件（契约 F 节）：codeRoots 下的 .py 与 JS 一族，去掉 ignore 命中的；几个 codeRoots 重叠的只扫一次。
const codeFiles = (root, cfg) => [...new Set(cfg.codeRoots.flatMap((d) => walk(root, cfg.ignore, d)).filter(isCodeFile))].sort(cmp);

// codeRoots：含 .py / .ts / .tsx 最多的两个顶层目录（契约 A 节），同数按名字。
function topCodeDirs(files) {
  const n = new Map();
  for (const f of files) {
    const k = f.indexOf('/');
    if (k > 0 && CODE_EXT.test(f)) n.set(f.slice(0, k), (n.get(f.slice(0, k)) || 0) + 1);
  }
  return [...n].sort((a, b) => b[1] - a[1] || cmp(a[0], b[0])).slice(0, 2).map(([d]) => d);
}

function cmdInit(o) {
  const p = join(o.root, CONFIG);
  if (existsSync(p)) {
    if (o.json) process.stdout.write(`${JSON.stringify({ created: false, path: CONFIG, message: '配置已存在' })}\n`);
    else console.log(`配置已存在：${CONFIG}（一个字节没动）`);
    return;
  }
  const files = walk(o.root, DEFAULT_IGNORE);
  const ddl = [...new Set(DDL_PATTERNS.flatMap(([, hit]) => files.filter(hit).sort(cmp)))];
  const spec = existsSync(join(o.root, 'Product-Spec.md')) ? 'Product-Spec.md' : null;
  const archDocs = existsSync(join(o.root, ARCH_DOC_FILE)) ? [ARCH_DOC_FILE] : [];
  const cfg = { version: 1, title: basename(resolve(o.root)), spec, ddl, codeRoots: topCodeDirs(files), ignore: DEFAULT_IGNORE, archDocs };
  const notes = [];
  if (!ddl.length) notes.push(`ddl 没找到建表定义文件（依次找过 ${DDL_PATTERNS.map(([g]) => g).join('、')}），写成空数组，请手填`);
  if (!spec) notes.push('根目录没有 Product-Spec.md，spec 写成 null');
  if (!cfg.codeRoots.length) notes.push('没找到含 .py / .ts / .tsx 文件的顶层目录，codeRoots 写成空数组');
  mkdirSync(dirname(p), { recursive: true });
  writeFileSync(p, `${JSON.stringify(cfg, null, 2)}\n`, { flag: 'wx' }); // wx：万一同时有人建了，宁可报错也不覆盖
  if (o.json) { process.stdout.write(`${JSON.stringify({ created: true, path: CONFIG, config: cfg, notes })}\n`); return; }
  console.log(`已起草 ${CONFIG}（title：${cfg.title}）`);
  console.log(`  ddl（按执行顺序，${ddl.length} 个）：`);
  ddl.forEach((f, i) => console.log(`    ${i + 1}. ${f}`));
  console.log(`  codeRoots：${cfg.codeRoots.join('、') || '（空）'}`);
  notes.forEach((t) => console.log(`  提示：${t}`));
}

// 取事实（契约 B、F 节）：建表定义（含 ddl 里列的代码文件）→ 项目判断（notes 读与校验）→ 代码里的写读 → 连起来
// → 绑说明（契约 G 节：notes 按现行的切片判现行、待更新、孤儿，交给页面与 --facts-json 的是同一份）。
// 需求规格的切块（第二期契约 B 节）最先做：还原自检不过就抛 SpecLoss，后面的都不必跑，也不会打出半份结果；没配 spec 的是 null。
function collect(root, cfg, skipped) {
  const spec = extractSpec(cfg, root);
  const ddl = extractDdl(cfg, root, skipped);
  const map = loadMap(root, ddl.tables.map((t) => t.name));
  const scan = extractCode(cfg, root, codeFiles(root, cfg), [...ddl.tables, ...ddl.views].map((x) => x.name));
  const linked = link(ddl, scan, map, cfg.ddl);
  const unscanned = scan.unscanned.sort((a, b) => cmp(a.file, b.file));
  // ambiguous（契约 F 节「提到了表名、像 SQL 又不像的」）：取事实那边 2026-11-23 正在加，连起来的结果里有就用它，
  // 只有扫描结果里有就用扫描的，都还没有时是空清单——只兜「这个键还没出」这一种，键在而形状不对照样往下报错。
  const ambiguous = linked.ambiguous ?? scan.ambiguous ?? [];
  // 文件清单、文件头说明与引用边（第三期契约 B 节，2026-11-23 Task 3.1）：交过去的是 codeRoots 下去掉 ignore 的全部文件，
  // 不只代码文件——别的扩展名要按扩展名报数（「没扫的文件」），不装作扫过。接口（Task 3.2）从同一批文件里取，填进 code.routes。
  const codeAll = [...new Set(cfg.codeRoots.flatMap((d) => walk(root, cfg.ignore, d)))].sort(cmp);
  const code = addRoutes(extractImports(cfg, root, codeAll), cfg, root, codeAll);
  // 照模块划分汇总（第三期契约 B 节「汇总成模块」，Task 3.3）：划分取自 map.json 的 modules，没有就按目录分；表的写读取自上面的 usage。
  const arch = buildArch(code, linked.usage, map.arch, cfg.codeRoots);
  const facts = { ...ddl, groups: linked.groups, usage: linked.usage, dynamic: linked.dynamic, ambiguous, codeTables: linked.codeTables, unscanned, mapProblems: map.problems, spec, code, arch };
  return { ...facts, ...bindNotes(root, facts) };
}
const loadFacts = (o) => collect(o.root, loadConfig(o.root), {});

// 出页面（只返回「路径 → 内容」，不碰磁盘）：build 落盘与 check 第 1 项重出用的是这同一个，两边才比得上。
// 配置里没写 title 时用根目录名，同 init 起草的口径；页面上不出现根目录的绝对路径。
// 首页的标题用 renderDb 隐去过的那一份（契约 G 节：配置的标题也过隐去）。
// 配了需求规格的再出 spec/ 下的页面，首页的文档清单多一项（第二期契约 C 节，2026-11-23 Task 2.2）；spec 为 null 的一页都不出、首页不列。
function pages(root, cfg, facts) {
  const page = { ...cfg, title: typeof cfg.title === 'string' && cfg.title ? cfg.title : basename(resolve(root)) };
  const db = renderDb(facts, page), spec = facts.spec ? renderSpec(facts.spec, { title: db.title }) : null;
  const docs = [db.entry, ...(spec ? [spec.entry] : [])];
  return { db, spec, files: [renderHome(db.title, docs), ...db.files, ...(spec ? spec.files : [])] };
}

// 核对（契约 H 节）：四项都在 check.mjs；这里只取事实、重出一遍交过去、出结果、定退出码。
function cmdCheck(o) {
  const cfg = loadConfig(o.root), facts = collect(o.root, cfg, {});
  const r = runCheck({ dir: join(o.root, OUT), label: `${OUT}/`, facts, rendered: pages(o.root, cfg, facts).files });
  if (o.json) process.stdout.write(`${JSON.stringify(r, null, 2)}\n`);
  // 人读输出里不是现行的页最多列 10 张，其余报个数（契约 H 节「输出」）；--json 照旧全列。
  else { console.error(`readable-docs: ${summaryLine(r.summary)}`); console.log(lines(r.problems, CHECK_PAGE_CAP).join('\n')); }
  process.exitCode = r.ok ? 0 : 1;
}

function cmdBuild(o) {
  const cfg = loadConfig(o.root), skipped = {};
  const facts = collect(o.root, cfg, skipped);
  const cols = facts.tables.reduce((s, t) => s + t.columns.length, 0);
  const uses = Object.values(facts.usage).reduce((s, u) => [s[0] + u.writes.length, s[1] + u.reads.length], [0, 0]);
  const tally = `表 ${facts.tables.length} 张、列 ${cols} 个；未合并的动态定义 ${facts.unfolded.length}、未解析的语句 ${facts.unparsed.length}、定义冲突 ${facts.conflicts.length}、改了不存在的表 ${facts.orphanAlters.length}`
    + `；分 ${facts.groups.length} 组；代码里写 ${uses[0]} 处、读 ${uses[1]} 处，表名运行时拼的 ${facts.dynamic.length}、代码里建的表 ${facts.codeTables.length}、没扫成的文件 ${facts.unscanned.length}、项目判断里对不上的 ${facts.mapProblems.length}`
    + `；说明 ${Object.keys(facts.notes).length} 段（待更新 ${Object.values(facts.notes).filter((n) => n.state === 'stale').length}）、孤儿 ${facts.orphanNotes.length} 段`;
  // 架构这一行（第三期 Task 3.3）只在配了 codeRoots 时报：没配的项目不出架构这一份，报数与之前逐字相同。
  const a = facts.arch, archTally = cfg.codeRoots.length ? `架构：模块 ${a.modules.length} 个（${a.source === 'map' ? '取自项目判断' : '按目录分的，还没有项目判断'}）、未归属的文件 ${a.unassigned.length} 个`
    + `；循环依赖 ${a.cycles.length} 组、越层引用 ${a.upward.reduce((s, u) => s + u.pairs.length, 0)} 处、接口 ${facts.code.routes.length} 个、项目判断里对不上的 ${a.problems.length} 条`
    + `；没解析到的引用 ${facts.code.unresolved.length} 处、运行时才定的引用 ${facts.code.dynamic.length} 处` : null;
  const sk = Object.entries(skipped).sort((a, b) => cmp(a[0], b[0]));
  if (o.factsJson) {
    // 不用 process.exit：大块输出写进管道时提前退出会截断，只设退出码让事件循环自己排空。
    process.stdout.write(`${JSON.stringify(facts, null, 2)}\n`);
    console.error(`readable-docs: ${tally}`);
    if (archTally) console.error(`readable-docs: ${archTally}`);
    if (sk.length) console.error(`readable-docs: 略过的非结构语句：${sk.map(([k, n]) => `${k} ${n}`).join('、')}`);
    return;
  }
  const { db, spec, files } = pages(o.root, cfg, facts);
  // 落盘前对临时目录跑核对第 2 项（契约 H 节），不过就不换上，CheckFailed 往上抛成退出码 3。
  publish(o.root, files, (tmp) => selfCheck(tmp, facts));
  const bytes = files.reduce((s, f) => s + Buffer.byteLength(f.html), 0);
  console.log(`已生成 ${OUT}/：${files.length} 个页面、${bytes} 字节`);
  console.log(`  数据库设计：${tally}；组页 ${db.stats.groupPages} 页，最大一页 ${db.stats.largest} 张表`);
  if (archTally) console.log(`  ${archTally}`);
  if (spec) {
    const k = {};
    for (const b of facts.spec.blocks) k[b.kind] = (k[b.kind] || 0) + 1;
    const kinds = Object.entries(k).sort((a, b) => cmp(a[0], b[0])).map(([x, n]) => `${x} ${n}`).join('、');
    console.log(`  需求规格：取自 ${cfg.spec}，${spec.stats.pages} 章、${spec.stats.blocks} 块（${kinds || '没有块'}）；隐去 ${spec.stats.hidden} 处`);
  }
  if (sk.length) console.log(`  略过的非结构语句：${sk.map(([k, n]) => `${k} ${n}`).join('、')}`);
}

const refuse = (msg) => { console.error(`readable-docs: ${msg}`); process.exitCode = 2; };
const indent = (text) => text.split('\n').map((l) => `    ${l}`).join('\n');
const today = () => { const d = new Date(), p = (n) => String(n).padStart(2, '0'); return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`; };

// 说明的落盘只经这几个命令（契约 G 节）；校验、指纹、落盘都在 notes，这里只读输入、报结果、定退出码。
function cmdNote(o) {
  if (o.action === 'drop') {
    const r = dropNotes(o.root, o.anchors);
    if (r.missing.length) return refuse(`这几个锚点没有说明，一段都没删：${r.missing.join('、')}`);
    console.log(`已删掉 ${r.dropped.length} 段说明：${r.dropped.join('、')}`);
    return;
  }
  const facts = loadFacts(o);
  if (o.action === 'put') {
    const r = putNotes(o.root, facts, readFileSync(o.file ?? 0, 'utf8'));
    if (!r.ok) {
      for (const p of r.problems) console.error(`readable-docs: ${p.where}：${p.reasons.join('；')}`);
      return refuse(`有 ${r.problems.length} 处不过，整批没有落盘`);
    }
    console.log(`已落盘 ${r.written.length} 段说明，状态 draft：${r.written.join('、')}`);
    return;
  }
  const r = confirmNotes(o.root, facts, o.all ? null : o.anchors, o.by, today());
  if (r.missing.length) return refuse(`这几个锚点没有说明，一段都没改：${r.missing.join('、')}`);
  console.log(`已记成 reviewed（${o.by}，${today()}）${r.confirmed.length} 段${r.confirmed.length ? `：${r.confirmed.join('、')}` : ''}`);
  if (r.kept.length) console.log(`原本已抽审、--all 没动的 ${r.kept.length} 段：${r.kept.join('、')}`);
  for (const m of r.mismatched) console.log(`没改 ${m.anchor}：${m.why}`);
  if (r.mismatched.length) process.exitCode = 1;
}

function cmdPending(o) {
  const r = pendingList(o.root, loadFacts(o));
  if (o.json) { process.stdout.write(`${JSON.stringify(r, null, 2)}\n`); return; }
  const s = r.summary;
  console.log(`要补的：表 ${s.tables} 张（缺表说明 ${s.missingTables} 张）、缺含义的列 ${s.columns} 个、组 ${s.groups} 个、doc:db ${s.doc ? '要补' : '不用补'}；待更新 ${s.stale} 段、孤儿 ${s.orphans} 段`);
  const staleLines = (list) => list.forEach((x) => console.log(`  待更新 ${x.anchor}，旧正文：\n${indent(x.text)}`));
  for (const t of r.tables) {
    const what = [t.missingTable ? '缺表说明' : null, t.missingColumns.length ? `缺含义的列 ${t.missingColumns.length} 个：${t.missingColumns.join('、')}` : null].filter(Boolean);
    console.log(`${t.anchor}${what.length ? `  ${what.join('；')}` : ''}`);
    staleLines(t.stale);
  }
  // 架构的（第三期契约 C 节）接在数据库设计的各项后面、孤儿前面；没有模块的项目一行都不多。
  if (s.modules || s.archDoc) console.log(`架构要补的：模块 ${s.modules} 个（缺说明 ${s.missingModules} 个）、doc:arch ${s.archDoc ? '要补' : '不用补'}`);
  for (const g of [...r.groups, ...(r.doc ? [r.doc] : []), ...r.modules, ...(r.archDoc ? [r.archDoc] : [])]) {
    console.log(`${g.anchor}${g.missing ? '  缺说明' : ''}`);
    if (g.stale) staleLines([g.stale]);
  }
  for (const x of r.orphans) console.log(`孤儿 ${x.anchor}（锚点已经不存在），正文：\n${indent(x.text)}`);
}

// 子命令表：后续 Task 在这里换掉桩（build 的页面分支在 cmdBuild 里）。
const COMMANDS = {
  init: cmdInit,
  build: cmdBuild,
  check: cmdCheck,
  pending: cmdPending,
  note: cmdNote,
};

try {
  const o = parseArgs(process.argv.slice(2));
  COMMANDS[o.sub](o);
} catch (e) {
  // 配置错与 map.json 不是合法 JSON 由 notes 抛 ConfigError：是用法错，退出码 2；别的都是本脚本的错。
  if (e instanceof ConfigError) { console.error(`readable-docs: ${e.message}`); process.exitCode = 2; }
  // build 落盘前的自检不过：新页面没换上，说明哪一页哪一项对不上，退出码 3（契约 H 节）。
  else if (e instanceof CheckFailed) { console.error(`readable-docs: ${e.message}`); process.exitCode = 3; }
  // 需求规格切块的还原自检不过（第二期契约 B 节）：点名哪一行对不上，退出码 3，什么都不出。
  else if (e instanceof SpecLoss) { console.error(`readable-docs: ${e.message}`); process.exitCode = 3; }
  else { console.error(`readable-docs: 脚本自身出错：${e?.stack || e}`); process.exitCode = 3; }
}
