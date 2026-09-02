// lib/core.mjs -- the bottom layer of the harness runtime: it imports nothing but node
// builtins, and every other module may import it. That one-way rule is what keeps the
// module graph acyclic now that the sections live in separate files.
//
// Carries S1 common / S2 git / S3 glob / S9 config, plus the vocabulary that more than one
// section needs and therefore cannot stay inside any single one of them:
//   - the JSDoc typedefs (Catalog / Module / Receipt / CheckResult / Waiver)
//   - ATTRIBUTES / TIERS / TIER_ENFORCEMENT / TIER_RANK / normalizeTier: declared for S11,
//     but read by S4 catalog-lint and S13 fitness too; leaving them in S11 would make
//     catalog.mjs and quality.mjs import each other
//   - parseCsv (from S4), DENY / isDenied (S6), SOURCE_EXTS (S12), whichCmd (S8): each
//     written for one section and consumed by another that now lives in a different file
// Source is ASCII-only, same as the rest of the runtime.

import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

// Directory of the harness root (.claude/harness), used to resolve checked-in fixtures and
// the shipped adapters table. ESM has no __dirname, and this file sits one level down in
// lib/, so the path goes up twice -- deriving it from process.cwd() instead would break
// every caller that runs the harness against another tree (the golden matrix does exactly
// that on every scenario).
const HARNESS_DIR = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

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
 * @property {Object<string,(string|{tier:string,reason?:string})>} [attributes]
 *           quality attributes this module must hold evidence for (S11)
 * @property {string[]} [forbiddenDependencies]  module ids this one must never import (S12)
 * @property {string} [layer]                architectural layer name from catalog.layers
 * @property {string[]} [provides]           import-specifier prefixes resolving to this module
 */
/**
 * @typedef {Object} Catalog
 * @property {number} version
 * @property {Module[]} modules
 * @property {string[]} [global]             paths that force full-fanout on change
 * @property {string[]} [ignored]            paths excluded from impact
 * @property {Object<string,string[]>} [riskChecks]
 * @property {Object<string,Object>} [checks]  check may declare attributes:[] it evidences
 * @property {ContextPackBudget} [contextPack]
 * @property {string[]} [layers]             layer names outermost-first; deps may only point inward (later entries)
 * @property {number} [maxTrackedPaths]      tracked-listing cap before truncated degradation
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
 * @property {string} [reason]   may carry waiver:<scope> prefix when SKIPPED via S10
 * @property {string} [cmd]
 */
/**
 * @typedef {Object} Waiver
 * @property {number} version
 * @property {string} owner
 * @property {string} reason
 * @property {string} scope          check id this waiver covers
 * @property {string} expiry         ISO timestamp
 * @property {string} compensation
 * @property {string} created_at     ISO timestamp
 * @property {string} [contentHash]
 */
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

/**
 * Sleep without burning a core. Atomics.wait on a private buffer is the only synchronous
 * sleep node has without a dependency, and a Date.now() spin would be measurably worse with
 * a dozen processes queued behind the same lock.
 */
function sleepSync(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, Math.max(0, Number(ms) || 0));
}

/**
 * Run fn while holding an exclusive lock. The lock is a directory, because mkdir is the one
 * filesystem call that creates and tests in a single atomic step; O_APPEND is deliberately
 * not used in its place, since the atomicity that offers stops at PIPE_BUF (4096 bytes on
 * Linux) and the records this guards are routinely larger than that.
 * A lock older than staleMs is reclaimed -- a process killed mid-write must not brick the
 * file for everyone after it -- and waiting past timeoutMs throws instead of blocking
 * forever, so the caller degrades loudly rather than hanging.
 * @param {string} lockPath   directory to create; its parent must already exist
 * @param {Function} fn       runs with the lock held
 * @param {{timeoutMs?:number,staleMs?:number,pollMs?:number}} [opts]
 */
function withDirLock(lockPath, fn, { timeoutMs = 10000, staleMs = 60000, pollMs = 20 } = {}) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try {
      fs.mkdirSync(lockPath);
      break;
    } catch (e) {
      if (!e || e.code !== 'EEXIST') throw e;
      let ageMs = 0;
      try { ageMs = Date.now() - fs.statSync(lockPath).mtimeMs; } catch (_e) { continue; }
      if (ageMs > staleMs) {
        // Another waiter may win the reclaim; losing it just means going round again.
        try { fs.rmSync(lockPath, { recursive: true, force: true }); } catch (_e) { /* retry */ }
        continue;
      }
      if (Date.now() >= deadline) {
        throw new Error('could not acquire lock ' + lockPath + ' within ' + timeoutMs
          + 'ms (current holder is ' + ageMs + 'ms old)');
      }
      sleepSync(pollMs);
    }
  }
  try {
    return fn();
  } finally {
    try { fs.rmSync(lockPath, { recursive: true, force: true }); } catch (_e) { /* best effort */ }
  }
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
// The three lists below, the DENY entry further down and .claude/.gitignore are exclusions of
// the same set, and they are written per DIRECTORY rather than per file on purpose: everything
// the runtime writes lands under one of these prefixes, so a new kind of state -- the review
// session and the authorship ledger under harness/state/, for instance -- is covered by all
// four the moment it is put there. A per-file rule would have to be added in four places, and
// missing one of them is a fresh source of false green.
const STATE_EXCLUDE = [
  ':(exclude).claude/.needs-review',
  ':(exclude).claude/.needs-review.lock',
  ':(exclude).claude/.fast-mode',
  ':(exclude).claude/evidence/**',
  ':(exclude).claude/harness/receipts/**',
  ':(exclude).claude/harness/waivers/**',
  ':(exclude).claude/harness/trend/**',
  ':(exclude).claude/harness/state/**',
  ':(exclude).claude/harness/evidence/**',
];
const STATE_EXCLUDE_PATHS = [
  '.claude/.needs-review',
  '.claude/.needs-review.lock',
  '.claude/.fast-mode',
];
const STATE_EXCLUDE_PREFIXES = [
  '.claude/evidence/',
  '.claude/harness/receipts/',
  '.claude/harness/waivers/',
  '.claude/harness/trend/',
  '.claude/harness/state/',
  '.claude/harness/evidence/',
];
function isStateExcluded(p) {
  const n = p.replace(/\\/g, '/');
  if (STATE_EXCLUDE_PATHS.includes(n)) return true;
  return STATE_EXCLUDE_PREFIXES.some(pre => n.startsWith(pre));
}

/** Split NUL-separated git output into a clean path list (non-ASCII names survive). */
function splitNul(buf) {
  return buf.toString('utf8').split('\0').map(s => s.trim()).filter(Boolean);
}

/**
 * Changed paths vs HEAD (tracked diff + untracked), deduped. Listings are NUL-separated
 * (-z) with quotePath off: the default quoting turns a CJK filename into an octal string
 * no catalog glob can ever match, which silently reclassifies it as unmapped.
 * @returns {string[]|{paths:string[],nonGit:true}}
 */
function changedPaths() {
  if (!isGitRepo()) return { paths: [], nonGit: true };
  const tracked = splitNul(git(['-c', 'core.quotePath=false', 'diff', '--name-only', '-z', 'HEAD']).stdout);
  const untracked = splitNul(git(['-c', 'core.quotePath=false', 'ls-files', '-z', '--others', '--exclude-standard']).stdout);
  const seen = new Set();
  const out = [];
  for (const p of tracked.concat(untracked)) {
    if (!seen.has(p)) { seen.add(p); out.push(p); }
  }
  return out;
}

/** Untracked files as a stable Buffer of "U <path> <contentHash>\n" lines (sorted, state files excluded). */
function hashUntracked() {
  const list = splitNul(git(['-c', 'core.quotePath=false', 'ls-files', '-z', '--others', '--exclude-standard']).stdout)
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
// Compiled globs are cached: classifying N tracked paths against M module globs is the
// hot loop of catalog-lint/impact on a 600k-LOC repository, and recompiling the same
// RegExp N*M times dominated the runtime before this cache existed.
const GLOB_CACHE = new Map();

/** glob -> anchored RegExp (cached). Supports ** * ? and literal /; no {a,b}/[..]. */
function globToRegExp(glob) {
  const hit = GLOB_CACHE.get(glob);
  if (hit) return hit;
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
  const compiled = new RegExp(re + '$');
  GLOB_CACHE.set(glob, compiled);
  return compiled;
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
// S9 config
// ===========================================================================
const DEFAULTS = {
  contextPack: { maxTotalChars: 120000, maxFiles: 40, maxFileChars: 6000, maxDiffChars: 40000 },
  maxTrackedPaths: 100000,
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

// ===========================================================================
// S* shared vocabulary  (defined once here because two or more sections read it)
// ===========================================================================
/** Parse a comma-separated flag value into a trimmed, non-empty string list. */
function parseCsv(v) {
  if (typeof v !== 'string') return [];
  return v.split(',').map(s => s.trim()).filter(Boolean);
}

const ATTRIBUTES = ['security', 'resilience', 'privacy', 'safety', 'reliability', 'availability', 'performance', 'maintainability'];

// Six strengths: uniform strictness is its own defect -- applied everywhere it makes a
// throwaway prototype as expensive as a payments service, and the usual response is to
// disable checks wholesale rather than tune them.
const TIERS = ['critical', 'high', 'medium', 'low', 'minimal', 'none'];
const TIER_ENFORCEMENT = {
  critical: 'block',      // absence of evidence blocks; cannot be waived
  high: 'block',          // absence of evidence blocks; an attribute waiver may defer it
  medium: 'warn',
  low: 'record',
  minimal: 'listed',      // requires a written reason
  none: 'opted-out',      // requires a written reason
};
const TIER_RANK = { critical: 5, high: 4, medium: 3, low: 2, minimal: 1, none: 0 };

/** Accepts "high" or {tier:"high",reason:"..."}; returns {tier,reason}. */
function normalizeTier(req) {
  if (typeof req === 'string') return { tier: req, reason: '' };
  if (req && typeof req === 'object') return { tier: String(req.tier || ''), reason: String(req.reason || '') };
  return { tier: '', reason: '' };
}

// DENY: paths that must never enter a pack, evaluated before any priority tier.
// Covers VCS/build dirs, harness runtime state, and secret material. A narrow
// whitelist (.env.example|sample|template) is checked first so shareable templates
// stay includable.
const DENY = [
  /(^|\/)\.git\//, /(^|\/)node_modules\//, /(^|\/)(dist|build|out|\.next|\.venv)\//,
  /(^|\/)\.claude\/(evidence|harness\/receipts|harness\/waivers|harness\/trend|harness\/state|harness\/evidence)\//,
  /(^|\/)\.env(\.|$)/,
  /\.(pem|key|p12|pfx)$/, /(^|\/)id_rsa/, /(^|\/)\.(ssh|aws|azure|gnupg|kube)\//,
];

/** True if a path must never be packed. Path is forward-slashed before matching. */
function isDenied(p) {
  const n = String(p).replace(/\\/g, '/');
  if (/(^|\/)\.env\.(example|sample|template)$/.test(n)) return false;   // whitelist first
  return DENY.some(r => r.test(n));
}

const SOURCE_EXTS = new Set([
  '.js', '.mjs', '.cjs', '.jsx', '.ts', '.mts', '.cts', '.tsx',
  '.py', '.go', '.java', '.kt', '.kts', '.cs', '.rs', '.rb', '.php', '.swift', '.scala',
]);

/**
 * Resolve whether an executable is reachable, without running it. Zero-dep, cross-platform:
 * scans PATH entries; on win32 appends PATHEXT suffixes. A path-qualified exe is tested directly.
 * @param {string} exe
 * @returns {boolean}
 */
function whichCmd(exe) {
  if (!exe) return false;
  if (exe.includes('/') || exe.includes('\\')) return fs.existsSync(exe);
  const dirs = String(process.env.PATH || '').split(path.delimiter).filter(Boolean);
  const exts = process.platform === 'win32'
    ? String(process.env.PATHEXT || '.COM;.EXE;.BAT;.CMD').split(';').map(s => s.trim()).filter(Boolean)
    : [''];
  for (const d of dirs) {
    if (process.platform === 'win32' && fs.existsSync(path.join(d, exe))) return true;
    for (const ext of exts) {
      if (fs.existsSync(path.join(d, exe + ext))) return true;
    }
  }
  return false;
}

export {
  HARNESS_DIR,
  readStdin, stableJson, sha256, emit, die, sleepSync, withDirLock,
  git, isGitRepo, headCommit, isStateExcluded, splitNul, changedPaths, canonicalDiff, gitFingerprint,
  globToRegExp, matchAny, specificity,
  DEFAULTS, projectRoot, catalogFilePath, loadHarnessConfig,
  parseCsv,
  ATTRIBUTES, TIERS, TIER_ENFORCEMENT, TIER_RANK, normalizeTier,
  isDenied, SOURCE_EXTS, whichCmd,
};
