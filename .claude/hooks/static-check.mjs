// static-check.mjs — 识别技术栈并跑静态检查（shellcheck / ruff|py_compile / tsc / node --check）。
// 全绿 exit 0；任一红 exit 1（并打印错误）；工具未装 → 跳过该栈（绝不因缺工具卡死）。
// 用法： node static-check.mjs [project_dir]
//
// 定位：code-review 的 Stage 0「静态闸」。单模型审查（同模型，盲区重合）天生弱，
//       用模型无关的机械化静态检查补偿——静态绿才进语义审查（Stage 1/2）。
// 这不是 hook：不读 stdin、不注册进 settings，退出码是「有没有红」而非 hook 的放行/拦停语义。
import fs from 'node:fs';
import path from 'node:path';
import { out, say, run } from './lib/io.mjs';

// 排除依赖/运行态/构建/VCS + 框架自身（.opencode/.claude 是装进来的基建，非被审的用户代码）
const PRUNE = new Set(['node_modules', '.git', '.ccb', 'dist', 'build', '.venv', 'out', '.opencode', '.claude']);
// JS 用的是另一张排除表，不复用上面那张：.claude 底下就是框架自己的 JS（引擎、审计脚本、
// workflow 编排），按 PRUNE 整块排掉等于框架的 .mjs 从来没人做过语法检查。
// 但 .claude/worktrees/ 必须挡——那底下是各 agent 的完整工作树副本，扫进去就是把同一个仓
// 重复检查 N 遍，还会把别的分支的代码算到本次审查头上。
const JS_PRUNE = new Set(['node_modules', '.git', '.ccb', 'dist', 'build', '.venv', 'out', 'coverage', '.opencode']);
const JS_PRUNE_PATHS = new Set(['.claude/worktrees']);

const ran = [];
let fail = 0;

function have(cmd) {
  return run(cmd, ['--version']).error === null;
}

function reportFail(tool, text) {
  out(`[${tool} 未通过]`);
  out(String(text).split('\n').slice(0, 40).join('\n'));
  fail = 1;
}

/**
 * 从 base 收集匹配的文件（相对路径，'./' 前缀与 find 一致）。
 * 目录级剪枝而不是先收全再过滤：node_modules 底下几万个文件，遍历本身就是成本。
 * 符号链接目录不跟进——跟进就可能把同一棵树数两遍，或走出被检查的目录。
 */
function findFiles({ match, prune, prunePaths = new Set(), maxDepth = Infinity }) {
  const found = [];
  const walk = (dir, rel, depth) => {
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (_e) { return; }
    for (const e of entries) {
      const childRel = rel ? `${rel}/${e.name}` : e.name;
      if (e.isSymbolicLink()) continue;
      if (e.isDirectory()) {
        if (prune.has(e.name) || prunePaths.has(childRel)) continue;
        if (depth + 1 <= maxDepth) walk(path.join(dir, e.name), childRel, depth + 1);
      } else if (e.isFile() && match(e.name)) {
        found.push(`./${childRel}`);
      }
    }
  };
  walk('.', '', 0);
  return found;
}

const extIs = (...exts) => (name) => exts.some((x) => name.endsWith(x));

// ---- 入口参数：目录 ----
const dir = process.argv[2] || '.';
if (dir.includes('..')) {
  say(`static-check: unsafe dir ${dir}`);
  process.exitCode = 1;
} else {
  let ok = true;
  try { process.chdir(dir); } catch (_e) { say(`static-check: bad dir ${dir}`); process.exitCode = 1; ok = false; }
  if (ok) main();
}

function main() {
  // ---- shell ----
  const sh = findFiles({ match: extIs('.sh'), prune: PRUNE });
  if (sh.length > 0 && have('shellcheck')) {
    ran.push('shellcheck');
    const r = run('shellcheck', sh);
    if (r.status !== 0) reportFail('shellcheck', `${r.stdout}${r.stderr}`);
  }

  // ---- python ----
  const py = findFiles({ match: extIs('.py'), prune: PRUNE });
  if (py.length > 0) {
    if (have('ruff')) {
      ran.push('ruff');
      const r = run('ruff', ['check', '.']);
      if (r.status !== 0) reportFail('ruff', `${r.stdout}${r.stderr}`);
    } else if (have('python3')) {
      ran.push('py_compile');
      const r = run('python3', ['-m', 'py_compile', ...py]);
      if (r.status !== 0) reportFail('py_compile', `${r.stdout}${r.stderr}`);
    }
  }

  // ---- TypeScript ----
  // tsconfig 不一定在仓库顶层（前端常在子目录，如 conflation/web）——有限深度探测全部
  // tsconfig.json；目录里装好依赖（有 node_modules）才进去跑，否则跳过该目录（缺依赖不卡死）。
  const tsDirs = [];
  if (have('npx')) {
    const cfgs = findFiles({ match: (n) => n === 'tsconfig.json', prune: PRUNE, maxDepth: 3 });
    for (const cfg of cfgs) {
      const tsdir = path.dirname(cfg);
      if (!fs.existsSync(path.join(tsdir, 'node_modules'))) continue;
      tsDirs.push(tsdir);
      ran.push(`tsc(${tsdir})`);
      const r = run('npx', ['--no-install', 'tsc', '--noEmit'], { cwd: tsdir });
      if (r.status !== 0) reportFail(`tsc ${tsdir}`, `${r.stdout}${r.stderr}`);
    }
  }

  // ---- JavaScript ----
  const js = findFiles({ match: extIs('.mjs', '.cjs', '.js'), prune: JS_PRUNE, prunePaths: JS_PRUNE_PATHS });
  if (js.length > 0) {
    let jsout = '';
    let jsn = 0;
    for (const f of js) {
      // 落在跑过 tsc 的子树里的不重复检查：tsc 看得比语法更远，同一份文件报两遍只是噪音。
      if (tsDirs.some((d) => f.startsWith(`${d}/`))) continue;
      jsn += 1;
      // node --check 自己就打 <文件>:<行>，原样透出去、不另造格式；只滤掉纯噪音的调用栈。
      const r = run(process.execPath, ['--check', f]);
      if (r.status !== 0) {
        jsout += `${`${r.stdout}${r.stderr}`.split('\n')
          .filter((l) => !l.startsWith('    at ') && !l.startsWith('Node.js v'))
          .join('\n')}\n`;
      }
    }
    if (jsn > 0) {
      ran.push(`node --check(${jsn})`);
      if (jsout.trim() !== '') reportFail('node --check', jsout);
    }
  }

  if (ran.length === 0) {
    out('static-check: 未识别到可跑的静态检查（无对应栈或工具未装），跳过。');
    return;
  }
  if (fail !== 0) {
    out('static-check: 静态检查有错（见上），请修绿后再进语义审查。');
    process.exitCode = 1;
    return;
  }
  out(`static-check: 全绿（${ran.join(' ')}）。`);
}
