// config.mjs —— 项目配置 docs/readable-src/config.json 的读取与校验（架构稿 §2 notes：docs/readable-src/ 的读者）。
// 原在 notes.mjs，2026-11-23 第三期 Task 3.3 原样搬来、行为不变，notes.mjs 照旧转出 CONFIG 与 loadConfig；
// 搬出来是为了给模块的说明腾地方（notes.mjs 不再长）。配置有错一律抛 ConfigError，由入口报退出码 2 并点名是哪一条（契约 A 节）。
import { existsSync, readFileSync, statSync } from 'node:fs';
import { isAbsolute, join, posix } from 'node:path';
import { ConfigError } from './notes-store.mjs';

export const CONFIG = 'docs/readable-src/config.json';

const bad = (msg) => { throw new ConfigError(msg); };

// 配置与项目判断共用：不是合法 JSON 是用法错，点名哪个文件；别的读错照原样往上抛。
export function readJson(root, rel, what) {
  try { return JSON.parse(readFileSync(join(root, rel), 'utf8')); }
  catch (e) { if (e instanceof SyntaxError) bad(`${what}不是合法 JSON：${rel}：${e.message}`); throw e; }
}

// archDocs（第三期契约 A 节）：现有的架构文档与决策记录，可以没有；写了路径而文件不存在，同 ddl 一样退出码 2 并点名。
// 内容怎么上页面是后面的 Task，这里只校验。
export function loadConfig(root) {
  if (!existsSync(join(root, CONFIG))) bad(`配置不存在：${CONFIG}（先跑 init）`);
  const cfg = readJson(root, CONFIG, '配置');
  if (!cfg || typeof cfg !== 'object' || Array.isArray(cfg)) bad(`配置的顶层该是对象：${CONFIG}`);
  if (cfg.version !== 1) bad(`配置的 version 只认 1，现在是 ${JSON.stringify(cfg.version)}`);
  const list = (key, required) => {
    const v = cfg[key];
    if (v === undefined && !required) return [];
    if (!Array.isArray(v) || v.some((s) => typeof s !== 'string' || !s)) bad(`配置的 ${key} 该是非空字符串的数组`);
    return v;
  };
  const ddl = list('ddl', true), codeRoots = list('codeRoots', false), ignore = list('ignore', false), archDocs = list('archDocs', false);
  if (cfg.spec != null && (typeof cfg.spec !== 'string' || !cfg.spec)) bad('配置的 spec 该是字符串或 null');
  // 生成器只读根目录以内的东西（契约 A 节）：绝对路径、用 .. 越出根目录的，退出码 2 并点名，不去读——join 会把它们拼到根目录外面去。
  const outside = (rel) => {
    const p = rel.replace(/\\/g, '/');
    if (isAbsolute(rel) || p.startsWith('/') || /^[A-Za-z]:/.test(p)) return '是绝对路径';
    const n = posix.normalize(p);
    return n === '..' || n.startsWith('../') ? '用 .. 越出了根目录' : null;
  };
  const must = (label, rel, kind) => {
    const why = outside(rel);
    if (why) bad(`配置里的 ${label} = ${rel} ${why}，生成器只读根目录以内的东西`);
    const abs = join(root, rel);
    if (!existsSync(abs)) bad(`配置里的路径不存在：${label} = ${rel}`);
    if (kind === 'file' ? !statSync(abs).isFile() : !statSync(abs).isDirectory()) bad(`配置里的 ${label} = ${rel} 该是${kind === 'file' ? '文件' : '目录'}`);
  };
  ddl.forEach((f, i) => must(`ddl[${i}]`, f, 'file'));
  codeRoots.forEach((d, i) => must(`codeRoots[${i}]`, d, 'dir'));
  if (cfg.spec != null) must('spec', cfg.spec, 'file');
  archDocs.forEach((f, i) => must(`archDocs[${i}]`, f, 'file'));
  return { ...cfg, ddl, codeRoots, ignore, archDocs };
}
