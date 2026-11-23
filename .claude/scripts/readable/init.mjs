// init.mjs —— 入口的两件独立的事：走项目里的文件（walk），与 init 起草 docs/readable-src/config.json（契约 docs/readable-spec/phase1-db-contract.md A 节）。
// 原在入口 readable-docs.mjs，2026-11-23 第三期 Task 3.4 原样搬来：入口要给架构这一份腾地方，单个文件别超过三百行。
// walk 也给 build 用（取代码文件、建表定义）；init 只在这里。
import { existsSync, writeFileSync, mkdirSync, readdirSync } from 'node:fs';
import { join, resolve, basename, dirname } from 'node:path';
import { cmp } from './model.mjs';
import { CONFIG } from './config.mjs';
import { globRe } from './arch-map.mjs'; // ignore 与模块的 paths 同一套通配（第三期契约 A 节）

// 后三条是测试文件与代码放在一起的写法（第三期契约 A 节）：不排掉，模块图上全是测试库。已有的配置不替人改。
const DEFAULT_IGNORE = ['**/tests/**', '**/node_modules/**', '**/*.test.*', '**/*.spec.*', '**/__tests__/**'];
const ARCH_DOC_FILE = 'Architecture-Design.md'; // init 在根目录有它时填进 archDocs
const CODE_EXT = /\.(py|ts|tsx)$/;
// 契约 A 节：ddl 依次找这三类，同一目录按文件名排序；三类都收、按这个先后排、去重——
// 只取先找到的一类会漏掉排在后面的迁移文件，漏表是这一层最贵的错；多收的在配置里一眼看得见、可删。
// sql/ 与 migrations/ 在任意深度都认：有的项目的建表文件在 <项目名>/sql/ 下按编号排（001_*.sql、002_*.sql…），只找根目录下的 sql/ 一张表都找不到。
const DDL_PATTERNS = [
  ['**/schema.sql', (f) => f.split('/').pop() === 'schema.sql'],
  ['**/sql/*.sql', (f) => /(?:^|\/)sql\/[^/]+\.sql$/.test(f)],
  ['**/migrations/*.sql', (f) => /(?:^|\/)migrations\/[^/]+\.sql$/.test(f)],
];

// 项目里的文件（相对路径、/ 分隔、按名字定序）。点开头的文件与目录、__pycache__ 目录不进，也不报数：.git、.venv、.claude 里的
// 不是项目的来源（cc-base 自己的 .claude/tests 里就有 SQL 夹具）；编译缓存不入库，算进去的话同一份代码在跑过与没跑过的副本上
// 出两样的页面（第三期契约 B 节「文件」）。符号链接不跟，免得绕圈。sub 给了就只走那个子目录，路径仍相对 root。
export function walk(root, ignore, sub = '') {
  const res = ignore.map(globRe), skip = (rel) => res.some((r) => r.test(rel)), out = [];
  const visit = (dir, rel) => {
    for (const d of readdirSync(dir, { withFileTypes: true }).sort((a, b) => cmp(a.name, b.name))) {
      if (d.name.startsWith('.') || (d.name === '__pycache__' && d.isDirectory())) continue;
      const r = rel ? `${rel}/${d.name}` : d.name;
      if (d.isDirectory()) { if (!skip(`${r}/`)) visit(join(dir, d.name), r); }
      else if (d.isFile() && !skip(r)) out.push(r);
    }
  };
  const start = sub.replace(/\\/g, '/').replace(/^\.?\/+|\/+$/g, '');
  visit(start ? join(root, start) : root, start);
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

export function cmdInit(o) {
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
