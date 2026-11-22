// notes.mjs —— docs/readable-src/ 的读者（架构稿 §2 notes、§3「数据所有权」）：项目配置 config.json 与项目判断 map.json。
// 这两份是人和 AI 直接编辑的，生成器只读、只校验，一个字节不写。说明（notes/）的落盘是 Task 1.4 往这个文件里加的。
// 两种「不对」分开处理（契约 A 节、F 节）：配置错、map.json 不是合法 JSON，是用法错，抛 ConfigError 由入口报退出码 2；
// map.json 的内容对不上（点到不存在的表或文件、一张表进了两个组、status 写错）不拦生成，逐条记进 mapProblems——
// 拦了，读者连页面都拿不到；不记，读者会把一条点错的判断当真。
import { existsSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';

export const CONFIG = 'docs/readable-src/config.json';
export const MAP = 'docs/readable-src/map.json';
export const STATUSES = ['proposed', 'confirmed']; // AI 提议 / 人已确认；confirmed 只由人改
export const UNGROUPED_ID = '_ungrouped';

export class ConfigError extends Error {}
const bad = (msg) => { throw new ConfigError(msg); };

function readJson(root, rel, what) {
  try { return JSON.parse(readFileSync(join(root, rel), 'utf8')); }
  catch (e) { if (e instanceof SyntaxError) bad(`${what}不是合法 JSON：${rel}：${e.message}`); throw e; }
}

// 配置有错一律退出码 2 并点名是哪一条（契约 A 节）；从入口原样搬来，提示文字不变。
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
  const ddl = list('ddl', true), codeRoots = list('codeRoots', false), ignore = list('ignore', false);
  if (cfg.spec != null && (typeof cfg.spec !== 'string' || !cfg.spec)) bad('配置的 spec 该是字符串或 null');
  const must = (label, rel, kind) => {
    const abs = join(root, rel);
    if (!existsSync(abs)) bad(`配置里的路径不存在：${label} = ${rel}`);
    if (kind === 'file' ? !statSync(abs).isFile() : !statSync(abs).isDirectory()) bad(`配置里的 ${label} = ${rel} 该是${kind === 'file' ? '文件' : '目录'}`);
  };
  ddl.forEach((f, i) => must(`ddl[${i}]`, f, 'file'));
  codeRoots.forEach((d, i) => must(`codeRoots[${i}]`, d, 'dir'));
  if (cfg.spec != null) must('spec', cfg.spec, 'file');
  return { ...cfg, ddl, codeRoots, ignore };
}

const isObj = (v) => v && typeof v === 'object' && !Array.isArray(v);
const str = (v) => typeof v === 'string' && v !== '';

// 项目判断（契约 F 节）。tables 是建表定义里有的表名；点名不分大小写，落到建表定义里的写法上。
// 返回校验过的一份：tableGroups 为 null 表示没有分组判断（照前缀分），每组只剩存在的、先出现的表；
// dynamicTables 只剩文件存在的条目与存在的表。对不上的每一条进 problems：{where, problem}，按在文件里出现的先后。
export function loadMap(root, tables) {
  const out = { tableGroups: null, dynamicTables: [], problems: [] };
  if (!existsSync(join(root, MAP))) return out;
  const m = readJson(root, MAP, '项目判断');
  if (!isObj(m)) bad(`项目判断的顶层该是对象：${MAP}`);
  if (m.version !== 1) bad(`项目判断的 version 只认 1，现在是 ${JSON.stringify(m.version)}：${MAP}`);
  const known = new Map(tables.map((n) => [n.toLowerCase(), n]));
  const problem = (where, text) => out.problems.push({ where, problem: text });
  const status = (where, v) => {
    if (STATUSES.includes(v)) return v;
    problem(`${where}.status`, `status 是 ${JSON.stringify(v ?? null)}，只认 proposed 或 confirmed；按 proposed（AI 提议）算`);
    return 'proposed';
  };
  const names = (where, v, kind) => {
    if (v === undefined) return [];
    if (!Array.isArray(v)) { problem(where, `${kind}该是表名的数组，整项没用`); return []; }
    const got = [];
    v.forEach((n, i) => {
      const t = typeof n === 'string' ? known.get(n.toLowerCase()) : undefined;
      if (!t) problem(`${where}[${i}]`, `点到的表 ${JSON.stringify(n)} 在建表定义里不存在`);
      else if (got.includes(t)) problem(`${where}[${i}]`, `表 ${t} 在这一项里列了两次`);
      else got.push(t);
    });
    return got;
  };

  // 空数组与没写同样处理：还没分组的判断不该把所有表都扔进「未分组」，照前缀分更有用。
  if (m.tableGroups !== undefined && !Array.isArray(m.tableGroups)) problem('tableGroups', 'tableGroups 该是数组，整段没用，照表名前缀分组');
  else if (m.tableGroups?.length) {
    const ids = new Set(), owner = new Map();
    out.tableGroups = [];
    m.tableGroups.forEach((g, i) => {
      const w = `tableGroups[${i}]`;
      if (!isObj(g)) return problem(w, '该是对象，这一组没用');
      if (!str(g.id)) return problem(`${w}.id`, '组没写 id，这一组没用');
      if (g.id === UNGROUPED_ID) return problem(`${w}.id`, `id ${UNGROUPED_ID} 留给「未分组」，这一组没用`);
      if (ids.has(g.id)) return problem(`${w}.id`, `组 id ${g.id} 重复，按先出现的那组算，这一组没用`);
      ids.add(g.id);
      if (!str(g.title)) problem(`${w}.title`, `组 ${g.id} 没写标题，用 id 当标题`);
      const st = status(w, g.status), mine = [];
      for (const t of names(`${w}.tables`, g.tables, 'tables ')) {
        if (owner.has(t)) problem(`${w}.tables`, `表 ${t} 已在组 ${owner.get(t)} 里，按先出现的算，这里不再收`);
        else { owner.set(t, g.id); mine.push(t); }
      }
      out.tableGroups.push({ id: g.id, title: str(g.title) ? g.title : g.id, status: st, tables: mine });
    });
  }

  if (m.dynamicTables !== undefined && !Array.isArray(m.dynamicTables)) problem('dynamicTables', 'dynamicTables 该是数组，整段没用');
  else (m.dynamicTables ?? []).forEach((d, i) => {
    const w = `dynamicTables[${i}]`;
    if (!isObj(d)) return problem(w, '该是对象，这一项没用');
    const file = str(d.file) ? d.file.replace(/\\/g, '/') : null;
    if (!file) return problem(`${w}.file`, '没写 file，这一项没用');
    if (!existsSync(join(root, file)) || !statSync(join(root, file)).isFile()) return problem(`${w}.file`, `点到的文件 ${file} 不存在，这一项没用`);
    const st = status(w, d.status);
    out.dynamicTables.push({ file, reads: names(`${w}.reads`, d.reads, 'reads '), writes: names(`${w}.writes`, d.writes, 'writes '), status: st });
  });
  return out;
}
