#!/usr/bin/env node
// readable-docs.mjs —— 「人读文档」生成器的入口：串起 取事实 → 连关联绑说明 → 出页面 → 核对（架构稿 §2 cli）。
// 为什么有它：conflation 约两周后交接，接手的 10 人没有 AI 编程工具，第一步就看数据库设计，而那约一百张表没有任何说明
// （需求 REQ-DOC-001；契约 docs/readable-spec/phase1-db-contract.md；2026-11-22 Task 1.1 先做 init 与 build --facts-json）。
// 用法：node .claude/scripts/readable-docs.mjs <子命令> [--root <目录>] [--json]
//   init                 起草 docs/readable-src/config.json；已存在则一个字节不动、报「配置已存在」
//   build --facts-json   只取事实、不出页面：文档模型（一份 JSON）打到标准输出，提示走标准错误
//   build                出页面到 docs/readable/（2026-11-23 Task 1.2 先出数据库设计）：先写同级临时目录，写完核对再整目录换上
//   check（Task 1.5）、pending 与 note put|confirm（Task 1.4）——现在都报「尚未实现」
//   --root   目标目录，默认 $CLAUDE_PROJECT_DIR，再默认当前目录
//   --json   init 的结果也只出一份 JSON（标准输出只有它）
// 退出码：0 成功；1 有不一致（check 用，本期没有）；2 用法或配置错；3 脚本自身出错（含尚未实现的子命令、页面落盘失败）
// 测试注入点：READABLE_FAIL_AT=render 时，build 在写完一半页面时模拟失败（契约 C 节「原子落盘」）。
// 配置与项目判断的读取与校验在 notes.mjs（架构稿把 docs/readable-src/ 的读写归 notes，2026-11-23 Task 1.3 从这里搬过去）；init 起草配置仍在这里。
import { existsSync, writeFileSync, mkdirSync, readdirSync, statSync } from 'node:fs';
import { join, resolve, basename, dirname } from 'node:path';
import { cmp } from './readable/model.mjs';
import { extract as extractDdl } from './readable/sources/sql-ddl.mjs';
import { extract as extractCode, isCodeFile } from './readable/sources/code-scan.mjs';
import { CONFIG, ConfigError, loadConfig, loadMap } from './readable/notes.mjs';
import { link } from './readable/links.mjs';
import { renderDb } from './readable/render/db.mjs';
import { renderHome } from './readable/render/layout.mjs';
import { OUT, publish } from './readable/render/publish.mjs'; // 原子落盘归 render 模块（契约 C 节），入口只调用它
const USAGE = 'readable-docs.mjs <init | build [--facts-json] | check | pending | note put|confirm> [--root <目录>] [--json]';
const DEFAULT_IGNORE = ['**/tests/**', '**/node_modules/**'];
const CODE_EXT = /\.(py|ts|tsx)$/;
// 契约 A 节：ddl 依次找这三类，同一目录按文件名排序；三类都收、按这个先后排、去重——
// 只取先找到的一类会漏掉排在后面的迁移文件，漏表是这一层最贵的错；多收的在配置里一眼看得见、可删。
// sql/ 与 migrations/ 在任意深度都认：lutetia 的建表文件在 lutetia/sql/001…009_*.sql，只找根目录下的 sql/ 一张表都找不到。
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
  const o = { sub, root: process.env.CLAUDE_PROJECT_DIR || process.cwd(), json: false, factsJson: false, action: null };
  for (let i = 1; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--root') { o.root = argv[++i]; if (o.root === undefined) usage('--root 缺值'); }
    else if (a === '--json') o.json = true;
    else if (a === '--facts-json' && sub === 'build') o.factsJson = true;
    else if (sub === 'note' && !o.action && (a === 'put' || a === 'confirm')) o.action = a;
    else usage(`未知参数：${a}`);
  }
  if (sub === 'note' && !o.action) usage('note 后面要跟 put 或 confirm');
  if (!existsSync(o.root) || !statSync(o.root).isDirectory()) usage(`--root 不是目录：${o.root}`);
  return o;
}

// 只认三种通配：**（含 **/ 前缀，可为空）、*、?，够 ignore 默认项用。
function globRe(g) {
  let re = '';
  for (let i = 0; i < g.length; i++) {
    const ch = g[i];
    if (ch === '*' && g[i + 1] === '*') { if (g[i + 2] === '/') { re += '(?:.*/)?'; i += 2; } else { re += '.*'; i++; } }
    else if (ch === '*') re += '[^/]*';
    else if (ch === '?') re += '[^/]';
    else re += ch.replace(/[.+^${}()|[\]\\]/g, '\\$&');
  }
  return new RegExp(`^${re}$`);
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
  const cfg = { version: 1, title: basename(resolve(o.root)), spec, ddl, codeRoots: topCodeDirs(files), ignore: DEFAULT_IGNORE };
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

// 取事实（契约 B、F 节）：建表定义（含 ddl 里列的代码文件）→ 项目判断（notes 读与校验）→ 代码里的写读 → 连起来。
function collect(root, cfg, skipped) {
  const ddl = extractDdl(cfg, root, skipped);
  const map = loadMap(root, ddl.tables.map((t) => t.name));
  const scan = extractCode(cfg, root, codeFiles(root, cfg), [...ddl.tables, ...ddl.views].map((x) => x.name));
  const linked = link(ddl, scan, map, cfg.ddl);
  const unscanned = scan.unscanned.sort((a, b) => cmp(a.file, b.file));
  return { ...ddl, groups: linked.groups, usage: linked.usage, dynamic: linked.dynamic, codeTables: linked.codeTables, unscanned, mapProblems: map.problems };
}

function cmdBuild(o) {
  const cfg = loadConfig(o.root), skipped = {};
  const facts = collect(o.root, cfg, skipped);
  const cols = facts.tables.reduce((s, t) => s + t.columns.length, 0);
  const uses = Object.values(facts.usage).reduce((s, u) => [s[0] + u.writes.length, s[1] + u.reads.length], [0, 0]);
  const tally = `表 ${facts.tables.length} 张、列 ${cols} 个；未合并的动态定义 ${facts.unfolded.length}、未解析的语句 ${facts.unparsed.length}、定义冲突 ${facts.conflicts.length}、改了不存在的表 ${facts.orphanAlters.length}`
    + `；分 ${facts.groups.length} 组；代码里写 ${uses[0]} 处、读 ${uses[1]} 处，表名运行时拼的 ${facts.dynamic.length}、代码里建的表 ${facts.codeTables.length}、没扫成的文件 ${facts.unscanned.length}、项目判断里对不上的 ${facts.mapProblems.length}`;
  const sk = Object.entries(skipped).sort((a, b) => cmp(a[0], b[0]));
  if (o.factsJson) {
    // 不用 process.exit：大块输出写进管道时提前退出会截断，只设退出码让事件循环自己排空。
    process.stdout.write(`${JSON.stringify(facts, null, 2)}\n`);
    console.error(`readable-docs: ${tally}`);
    if (sk.length) console.error(`readable-docs: 略过的非结构语句：${sk.map(([k, n]) => `${k} ${n}`).join('、')}`);
    return;
  }
  // 配置里没写 title 时用根目录名，同 init 起草的口径；页面上不出现根目录的绝对路径。
  const page = { ...cfg, title: typeof cfg.title === 'string' && cfg.title ? cfg.title : basename(resolve(o.root)) };
  const db = renderDb(facts, page);
  const files = [renderHome(page.title, [db.entry]), ...db.files];
  publish(o.root, files);
  const bytes = files.reduce((s, f) => s + Buffer.byteLength(f.html), 0);
  console.log(`已生成 ${OUT}/：${files.length} 个页面、${bytes} 字节`);
  console.log(`  数据库设计：${tally}；组页 ${db.stats.groupPages} 页，最大一页 ${db.stats.largest} 张表`);
  if (sk.length) console.log(`  略过的非结构语句：${sk.map(([k, n]) => `${k} ${n}`).join('、')}`);
}

const stub = (what) => () => die(3, `${what}尚未实现`);

// 子命令表：后续 Task 在这里换掉桩（build 的页面分支在 cmdBuild 里）。
const COMMANDS = {
  init: cmdInit,
  build: cmdBuild,
  check: stub('核对（check，Task 1.5）'),
  pending: stub('待办（pending，Task 1.4）'),
  note: stub('说明落盘（note put / confirm，Task 1.4）'),
};

try {
  const o = parseArgs(process.argv.slice(2));
  COMMANDS[o.sub](o);
} catch (e) {
  // 配置错与 map.json 不是合法 JSON 由 notes 抛 ConfigError：是用法错，退出码 2；别的都是本脚本的错。
  if (e instanceof ConfigError) { console.error(`readable-docs: ${e.message}`); process.exitCode = 2; }
  else { console.error(`readable-docs: 脚本自身出错：${e?.stack || e}`); process.exitCode = 3; }
}
