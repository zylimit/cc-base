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
// 配置的读写暂放这里：架构稿把 docs/readable-src/ 的读写归 notes，notes.mjs 由 Task 1.4 新建，届时搬过去。
import { existsSync, readFileSync, writeFileSync, mkdirSync, readdirSync, statSync, renameSync, rmSync } from 'node:fs';
import { join, resolve, basename, dirname } from 'node:path';
import { cmp } from './readable/model.mjs';
import { extract as extractDdl } from './readable/sources/sql-ddl.mjs';
import { renderDb } from './readable/render/db.mjs';
import { renderHome } from './readable/render/layout.mjs';

const CONFIG = 'docs/readable-src/config.json';
const OUT = 'docs/readable';
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
// （cc-base 自己的 .claude/tests 里就有 SQL 夹具）。符号链接不跟，免得绕圈。
function walk(root, ignore) {
  const res = ignore.map(globRe), skip = (rel) => res.some((r) => r.test(rel)), out = [];
  const visit = (dir, rel) => {
    for (const d of readdirSync(dir, { withFileTypes: true }).sort((a, b) => cmp(a.name, b.name))) {
      if (d.name.startsWith('.')) continue;
      const r = rel ? `${rel}/${d.name}` : d.name;
      if (d.isDirectory()) { if (!skip(`${r}/`)) visit(join(dir, d.name), r); }
      else if (d.isFile() && !skip(r)) out.push(r);
    }
  };
  visit(root, '');
  return out;
}

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

// 配置有错一律退出码 2 并点名是哪一条（契约 A 节）。
function loadConfig(root) {
  const p = join(root, CONFIG);
  if (!existsSync(p)) die(2, `配置不存在：${CONFIG}（先跑 init）`);
  let cfg;
  try { cfg = JSON.parse(readFileSync(p, 'utf8')); }
  catch (e) { if (e instanceof SyntaxError) die(2, `配置不是合法 JSON：${CONFIG}：${e.message}`); throw e; }
  if (!cfg || typeof cfg !== 'object' || Array.isArray(cfg)) die(2, `配置的顶层该是对象：${CONFIG}`);
  if (cfg.version !== 1) die(2, `配置的 version 只认 1，现在是 ${JSON.stringify(cfg.version)}`);
  const list = (key, required) => {
    const v = cfg[key];
    if (v === undefined && !required) return [];
    if (!Array.isArray(v) || v.some((s) => typeof s !== 'string' || !s)) die(2, `配置的 ${key} 该是非空字符串的数组`);
    return v;
  };
  const ddl = list('ddl', true), codeRoots = list('codeRoots', false);
  list('ignore', false);
  if (cfg.spec != null && (typeof cfg.spec !== 'string' || !cfg.spec)) die(2, '配置的 spec 该是字符串或 null');
  const must = (label, rel, kind) => {
    const abs = join(root, rel);
    if (!existsSync(abs)) die(2, `配置里的路径不存在：${label} = ${rel}`);
    if (kind === 'file' ? !statSync(abs).isFile() : !statSync(abs).isDirectory()) die(2, `配置里的 ${label} = ${rel} 该是${kind === 'file' ? '文件' : '目录'}`);
  };
  ddl.forEach((f, i) => must(`ddl[${i}]`, f, 'file'));
  codeRoots.forEach((d, i) => must(`codeRoots[${i}]`, d, 'dir'));
  if (cfg.spec != null) must('spec', cfg.spec, 'file');
  return { ...cfg, ddl, codeRoots };
}

// 原子落盘（契约 C 节）：先写到与 docs/readable/ 同级的临时目录，写完从磁盘逐个核对字节数，再整目录换上；
// 任何一步失败，临时目录删掉、原有的 docs/readable/ 一个字节不动，错误往上抛成退出码 3。
// 换上那一步是两次改名：旧目录先挪开，新目录改名进位，进位失败就把旧目录挪回来。
function publish(root, files) {
  const out = join(root, OUT), parent = dirname(out);
  const tmp = join(parent, `.readable-tmp-${process.pid}`), old = join(parent, `.readable-old-${process.pid}`);
  const failAt = process.env.READABLE_FAIL_AT === 'render' ? Math.floor(files.length / 2) : -1;
  mkdirSync(parent, { recursive: true });
  try {
    files.forEach((f, i) => {
      if (i === failAt) throw new Error(`READABLE_FAIL_AT=render：写完 ${i} / ${files.length} 个页面时按要求模拟失败`);
      const p = join(tmp, f.path);
      mkdirSync(dirname(p), { recursive: true });
      writeFileSync(p, f.html);
    });
    for (const f of files) {
      if (statSync(join(tmp, f.path)).size !== Buffer.byteLength(f.html)) throw new Error(`落盘核对不过：${f.path} 的字节数与生成的不同`);
    }
    const had = existsSync(out);
    if (had) renameSync(out, old);
    try { renameSync(tmp, out); } catch (e) { if (had) renameSync(old, out); throw e; }
    if (had) {
      // 新目录已经换上，旧目录删不掉不算失败，但要让人看见那个残留。
      try { rmSync(old, { recursive: true, force: true }); } catch (e) { console.error(`readable-docs: 新页面已换上，旧目录没删掉，请手动删：${join(OUT, '..', basename(old))}：${e.message}`); }
    }
  } catch (e) {
    rmSync(tmp, { recursive: true, force: true });
    throw e;
  }
}

function cmdBuild(o) {
  const cfg = loadConfig(o.root), skipped = {};
  const facts = extractDdl(cfg, o.root, skipped);
  const cols = facts.tables.reduce((s, t) => s + t.columns.length, 0);
  const tally = `表 ${facts.tables.length} 张、列 ${cols} 个；未合并的动态定义 ${facts.unfolded.length}、未解析的语句 ${facts.unparsed.length}、定义冲突 ${facts.conflicts.length}、改了不存在的表 ${facts.orphanAlters.length}`;
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
  console.log(`  数据库设计：${tally}；分 ${db.stats.groups} 组、${db.stats.groupPages} 页，最大一页 ${db.stats.largest} 张表`);
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
  console.error(`readable-docs: 脚本自身出错：${e?.stack || e}`);
  process.exitCode = 3;
}
