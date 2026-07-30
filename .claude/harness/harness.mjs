// harness.mjs -- cc-base monorepo governance runtime (single file, zero npm deps).
// Node builtins only: node:crypto / node:fs / node:path / node:child_process / node:process.
// Default-off: catalog presence (.claude/harness/module-catalog.json) is the only switch.
// All subcommands: stdout single-line JSON + exit code; human diagnostics -> stderr.
// Source is ASCII-only (matches the .ps1 pure-ASCII convention) to avoid cross-platform encoding traps.
//
// Section map (banner + JSDoc, one file, do not split):
//   S0 CLI dispatch   main(), parseArgs(), route(cmd)
//   S1 common         readStdin(), stableJson(), sha256(), emit(obj,code), die(msg,code)
//   S2 git            headCommit(), changedPaths(), canonicalDiff()->Buffer, gitFingerprint()
//   S3 glob           globToRegExp(glob), matchAny(path,globs), specificity(glob)
//   S4 catalog        loadCatalog(), validateSchema(), classifyPath(), lintCatalog()   [T1.1/T1.2]
//   S5 impact         reverseClosure(), analyzeImpact()                                 [T1.3]
//   S6 context-pack   DENY, isDenied(), prioritize(), buildPack()                       [T1.4]
//   S7 receipt        contentHash(), writeReceipt(), verifyReceipt()                    [T2.1]
//   S8 quality        requiredChecks(risk), runCheck()->four-state, verifyPlan()        [T2.3]
//   S9 config         loadHarnessConfig(), DEFAULTS

import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import assert from 'node:assert';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

// Directory of this script (ESM has no __dirname); used to resolve checked-in test fixtures.
const HARNESS_DIR = path.dirname(fileURLToPath(import.meta.url));

// ---------------------------------------------------------------------------
// JSDoc typedefs (centralized; only fields relevant to current + near Tasks).
// ---------------------------------------------------------------------------
/**
 * @typedef {Object} Module
 * @property {string} id                     unique module id
 * @property {string[]} paths                glob patterns owned by this module
 * @property {string[]} [dependsOn]          module ids this one depends on
 * @property {string[]} [owners]             owner handles
 * @property {('low'|'medium'|'high')} [riskTier]
 */
/**
 * @typedef {Object} Catalog
 * @property {number} version
 * @property {Module[]} modules
 * @property {string[]} [global]             paths that force full-fanout on change
 * @property {string[]} [ignored]            paths excluded from impact
 * @property {Object<string,string[]>} [riskChecks]
 * @property {Object<string,Object>} [checks]
 * @property {ContextPackBudget} [contextPack]
 */
/**
 * @typedef {Object} ContextPackBudget
 * @property {number} maxTotalChars
 * @property {number} maxFiles
 * @property {number} maxFileChars
 * @property {number} maxDiffChars
 */
/**
 * @typedef {Object} Receipt
 * @property {string} taskId
 * @property {string} baseCommit
 * @property {string} diffHash
 * @property {string} reviewer
 * @property {string} verdict
 * @property {Object} scope
 * @property {string} timestamp
 * @property {string} contentHash
 */
/**
 * @typedef {Object} CheckResult
 * @property {string} id
 * @property {string} [class]
 * @property {('PASS'|'FAIL'|'BLOCKED'|'SKIPPED')} state
 * @property {number} [exit]
 * @property {string} [reason]
 * @property {string} [cmd]
 */

// ===========================================================================
// S0 CLI dispatch
// ===========================================================================
const IMPLEMENTED_SUBCOMMANDS = ['doctor', 'diff-hash', 'selftest', 'catalog-lint', 'impact'];
const NOT_IMPLEMENTED_SUBCOMMANDS = ['context-pack', 'receipt', 'verify'];

/**
 * Parse `<subcommand> [--flag value ...] [positional ...]`.
 * A flag with no following value (or followed by another --flag) is boolean true.
 * @param {string[]} argv  process.argv.slice(2)
 */
function parseArgs(argv) {
  const cmd = argv[0];
  const flags = {};
  const positional = [];
  for (let i = 1; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith('--')) {
        flags[key] = true;
      } else {
        flags[key] = next;
        i++;
      }
    } else {
      positional.push(a);
    }
  }
  return { cmd, flags, positional, sub: positional[0] };
}

function main() {
  const { cmd } = parseArgs(process.argv.slice(2));
  const { flags } = parseArgs(process.argv.slice(2));
  switch (cmd) {
    case 'doctor':       return cmdDoctor();
    case 'diff-hash':    return cmdDiffHash();
    case 'selftest':     return cmdSelftest();
    case 'catalog-lint': return cmdCatalogLint(flags);
    case 'impact':       return cmdImpact(flags);
    // Planned subcommands: explicit not-implemented, never crash / never fake success.
    case 'context-pack':
    case 'receipt':
    case 'verify':
      return emit({ error: 'not-implemented', cmd }, 3);
    default:
      return die(usage(cmd), 3);
  }
}

function usage(cmd) {
  const prefix = cmd ? ('unknown subcommand: ' + cmd + '\n') : 'missing subcommand\n';
  return prefix +
    'usage: node harness.mjs <subcommand>\n' +
    'implemented: ' + IMPLEMENTED_SUBCOMMANDS.join(', ') + '\n' +
    'planned (not-implemented): ' + NOT_IMPLEMENTED_SUBCOMMANDS.join(', ');
}

function cmdDoctor() {
  const cfg = loadHarnessConfig();
  emit({
    node: process.version,
    catalogPresent: cfg.catalogPresent,
    gitRepo: isGitRepo(),
    headCommit: headCommit(),
    harnessDir: '.claude/harness',
    subcommands: IMPLEMENTED_SUBCOMMANDS,
  }, 0);
}

function cmdDiffHash() {
  const { buf, nonGit } = canonicalDiff();
  emit({ diffHash: sha256(buf), baseCommit: headCommit(), nonGit }, 0);
}

/**
 * Inline regression assertions (node:assert, zero npm). Extensible: later Tasks append
 * more cases to selftestCases(). All pass -> {ok:true,tests:N} exit 0; any fail ->
 * {ok:false,failed:[...]} exit 1.
 */
function selftestCases() {
  // Fixture loader (checked-in tiny catalogs live under .claude/tests/fixtures/harness).
  const fx = (n) => path.join(HARNESS_DIR, '..', 'tests', 'fixtures', 'harness', n);
  const loadFx = (n) => { const r = loadCatalog(fx(n)); assert.ok(r.ok, 'fixture load failed: ' + n + ' ' + (r.detail || '')); return r.catalog; };
  const hasCode = (errors, code) => errors.some(e => e.code === code);

  const good = loadFx('catalog-good.json');
  // A tracked set where every path is claimed by a module/global/ignored (no unmapped/overlap).
  const goodTracked = ['core/index.ts', 'db/schema.ts', 'auth/login.ts', 'api/routes.ts', 'package.json', 'README.md', 'docs/guide.md'];

  return [
    // S3 glob -- trailing ** must match files at any depth (T0.1 P1 target).
    ['glob src/auth/** matches src/auth/login.ts', () => assert.ok(matchAny('src/auth/login.ts', ['src/auth/**']))],
    ['glob src/auth/** matches src/auth/x/y.ts', () => assert.ok(matchAny('src/auth/x/y.ts', ['src/auth/**']))],
    ['glob src/auth/** does not match src/authz/z.ts', () => assert.ok(!matchAny('src/authz/z.ts', ['src/auth/**']))],
    ['glob src/auth/** does not match src/auth (dir itself)', () => assert.ok(!matchAny('src/auth', ['src/auth/**']))],
    ['glob src/**/*.ts matches src/a/b.ts', () => assert.ok(matchAny('src/a/b.ts', ['src/**/*.ts']))],
    ['glob src/* matches src/a.ts', () => assert.ok(matchAny('src/a.ts', ['src/*']))],
    ['glob src/* does not match src/a/b.ts (single * no /)', () => assert.ok(!matchAny('src/a/b.ts', ['src/*']))],
    ['specificity src/auth/** > src/**', () => assert.ok(specificity('src/auth/**') > specificity('src/**'))],

    // S4 classifyPath -- priority module > ignored > global > unmapped.
    ['classify db/schema.ts -> module db', () => { const c = classifyPath('db/schema.ts', good); assert.equal(c.kind, 'module'); assert.equal(c.moduleId, 'db'); }],
    ['classify README.md -> ignored', () => assert.equal(classifyPath('README.md', good).kind, 'ignored')],
    ['classify package.json -> global', () => assert.equal(classifyPath('package.json', good).kind, 'global')],
    ['classify weird/x -> unmapped', () => assert.equal(classifyPath('weird/x', good).kind, 'unmapped')],

    // S4 catalog-lint -- good catalog with fully-classified tracked set is clean.
    ['lint good catalog (all tracked classified) -> ok, no errors', () => { const r = lintCatalog(good, goodTracked); assert.ok(r.ok); assert.equal(r.errors.length, 0); }],
    ['lint bad-catchall -> CATCH_ALL error', () => { const r = lintCatalog(loadFx('catalog-bad-catchall.json'), []); assert.ok(!r.ok); assert.ok(hasCode(r.errors, 'CATCH_ALL')); }],
    ['lint bad-unmapped -> UNMAPPED error', () => { const r = lintCatalog(loadFx('catalog-bad-unmapped.json'), ['weird/x.ts']); assert.ok(!r.ok); assert.ok(hasCode(r.errors, 'UNMAPPED')); }],
    ['lint bad-overlap -> OVERLAP error', () => { const r = lintCatalog(loadFx('catalog-bad-overlap.json'), ['core/shared/x.ts']); assert.ok(!r.ok); assert.ok(hasCode(r.errors, 'OVERLAP')); }],
    ['lint bad-dangling -> DANGLING_DEP error', () => { const r = lintCatalog(loadFx('catalog-bad-dangling.json'), []); assert.ok(!r.ok); assert.ok(hasCode(r.errors, 'DANGLING_DEP')); }],

    // S5 impact -- reverse closure + conservative fanout.
    ['impact db/x.ts -> affected includes db+auth+api (reverse closure), not degraded', () => {
      const r = analyzeImpact(['db/x.ts'], good, {});
      assert.ok(r.affected.includes('db') && r.affected.includes('auth') && r.affected.includes('api'));
      assert.equal(r.degraded, false);
    }],
    ['impact package.json (global) -> all modules + expansionReasons has global + degraded', () => {
      const r = analyzeImpact(['package.json'], good, {});
      assert.equal(r.affected.length, good.modules.length);
      assert.ok(r.expansionReasons.some(x => x.startsWith('global')));
      assert.equal(r.degraded, true);
    }],
    ['impact weird/x.ts (unmapped) -> all modules + degraded', () => {
      const r = analyzeImpact(['weird/x.ts'], good, {});
      assert.equal(r.affected.length, good.modules.length);
      assert.equal(r.degraded, true);
    }],
    ['impact README.md (ignored only) -> affected/direct empty, not degraded', () => {
      const r = analyzeImpact(['README.md'], good, {});
      assert.equal(r.affected.length, 0);
      assert.equal(r.direct.length, 0);
      assert.equal(r.degraded, false);
    }],
    ['impact non-git flag -> all modules + non-git reason + degraded', () => {
      const r = analyzeImpact([], good, { nonGit: true });
      assert.equal(r.affected.length, good.modules.length);
      assert.ok(r.expansionReasons.includes('non-git'));
      assert.equal(r.degraded, true);
    }],
    ['impact filters state files -> .claude/.fast-mode not treated as unmapped', () => {
      const r = analyzeImpact(['.claude/.fast-mode'], good, {});
      assert.equal(r.affected.length, 0);
      assert.equal(r.degraded, false);
    }],
  ];
}

function cmdSelftest() {
  const cases = selftestCases();
  const failed = [];
  for (const [name, fn] of cases) {
    try { fn(); } catch (e) { failed.push({ name, error: String(e && e.message || e) }); }
  }
  if (failed.length) return emit({ ok: false, tests: cases.length, failed }, 1);
  return emit({ ok: true, tests: cases.length }, 0);
}

// ===========================================================================
// S1 common
// ===========================================================================
/** Read process.stdin fully to a string; returns '' when there is no input. */
function readStdin() {
  try {
    if (process.stdin.isTTY) return '';
    return fs.readFileSync(0, 'utf8');
  } catch (_e) {
    return '';
  }
}

/** Deterministic JSON: recursive key sort. Null/non-object -> JSON.stringify; arrays recurse. */
function stableJson(v) {
  if (v === null || typeof v !== 'object') return JSON.stringify(v);
  if (Array.isArray(v)) return '[' + v.map(stableJson).join(',') + ']';
  return '{' + Object.keys(v).sort().map(k => JSON.stringify(k) + ':' + stableJson(v[k])).join(',') + '}';
}

/** @param {string|Buffer} data */
function sha256(data) {
  return createHash('sha256').update(data).digest('hex');
}

/** Write single-line JSON to stdout, then exit. */
function emit(obj, code = 0) {
  process.stdout.write(JSON.stringify(obj) + '\n');
  process.exit(code);
}

/** Write a human diagnostic to stderr, then exit. */
function die(msg, code = 1) {
  process.stderr.write(String(msg) + '\n');
  process.exit(code);
}

// ===========================================================================
// S2 git  (all git calls: spawnSync + maxBuffer 1<<28; diff stdout stays Buffer)
// ===========================================================================
function git(args) {
  return spawnSync('git', args, { maxBuffer: 1 << 28 });
}

function isGitRepo() {
  return git(['rev-parse', '--is-inside-work-tree']).status === 0;
}

/** @returns {string|null} */
function headCommit() {
  if (!isGitRepo()) return null;
  const r = git(['rev-parse', 'HEAD']);
  if (r.status !== 0) return null;
  return r.stdout.toString('utf8').trim();
}

// State files that must not perturb the diff fingerprint (runtime state, not code).
const STATE_EXCLUDE = [
  ':(exclude).claude/.needs-review',
  ':(exclude).claude/.needs-review.lock',
  ':(exclude).claude/.fast-mode',
  ':(exclude).claude/evidence/**',
  ':(exclude).claude/harness/receipts/**',
];
const STATE_EXCLUDE_PATHS = [
  '.claude/.needs-review',
  '.claude/.needs-review.lock',
  '.claude/.fast-mode',
];
const STATE_EXCLUDE_PREFIXES = [
  '.claude/evidence/',
  '.claude/harness/receipts/',
];
function isStateExcluded(p) {
  const n = p.replace(/\\/g, '/');
  if (STATE_EXCLUDE_PATHS.includes(n)) return true;
  return STATE_EXCLUDE_PREFIXES.some(pre => n.startsWith(pre));
}

/**
 * Changed paths vs HEAD (tracked diff + untracked), deduped.
 * @returns {string[]|{paths:string[],nonGit:true}}
 */
function changedPaths() {
  if (!isGitRepo()) return { paths: [], nonGit: true };
  const tracked = git(['diff', '--name-only', 'HEAD']).stdout.toString('utf8')
    .split('\n').map(s => s.trim()).filter(Boolean);
  const untracked = git(['-c', 'core.quotePath=false', 'ls-files', '--others', '--exclude-standard'])
    .stdout.toString('utf8').split('\n').map(s => s.trim()).filter(Boolean);
  const seen = new Set();
  const out = [];
  for (const p of tracked.concat(untracked)) {
    if (!seen.has(p)) { seen.add(p); out.push(p); }
  }
  return out;
}

/** Untracked files as a stable Buffer of "U <path> <contentHash>\n" lines (sorted, state files excluded). */
function hashUntracked() {
  const list = git(['-c', 'core.quotePath=false', 'ls-files', '--others', '--exclude-standard'])
    .stdout.toString('utf8').split('\n').map(s => s.trim()).filter(Boolean)
    .filter(p => !isStateExcluded(p))
    .sort();
  const parts = [];
  for (const p of list) {
    let content;
    try { content = fs.readFileSync(p); } catch (_e) { continue; }
    parts.push(Buffer.from('U ' + p + ' ' + sha256(content) + '\n', 'utf8'));
  }
  return Buffer.concat(parts);
}

/**
 * Canonical git diff as a Buffer (never stringified -- guards against encoding/truncation
 * corruption of binary diffs). Non-git -> Buffer.from('NON_GIT').
 * @returns {{buf:Buffer,nonGit:boolean}}
 */
function canonicalDiff() {
  if (!isGitRepo()) return { buf: Buffer.from('NON_GIT'), nonGit: true };
  const tracked = git(['diff', '--binary', '--no-ext-diff', 'HEAD', '--', ...STATE_EXCLUDE]).stdout || Buffer.alloc(0);
  const untracked = hashUntracked();
  return { buf: Buffer.concat([tracked, untracked]), nonGit: false };
}

/** sha256 of the canonical diff buffer. */
function gitFingerprint() {
  return sha256(canonicalDiff().buf);
}

// ===========================================================================
// S3 glob  (zero-dep; supports ** * ? and literal /; no {a,b}/[..])
// ===========================================================================
/** glob -> anchored RegExp. Supports ** * ? and literal /; no {a,b}/[..]. */
function globToRegExp(glob) {
  let re = '^';
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === '*') {
      if (glob[i + 1] === '*') {                              // **
        i++;                                                  // consume second *
        if (glob[i + 1] === '/') { i++; re += '(?:.*/)?'; }   // **/ -> zero-or-more path segments (prefix may be empty)
        else re += '.*';                                      // trailing ** (or **x) -> anything, crosses /
      } else re += '[^/]*';                                   // * -> within a segment, no /
    } else if (c === '?') re += '[^/]';
    else re += c.replace(/[.+^${}()|[\]\\]/g, '\\$&');
  }
  return new RegExp(re + '$');
}

/** True if `p` matches any glob in `globs`. */
function matchAny(p, globs) {
  return (globs || []).some(g => globToRegExp(g).test(p));
}

/** Literal-char count after stripping wildcards; most specific glob wins on multi-match. */
function specificity(glob) {
  return glob.replace(/[*?]/g, '').length;
}

// ===========================================================================
// S4 catalog
// ===========================================================================
// Path globs that swallow the whole tree; forbidden as a module's paths entry
// (a root catch-all hides unmapped files from the UNMAPPED gate).
const CATCH_ALL_GLOBS = ['', '.', '*', '**', '**/*'];

/**
 * Read + parse the catalog file. Never throws: on missing/unreadable/invalid JSON
 * it returns {ok:false,error,detail} so callers can degrade instead of crashing.
 * @param {string} [catalogPath]  defaults to catalogFilePath()
 * @returns {{ok:true,catalog:Catalog}|{ok:false,error:string,detail:string}}
 */
function loadCatalog(catalogPath) {
  const cp = catalogPath || catalogFilePath();
  if (!fs.existsSync(cp)) {
    return { ok: false, error: 'catalog-missing', detail: cp };
  }
  let raw;
  try {
    raw = fs.readFileSync(cp, 'utf8');
  } catch (e) {
    return { ok: false, error: 'catalog-unreadable', detail: String(e && e.message || e) };
  }
  try {
    return { ok: true, catalog: JSON.parse(raw) };
  } catch (e) {
    return { ok: false, error: 'catalog-parse-error', detail: String(e && e.message || e) };
  }
}

/**
 * Shallow structural validation: version present, modules is an array, each module
 * has a non-empty id and a paths array. Does not run the linter's cross-checks.
 * @param {Catalog} catalog
 * @returns {{ok:boolean,errors:string[]}}
 */
function validateSchema(catalog) {
  const errors = [];
  if (!catalog || typeof catalog !== 'object') {
    return { ok: false, errors: ['catalog is not an object'] };
  }
  if (catalog.version === undefined) errors.push('missing version');
  if (!Array.isArray(catalog.modules)) {
    errors.push('modules is not an array');
    return { ok: errors.length === 0, errors };
  }
  catalog.modules.forEach((m, i) => {
    if (!m || typeof m !== 'object') { errors.push('module[' + i + '] is not an object'); return; }
    if (!m.id || typeof m.id !== 'string') errors.push('module[' + i + '] missing id');
    if (!Array.isArray(m.paths)) errors.push('module[' + (m.id || i) + '] missing paths array');
  });
  return { ok: errors.length === 0, errors };
}

/**
 * Classify a path against the catalog. Priority module > ignored > global > unmapped
 * (ignored beats global/unmapped so broad ignores never mask a module file; but a module
 * match still wins over ignored). On multiple module matches the most specific glob wins.
 * @param {string} p
 * @param {Catalog} catalog
 * @returns {{kind:('module'|'global'|'ignored'|'unmapped'),moduleId?:string}}
 */
function classifyPath(p, catalog) {
  let best = null;
  let bestScore = -1;
  for (const m of (catalog.modules || [])) {
    for (const g of (m.paths || [])) {
      if (globToRegExp(g).test(p)) {
        const s = specificity(g);
        if (s > bestScore) { bestScore = s; best = m.id; }
      }
    }
  }
  if (best !== null) return { kind: 'module', moduleId: best };
  if (matchAny(p, catalog.ignored)) return { kind: 'ignored' };
  if (matchAny(p, catalog.global)) return { kind: 'global' };
  return { kind: 'unmapped' };
}

/**
 * Detect a dependsOn cycle among modules. Returns true if any cycle exists.
 * @param {Catalog} catalog
 */
function hasDependencyCycle(catalog) {
  const graph = new Map();
  for (const m of (catalog.modules || [])) graph.set(m.id, m.dependsOn || []);
  const WHITE = 0, GRAY = 1, BLACK = 2;
  const color = new Map();
  for (const id of graph.keys()) color.set(id, WHITE);
  const visit = (id) => {
    color.set(id, GRAY);
    for (const dep of (graph.get(id) || [])) {
      if (!graph.has(dep)) continue;              // dangling dep is a separate error
      const c = color.get(dep);
      if (c === GRAY) return true;
      if (c === WHITE && visit(dep)) return true;
    }
    color.set(id, BLACK);
    return false;
  };
  for (const id of graph.keys()) {
    if (color.get(id) === WHITE && visit(id)) return true;
  }
  return false;
}

/**
 * Lint a catalog against a full tracked-path list. Enforces: valid schema, no catch-all
 * module paths, every tracked path claimed (UNMAPPED), no path claimed by >1 module
 * (OVERLAP), no dangling dependsOn. Cycles are warnings, not errors.
 * @param {Catalog} catalog
 * @param {string[]} trackedPaths
 * @returns {{ok,errors,warnings,stats}}
 */
function lintCatalog(catalog, trackedPaths) {
  const errors = [];
  const warnings = [];

  const schema = validateSchema(catalog);
  for (const detail of schema.errors) errors.push({ code: 'SCHEMA', path: null, detail });

  const modules = Array.isArray(catalog.modules) ? catalog.modules : [];

  // CATCH_ALL: a module path that swallows the whole tree.
  for (const m of modules) {
    for (const g of (m.paths || [])) {
      if (CATCH_ALL_GLOBS.includes(g)) {
        errors.push({ code: 'CATCH_ALL', path: g, detail: 'module ' + m.id + ' has catch-all path "' + g + '"' });
      }
    }
  }

  // DANGLING_DEP: dependsOn references a module id that does not exist.
  const ids = new Set(modules.map(m => m.id));
  for (const m of modules) {
    for (const dep of (m.dependsOn || [])) {
      if (!ids.has(dep)) {
        errors.push({ code: 'DANGLING_DEP', path: null, detail: 'module ' + m.id + ' dependsOn missing id "' + dep + '"' });
      }
    }
  }

  // OVERLAP + UNMAPPED: per tracked path, count matching modules and require a claim.
  let unmapped = 0;
  let overlaps = 0;
  for (const p of (trackedPaths || [])) {
    const hits = [];
    for (const m of modules) {
      if (matchAny(p, m.paths)) hits.push(m.id);
    }
    if (hits.length > 1) {
      overlaps++;
      errors.push({ code: 'OVERLAP', path: p, detail: 'path claimed by modules: ' + hits.join(', ') });
    }
    if (hits.length === 0) {
      const cls = classifyPath(p, catalog);   // module already excluded (hits==0), so global|ignored|unmapped
      if (cls.kind === 'unmapped') {
        unmapped++;
        errors.push({ code: 'UNMAPPED', path: p, detail: 'tracked path not claimed by any module/global/ignored' });
      }
    }
  }

  if (hasDependencyCycle(catalog)) {
    warnings.push({ code: 'CYCLE', path: null, detail: 'dependsOn graph contains a cycle' });
  }

  return {
    ok: errors.length === 0,
    errors,
    warnings,
    stats: {
      modules: modules.length,
      trackedPaths: (trackedPaths || []).length,
      unmapped,
      overlaps,
    },
  };
}

/** git ls-files -> tracked path list (forward-slashed, deduped). Empty on non-git. */
function trackedFiles() {
  if (!isGitRepo()) return [];
  const r = git(['-c', 'core.quotePath=false', 'ls-files']);
  if (r.status !== 0) return [];
  return r.stdout.toString('utf8').split('\n').map(s => s.trim()).filter(Boolean);
}

/** Parse a comma-separated flag value into a trimmed, non-empty string list. */
function parseCsv(v) {
  if (typeof v !== 'string') return [];
  return v.split(',').map(s => s.trim()).filter(Boolean);
}

function cmdCatalogLint(flags) {
  const loaded = loadCatalog(typeof flags.catalog === 'string' ? flags.catalog : undefined);
  if (!loaded.ok) {
    return emit({ ok: false, degraded: true, error: loaded.error, detail: loaded.detail }, 3);
  }
  const tracked = typeof flags.tracked === 'string' ? parseCsv(flags.tracked) : trackedFiles();
  const result = lintCatalog(loaded.catalog, tracked);
  return emit(result, result.ok ? 0 : 1);
}

// ===========================================================================
// S5 impact
// ===========================================================================
/**
 * Reverse dependency closure: the seed modules plus every module that transitively
 * dependsOn a seed (its consumers). The visited Set tolerates dependency cycles.
 * @param {Iterable<string>} seeds
 * @param {Catalog} catalog
 * @returns {Set<string>}
 */
function reverseClosure(seeds, catalog) {
  const rev = new Map();   // dep -> [consumers]
  for (const m of (catalog.modules || [])) {
    for (const d of (m.dependsOn || [])) {
      if (!rev.has(d)) rev.set(d, []);
      rev.get(d).push(m.id);
    }
  }
  const out = new Set(seeds);
  const q = [...out];
  while (q.length) {
    const cur = q.pop();
    for (const consumer of (rev.get(cur) || [])) {
      if (!out.has(consumer)) { out.add(consumer); q.push(consumer); }
    }
  }
  return out;
}

/**
 * Compute the affected module set for a changed-path list. Runtime-state files are
 * filtered first (isStateExcluded) so they never trigger a false unmapped fanout.
 * Any global/unmapped hit, or nonGit/truncated, forces conservative full-fanout
 * (all modules) + degraded -- the correct default against missed tests.
 * @param {string[]} changed
 * @param {Catalog} catalog
 * @param {{nonGit?:boolean,truncated?:boolean}} [opts]
 * @returns {{affected:string[],direct:string[],expansionReasons:string[],verification:Object,degraded:boolean}}
 */
function analyzeImpact(changed, catalog, { nonGit = false, truncated = false } = {}) {
  const reasons = new Set();
  const direct = new Set();
  for (const p of (changed || [])) {
    if (isStateExcluded(p)) continue;   // runtime-state files never drive impact
    const cls = classifyPath(p, catalog);
    if (cls.kind === 'ignored') continue;
    else if (cls.kind === 'global') reasons.add('global:' + p);
    else if (cls.kind === 'unmapped') reasons.add('unmapped:' + p);
    else direct.add(cls.moduleId);
  }
  if (nonGit) reasons.add('non-git');
  if (truncated) reasons.add('truncated');

  const allIds = (catalog.modules || []).map(m => m.id);
  const degraded = reasons.size > 0;
  const affected = degraded ? allIds : [...reverseClosure(direct, catalog)];

  // verification: map each affected module to its declared checks (module.verification
  // overrides catalog.riskChecks[riskTier]). Best-effort placeholder for T2.3; the
  // impact contract only requires affected/expansionReasons/degraded to be correct.
  const verification = {};
  const riskChecks = (catalog.riskChecks && typeof catalog.riskChecks === 'object') ? catalog.riskChecks : {};
  const byId = new Map((catalog.modules || []).map(m => [m.id, m]));
  for (const id of affected) {
    const m = byId.get(id);
    if (!m) continue;
    if (Array.isArray(m.verification)) verification[id] = m.verification;
    else if (m.riskTier && Array.isArray(riskChecks[m.riskTier])) verification[id] = riskChecks[m.riskTier];
  }

  return {
    affected,
    direct: [...direct],
    expansionReasons: [...reasons],
    verification,
    degraded,
  };
}

function cmdImpact(flags) {
  const loaded = loadCatalog(typeof flags.catalog === 'string' ? flags.catalog : undefined);
  if (!loaded.ok) {
    return emit({ affected: [], direct: [], expansionReasons: [loaded.error], verification: {}, degraded: true }, 3);
  }

  let changed;
  let nonGit = false;
  if (typeof flags.changed === 'string') {
    changed = parseCsv(flags.changed);
  } else {
    const cp = changedPaths();
    if (Array.isArray(cp)) { changed = cp; }
    else { changed = cp.paths; nonGit = !!cp.nonGit; }
  }

  const result = analyzeImpact(changed, loaded.catalog, { nonGit });
  return emit(result, nonGit ? 3 : 0);
}

// ===========================================================================
// S6 context-pack  -- TODO(T1.4): DENY + prioritize + budget + stable packHash.
// ===========================================================================

// ===========================================================================
// S7 receipt  -- TODO(T2.1): contentHash + writeReceipt + verifyReceipt (diff-bound, stale exit 4).
// ===========================================================================

// ===========================================================================
// S8 quality  -- TODO(T2.3): requiredChecks(risk) + runCheck four-state + verifyPlan.
// ===========================================================================

// ===========================================================================
// S9 config
// ===========================================================================
const DEFAULTS = {
  contextPack: { maxTotalChars: 120000, maxFiles: 40, maxFileChars: 6000, maxDiffChars: 40000 },
};

function projectRoot() {
  return process.env.CLAUDE_PROJECT_DIR || process.cwd();
}
function catalogFilePath() {
  return path.join(projectRoot(), '.claude', 'harness', 'module-catalog.json');
}

/**
 * Load harness config. Catalog present -> shallow-merge its contextPack over DEFAULTS.
 * Not present -> DEFAULTS + {catalogPresent:false}. This Task only checks existence,
 * not schema validity (T1.2 catalog-lint owns schema validation).
 */
function loadHarnessConfig() {
  const cp = catalogFilePath();
  const present = fs.existsSync(cp);
  if (!present) {
    return { contextPack: { ...DEFAULTS.contextPack }, catalogPresent: false };
  }
  let contextPack = { ...DEFAULTS.contextPack };
  try {
    const raw = JSON.parse(fs.readFileSync(cp, 'utf8'));
    if (raw && typeof raw.contextPack === 'object' && raw.contextPack) {
      contextPack = { ...DEFAULTS.contextPack, ...raw.contextPack };
    }
  } catch (_e) {
    // Catalog present but unreadable/invalid; keep defaults, T1.2 catalog-lint will report.
  }
  return { contextPack, catalogPresent: true };
}

main();
