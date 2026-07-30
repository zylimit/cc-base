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
const IMPLEMENTED_SUBCOMMANDS = ['doctor', 'diff-hash', 'selftest'];
const NOT_IMPLEMENTED_SUBCOMMANDS = ['catalog-lint', 'impact', 'context-pack', 'receipt', 'verify'];

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
  switch (cmd) {
    case 'doctor':    return cmdDoctor();
    case 'diff-hash': return cmdDiffHash();
    case 'selftest':  return cmdSelftest();
    // Planned subcommands: explicit not-implemented, never crash / never fake success.
    case 'catalog-lint':
    case 'impact':
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
// S4 catalog  -- TODO(T1.1/T1.2): loadCatalog/validateSchema/classifyPath/lintCatalog.
// ===========================================================================

// ===========================================================================
// S5 impact  -- TODO(T1.3): reverseClosure + analyzeImpact (conservative fanout).
// ===========================================================================

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
