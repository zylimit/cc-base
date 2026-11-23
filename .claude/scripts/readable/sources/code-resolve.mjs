// code-resolve.mjs —— 代码文件的两个取事实器共用的几样：Python 引用语句在哪、一条引用解析到哪个文件、说明的统一缩进
// （第三期契约 docs/readable-spec/phase3-arch-contract.md B 节「引用」「接口」）。
// 为什么单拆出来：code-imports.mjs 靠它们出引用边，code-routes.mjs 靠同一套找「挂上来的乙是哪个文件里的路由器」、取处理函数的说明。
// 只许有这一份：两边各写一份，迟早一边改了「from a import b 指向谁」而另一边没改，接口挂到的文件与模块图上的边就对不上
// （2026-11-23 Task 3.2 从 code-imports.mjs 原样搬来，行为一个字节没变）。
import { statSync } from 'node:fs';
import { join, posix } from 'node:path';
import { builtinModules } from 'node:module';
import { sticky } from './code-lex.mjs';

export const langOf = (f) => (/\.py$/.test(f) ? 'python' : /\.(?:js|jsx|mjs|cjs|ts|tsx)$/.test(f) ? 'js' : null);
const JS_TRY = ['.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs']; // 契约 B 节：原样之后依次试这些，再试 /index 加这些
// Python 标准库的顶层模块：本机 Python 3.14.4 的 sys.stdlib_module_names 去掉下划线开头的，194 个（2026-11-23 取）。
// 另补 __future__：它在 stdlib_module_names 里，跟着下划线开头的一起被去掉了，而 from __future__ import annotations 几乎每个文件都有。
export const PY_STDLIB = new Set(`abc annotationlib antigravity argparse array ast asyncio atexit base64 bdb binascii bisect builtins bz2 cProfile calendar
cmath cmd code codecs codeop collections colorsys compileall compression concurrent configparser contextlib contextvars copy copyreg csv ctypes
curses dataclasses datetime dbm decimal difflib dis doctest email encodings ensurepip enum errno faulthandler fcntl filecmp fileinput fnmatch
fractions ftplib functools gc genericpath getopt getpass gettext glob graphlib grp gzip hashlib heapq hmac html http idlelib imaplib importlib
inspect io ipaddress itertools json keyword linecache locale logging lzma mailbox marshal math mimetypes mmap modulefinder msvcrt multiprocessing
netrc nt ntpath nturl2path numbers opcode operator optparse os pathlib pdb pickle pickletools pkgutil platform plistlib poplib posix posixpath
pprint profile pstats pty pwd py_compile pyclbr pydoc pydoc_data pyexpat queue quopri random re readline reprlib resource rlcompleter runpy sched
secrets select selectors shelve shlex shutil signal site smtplib socket socketserver sqlite3 sre_compile sre_constants sre_parse ssl stat
statistics string stringprep struct subprocess symtable sys sysconfig syslog tabnanny tarfile tempfile termios textwrap this threading time
timeit tkinter token tokenize tomllib trace traceback tracemalloc tty turtle turtledemo types typing unicodedata unittest urllib uuid venv
warnings wave weakref webbrowser winreg winsound wsgiref xml xmlrpc zipapp zipfile zipimport zlib zoneinfo __future__`.split(/\s+/));
const NODE_BUILTIN = new Set(builtinModules);

// ---- Python：引用语句 ----
// 只认语句开头的 import / from：行首（括号里换行、反斜杠续行的不算新行）、分号之后、括号外的冒号之后（if TYPE_CHECKING: import x）。
// yield from、raise … from 里的 from 不在语句开头，自然不认。写在函数里、try 里、条件分支里的照认——它们也在语句开头。
export const PY_NAME = '[A-Za-z_\\u0080-\\uffff][\\w\\u0080-\\uffff]*';
export const PY_DOTTED = `${PY_NAME}(?:\\s*\\.\\s*${PY_NAME})*`;
const PY_KW = /(?:import|from)(?![\w\u0080-￿])/y;
export const PY_IMPORT = /^import\s+([\s\S]+)$/;
export const PY_FROM = new RegExp(`^from\\s*(\\.*)\\s*(${PY_DOTTED})?\\s*import(?![\\w\\u0080-\\uffff])\\s*([\\s\\S]*)$`);
export const dotted = (s) => s.replace(/\s+/g, '').split('.');

export function pyStatements(o) { // 以 import / from 开头的简单语句：[[起, 止]]，o 是抹掉了注释与字符串正文的源码
  const res = [];
  let depth = 0, atStart = true, cur = -1;
  const close = (i) => { if (cur >= 0) res.push([cur, i]); cur = -1; atStart = true; };
  for (let i = 0; i < o.length; i++) {
    const c = o[i];
    if (c === '\\' && (o[i + 1] === '\n' || (o[i + 1] === '\r' && o[i + 2] === '\n'))) { i += o[i + 1] === '\r' ? 2 : 1; continue; }
    if (c === '\n') { if (depth === 0) close(i); continue; }
    if (/\s/.test(c)) continue;
    if (depth === 0 && c === ';') { close(i); continue; }
    if (atStart) {
      atStart = false;
      const w = sticky(PY_KW, o, i);
      if (w) { cur = i; i += w.length - 1; continue; }
    }
    if (depth === 0 && c === ':' && cur < 0) atStart = true;
    else if (c === '(' || c === '[' || c === '{') depth++;
    else if (c === ')' || c === ']' || c === '}') depth = Math.max(0, depth - 1);
  }
  close(o.length);
  return res;
}

// ---- 说明：统一缩进 ----
const expandTabs = (s) => { let r = ''; for (const ch of s) r += ch === '\t' ? ' '.repeat(8 - (r.length % 8)) : ch; return r; };
// first 为真时同 inspect.cleandoc：第一行只去行首空白，公共缩进只从第二行起算；为假时所有行一起算。全空返回 null。
export function cleandoc(lines, first) {
  const ls = lines.map(expandTabs);
  let margin = Infinity;
  ls.forEach((x, i) => { const t = x.trimStart(); if (t && (i > 0 || !first)) margin = Math.min(margin, x.length - t.length); });
  if (first) ls[0] = ls[0].trimStart();
  if (margin < Infinity) for (let i = first ? 1 : 0; i < ls.length; i++) ls[i] = ls[i].slice(margin);
  while (ls.length && !ls[ls.length - 1]) ls.pop();
  while (ls.length && !ls[0]) ls.shift();
  return ls.length ? ls.join('\n') : null;
}

// ---- 解析到文件 ----
export function resolver(root, config) {
  const seen = new Map();
  const isFile = (rel) => { if (!seen.has(rel)) seen.set(rel, statSync(join(root, rel), { throwIfNoEntry: false })?.isFile() ?? false); return seen.get(rel); };
  const norm = (d) => { const x = posix.normalize(String(d).replace(/\\/g, '/')).replace(/\/+$/, ''); return x === '.' ? '' : x; };
  const starts = [...new Set([...(config.codeRoots ?? []).map(norm), ''])]; // 契约 B 节：依次拿每个代码根目录、再拿项目根当起点
  const cat = (...xs) => xs.filter((x) => x !== '').join('/');
  // 同一个名字既有 a/ 包又有 a.py 时 Python 先认包，这里同它。
  const pyFile = (dir, parts) => { const b = cat(dir, ...parts), init = cat(b, '__init__.py'); return isFile(init) ? init : parts.length && isFile(`${b}.py`) ? `${b}.py` : null; };
  // 能对上文件的最长前缀；几个起点都对得上时取最长的，一样长取先试的起点。
  const longest = (parts) => {
    let best = null;
    for (const s of starts) for (let j = parts.length; j > (best?.j ?? 0); j--) { const f = pyFile(s, parts.slice(0, j)); if (f) { best = { j, f }; break; } }
    return best;
  };
  const jsTarget = (file, spec) => {
    if (!/^\.\.?(?:\/|$)/.test(spec)) {
      if (/^[@~]\//.test(spec) || spec.startsWith('/')) return { to: null }; // 别名开头的现在不解析（契约 B 节）
      const pkg = spec.startsWith('@') ? spec.split('/').slice(0, 2).join('/') : spec.split('/')[0];
      return { ext: spec.startsWith('node:') || NODE_BUILTIN.has(spec) || NODE_BUILTIN.has(pkg) ? null : pkg };
    }
    const b = norm(posix.join(posix.dirname(file), spec));
    if (b === '..' || b.startsWith('../')) return { to: null };
    for (const c of [b, ...JS_TRY.map((x) => `${b}${x}`), ...JS_TRY.map((x) => cat(b, `index${x}`))]) {
      if (c && isFile(c)) return langOf(c) ? { to: c } : { asset: true }; // 样式表、JSON、图片：不成边，也不算没解析到
    }
    return { to: null };
  };
  return { pyFile, longest, jsTarget };
}
