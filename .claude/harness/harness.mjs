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
const IMPLEMENTED_SUBCOMMANDS = ['doctor', 'diff-hash', 'selftest', 'catalog-lint', 'impact', 'context-pack', 'receipt', 'verify'];
const NOT_IMPLEMENTED_SUBCOMMANDS = [];

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
  const { cmd, flags, positional } = parseArgs(process.argv.slice(2));
  switch (cmd) {
    case 'doctor':       return cmdDoctor();
    case 'diff-hash':    return cmdDiffHash();
    case 'selftest':     return cmdSelftest();
    case 'catalog-lint': return cmdCatalogLint(flags);
    case 'impact':       return cmdImpact(flags);
    case 'context-pack': return cmdContextPack(flags);
    case 'receipt':      return cmdReceipt(flags, positional);
    case 'verify':       return cmdVerify(flags);
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

    // S6 context-pack -- DENY, budget truncation, stable packHash.
    ['isDenied .env / node_modules / id_rsa / receipts -> true', () => {
      assert.ok(isDenied('.env'));
      assert.ok(isDenied('config/.env.local'));
      assert.ok(isDenied('node_modules/x.js'));
      assert.ok(isDenied('id_rsa'));
      assert.ok(isDenied('.claude/harness/receipts/foo.json'));
      assert.ok(isDenied('secrets/server.pem'));
    }],
    ['isDenied .env.example / real source -> false', () => {
      assert.ok(!isDenied('.env.example'));
      assert.ok(!isDenied('config/.env.sample'));
      assert.ok(!isDenied('.env.template'));
      assert.ok(!isDenied('src/real.ts'));
    }],
    ['buildPack DENY files never in included, recorded in denied', () => {
      const r = buildPack({
        diffHash: 'd', diffChars: 0,
        candidateFiles: [
          { path: '.env', bytes: 10 }, { path: 'node_modules/a.js', bytes: 10 },
          { path: 'id_rsa', bytes: 10 }, { path: '.claude/harness/receipts/x.json', bytes: 10 },
          { path: 'src/real.ts', bytes: 10 },
        ],
      });
      const inc = r.included.map(f => f.path);
      assert.ok(!inc.includes('.env') && !inc.includes('node_modules/a.js') && !inc.includes('id_rsa'));
      assert.ok(inc.includes('src/real.ts'));
      assert.ok(r.denied.includes('.env') && r.denied.includes('node_modules/a.js'));
    }],
    ['buildPack respects maxFiles cap (included.length <= maxFiles)', () => {
      const files = [];
      for (let i = 0; i < 50; i++) files.push({ path: 'src/f' + i + '.ts', bytes: 5 });
      const r = buildPack({ budgets: { maxFiles: 10 }, candidateFiles: files });
      assert.ok(r.included.length <= 10);
    }],
    ['buildPack respects maxTotalChars (stops filling when full)', () => {
      const files = [];
      for (let i = 0; i < 20; i++) files.push({ path: 'src/f' + i + '.ts', bytes: 100 });
      const r = buildPack({ budgets: { maxTotalChars: 250, maxFiles: 100 }, candidateFiles: files });
      const total = r.included.reduce((a, f) => a + f.bytes, 0);
      assert.ok(total <= 250);
      assert.ok(r.included.length < 20);
    }],
    ['buildPack truncates oversized file to maxFileChars + marks omitted', () => {
      const r = buildPack({ budgets: { maxFileChars: 50 }, candidateFiles: [{ path: 'src/big.ts', bytes: 5000 }] });
      const f = r.included.find(x => x.path === 'src/big.ts');
      assert.equal(f.bytes, 50);
      assert.equal(f.omitted, 'truncated');
    }],
    ['buildPack packHash stable for identical input', () => {
      const input = { budgets: { maxFiles: 40 }, diffHash: 'abc', diffChars: 100,
        candidateFiles: [{ path: 'b.ts', bytes: 20 }, { path: 'a.ts', bytes: 30 }] };
      const h1 = buildPack(input).packHash;
      const h2 = buildPack(input).packHash;
      assert.equal(h1, h2);
    }],
    ['buildPack packHash changes when included set changes', () => {
      const h1 = buildPack({ diffHash: 'abc', candidateFiles: [{ path: 'a.ts', bytes: 10 }] }).packHash;
      const h2 = buildPack({ diffHash: 'abc', candidateFiles: [{ path: 'a.ts', bytes: 10 }, { path: 'b.ts', bytes: 10 }] }).packHash;
      assert.notEqual(h1, h2);
    }],

    // S7 receipt -- contentHash round-trip / tamper detection + diff-bound matching (fs-free).
    ['contentHash round-trip: recompute equals stored', () => {
      const r = { taskId: 't1', baseCommit: 'c0', diffHash: 'H1', reviewer: 'rev', verdict: 'pass', scope: 'x', timestamp: '2026-01-01T00:00:00Z' };
      const h = contentHash(r);
      assert.equal(contentHash({ ...r, contentHash: h }), h);
    }],
    ['contentHash changes when any field is mutated (tamper detectable)', () => {
      const r = { taskId: 't1', baseCommit: 'c0', diffHash: 'H1', reviewer: 'rev', verdict: 'pass', scope: 'x', timestamp: '2026-01-01T00:00:00Z' };
      assert.notEqual(contentHash({ ...r, verdict: 'fail' }), contentHash(r));
    }],
    ['receiptIntact true for freshly hashed, false when tampered', () => {
      const r = { taskId: 't1', diffHash: 'H1', reviewer: 'rev', verdict: 'pass', scope: 'x', timestamp: 'T' };
      r.contentHash = contentHash(r);
      assert.ok(receiptIntact(r));
      assert.ok(!receiptIntact({ ...r, diffHash: 'H2' }));
    }],
    ['matchReceipts: current diff H1 matches receipt bound to H1', () => {
      const r = { taskId: 't1', diffHash: 'H1', reviewer: 'rev', verdict: 'pass', scope: 'x', timestamp: 'T' };
      r.contentHash = contentHash(r);
      const m = matchReceipts([r], 'H1');
      assert.equal(m.matched, 't1');
    }],
    ['matchReceipts: current diff H2 does not match receipt bound to H1 (stale)', () => {
      const r = { taskId: 't1', diffHash: 'H1', reviewer: 'rev', verdict: 'pass', scope: 'x', timestamp: 'T' };
      r.contentHash = contentHash(r);
      const m = matchReceipts([r], 'H2');
      assert.equal(m.matched, null);
      assert.equal(m.hadReceipts, true);
    }],
    ['matchReceipts: tampered receipt never matches even on equal diffHash', () => {
      const r = { taskId: 't1', diffHash: 'H1', reviewer: 'rev', verdict: 'pass', scope: 'x', timestamp: 'T' };
      r.contentHash = contentHash(r);
      const m = matchReceipts([{ ...r, verdict: 'fail' }], 'H1');
      assert.equal(m.matched, null);
    }],
    ['matchReceipts: empty receipts -> no match, hadReceipts false (adoption grace)', () => {
      const m = matchReceipts([], 'H1');
      assert.equal(m.matched, null);
      assert.equal(m.hadReceipts, false);
    }],
    ['safeTaskId strips path traversal / separators', () => {
      assert.equal(safeTaskId('../../etc/passwd'), '.._.._etc_passwd');
      assert.equal(safeTaskId('a/b\\c'), 'a_b_c');
      assert.equal(safeTaskId('..'), '');
    }],

    // S8 quality -- runCheck four-state + fast-mode + aggregation.
    ['runCheck no command -> BLOCKED no-command', () => {
      const r = runCheck({ id: 'x' }, {});
      assert.equal(r.state, 'BLOCKED');
      assert.equal(r.reason, 'no-command');
    }],
    ['runCheck missing binary -> BLOCKED command-missing (never fake green)', () => {
      const r = runCheck({ id: 'x', command: '__no_such_cmd_zzz__ arg' }, {});
      assert.equal(r.state, 'BLOCKED');
      assert.ok(r.reason.startsWith('command-missing:'));
    }],
    ['runCheck present + exit 0 -> PASS', () => {
      const r = runCheck({ id: 'ver', command: 'node --version' }, {});
      assert.equal(r.state, 'PASS');
      assert.equal(r.exit, 0);
    }],
    ['runCheck present + exit != 0 -> FAIL with exit code', () => {
      const r = runCheck({ id: 'boom', command: 'node -e "process.exit(3)"' }, {});
      assert.equal(r.state, 'FAIL');
      assert.equal(r.exit, 3);
    }],
    ['runCheck fast + non-security + allowFastSkip -> SKIPPED', () => {
      const r = runCheck({ id: 'lint', command: 'node --version', allowFastSkip: true }, { fastActive: true });
      assert.equal(r.state, 'SKIPPED');
      assert.equal(r.reason, 'fast-mode');
    }],
    ['runCheck fast + security -> still runs (never SKIPPED)', () => {
      const r = runCheck({ id: 'audit', command: 'node --version', class: 'security', allowFastSkip: true }, { fastActive: true });
      assert.notEqual(r.state, 'SKIPPED');
      assert.equal(r.state, 'PASS');
    }],
    ['runCheck fast + non-security without allowFastSkip -> still runs', () => {
      const r = runCheck({ id: 'build', command: 'node --version' }, { fastActive: true });
      assert.notEqual(r.state, 'SKIPPED');
      assert.equal(r.state, 'PASS');
    }],
    ['aggregateStates: any FAIL -> FAIL', () => assert.equal(aggregateStates(['PASS', 'FAIL', 'BLOCKED']), 'FAIL')],
    ['aggregateStates: no FAIL, has BLOCKED -> BLOCKED', () => assert.equal(aggregateStates(['PASS', 'BLOCKED', 'SKIPPED']), 'BLOCKED')],
    ['aggregateStates: all PASS/SKIPPED -> PASS', () => assert.equal(aggregateStates(['PASS', 'SKIPPED', 'PASS']), 'PASS')],
    ['requiredChecks: module.verification overrides catalog.riskChecks[risk]', () => {
      const cat = { riskChecks: { high: ['a', 'b'] } };
      assert.deepEqual(requiredChecks('high', { verification: ['x'] }, cat), ['x']);
      assert.deepEqual(requiredChecks('high', {}, cat), ['a', 'b']);
      assert.deepEqual(requiredChecks('low', {}, cat), []);
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
// S6 context-pack
// ===========================================================================
// DENY: paths that must never enter a pack, evaluated before any priority tier.
// Covers VCS/build dirs, harness runtime state, and secret material. A narrow
// whitelist (.env.example|sample|template) is checked first so shareable templates
// stay includable.
const DENY = [
  /(^|\/)\.git\//, /(^|\/)node_modules\//, /(^|\/)(dist|build|out|\.next|\.venv)\//,
  /(^|\/)\.claude\/(evidence|harness\/receipts)\//,
  /(^|\/)\.env(\.|$)/,
  /\.(pem|key|p12|pfx)$/, /(^|\/)id_rsa/, /(^|\/)\.(ssh|aws|azure|gnupg|kube)\//,
];

/** True if a path must never be packed. Path is forward-slashed before matching. */
function isDenied(p) {
  const n = String(p).replace(/\\/g, '/');
  if (/(^|\/)\.env\.(example|sample|template)$/.test(n)) return false;   // whitelist first
  return DENY.some(r => r.test(n));
}

/**
 * Budgeted context pack. Pure + injectable so selftest exercises it without real git/fs:
 * pass diffHash + candidateFiles directly. Priority order (blueprint sec.4):
 *   1 task envelope + Spec/Plan pointers (always first)
 *   2 canonical diff (truncated to maxDiffChars)
 *   3 changed files themselves (each truncated to maxFileChars)
 *   4-6 affected/dependency module summaries (Phase 0-2 catalogs carry no such field -> empty)
 * DENY files are dropped before packing at every tier and recorded in `denied`.
 * Fill stops when maxFiles or maxTotalChars is reached. packHash hashes only the
 * {path,bytes} manifest (path-sorted) + budgets + diffHash -> stable across whitespace churn.
 * @returns {{budgets,diffHash,included,denied,affected,degraded,packHash}}
 */
function buildPack({ budgets, diffHash = '', diffChars = 0, candidateFiles = [], envelope = null,
  specPointers = [], affected = [], moduleSummaries = [], degraded = false } = {}) {
  const b = { ...DEFAULTS.contextPack, ...(budgets || {}) };
  const { maxTotalChars, maxFiles, maxFileChars, maxDiffChars } = b;

  const denied = [];
  const candidates = [];

  // P1: task envelope, then Spec/Plan pointers (pointers are path strings, not full content).
  if (envelope) candidates.push({ path: '<task-envelope>', bytes: stableJson(envelope).length, reason: 'envelope' });
  for (const sp of specPointers) { const s = String(sp); candidates.push({ path: s, bytes: s.length, reason: 'spec-pointer' }); }

  // P2: canonical diff, truncated to maxDiffChars.
  if (diffHash || diffChars > 0) {
    const entry = { path: '<canonical-diff>', bytes: Math.min(diffChars, maxDiffChars), reason: 'diff' };
    if (diffChars > maxDiffChars) entry.omitted = 'truncated';
    candidates.push(entry);
  }

  // P3: changed files, each truncated to maxFileChars; DENY never enters.
  for (const f of candidateFiles) {
    const norm = String(f.path).replace(/\\/g, '/');
    if (isDenied(norm)) { denied.push(norm); continue; }
    const rawBytes = typeof f.bytes === 'number' ? f.bytes : (typeof f.content === 'string' ? f.content.length : 0);
    const entry = { path: norm, bytes: Math.min(rawBytes, maxFileChars), reason: 'changed-file' };
    if (rawBytes > maxFileChars) entry.omitted = 'truncated';
    candidates.push(entry);
  }

  // P4-6: affected/dependency module summaries (test entries etc.).
  for (const s of moduleSummaries) {
    const norm = String(s.path).replace(/\\/g, '/');
    if (isDenied(norm)) { denied.push(norm); continue; }
    candidates.push({ path: norm, bytes: typeof s.bytes === 'number' ? s.bytes : 0, reason: s.reason || 'module-summary' });
  }

  // Fill in priority order; stop when full (file count or total chars).
  const included = [];
  let total = 0;
  for (const c of candidates) {
    if (included.length >= maxFiles) break;
    if (total + c.bytes > maxTotalChars) break;
    included.push(c);
    total += c.bytes;
  }

  const packHash = sha256(stableJson({
    budgets: b,
    diffHash,
    included: included.map(f => ({ path: f.path, bytes: f.bytes }))
      .sort((a, z) => (a.path < z.path ? -1 : a.path > z.path ? 1 : 0)),
  }));

  return { budgets: b, diffHash, included, denied, affected, degraded, packHash };
}

/** Minimal task envelope from flags (--task id); stdin envelope support is a later Task. */
function buildEnvelope(flags) {
  return { task: typeof flags.task === 'string' ? flags.task : null };
}

/** Spec/Plan pointers = existing doc paths at project root (path strings, never full content). */
function specPlanPointers() {
  const root = projectRoot();
  const out = [];
  for (const rel of ['Product-Spec.md', 'DEV-PLAN.md', 'Design-Brief.md']) {
    if (fs.existsSync(path.join(root, rel))) out.push(rel);
  }
  return out;
}

function cmdContextPack(flags) {
  const cfg = loadHarnessConfig();
  const budgets = { ...cfg.contextPack };
  if (typeof flags['budget-chars'] === 'string') {
    const n = parseInt(flags['budget-chars'], 10);
    if (!Number.isNaN(n) && n > 0) budgets.maxTotalChars = n;
  }

  // Catalog optional: present -> compute affected modules; absent -> degraded, no affected.
  const loaded = loadCatalog(typeof flags.catalog === 'string' ? flags.catalog : undefined);
  const catalog = loaded.ok ? loaded.catalog : null;

  // Changed paths: --changed csv override, else real working-tree diff.
  let changed;
  let nonGit = false;
  if (typeof flags.changed === 'string') {
    changed = parseCsv(flags.changed);
  } else {
    const cp = changedPaths();
    if (Array.isArray(cp)) { changed = cp; }
    else { changed = cp.paths; nonGit = !!cp.nonGit; }
  }

  let affected = [];
  let degraded = nonGit;
  const moduleSummaries = [];
  if (catalog) {
    const imp = analyzeImpact(changed, catalog, { nonGit });
    affected = imp.affected;
    degraded = imp.degraded || nonGit;
    // P5: affected module test entries -- only module-level path-like verification strings
    // (Phase 0-2 catalogs carry none, so this stays empty in practice).
    const byId = new Map((catalog.modules || []).map(m => [m.id, m]));
    for (const id of affected) {
      const m = byId.get(id);
      if (m && Array.isArray(m.verification)) {
        for (const v of m.verification) {
          if (typeof v === 'string' && v.includes('/')) moduleSummaries.push({ path: v, bytes: v.length, reason: 'test-entry' });
        }
      }
    }
  } else {
    degraded = true;   // no catalog -> cannot resolve affected modules
  }

  // Canonical diff fingerprint + size (never stringified; size drives budget accounting).
  const { buf } = canonicalDiff();
  const diffHash = sha256(buf);
  const diffChars = buf.length;

  // Candidate changed files: drop runtime-state files, read on-disk size for budgeting.
  const candidateFiles = [];
  for (const p of changed) {
    if (isStateExcluded(p)) continue;
    const norm = p.replace(/\\/g, '/');
    let bytes = 0;
    try { bytes = fs.statSync(path.join(projectRoot(), p)).size; } catch (_e) { bytes = 0; }
    candidateFiles.push({ path: norm, bytes });
  }

  const pack = buildPack({
    budgets, diffHash, diffChars, candidateFiles,
    envelope: buildEnvelope(flags), specPointers: specPlanPointers(),
    affected, moduleSummaries, degraded,
  });
  return emit(pack, nonGit ? 3 : 0);
}


// ===========================================================================
// S7 receipt  (diff-bound review receipts; stale/tamper -> exit 4)
// ===========================================================================
// Receipts live under .claude/harness/receipts/<taskId>.json (git-ignored runtime state).
// The receipt binds a review verdict to the exact working-tree diff it reviewed via
// diffHash = gitFingerprint(). If code moves past that diff, the receipt goes stale.

/** Where receipts are stored (project-relative, git-ignored). */
function receiptsDir() {
  return path.join(projectRoot(), '.claude', 'harness', 'receipts');
}

/** Sanitize a taskId into a safe single filename segment (guards path traversal). */
function safeTaskId(id) {
  const s = String(id == null ? '' : id).replace(/[^A-Za-z0-9._-]/g, '_');
  return (s === '' || s === '.' || s === '..') ? '' : s;
}

/**
 * Tamper-evident content hash: stable JSON of the receipt with contentHash blanked out,
 * then sha256. Recompute on verify; any field mutation changes the hash. Pure + injectable
 * so selftest exercises round-trip / tamper detection without touching fs.
 * @param {Object} r
 * @returns {string}
 */
function contentHash(r) {
  return sha256(stableJson({ ...r, contentHash: undefined }));
}

/** True if the working tree carries code changes vs HEAD (state files excluded). */
function hasCodeChange() {
  const cp = changedPaths();
  const list = Array.isArray(cp) ? cp : cp.paths;
  return list.some(p => !isStateExcluded(p));
}

/**
 * Build + persist a receipt bound to the current working-tree diff. taskId is required.
 * baseCommit/diffHash are captured live; timestamp is injectable for deterministic tests.
 * @param {Object} input   { taskId, reviewer?, verdict?, scope? }
 * @param {{timestamp?:string}} [opts]
 * @returns {Receipt}
 */
function writeReceipt(input, { timestamp } = {}) {
  const input0 = input && typeof input === 'object' ? input : {};
  const taskId = safeTaskId(input0.taskId);
  if (!taskId) throw new Error('writeReceipt: taskId required (allowed chars: A-Za-z0-9._-)');
  const receipt = {
    taskId,
    baseCommit: headCommit(),
    diffHash: gitFingerprint(),
    reviewer: typeof input0.reviewer === 'string' ? input0.reviewer : 'unknown',
    verdict: typeof input0.verdict === 'string' ? input0.verdict : 'pass',
    scope: input0.scope === undefined ? null : input0.scope,
    timestamp: timestamp || new Date().toISOString(),
  };
  receipt.contentHash = contentHash(receipt);
  const dir = receiptsDir();
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, taskId + '.json'), JSON.stringify(receipt, null, 2) + '\n', 'utf8');
  return receipt;
}

/** True if a receipt object's stored contentHash matches a fresh recompute (untampered). */
function receiptIntact(r) {
  return !!r && typeof r === 'object' && typeof r.contentHash === 'string'
    && contentHash(r) === r.contentHash;
}

/**
 * Pure matcher (fs-free, injectable): does any intact receipt bind to diffHash D?
 * @param {Receipt[]} receipts
 * @param {string} D  current gitFingerprint()
 * @returns {{matched:string|null,hadReceipts:boolean}}
 */
function matchReceipts(receipts, D) {
  const list = Array.isArray(receipts) ? receipts : [];
  for (const r of list) {
    if (receiptIntact(r) && r.diffHash === D) return { matched: r.taskId || true, hadReceipts: true };
  }
  return { matched: null, hadReceipts: list.length > 0 };
}

/** Load every receipt JSON in the receipts dir (skips unreadable/unparseable). */
function loadReceipts() {
  const dir = receiptsDir();
  let names;
  try { names = fs.readdirSync(dir); } catch (_e) { return []; }
  const out = [];
  for (const n of names) {
    if (!n.endsWith('.json')) continue;
    try { out.push(JSON.parse(fs.readFileSync(path.join(dir, n), 'utf8'))); } catch (_e) { /* skip bad file */ }
  }
  return out;
}

/**
 * Diff-centric verification. Semantics (no active-task concept):
 *  - non-git            -> DEGRADED, exit 3 (cannot compute a trustworthy diff; do not block).
 *  - --task <id>        -> that receipt must exist + be intact + bind to current diff, else exit 4.
 *  - no --task (stop-gate default):
 *      * no code change            -> PASS exit 0 (nothing to review).
 *      * no receipts yet           -> PASS exit 0, note:"no-receipts" (adoption grace, never over-block).
 *      * some receipt binds diff   -> PASS exit 0.
 *      * receipts exist, none bind -> STALE exit 4 (code moved past every reviewed diff).
 * @param {{task?:string}} [flags]
 * @returns {{result:Object,code:number}}
 */
function verifyReceipt(flags = {}) {
  if (!isGitRepo()) {
    return { result: { state: 'DEGRADED', note: 'non-git', diffHash: null, degraded: true }, code: 3 };
  }
  const D = gitFingerprint();

  if (typeof flags.task === 'string' && flags.task) {
    const id = safeTaskId(flags.task);
    const file = path.join(receiptsDir(), id + '.json');
    let receipt;
    try { receipt = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_e) {
      return { result: { state: 'STALE', note: 'receipt-missing', task: flags.task, diffHash: D }, code: 4 };
    }
    if (!receiptIntact(receipt)) {
      return { result: { state: 'STALE', note: 'tampered', task: flags.task, diffHash: D }, code: 4 };
    }
    if (receipt.diffHash === D) {
      return { result: { state: 'PASS', matched: receipt.taskId, diffHash: D }, code: 0 };
    }
    return { result: { state: 'STALE', note: 'diff-moved', task: flags.task, diffHash: D, receiptDiffHash: receipt.diffHash }, code: 4 };
  }

  if (!hasCodeChange()) {
    return { result: { state: 'PASS', note: 'no-change', diffHash: D }, code: 0 };
  }
  const receipts = loadReceipts();
  if (receipts.length === 0) {
    return { result: { state: 'PASS', note: 'no-receipts', diffHash: D }, code: 0 };
  }
  const m = matchReceipts(receipts, D);
  if (m.matched) {
    return { result: { state: 'PASS', matched: m.matched, diffHash: D }, code: 0 };
  }
  return { result: { state: 'STALE', note: 'no-matching-receipt', diffHash: D }, code: 4 };
}

function cmdReceipt(flags, positional = []) {
  const sub = positional[0];   // parseArgs: cmd=argv[0], positional=argv[1..], so sub is positional[0]
  if (sub === 'write') {
    const raw = readStdin();
    let input;
    try { input = raw.trim() ? JSON.parse(raw) : {}; } catch (e) {
      return emit({ error: 'receipt-parse-error', detail: String(e && e.message || e) }, 3);
    }
    let receipt;
    try { receipt = writeReceipt(input); } catch (e) {
      return emit({ error: 'receipt-write-error', detail: String(e && e.message || e) }, 3);
    }
    return emit(receipt, 0);
  }
  if (sub === 'verify') {
    const { result, code } = verifyReceipt(flags);
    return emit(result, code);
  }
  return emit({ error: 'receipt-subcommand', detail: 'usage: receipt write|verify', got: sub || null }, 3);
}

function cmdVerify(flags) {
  const { result, code } = verifyPlanCmd(flags);
  return emit(result, code);
}

// ===========================================================================
// S8 quality  (four-state verification gate; command-missing -> BLOCKED, never fake green)
// ===========================================================================
// runCheck maps one declared check to PASS/FAIL/BLOCKED/SKIPPED. A missing binary is
// BLOCKED (not a silent pass); fast-mode may SKIP a non-security check that opts in, but
// security checks always run for real. Aggregation: any FAIL -> FAIL; else any BLOCKED ->
// BLOCKED; else PASS (SKIPPED counts toward the report but does not block).

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

/**
 * Run one shell command, returning its exit code. win32 uses cmd /c with
 * windowsVerbatimArguments so nested quotes in the command survive to the child
 * (plain cmd /c mangles e.g. node -e "process.exit(3)" into a 0 exit -- a false green).
 * @param {string} command
 * @returns {{code:number}}
 */
function spawnCmd(command) {
  const r = process.platform === 'win32'
    ? spawnSync('cmd', ['/c', command], { maxBuffer: 1 << 28, windowsVerbatimArguments: true })
    : spawnSync('sh', ['-c', command], { maxBuffer: 1 << 28 });
  return { code: r.status };
}

/**
 * Evaluate one check to a four-state result. Never fakes green: an absent binary is BLOCKED.
 * Security checks ignore fast-mode entirely (always run). Non-security opt-in checks may SKIP
 * under fast-mode.
 * @param {{id?:string,command?:string,class?:string,allowFastSkip?:boolean}} check
 * @param {{fastActive?:boolean}} [opts]
 * @returns {CheckResult}
 */
function runCheck(check, { fastActive = false } = {}) {
  const id = check && check.id ? check.id : (check && check.command) || 'check';
  const cls = check && check.class;
  const base = { id, class: cls, cmd: check && check.command };
  if (!check || !check.command) return { ...base, state: 'BLOCKED', reason: 'no-command' };
  const exe = String(check.command).trim().split(/\s+/)[0];
  if (!whichCmd(exe)) return { ...base, state: 'BLOCKED', reason: 'command-missing:' + exe };
  if (fastActive && cls !== 'security' && check.allowFastSkip) {
    return { ...base, state: 'SKIPPED', reason: 'fast-mode' };
  }
  const r = spawnCmd(check.command);
  return r.code === 0 ? { ...base, state: 'PASS', exit: 0 } : { ...base, state: 'FAIL', exit: r.code };
}

/** Aggregate check states: any FAIL -> FAIL; else any BLOCKED -> BLOCKED; else PASS. */
function aggregateStates(states) {
  if (states.some(s => s === 'FAIL')) return 'FAIL';
  if (states.some(s => s === 'BLOCKED')) return 'BLOCKED';
  return 'PASS';
}

/**
 * Required checks for a module: module-level `verification` overrides the catalog's
 * per-risk-tier default (catalog.riskChecks[risk]). Returns an array of check ids/specs.
 * @param {string} risk
 * @param {Module} module
 * @param {Catalog} catalog
 * @returns {any[]}
 */
function requiredChecks(risk, module, catalog) {
  if (module && Array.isArray(module.verification)) return module.verification;
  const riskChecks = (catalog && catalog.riskChecks && typeof catalog.riskChecks === 'object') ? catalog.riskChecks : {};
  return (risk && Array.isArray(riskChecks[risk])) ? riskChecks[risk] : [];
}

/** Resolve a check ref (string id or inline object) against catalog.checks. */
function resolveCheck(ref, catalog) {
  if (ref && typeof ref === 'object') return ref;
  const defs = (catalog && catalog.checks && typeof catalog.checks === 'object') ? catalog.checks : {};
  const def = defs[ref];
  if (def && typeof def === 'object') return { id: ref, ...def };
  return { id: String(ref), command: undefined };   // unresolved -> BLOCKED no-command
}

/**
 * Plan + run verification for a changed-path set: compute impact, gather each affected
 * module's required checks, run them four-state, aggregate. Missing catalog fields degrade
 * gracefully (empty check list per module).
 * @param {string[]} changed
 * @param {Catalog} catalog
 * @param {{fastActive?:boolean,nonGit?:boolean}} [opts]
 * @returns {{state:string,checks:CheckResult[],affected:string[],degraded:boolean}}
 */
function verifyPlan(changed, catalog, { fastActive = false, nonGit = false } = {}) {
  const imp = analyzeImpact(changed, catalog, { nonGit });
  const byId = new Map((catalog.modules || []).map(m => [m.id, m]));
  const checks = [];
  const seen = new Set();
  for (const id of imp.affected) {
    const m = byId.get(id);
    if (!m) continue;
    const risk = m.riskTier;
    for (const ref of requiredChecks(risk, m, catalog)) {
      const spec = resolveCheck(ref, catalog);
      const key = id + '::' + (spec.id || spec.command || JSON.stringify(ref));
      if (seen.has(key)) continue;
      seen.add(key);
      const res = runCheck(spec, { fastActive });
      checks.push({ module: id, ...res });
    }
  }
  return { state: aggregateStates(checks.map(c => c.state)), checks, affected: imp.affected, degraded: imp.degraded };
}

/** True if fast-mode flag file is present and unexpired (mirrors lib-fast-mode.sh). */
function fastModeActive() {
  const flag = path.join(projectRoot(), '.claude', '.fast-mode');
  let raw;
  try { raw = fs.readFileSync(flag, 'utf8'); } catch (_e) { return false; }
  const m = raw.match(/^expires_epoch=(\d+)$/m);
  if (!m) return false;
  return Number(m[1]) * 1000 > Date.now();
}

/**
 * `verify` subcommand driver. Exit convention:
 *   PASS or all-SKIPPED  -> 0
 *   FAIL or BLOCKED      -> 2 (never fake green; a command-missing BLOCKED also exits 2)
 *   no catalog / non-git -> 3 (degraded, gate skipped rather than block or fake-pass)
 */
function verifyPlanCmd(flags) {
  const loaded = loadCatalog(typeof flags.catalog === 'string' ? flags.catalog : undefined);
  if (!loaded.ok) {
    return { result: { state: 'DEGRADED', degraded: true, error: loaded.error, detail: loaded.detail, checks: [], affected: [] }, code: 3 };
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
  if (nonGit) {
    return { result: { state: 'DEGRADED', degraded: true, note: 'non-git', checks: [], affected: [] }, code: 3 };
  }
  const fastActive = fastModeActive();
  const plan = verifyPlan(changed, loaded.catalog, { fastActive, nonGit });
  const code = (plan.state === 'FAIL' || plan.state === 'BLOCKED') ? 2 : 0;
  return { result: { ...plan, fastActive }, code };
}

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
