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
//   S10 waiver        loadWaivers(), validateWaiver(), findWaiver(), cmdWaiver()         [T3.1]
//   S11 attributes    ATTRIBUTES/TIERS, normalizeTier(), assessAttributes(), cmdAttributes()
//   S12 arch-check    extractImports(), resolveImportTarget(), layerViolation(), cmdArchCheck()
//   S13 fitness       FITNESS_RULES, loadFitnessRules(), scanFitness(), cmdFitness()
//   S14 adapters      loadAdapters(), cmdAdapters()
//   S15 adr-check     parseInlineAdrs(), resolveEnforcement(), assessAdrRecords(), cmdAdrCheck()
//   S16 arch-trend    appendTrendRecord(), compareRatchet(), cmdArchTrend()
//
// Scale target: 600k+ LOC repositories. Hot paths (classifyPath / lintCatalog / impact)
// go through a compiled-regex cache; git path listings are NUL-separated so non-ASCII
// names survive; tracked listings are capped (maxTrackedPaths) and a truncated listing
// degrades conservatively instead of under-reporting.

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
// S0 CLI dispatch
// ===========================================================================
const IMPLEMENTED_SUBCOMMANDS = ['doctor', 'diff-hash', 'selftest', 'catalog-lint', 'impact', 'context-pack', 'receipt', 'verify', 'waiver', 'attributes', 'arch-check', 'fitness', 'adapters', 'adr-check', 'arch-trend'];
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
    case 'waiver':       return cmdWaiver(flags, positional);
    case 'attributes':   return cmdAttributes(flags);
    case 'arch-check':   return cmdArchCheck(flags);
    case 'fitness':      return cmdFitness(flags);
    case 'adapters':     return cmdAdapters(flags, positional);
    case 'adr-check':    return cmdAdrCheck(flags);
    case 'arch-trend':   return cmdArchTrend(flags);
    default:
      return die(usage(cmd), 3);
  }
}

function usage(cmd) {
  const prefix = cmd ? ('unknown subcommand: ' + cmd + '\n') : 'missing subcommand\n';
  return prefix +
    'usage: node harness.mjs <subcommand>\n' +
    'implemented: ' + IMPLEMENTED_SUBCOMMANDS.join(', ') + '\n' +
    '  attributes  static wiring audit: declared quality attributes vs claiming checks\n' +
    '  arch-check  real import edges vs declared graph (forbidden deps / layers / cycles); --record snapshots drift\n' +
    '  fitness     built-in day-one rules (secrets/pii/silent-failure/retry/deferral)\n' +
    '  adapters    list external quality tools, or add one into catalog checks\n' +
    '  adr-check   every active ADR must name a real enforcement (check/rule/harness cap or explicit manual)\n' +
    '  arch-trend  drift ratchet over recorded snapshots; --gate fails on new debt beyond best state\n' +
    'planned (not-implemented): ' + NOT_IMPLEMENTED_SUBCOMMANDS.join(', ');
}

function cmdDoctor() {
  const cfg = loadHarnessConfig();
  let waiverCount = 0;
  let waiversDirExists = false;
  try {
    waiversDirExists = fs.existsSync(waiversDir());
    if (waiversDirExists) waiverCount = loadWaivers().length;
  } catch (_e) { /* doctor must not throw */ }
  let attributesDeclared = 0;
  let modulesWithLayer = 0;
  let forbiddenEdges = 0;
  try {
    const loaded = loadCatalog();
    if (loaded.ok) {
      for (const m of (loaded.catalog.modules || [])) {
        attributesDeclared += Object.keys(m.attributes || {}).length;
        if (m.layer) modulesWithLayer++;
        forbiddenEdges += (m.forbiddenDependencies || []).length;
      }
    }
  } catch (_e) { /* doctor must not throw */ }
  emit({
    node: process.version,
    catalogPresent: cfg.catalogPresent,
    gitRepo: isGitRepo(),
    headCommit: headCommit(),
    harnessDir: '.claude/harness',
    subcommands: IMPLEMENTED_SUBCOMMANDS,
    waiversDirExists,
    activeWaivers: waiverCount,
    attributesDeclared,
    modulesWithLayer,
    forbiddenEdges,
    adaptersPresent: fs.existsSync(adaptersFilePath()),
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
    ['runCheck fast + privacy class -> never SKIPPED (runs for real)', () => {
      const r = runCheck({ id: 'pii-scan', command: 'node --version', class: 'privacy', allowFastSkip: true }, { fastActive: true });
      assert.notEqual(r.state, 'SKIPPED');
      assert.equal(r.state, 'PASS');
    }],
    ['verifyPlan: affected modules with zero checks -> BLOCKED emptyPlan (config failure, not green)', () => {
      const cat = { modules: [{ id: 'a', paths: ['a/**'] }] };
      const plan = verifyPlan(['a/x.js'], cat);
      assert.equal(plan.state, 'BLOCKED');
      assert.equal(plan.emptyPlan, true);
    }],
    ['verifyPlan: no changes -> PASS (nothing affected, nothing owed)', () => {
      const cat = { modules: [{ id: 'a', paths: ['a/**'] }] };
      const plan = verifyPlan([], cat);
      assert.equal(plan.state, 'PASS');
      assert.equal(plan.emptyPlan, false);
    }],
    ['requiredChecks: module.verification overrides catalog.riskChecks[risk]', () => {
      const cat = { riskChecks: { high: ['a', 'b'] } };
      assert.deepEqual(requiredChecks('high', { verification: ['x'] }, cat), ['x']);
      assert.deepEqual(requiredChecks('high', {}, cat), ['a', 'b']);
      assert.deepEqual(requiredChecks('low', {}, cat), []);
    }],

    // S10 waiver -- validate / apply (fs-free pure functions).
    ['validateWaiver missing fields -> errors non-empty', () => {
      const errs = validateWaiver({});
      assert.ok(errs.length > 0);
    }],
    ['validateWaiver security keyword in reason -> reject', () => {
      const w = {
        version: 1, owner: 't', reason: 'bypass security gate temporarily',
        scope: 'lint', expiry: '2099-01-01T00:00:00.000Z',
        compensation: 'fix later', created_at: '2026-01-01T00:00:00.000Z',
      };
      const errs = validateWaiver(w);
      assert.ok(errs.some(e => /forbidden|security|keyword/i.test(e)));
    }],
    ['validateWaiver expired expiry -> reject', () => {
      const w = {
        version: 1, owner: 't', reason: 'flake',
        scope: 'lint', expiry: '2000-01-01T00:00:00.000Z',
        compensation: 'fix later', created_at: '1999-01-01T00:00:00.000Z',
      };
      const errs = validateWaiver(w);
      assert.ok(errs.some(e => /expir/i.test(e)));
    }],
    ['validateWaiver complete object -> errors empty', () => {
      const w = {
        version: 1, owner: 't', reason: 'flake on CI',
        scope: 'lint', expiry: '2099-01-01T00:00:00.000Z',
        compensation: 'fix in CI', created_at: '2026-01-01T00:00:00.000Z',
      };
      assert.deepEqual(validateWaiver(w), []);
    }],
    ['applyWaiver: FAIL + matching scope + non-security -> SKIPPED waiver:', () => {
      const res = { id: 'lint', class: 'quality', state: 'FAIL', exit: 1 };
      const waivers = [{
        version: 1, owner: 't', reason: 'flake', scope: 'lint',
        expiry: '2099-01-01T00:00:00.000Z', compensation: 'x',
        created_at: '2026-01-01T00:00:00.000Z',
      }];
      const out = applyWaiver(res, waivers);
      assert.equal(out.state, 'SKIPPED');
      assert.ok(String(out.reason).startsWith('waiver:'));
    }],
    ['applyWaiver: FAIL + class security -> still FAIL', () => {
      const res = { id: 'audit', class: 'security', state: 'FAIL', exit: 1 };
      const waivers = [{
        version: 1, owner: 't', reason: 'flake', scope: 'audit',
        expiry: '2099-01-01T00:00:00.000Z', compensation: 'x',
        created_at: '2026-01-01T00:00:00.000Z',
      }];
      const out = applyWaiver(res, waivers);
      assert.equal(out.state, 'FAIL');
    }],
    ['applyWaiver: FAIL + no matching scope -> still FAIL', () => {
      const res = { id: 'lint', class: 'quality', state: 'FAIL', exit: 1 };
      const waivers = [{
        version: 1, owner: 't', reason: 'flake', scope: 'other',
        expiry: '2099-01-01T00:00:00.000Z', compensation: 'x',
        created_at: '2026-01-01T00:00:00.000Z',
      }];
      const out = applyWaiver(res, waivers);
      assert.equal(out.state, 'FAIL');
    }],
    ['applyWaiver: PASS -> still PASS (untouched)', () => {
      const res = { id: 'lint', class: 'quality', state: 'PASS', exit: 0 };
      const waivers = [{
        version: 1, owner: 't', reason: 'flake', scope: 'lint',
        expiry: '2099-01-01T00:00:00.000Z', compensation: 'x',
        created_at: '2026-01-01T00:00:00.000Z',
      }];
      const out = applyWaiver(res, waivers);
      assert.equal(out.state, 'PASS');
    }],
    ['applyWaiver: BLOCKED + matching scope + non-security -> SKIPPED', () => {
      const res = { id: 'lint', state: 'BLOCKED', reason: 'command-missing:foo' };
      const waivers = [{
        version: 1, owner: 't', reason: 'tool not on CI image yet', scope: 'lint',
        expiry: '2099-01-01T00:00:00.000Z', compensation: 'install tool',
        created_at: '2026-01-01T00:00:00.000Z',
      }];
      const out = applyWaiver(res, waivers);
      assert.equal(out.state, 'SKIPPED');
      assert.ok(String(out.reason).startsWith('waiver:'));
    }],
    ['validateWaiver forbidden keyword in scope -> reject', () => {
      const w = {
        version: 1, owner: 't', reason: 'temp',
        scope: 'security-scan', expiry: '2099-01-01T00:00:00.000Z',
        compensation: 'x', created_at: '2026-01-01T00:00:00.000Z',
      };
      const errs = validateWaiver(w);
      assert.ok(errs.some(e => /forbidden|keyword/i.test(e)));
    }],
    ['validateWaiver privacy/pii keyword -> reject (privacy joins the protected set)', () => {
      const base = {
        version: 1, owner: 't', expiry: '2099-01-01T00:00:00.000Z',
        compensation: 'x', created_at: '2026-01-01T00:00:00.000Z',
      };
      const w1 = { ...base, reason: 'skip privacy scan for demo', scope: 'lint' };
      const w2 = { ...base, reason: 'temp', scope: 'pii-log-check' };
      assert.ok(validateWaiver(w1).some(e => /forbidden|keyword/i.test(e)));
      assert.ok(validateWaiver(w2).some(e => /forbidden|keyword/i.test(e)));
    }],
    ['applyWaiver: FAIL + class privacy -> still FAIL (never waivable)', () => {
      const res = { id: 'pii-scan', class: 'privacy', state: 'FAIL', exit: 1 };
      const waivers = [{
        version: 1, owner: 't', reason: 'flake', scope: 'pii-scan',
        expiry: '2099-01-01T00:00:00.000Z', compensation: 'x',
        created_at: '2026-01-01T00:00:00.000Z',
      }];
      assert.equal(applyWaiver(res, waivers).state, 'FAIL');
    }],
    ['findWaiverForCheck returns first matching scope', () => {
      const list = [
        { scope: 'a' }, { scope: 'lint' }, { scope: 'lint' },
      ];
      const w = findWaiverForCheck('lint', list);
      assert.equal(w.scope, 'lint');
      assert.equal(findWaiverForCheck('nope', list), null);
    }],

    // S2 -- NUL-separated git listings (non-ASCII names survive).
    ['splitNul parses NUL-separated buffer incl. CJK path', () => {
      const buf = Buffer.from('src/a.ts\0\u6a21\u5757/\u4e2d\u6587.ts\0', 'utf8');
      assert.deepEqual(splitNul(buf), ['src/a.ts', '\u6a21\u5757/\u4e2d\u6587.ts']);
    }],

    // S8 -- safety class sits beside security: never fast-skipped, never waived.
    ['runCheck fast + safety class -> still runs (never SKIPPED)', () => {
      const r = runCheck({ id: 'haz', command: 'node --version', class: 'safety', allowFastSkip: true }, { fastActive: true });
      assert.equal(r.state, 'PASS');
    }],
    ['applyWaiver: FAIL + class safety -> still FAIL', () => {
      const res = { id: 'haz', class: 'safety', state: 'FAIL', exit: 1 };
      const waivers = [{ scope: 'haz' }];
      assert.equal(applyWaiver(res, waivers).state, 'FAIL');
    }],

    // S11 -- tier normalization + attribute lint codes.
    ['normalizeTier accepts string and {tier,reason}', () => {
      assert.deepEqual(normalizeTier('high'), { tier: 'high', reason: '' });
      assert.deepEqual(normalizeTier({ tier: 'none', reason: 'lib only' }), { tier: 'none', reason: 'lib only' });
    }],
    ['lint UNKNOWN_ATTRIBUTE / UNKNOWN_TIER / UNJUSTIFIED_TIER', () => {
      const cat = { version: 1, modules: [
        { id: 'a', paths: ['a/**'], attributes: { bogus: 'high' } },
        { id: 'b', paths: ['b/**'], attributes: { security: 'ultra' } },
        { id: 'c', paths: ['c/**'], attributes: { privacy: 'none' } },
      ] };
      const r = lintCatalog(cat, []);
      assert.ok(hasCode(r.errors, 'UNKNOWN_ATTRIBUTE'));
      assert.ok(hasCode(r.errors, 'UNKNOWN_TIER'));
      assert.ok(hasCode(r.errors, 'UNJUSTIFIED_TIER'));
    }],
    ['lint UNJUSTIFIED_TIER absent when none carries a reason', () => {
      const cat = { version: 1, modules: [
        { id: 'c', paths: ['c/**'], attributes: { privacy: { tier: 'none', reason: 'no personal data in scope' } } },
      ] };
      const r = lintCatalog(cat, []);
      assert.ok(!hasCode(r.errors, 'UNJUSTIFIED_TIER'));
    }],
    ['lint SELF_FORBIDDEN / FORBIDDEN_DECLARED / UNKNOWN_LAYER', () => {
      const cat = { version: 1, layers: ['app'], modules: [
        { id: 'a', paths: ['a/**'], forbiddenDependencies: ['a'] },
        { id: 'b', paths: ['b/**'], dependsOn: ['a'], forbiddenDependencies: ['a'] },
        { id: 'c', paths: ['c/**'], layer: 'ghost' },
      ] };
      const r = lintCatalog(cat, []);
      assert.ok(hasCode(r.errors, 'SELF_FORBIDDEN'));
      assert.ok(hasCode(r.errors, 'FORBIDDEN_DECLARED'));
      assert.ok(hasCode(r.errors, 'UNKNOWN_LAYER'));
    }],

    // S11 -- attribute coverage decisions (pure, fs-free).
    ['attributes: PASS claiming check covers the attribute', () => {
      const cat = attrCatalog();
      const r = assessAttributes(['pay'], cat, [{ module: 'pay', id: 'sec-scan', state: 'PASS' }]);
      const e = r.attributes.find(a => a.attribute === 'security');
      assert.equal(e.covered, true);
      assert.equal(r.blockingGaps.length, 0);
    }],
    ['attributes: failing claim outweighs a passing one', () => {
      const cat = attrCatalog({ verification: ['sec-scan', 'sec-audit'] });
      const r = assessAttributes(['pay'], cat, [
        { module: 'pay', id: 'sec-scan', state: 'PASS' },
        { module: 'pay', id: 'sec-audit', state: 'FAIL' },
      ]);
      const e = r.attributes.find(a => a.attribute === 'security');
      assert.equal(e.covered, false);
      assert.ok(r.blockingGaps.some(g => g.attribute === 'security'));
    }],
    ['attributes: SKIPPED neither covers nor contradicts', () => {
      const cat = attrCatalog();
      const r = assessAttributes(['pay'], cat, [{ module: 'pay', id: 'sec-scan', state: 'SKIPPED' }]);
      const e = r.attributes.find(a => a.attribute === 'security');
      assert.equal(e.covered, false);
    }],
    ['attributes: declared but unwired -> visible blocking gap (high)', () => {
      const cat = attrCatalog({ attributes: { security: 'critical', resilience: 'high' } });
      const r = assessAttributes(['pay'], cat, [{ module: 'pay', id: 'sec-scan', state: 'PASS' }]);
      const e = r.attributes.find(a => a.attribute === 'resilience');
      assert.equal(e.covered, false);
      assert.ok(/no check/.test(e.reason));
      assert.ok(r.blockingGaps.some(g => g.attribute === 'resilience'));
    }],
    ['attributes: none tier -> opted out, never a gap', () => {
      const cat = attrCatalog({ attributes: { availability: { tier: 'none', reason: 'no service surface' } } });
      const r = assessAttributes(['pay'], cat, []);
      const e = r.attributes.find(a => a.attribute === 'availability');
      assert.equal(e.covered, true);
      assert.equal(e.enforcement, 'opted-out');
      assert.equal(r.blockingGaps.length, 0);
    }],
    ['attributes: medium uncovered warns but never blocks', () => {
      const cat = attrCatalog({ attributes: { performance: 'medium' } });
      const r = assessAttributes(['pay'], cat, []);
      const e = r.attributes.find(a => a.attribute === 'performance');
      assert.equal(e.covered, false);
      assert.equal(e.enforcement, 'warn');
      assert.equal(r.blockingGaps.length, 0);
    }],
    ['attributes: high gap deferred by attribute waiver; critical never', () => {
      const cat = attrCatalog({ attributes: { resilience: 'high', security: 'critical' } });
      const waivers = [{ scope: 'attribute:pay/resilience' }, { scope: 'attribute:pay/security' }];
      const r = assessAttributes(['pay'], cat, [], waivers);
      const res = r.attributes.find(a => a.attribute === 'resilience');
      assert.equal(res.waived, true);
      assert.ok(!r.blockingGaps.some(g => g.attribute === 'resilience'));
      assert.ok(r.blockingGaps.some(g => g.attribute === 'security'));
    }],
    ['attributes: security/safety attribute waiver is unrepresentable (forbidden keyword)', () => {
      const w = {
        version: 1, owner: 't', reason: 'defer evidence', scope: 'attribute:pay/security',
        expiry: '2099-01-01T00:00:00.000Z', compensation: 'wire scanner next sprint',
        created_at: '2026-01-01T00:00:00.000Z',
      };
      assert.ok(validateWaiver(w).some(e => /forbidden|keyword/i.test(e)));
    }],
    ['claimingChecks resolves via module.verification and check attributes', () => {
      const cat = attrCatalog();
      assert.deepEqual(claimingChecks(cat.modules[0], cat, 'security'), ['sec-scan']);
      assert.deepEqual(claimingChecks(cat.modules[0], cat, 'privacy'), []);
    }],

    // S12 -- arch-check pure functions.
    ['extractImports: js import/require/dynamic/export-from', () => {
      const src = 'import a from "mod-a";\nexport { x } from "./rel";\nconst b = require("pkg/b");\nawait import("dyn");\n';
      const got = extractImports('src/x.ts', src);
      assert.ok(got.includes('mod-a') && got.includes('./rel') && got.includes('pkg/b') && got.includes('dyn'));
    }],
    ['extractImports: python from/import', () => {
      const got = extractImports('a/b.py', 'from pkg.sub import thing\nimport os\n');
      assert.ok(got.includes('pkg.sub') && got.includes('os'));
    }],
    ['extractImports: go quoted import', () => {
      const got = extractImports('m/main.go', 'import (\n  "example.com/mod/db"\n)\n');
      assert.ok(got.includes('example.com/mod/db'));
    }],
    ['moduleForSpecifier: longest provides prefix wins', () => {
      const cat = { modules: [
        { id: 'core', paths: ['core/**'], provides: ['@acme'] },
        { id: 'db', paths: ['db/**'], provides: ['@acme/db'] },
      ] };
      assert.equal(moduleForSpecifier(cat, '@acme/db/client'), 'db');
      assert.equal(moduleForSpecifier(cat, '@acme/util'), 'core');
      assert.equal(moduleForSpecifier(cat, 'left-pad'), null);
    }],
    ['layerViolation: outward-reaching dependency flagged, inward ok', () => {
      const cat = { layers: ['app', 'domain', 'infra'] };
      const app = { id: 'a', layer: 'app' };
      const domain = { id: 'd', layer: 'domain' };
      assert.equal(layerViolation(cat, app, domain), null);            // inward ok
      assert.ok(/may not depend/.test(layerViolation(cat, domain, app)));  // outward violation
      assert.equal(layerViolation(cat, app, app), null);               // same layer ok
      assert.equal(layerViolation(cat, app, { id: 'x' }), null);       // missing layer -> null
    }],
    ['findCycles detects a->b->a', () => {
      const edges = new Map([['a', new Set(['b'])], ['b', new Set(['a'])], ['c', new Set()]]);
      const cycles = findCycles(edges);
      assert.ok(cycles.length >= 1);
      assert.ok(cycles[0].includes('a') && cycles[0].includes('b'));
    }],

    // S13 -- fitness rules (pure over injected contents).
    ['fitness: secret literal is an error finding', () => {
      const f = scanFitness([{ path: 'src/cfg.ts', content: 'const apiKey = "AKIAABCDEFGHIJKLMNOP";\n' }], null, DEFAULT_FITNESS_RULES);
      assert.ok(f.some(x => x.rule === 'no-secret-literal' && x.severity === 'error'));
    }],
    ['fitness: suppression marker kills exactly that finding', () => {
      const content = '// harness-fitness:ignore\nconst password = "abcdefghijklmnop123456";\n';
      const f = scanFitness([{ path: 'src/cfg.ts', content }], null, DEFAULT_FITNESS_RULES);
      assert.ok(!f.some(x => x.rule === 'no-secret-literal'));
    }],
    ['fitness: pii in log call flagged', () => {
      const f = scanFitness([{ path: 'src/a.ts', content: 'logger.info("user " + email + " ssn " + ssn)\n' }], null, DEFAULT_FITNESS_RULES);
      assert.ok(f.some(x => x.rule === 'no-pii-in-logs'));
    }],
    ['fitness: empty catch flagged as silent failure', () => {
      const f = scanFitness([{ path: 'src/a.ts', content: 'try { x() } catch (e) {}\n' }], null, DEFAULT_FITNESS_RULES);
      assert.ok(f.some(x => x.rule === 'no-silent-failure'));
    }],
    ['fitness: unbounded retry loop flagged', () => {
      const f = scanFitness([{ path: 'src/a.ts', content: 'while (true) {\n  await fetch(url);\n}\n' }], null, DEFAULT_FITNESS_RULES);
      assert.ok(f.some(x => x.rule === 'no-unbounded-retry'));
    }],
    ['fitness: minimumTier rule fires only where module asked for that strength', () => {
      const cat = { modules: [
        { id: 'pay', paths: ['pay/**'], attributes: { safety: 'high' } },
        { id: 'proto', paths: ['proto/**'] },
      ] };
      const content = '// TODO handle overflow\n';
      const inPay = scanFitness([{ path: 'pay/a.ts', content }], cat, DEFAULT_FITNESS_RULES);
      const inProto = scanFitness([{ path: 'proto/a.ts', content }], cat, DEFAULT_FITNESS_RULES);
      const noCat = scanFitness([{ path: 'x/a.ts', content }], null, DEFAULT_FITNESS_RULES);
      assert.ok(inPay.some(x => x.rule === 'no-unreferenced-deferral'));
      assert.ok(!inProto.some(x => x.rule === 'no-unreferenced-deferral'));
      assert.ok(!noCat.some(x => x.rule === 'no-unreferenced-deferral'));
    }],
    ['fitness: attribute opted out (none) silences the rule for that module', () => {
      const cat = { modules: [
        { id: 'gen', paths: ['gen/**'], attributes: { reliability: { tier: 'none', reason: 'generated code' } } },
      ] };
      const f = scanFitness([{ path: 'gen/a.ts', content: 'try { x() } catch (e) {}\n' }], cat, DEFAULT_FITNESS_RULES);
      assert.ok(!f.some(x => x.rule === 'no-silent-failure'));
    }],
    ['fitness: referenced deferral marker (issue link) does not fire', () => {
      const cat = { modules: [{ id: 'pay', paths: ['pay/**'], attributes: { safety: 'high' } }] };
      const f = scanFitness([{ path: 'pay/a.ts', content: '// TODO issue #123 handle overflow\n' }], cat, DEFAULT_FITNESS_RULES);
      assert.ok(!f.some(x => x.rule === 'no-unreferenced-deferral'));
    }],

    // S15 -- ADR parsing + enforcement resolution (pure, fs-free).
    ['parseInlineAdrs extracts id/status/enforced from ### blocks', () => {
      const md = '## 6. ADR\n\n### ADR-001\uFF1A\u9009\u5b58\u50a8\n- **\u72b6\u6001**\uFF1Aaccepted\n- **\u6267\u6cd5\u65b9\u5f0f**\uFF1Aarch-check \u7981\u8fb9\n\n### ADR-002 \u98ce\u683c\n- **\u6267\u6cd5\u65b9\u5f0f**\uFF1A\u4eba\u5de5\u8bc4\u5ba1\n\n## 7. next\n';
      const got = parseInlineAdrs(md);
      assert.equal(got.length, 2);
      assert.equal(got[0].id, 'ADR-001');
      assert.ok(got[0].enforcedRaw.includes('arch-check'));
      assert.equal(got[1].id, 'ADR-002');
      assert.equal(got[1].status, 'accepted');
    }],
    ['resolveEnforcement: known check / fitness rule / harness cap / manual / unknown', () => {
      const checks = ['sec-scan'];
      const rules = ['no-secret-literal'];
      assert.equal(resolveEnforcement('sec-scan', checks, rules).kind, 'check');
      assert.equal(resolveEnforcement('fitness \u89c4\u5219 no-secret-literal', checks, rules).kind, 'fitness-rule');
      assert.equal(resolveEnforcement('arch-check \u7981\u8fb9', checks, rules).kind, 'harness');
      assert.equal(resolveEnforcement('\u9760\u8bc4\u5ba1', checks, rules).kind, 'manual');
      assert.equal(resolveEnforcement('ghost-gate-xyz', checks, rules).kind, 'unknown');
    }],
    ['assessAdrRecords: machine ok / manual-only listed / missing fails / phantom fails / retired exempt', () => {
      const recs = [
        { id: 'A1', status: 'accepted', enforcedRaw: 'arch-check / layers' },
        { id: 'A2', status: 'accepted', enforcedRaw: '\u65e0\u6cd5\u673a\u5668\u6267\u6cd5\uFF0C\u9760\u8bc4\u5ba1' },
        { id: 'A3', status: 'accepted', enforcedRaw: '' },
        { id: 'A4', status: 'accepted', enforcedRaw: 'ghost-check-typo' },
        { id: 'A5', status: 'superseded', enforcedRaw: '' },
      ];
      const r = assessAdrRecords(recs, [], DEFAULT_FITNESS_RULES.map(x => x.id));
      const by = Object.fromEntries(r.records.map(x => [x.id, x]));
      assert.ok(by.A1.ok && !by.A1.manualOnly);
      assert.ok(by.A2.ok && by.A2.manualOnly);
      assert.ok(!by.A3.ok);
      assert.ok(!by.A4.ok && /phantom|recognizable/.test(by.A4.reason));
      assert.ok(by.A5.ok && by.A5.retired);
      assert.equal(r.failing.length, 2);
    }],
    ['assessAdrRecords: unknown fragment beside a known one is surfaced, not failed', () => {
      const r = assessAdrRecords([{ id: 'A1', status: 'accepted', enforcedRaw: 'no-secret-literal, ghost-thing' }], [], DEFAULT_FITNESS_RULES.map(x => x.id));
      assert.ok(r.records[0].ok);
      assert.deepEqual(r.records[0].unrecognized, ['ghost-thing']);
    }],

    // S16 -- drift ratchet (pure).
    ['compareRatchet: single record -> baseline, not comparable', () => {
      const r = compareRatchet([{ undeclared: 5, forbidden: 0, cycles: 0 }]);
      assert.equal(r.comparable, false);
      assert.equal(r.regressed.length, 0);
      assert.equal(r.summary.undeclared.baseline, 5);
    }],
    ['compareRatchet: improvement passes and is listed', () => {
      const r = compareRatchet([
        { undeclared: 5, forbidden: 1, cycles: 0 },
        { undeclared: 3, forbidden: 0, cycles: 0 },
      ]);
      assert.equal(r.regressed.length, 0);
      assert.ok(r.improved.some(x => x.metric === 'undeclared' && x.latest === 3));
    }],
    ['compareRatchet: regression beyond best historical value is flagged', () => {
      const r = compareRatchet([
        { undeclared: 5, forbidden: 0, cycles: 0 },
        { undeclared: 2, forbidden: 0, cycles: 0 },
        { undeclared: 4, forbidden: 0, cycles: 0 },
      ]);
      assert.ok(r.regressed.some(x => x.metric === 'undeclared' && x.latest === 4 && x.bestBefore === 2));
    }],
    ['compareRatchet: equal to best -> no regression (ratchet holds)', () => {
      const r = compareRatchet([
        { undeclared: 2, forbidden: 0, cycles: 0 },
        { undeclared: 2, forbidden: 0, cycles: 0 },
      ]);
      assert.equal(r.regressed.length, 0);
    }],
    ['compareRatchet: unresolved/unused are context, never ratchet', () => {
      const r = compareRatchet([
        { undeclared: 0, forbidden: 0, cycles: 0, unresolved: 10, unused: 1 },
        { undeclared: 0, forbidden: 0, cycles: 0, unresolved: 50, unused: 5 },
      ]);
      assert.equal(r.regressed.length, 0);
    }],

    // Scale smoke -- the glob cache must keep classification linear-ish. 120 modules x
    // 3 globs against 30k paths stays far under the bound on any dev machine; without
    // the cache this same loop recompiled ~10.8M RegExps and blew straight past it.
    ['scale: classify 30k paths against 120-module catalog under 2500ms', () => {
      const mods = [];
      for (let i = 0; i < 120; i++) {
        mods.push({ id: 'm' + i, paths: ['pkg' + i + '/**', 'src/pkg' + i + '/**/*.ts', 'libs/p' + i + '/*'] });
      }
      const cat = { version: 1, modules: mods, global: ['package.json'], ignored: ['**/*.md'] };
      const paths = [];
      for (let i = 0; i < 30000; i++) paths.push('pkg' + (i % 120) + '/f' + i + '.ts');
      const t0 = Date.now();
      const r = lintCatalog(cat, paths);
      const elapsed = Date.now() - t0;
      assert.ok(r.ok, 'synthetic catalog should lint clean');
      assert.ok(elapsed < 2500, 'lint took ' + elapsed + 'ms (>= 2500ms)');
    }],
  ];
}

/** Tiny attribute-enabled catalog for S11 selftests (payments module + sec-scan check). */
function attrCatalog(overrides = {}) {
  return {
    version: 1,
    modules: [{
      id: 'pay', paths: ['pay/**'], riskTier: 'high',
      verification: overrides.verification || ['sec-scan'],
      attributes: overrides.attributes || { security: 'critical' },
    }],
    checks: {
      'sec-scan': { command: 'node --version', class: 'security', attributes: ['security'] },
      'sec-audit': { command: 'node --version', class: 'security', attributes: ['security'] },
    },
  };
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
  ':(exclude).claude/harness/waivers/**',
  ':(exclude).claude/harness/trend/**',
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

  // S11 attributes + S12 boundary declarations. Opting out (none|minimal) must carry a
  // written reason: silence is the state every attribute drifts toward when it costs nothing.
  const layerNames = Array.isArray(catalog.layers) ? catalog.layers : [];
  for (const m of modules) {
    for (const [attr, req] of Object.entries(m.attributes || {})) {
      if (!ATTRIBUTES.includes(attr)) {
        errors.push({ code: 'UNKNOWN_ATTRIBUTE', path: null, detail: 'module ' + m.id + ' declares unknown attribute "' + attr + '"' });
        continue;
      }
      const { tier, reason } = normalizeTier(req);
      if (!TIERS.includes(tier)) {
        errors.push({ code: 'UNKNOWN_TIER', path: null, detail: 'module ' + m.id + ' sets ' + attr + ' to unknown tier "' + tier + '"' });
        continue;
      }
      if ((tier === 'none' || tier === 'minimal') && !reason.trim()) {
        errors.push({ code: 'UNJUSTIFIED_TIER', path: null, detail: 'module ' + m.id + ' sets ' + attr + ' to "' + tier + '" without a reason ({"tier":"' + tier + '","reason":"..."})' });
      }
    }
    for (const f of (m.forbiddenDependencies || [])) {
      if (f === m.id) {
        errors.push({ code: 'SELF_FORBIDDEN', path: null, detail: 'module ' + m.id + ' forbids depending on itself' });
      } else if (!ids.has(f)) {
        errors.push({ code: 'DANGLING_DEP', path: null, detail: 'module ' + m.id + ' forbiddenDependencies missing id "' + f + '"' });
      }
      // Declaring and forbidding the same edge is a contradiction; the prohibition wins,
      // but the catalog must not carry both statements.
      if ((m.dependsOn || []).includes(f)) {
        errors.push({ code: 'FORBIDDEN_DECLARED', path: null, detail: 'module ' + m.id + ' both declares and forbids dependency "' + f + '"' });
      }
    }
    if (m.layer && !layerNames.includes(m.layer)) {
      errors.push({ code: 'UNKNOWN_LAYER', path: null, detail: 'module ' + m.id + ' is in layer "' + m.layer + '" which catalog.layers does not declare' });
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

/**
 * git ls-files -> tracked path list, NUL-separated, capped at maxTrackedPaths.
 * A truncated listing is a broken measurement, not a smaller one: callers must surface
 * `truncated` (catalog-lint warns; impact treats it as a degraded full-fanout signal).
 * @param {number} [cap]  catalog.maxTrackedPaths or the 100k default
 * @returns {{paths:string[],truncated:boolean}}
 */
function trackedFiles(cap) {
  if (!isGitRepo()) return { paths: [], truncated: false };
  const r = git(['-c', 'core.quotePath=false', 'ls-files', '-z']);
  if (r.status !== 0) return { paths: [], truncated: false };
  const all = splitNul(r.stdout);
  const limit = (typeof cap === 'number' && cap > 0) ? cap : DEFAULTS.maxTrackedPaths;
  return { paths: all.slice(0, limit), truncated: all.length > limit };
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
  let tracked;
  let truncated = false;
  if (typeof flags.tracked === 'string') {
    tracked = parseCsv(flags.tracked);
  } else {
    const t = trackedFiles(loaded.catalog.maxTrackedPaths);
    tracked = t.paths;
    truncated = t.truncated;
  }
  const result = lintCatalog(loaded.catalog, tracked);
  if (truncated) {
    result.warnings.push({ code: 'TRUNCATED', path: null, detail: 'tracked listing hit maxTrackedPaths; coverage is incomplete' });
  }
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
  /(^|\/)\.claude\/(evidence|harness\/receipts|harness\/waivers|harness\/trend)\//,
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
// BLOCKED (not a silent pass); fast-mode may SKIP a non-security/safety/privacy check that
// opts in, but security/safety/privacy checks always run for real. Aggregation: any FAIL ->
// FAIL; else any BLOCKED -> BLOCKED; else PASS (SKIPPED counts toward the report but does
// not block). An empty plan with affected modules is BLOCKED (config failure, not green).

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
  if (fastActive && cls !== 'security' && cls !== 'safety' && cls !== 'privacy' && check.allowFastSkip) {
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
  // S10: apply structured waivers at the orchestration layer (not inside runCheck).
  // Non-security/safety FAIL/BLOCKED with a matching valid waiver become SKIPPED
  // (reason waiver:<scope>). Security/safety classes are never rewritten. Fast-mode
  // SKIPPED stays orthogonal.
  const waivers = loadWaivers();
  const waived = checks.map(c => {
    const next = applyWaiver(c, waivers);
    // preserve module field if present
    if (c.module !== undefined && next.module === undefined) return { ...next, module: c.module };
    return next;
  });
  // S11: attribute coverage over the executed results. Blocking gaps (critical/high
  // declared, no passing claiming check, no attribute waiver) close the gate alongside
  // FAIL/BLOCKED so "all checks green but nothing evidenced security" stops reading as done.
  const attrs = assessAttributes(imp.affected, catalog, waived, waivers);
  // Empty verification plan while modules ARE affected is a configuration failure, not a
  // green: nothing ran, so nothing was established. BLOCKED (never fake green), same class
  // as command-missing. No affected modules (no changes) still aggregates to PASS.
  const emptyPlan = imp.affected.length > 0 && waived.length === 0;
  return {
    state: emptyPlan ? 'BLOCKED' : aggregateStates(waived.map(c => c.state)),
    checks: waived, affected: imp.affected, degraded: imp.degraded,
    emptyPlan,
    attributes: attrs.attributes, attributeGaps: attrs.blockingGaps,
  };
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
 *   PASS or all-SKIPPED, no blocking attribute gap -> 0
 *   FAIL or BLOCKED, or a critical/high attribute lacks evidence -> 2 (never fake green)
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
  const attrBlocked = Array.isArray(plan.attributeGaps) && plan.attributeGaps.length > 0;
  const gate = (plan.state === 'FAIL' || plan.state === 'BLOCKED') ? plan.state
    : attrBlocked ? 'BLOCKED_BY_ATTRIBUTES' : 'PASS';
  const code = gate === 'PASS' ? 0 : 2;
  return { result: { ...plan, gate, fastActive }, code };
}


// ===========================================================================
// S10 waiver  (structured per-check exemptions; security never waivable)
// ===========================================================================
// Waivers live under .claude/harness/waivers/*.json (git-ignored runtime state).
// A valid waiver can demote a non-security FAIL/BLOCKED check to SKIPPED with
// reason "waiver:<scope>". Security-class checks are never rewritten, even if a
// file claims their id. Fast Mode remains a bulk sugar path orthogonal to this.
// Forbidden keywords in reason|scope block create/validate (safety net for HIGH gates).

/** Forbidden whole-word tokens in reason+scope (case-insensitive). */
const WAIVER_FORBIDDEN_RE = /\b(safety|security|privacy|pii|secret|credential|destructive|push|deploy|production)\b/i;

/** Where waiver JSON files are stored (project-relative, git-ignored). */
function waiversDir() {
  return path.join(projectRoot(), '.claude', 'harness', 'waivers');
}

/**
 * Validate a waiver object. Returns a list of human-readable error strings
 * (empty => valid). Does not touch fs. Expired expiry is an error.
 * @param {any} w
 * @returns {string[]}
 */
function validateWaiver(w) {
  const errors = [];
  if (!w || typeof w !== 'object' || Array.isArray(w)) return ['waiver must be an object'];
  if (w.version !== 1) errors.push('version must be 1');
  for (const k of ['owner', 'reason', 'scope', 'expiry', 'compensation', 'created_at']) {
    if (typeof w[k] !== 'string' || !String(w[k]).trim()) errors.push(k + ' required (non-empty string)');
  }
  const createdMs = Date.parse(w.created_at);
  if (typeof w.created_at === 'string' && Number.isNaN(createdMs)) {
    errors.push('created_at must be ISO timestamp');
  }
  const expMs = Date.parse(w.expiry);
  if (typeof w.expiry === 'string') {
    if (Number.isNaN(expMs)) errors.push('expiry must be ISO timestamp');
    else if (expMs <= Date.now()) errors.push('expiry must be in the future (not expired)');
  }
  const blob = (String(w.reason || '') + ' ' + String(w.scope || '')).toLowerCase();
  if (WAIVER_FORBIDDEN_RE.test(blob)) {
    errors.push('forbidden keyword in reason|scope (safety|security|privacy|pii|secret|credential|destructive|push|deploy|production)');
  }
  return errors;
}

/**
 * Load *.json waivers that pass validateWaiver (skips bad/expired files).
 * Each entry is annotated with _path (absolute) for list/CLI.
 * @returns {Array<Waiver & {_path?:string}>}
 */
function loadWaivers() {
  const dir = waiversDir();
  let names;
  try { names = fs.readdirSync(dir); } catch (_e) { return []; }
  const out = [];
  for (const n of names) {
    if (!n.endsWith('.json')) continue;
    const fp = path.join(dir, n);
    let obj;
    try { obj = JSON.parse(fs.readFileSync(fp, 'utf8')); } catch (_e) { continue; }
    if (validateWaiver(obj).length) continue;
    out.push({ ...obj, _path: fp });
  }
  return out;
}

/**
 * First waiver whose scope exactly equals checkId, or null.
 * @param {string} checkId
 * @param {Array<{scope?:string}>} waivers
 */
function findWaiverForCheck(checkId, waivers) {
  const id = String(checkId == null ? '' : checkId);
  const list = Array.isArray(waivers) ? waivers : [];
  for (const w of list) {
    if (w && w.scope === id) return w;
  }
  return null;
}

/**
 * If result is FAIL|BLOCKED, class is not security/safety, and a waiver matches scope==id,
 * rewrite to SKIPPED with reason waiver:<scope>. Otherwise return result unchanged.
 * Safety-class checks sit beside security: a failing functional-safety gate must never be
 * waived into green, for the same reason a security gate must not.
 * Pure + injectable (waivers array passed in) so selftest stays fs-free.
 * @param {CheckResult} result
 * @param {Array<Waiver>} waivers
 * @returns {CheckResult}
 */
function applyWaiver(result, waivers) {
  if (!result || typeof result !== 'object') return result;
  const state = result.state;
  if (state !== 'FAIL' && state !== 'BLOCKED') return result;
  if (result.class === 'security' || result.class === 'safety' || result.class === 'privacy') return result;
  const hit = findWaiverForCheck(result.id, waivers);
  if (!hit) return result;
  return { ...result, state: 'SKIPPED', reason: 'waiver:' + hit.scope };
}

/**
 * CLI: waiver list | check | create.
 *   list (default)                         -> {ok, waivers:[{path,...fields}]} exit 0
 *   check --file path | positional path    -> {ok, valid, errors, waiver} exit 0/1
 *   create --owner --reason --scope --expiry --compensation [--dry-run]
 *                                          -> validate then write waivers/<ts>-<hash10>.json
 * @param {Object} flags
 * @param {string[]} positional
 */
function cmdWaiver(flags = {}, positional = []) {
  const sub = (positional[0] || flags.sub || 'list');
  if (sub === 'list') {
    const list = loadWaivers().map(w => {
      const { _path, ...rest } = w;
      return { path: _path || null, ...rest };
    });
    return emit({ ok: true, waivers: list }, 0);
  }
  if (sub === 'check') {
    const file = (typeof flags.file === 'string' && flags.file) || positional[1] || '';
    if (!file) return emit({ ok: false, valid: false, errors: ['--file or path required'], waiver: null }, 1);
    let obj;
    try { obj = JSON.parse(fs.readFileSync(file, 'utf8')); }
    catch (e) { return emit({ ok: false, valid: false, errors: ['read/parse: ' + String(e && e.message || e)], waiver: null }, 1); }
    const errors = validateWaiver(obj);
    const valid = errors.length === 0;
    return emit({ ok: valid, valid, errors, waiver: obj }, valid ? 0 : 1);
  }
  if (sub === 'create') {
    const now = new Date().toISOString();
    const waiver = {
      version: 1,
      owner: typeof flags.owner === 'string' ? flags.owner : '',
      reason: typeof flags.reason === 'string' ? flags.reason : '',
      scope: typeof flags.scope === 'string' ? flags.scope : '',
      expiry: typeof flags.expiry === 'string' ? flags.expiry : '',
      compensation: typeof flags.compensation === 'string' ? flags.compensation : '',
      created_at: now,
    };
    const errors = validateWaiver(waiver);
    if (errors.length) {
      process.stderr.write('waiver create rejected: ' + errors.join('; ') + '\n');
      return emit({ ok: false, errors, waiver }, 1);
    }
    waiver.contentHash = contentHash(waiver);
    if (flags['dry-run'] === true || flags.dryRun === true) {
      return emit({ ok: true, dryRun: true, path: null, waiver }, 0);
    }
    const dir = waiversDir();
    fs.mkdirSync(dir, { recursive: true });
    const ts = now.replace(/[:.]/g, '-');
    const h10 = String(waiver.contentHash).slice(0, 10);
    const fname = ts + '-' + h10 + '.json';
    const fp = path.join(dir, fname);
    fs.writeFileSync(fp, JSON.stringify(waiver, null, 2) + '\n', 'utf8');
    return emit({ ok: true, path: fp, waiver }, 0);
  }
  return emit({ error: 'waiver-subcommand', detail: 'usage: waiver list|check|create', got: sub || null }, 3);
}

// ===========================================================================
// S11 attributes  (quality attributes per module: the five-property governance layer)
// ===========================================================================
// A passing check proves it ran; it does not say what property it established. This layer
// closes the gap: modules declare which attributes they must hold evidence for (and how
// strongly), checks declare which attributes a passing run evidences, and coverage becomes
// decidable. Drawn from ISO/IEC 25010, narrowed to what a repository can hold evidence for.

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

/** Check ids in a module's resolved verification list whose spec claims `attr`. */
function claimingChecks(module, catalog, attr) {
  const out = [];
  for (const ref of requiredChecks(module && module.riskTier, module, catalog)) {
    const spec = resolveCheck(ref, catalog);
    if (Array.isArray(spec.attributes) && spec.attributes.includes(attr)) out.push(spec.id);
  }
  return out;
}

/**
 * Attribute coverage over executed check results (pure + injectable for selftest).
 * Coverage rules: an attribute is covered when a check the module itself selected claims
 * it and PASSed, and no claiming check FAILed/BLOCKED -- a demonstration of absence is
 * stronger evidence than a partial demonstration of presence. SKIPPED neither covers nor
 * contradicts. Declaring without wiring produces a visible gap, not silent success.
 * A `high` gap may be deferred by a waiver with scope "attribute:<module>/<attr>"
 * (the forbidden-keyword rule makes security/safety attribute waivers unrepresentable);
 * `critical` is beyond waiver.
 * @param {string[]} affectedIds
 * @param {Catalog} catalog
 * @param {Array<{module:string,id:string,state:string}>} checkResults
 * @param {Array<Waiver>} [waivers]
 * @returns {{attributes:Array,blockingGaps:Array}}
 */
function assessAttributes(affectedIds, catalog, checkResults, waivers = []) {
  const byId = new Map((catalog.modules || []).map(m => [m.id, m]));
  const attributes = [];
  const blockingGaps = [];
  for (const moduleId of (affectedIds || [])) {
    const m = byId.get(moduleId);
    if (!m || !m.attributes) continue;
    for (const [attr, req] of Object.entries(m.attributes)) {
      const { tier, reason } = normalizeTier(req);
      const enforcement = TIER_ENFORCEMENT[tier] || 'warn';
      if (tier === 'none') {
        attributes.push({ module: moduleId, attribute: attr, tier, enforcement, covered: true, evidence: [], reason: 'opted out: ' + reason });
        continue;
      }
      const claiming = claimingChecks(m, catalog, attr);
      const evidence = claiming.map(id => {
        const r = checkResults.find(c => c.module === moduleId && c.id === id);
        return { check: id, state: r ? r.state : 'MISSING' };
      });
      const passing = evidence.filter(e => e.state === 'PASS');
      const contradicting = evidence.filter(e => e.state === 'FAIL' || e.state === 'BLOCKED');
      const covered = passing.length > 0 && contradicting.length === 0;
      const entry = {
        module: moduleId, attribute: attr, tier, enforcement, covered, evidence,
        reason: contradicting.length > 0 ? 'contradicted by ' + contradicting.map(e => e.check + '(' + e.state + ')').join(',')
          : covered ? 'evidenced by ' + passing.map(e => e.check).join(',')
          : claiming.length === 0 ? 'no check in this module verification list claims ' + attr
          : 'claiming checks have not passed for the current change',
      };
      if (!covered && enforcement === 'block') {
        const w = tier === 'high' ? findWaiverForCheck('attribute:' + moduleId + '/' + attr, waivers) : null;
        if (w) {
          entry.waived = true;
          entry.reason = entry.reason + '; deferred by waiver:' + w.scope;
        } else {
          blockingGaps.push({ module: moduleId, attribute: attr, tier, reason: entry.reason });
        }
      }
      attributes.push(entry);
    }
  }
  return { attributes, blockingGaps };
}

/**
 * `attributes` subcommand: static wiring audit, no execution. For every module (or
 * --module <id>), report declared attributes, tier, enforcement, and which checks claim
 * them. A blocking-tier attribute with no claiming check is a visible gap -> exit 1.
 */
function cmdAttributes(flags) {
  const loaded = loadCatalog(typeof flags.catalog === 'string' ? flags.catalog : undefined);
  if (!loaded.ok) {
    return emit({ ok: false, degraded: true, error: loaded.error, detail: loaded.detail }, 3);
  }
  const catalog = loaded.catalog;
  const only = typeof flags.module === 'string' ? flags.module : null;
  const report = [];
  let unwiredBlocking = 0;
  const byTier = {};
  for (const m of (catalog.modules || [])) {
    if (only && m.id !== only) continue;
    for (const [attr, req] of Object.entries(m.attributes || {})) {
      const { tier, reason } = normalizeTier(req);
      const enforcement = TIER_ENFORCEMENT[tier] || 'warn';
      byTier[tier] = (byTier[tier] || 0) + 1;
      if (tier === 'none') {
        report.push({ module: m.id, attribute: attr, tier, enforcement, wired: [], reason });
        continue;
      }
      const wired = claimingChecks(m, catalog, attr);
      const entry = { module: m.id, attribute: attr, tier, enforcement, wired };
      if (wired.length === 0) {
        entry.gap = 'declared but no claiming check is wired';
        if (enforcement === 'block') unwiredBlocking++;
      }
      report.push(entry);
    }
  }
  return emit({ ok: unwiredBlocking === 0, declared: report.length, byTier, unwiredBlocking, attributes: report }, unwiredBlocking === 0 ? 0 : 1);
}

// ===========================================================================
// S12 arch-check  (declared graph vs real import edges; boundaries become executable)
// ===========================================================================
// The module graph is only a guardrail if the declaration is checked against what the
// code actually imports. A stale dependsOn under-reports impact, so the tests that should
// have run silently do not; a forbidden edge (privacy/layer boundary) that only lives in
// a document is crossed without anyone noticing. This makes both machine-checked.

const SOURCE_EXTS = new Set([
  '.js', '.mjs', '.cjs', '.jsx', '.ts', '.mts', '.cts', '.tsx',
  '.py', '.go', '.java', '.kt', '.kts', '.cs', '.rs', '.rb', '.php', '.swift', '.scala',
]);
const JS_EXTS = ['.ts', '.tsx', '.mts', '.cts', '.js', '.jsx', '.mjs', '.cjs'];

const IMPORT_PATTERNS = [
  { exts: /\.(m|c)?(j|t)sx?$/, patterns: [
    /\bimport\s+(?:[\w*{}\n\r\t, ]+\s+from\s+)?["']([^"']+)["']/g,
    /\bexport\s+(?:[\w*{}\n\r\t, ]+\s+)?from\s+["']([^"']+)["']/g,
    /\brequire\s*\(\s*["']([^"']+)["']\s*\)/g,
    /\bimport\s*\(\s*["']([^"']+)["']\s*\)/g,
  ] },
  { exts: /\.py$/, patterns: [/^[ \t]*from[ \t]+([.\w]+)[ \t]+import\b/gm, /^[ \t]*import[ \t]+([.\w]+)/gm] },
  { exts: /\.go$/, patterns: [/^[ \t]*(?:[\w.]+[ \t]+)?"([^"]+)"/gm] },
  { exts: /\.(java|kt|kts|scala)$/, patterns: [/^[ \t]*import[ \t]+(?:static[ \t]+)?([\w.]+)/gm] },
  { exts: /\.cs$/, patterns: [/^[ \t]*using[ \t]+(?:static[ \t]+)?([\w.]+)[ \t]*;/gm] },
  { exts: /\.rs$/, patterns: [/^[ \t]*use[ \t]+([\w:]+)/gm] },
  { exts: /\.rb$/, patterns: [/\brequire(?:_relative)?\s+["']([^"']+)["']/g] },
  { exts: /\.php$/, patterns: [/^[ \t]*use[ \t]+([\w\\]+)/gm] },
  { exts: /\.swift$/, patterns: [/^[ \t]*import[ \t]+([\w.]+)/gm] },
];

/** Import specifiers found in one source file (language chosen by extension). */
function extractImports(file, content) {
  const found = new Set();
  for (const group of IMPORT_PATTERNS) {
    if (!group.exts.test(file)) continue;
    for (const pattern of group.patterns) {
      pattern.lastIndex = 0;
      let m = pattern.exec(content);
      while (m) {
        if (m[1]) found.add(m[1]);
        m = pattern.exec(content);
      }
    }
  }
  return [...found];
}

/** Owning module id for a path, or null (classifyPath module priority applies). */
function moduleForPath(p, catalog) {
  const cls = classifyPath(p, catalog);
  return cls.kind === 'module' ? cls.moduleId : null;
}

/**
 * Resolve a relative import to a repo-relative file. TypeScript under NodeNext writes the
 * emitted extension in the specifier (`./x.js` importing x.ts), so the rewrite candidates
 * are required or the whole TS graph reads as unresolved.
 */
function resolveRelativeImport(root, fromFile, spec) {
  const base = path.resolve(path.dirname(path.resolve(root, fromFile)), spec);
  const candidates = [base, ...JS_EXTS.map(e => base + e)];
  const rewritten = base.replace(/\.(js|mjs|cjs|jsx)$/, '');
  if (rewritten !== base) for (const e of JS_EXTS) candidates.push(rewritten + e);
  for (const e of JS_EXTS) candidates.push(path.join(base, 'index' + e));
  candidates.push(base + '.py', path.join(base, '__init__.py'));
  for (const c of candidates) {
    let st;
    try { st = fs.statSync(c); } catch (_e) { continue; }
    if (!st.isFile()) continue;
    const rel = path.relative(root, c).replace(/\\/g, '/');
    if (rel.startsWith('..')) continue;
    return rel;
  }
  return null;
}

/** Module whose `provides` prefix matches a bare specifier (longest prefix wins). */
function moduleForSpecifier(catalog, spec) {
  let best = null;
  let bestLen = -1;
  for (const m of (catalog.modules || [])) {
    for (const p of (m.provides || [])) {
      if (spec !== p && !spec.startsWith(p + '/') && !spec.startsWith(p + '.')) continue;
      if (p.length > bestLen) { best = m; bestLen = p.length; }
    }
  }
  return best ? best.id : null;
}

/**
 * Layer rule: a layer may depend on itself or anything further inward (later in
 * catalog.layers). Reaching outward inverts the architecture -- the failure that boundary
 * documents never catch on their own. Returns a violation string or null.
 */
function layerViolation(catalog, fromModule, toModule) {
  const order = Array.isArray(catalog.layers) ? catalog.layers : [];
  if (!order.length || !fromModule || !toModule || !fromModule.layer || !toModule.layer) return null;
  const fi = order.indexOf(fromModule.layer);
  const ti = order.indexOf(toModule.layer);
  if (fi === -1 || ti === -1 || ti >= fi) return null;
  return 'layer ' + fromModule.layer + ' may not depend on outer layer ' + toModule.layer;
}

/** All cycles in an actual-edge map (id -> Set(dep)); DFS with a gray stack. */
function findCycles(edges) {
  const cycles = [];
  const state = new Map();
  const stack = [];
  const visit = (node) => {
    state.set(node, 1);
    stack.push(node);
    for (const next of (edges.get(node) || [])) {
      if (state.get(next) === 1) {
        const start = stack.indexOf(next);
        if (start !== -1) cycles.push([...stack.slice(start), next]);
      } else if (!state.has(next)) visit(next);
    }
    stack.pop();
    state.set(node, 2);
  };
  for (const node of edges.keys()) if (!state.has(node)) visit(node);
  return cycles;
}

function cmdArchCheck(flags) {
  const loaded = loadCatalog(typeof flags.catalog === 'string' ? flags.catalog : undefined);
  if (!loaded.ok) {
    return emit({ ok: false, degraded: true, error: loaded.error, detail: loaded.detail }, 3);
  }
  if (!isGitRepo()) {
    return emit({ ok: false, degraded: true, error: 'non-git', detail: 'arch-check enumerates tracked files via git' }, 3);
  }
  const catalog = loaded.catalog;
  const root = projectRoot();
  const maxFiles = (() => {
    const n = parseInt(flags['max-files'], 10);
    return (!Number.isNaN(n) && n > 0) ? n : 20000;
  })();

  const declared = new Map((catalog.modules || []).map(m => [m.id, new Set(m.dependsOn || [])]));
  const byId = new Map((catalog.modules || []).map(m => [m.id, m]));
  const actual = new Map((catalog.modules || []).map(m => [m.id, new Set()]));
  const forbidden = new Map();
  const undeclared = new Map();

  const t = trackedFiles(catalog.maxTrackedPaths);
  let scanned = 0;
  let unresolved = 0;
  let truncatedScan = t.truncated;
  for (const rel of t.paths) {
    if (scanned >= maxFiles) { truncatedScan = true; break; }
    const ext = rel.slice(rel.lastIndexOf('.'));
    if (!SOURCE_EXTS.has(ext)) continue;
    const owner = moduleForPath(rel, catalog);
    if (!owner) continue;
    let content;
    try {
      const st = fs.statSync(path.join(root, rel));
      if (!st.isFile() || st.size > 1500000) continue;   // oversized source is generated; skip
      content = fs.readFileSync(path.join(root, rel), 'utf8');
    } catch (_e) { continue; }
    scanned++;
    for (const spec of extractImports(rel, content)) {
      let target = null;
      if (spec.startsWith('.')) {
        const resolved = resolveRelativeImport(root, rel, spec);
        target = resolved ? moduleForPath(resolved, catalog) : null;
        if (!resolved) unresolved++;
      } else {
        target = moduleForSpecifier(catalog, spec);
        if (!target) unresolved++;
      }
      if (!target || target === owner) continue;
      actual.get(owner).add(target);
      const key = owner + '->' + target;
      const site = rel + ': ' + spec;
      // A forbidden edge outranks a declared one: the prohibition is the stronger statement.
      const rule = (byId.get(owner).forbiddenDependencies || []).includes(target)
        ? owner + ' forbids depending on ' + target
        : layerViolation(catalog, byId.get(owner), byId.get(target));
      if (rule) {
        const entry = forbidden.get(key) || { from: owner, to: target, rule, evidence: [] };
        if (entry.evidence.length < 5) entry.evidence.push(site);
        forbidden.set(key, entry);
        continue;
      }
      if (declared.get(owner).has(target)) continue;
      const entry = undeclared.get(key) || { from: owner, to: target, evidence: [] };
      if (entry.evidence.length < 5) entry.evidence.push(site);
      undeclared.set(key, entry);
    }
  }

  // A declaration with no matching import over-reports impact: safe for testing, but the
  // boundary is no longer real. Reported without failing the check.
  const unusedDeclarations = [];
  for (const [id, deps] of declared) {
    for (const d of deps) {
      if (!(actual.get(id) || new Set()).has(d)) unusedDeclarations.push({ from: id, to: d });
    }
  }
  const cycles = findCycles(actual);
  const resolvedEdges = [...actual.values()].reduce((a, s) => a + s.size, 0);
  const notes = [];
  if (scanned > 0 && resolvedEdges === 0) {
    // Passing with no resolved edges means nothing was exercised -- legitimate for a
    // genuinely self-contained catalog, a blind spot for anything else. Say so.
    notes.push('no cross-module import edge resolved across ' + scanned + ' scanned files; '
      + (unresolved > 0 ? unresolved + ' specifiers unattributed -- add `provides` prefixes for package-name imports' : 'expected only when modules are genuinely self-contained'));
  }
  if (truncatedScan) notes.push('scan truncated at ' + Math.min(maxFiles, t.paths.length) + ' files; coverage incomplete');

  const ok = forbidden.size === 0 && undeclared.size === 0 && cycles.length === 0;
  const sortEdges = (a, z) => (a.from + '->' + a.to).localeCompare(z.from + '->' + z.to);
  // --record: snapshot drift metrics into the trend ledger (S16) even when failing --
  // a legacy repo records its debt baseline first, then arch-trend --gate ratchets it.
  let recordedTo = null;
  if (flags.record === true) {
    try {
      recordedTo = appendTrendRecord({
        at: new Date().toISOString(), headCommit: headCommit(),
        scannedFiles: scanned, truncated: truncatedScan, resolvedEdges,
        undeclared: undeclared.size, forbidden: forbidden.size, cycles: cycles.length,
        unused: unusedDeclarations.length, unresolved,
      });
      recordedTo = path.relative(projectRoot(), recordedTo).replace(/\\/g, '/');
    } catch (e) {
      process.stderr.write('arch-check: trend record failed: ' + String(e && e.message || e) + '\n');
    }
  }
  return emit({
    ok, scannedFiles: scanned, truncated: truncatedScan, unresolvedImports: unresolved, resolvedEdges, notes,
    recordedTo,
    edges: [...actual].map(([id, s]) => ({ module: id, dependsOn: [...s].sort() })),
    forbiddenDependencies: [...forbidden.values()].sort(sortEdges),
    undeclaredDependencies: [...undeclared.values()].sort(sortEdges),
    unusedDeclarations: unusedDeclarations.sort(sortEdges),
    cycles,
  }, ok ? 0 : 1);
}

// ===========================================================================
// S13 fitness  (built-in day-one quality-attribute rules; no external tools)
// ===========================================================================
// Pattern rules that need no toolchain, so they work immediately in any language:
// credential literals, personal data in logs, silent failure handlers, unbounded retry
// loops, unreferenced deferral markers. Heuristics over text -- they reduce the set of
// defects nobody looked for; they do not establish that a property holds. Suppress one
// finding with `harness-fitness:ignore` on the line or the line above.

const FITNESS_IGNORE = 'harness-fitness:ignore';

const DEFAULT_FITNESS_RULES = [
  {
    id: 'no-secret-literal', attributes: ['security'], severity: 'error',
    forbid: '(?:api[_-]?key|secret|password|passwd|token|private[_-]?key|credential)\\s*[:=]\\s*["\'][A-Za-z0-9/+_\\-]{16,}["\']'
      + '|["\'](?:sk|pk|rk)[_-]live[_-][A-Za-z0-9]{12,}["\']'
      + '|["\']gh[pousr]_[A-Za-z0-9]{16,}["\']'
      + '|["\']xox[abposr]-[A-Za-z0-9-]{10,}["\']'
      + '|["\']AKIA[0-9A-Z]{16}["\']'
      + '|-----BEGIN (?:RSA |EC |OPENSSH |PGP )?PRIVATE KEY-----',
    rationale: 'a credential written into source is published the moment the repository is shared',
    fix: 'read the value from the environment or a secrets manager; keep only a placeholder in code',
  },
  {
    id: 'no-pii-in-logs', attributes: ['privacy'], severity: 'error',
    forbid: '(?:log|logger|console|print|println|fmt\\.Print\\w*)[.\\w]*\\s*\\([^)\\n]*\\b(?:email|e_mail|ssn|social_security|passport|credit_card|card_number|phone_number|date_of_birth|dob|national_id|id_card)\\b',
    rationale: 'personal data in logs spreads to systems with weaker access control and longer retention',
    fix: 'log a stable pseudonymous identifier instead of the personal field',
  },
  {
    id: 'no-silent-failure', attributes: ['reliability'], severity: 'error',
    forbid: 'catch\\s*(?:\\([^)]*\\))?\\s*\\{\\s*\\}|except[^:\\n]*:\\s*(?:pass|\\.\\.\\.)\\s*$',
    rationale: 'an empty handler converts a failure into a wrong answer that nothing reports',
    fix: 'handle the error, rethrow it, or log it with enough context to diagnose',
  },
  {
    id: 'no-unbounded-retry', attributes: ['resilience'], severity: 'warning',
    forbid: '(?:while\\s*\\(\\s*true\\s*\\)|while\\s+True\\s*:|for\\s*\\(\\s*;\\s*;\\s*\\))[\\s\\S]{0,240}?\\b(?:retry|reconnect|fetch|request|poll)\\b',
    rationale: 'a retry loop with no bound or backoff turns a transient fault into a sustained outage',
    fix: 'add a maximum attempt count and exponential backoff with jitter',
  },
  {
    id: 'no-unreferenced-deferral', attributes: ['safety'], severity: 'warning', minimumTier: 'high',
    forbid: '\\b(?:TODO|FIXME|XXX|HACK)\\b(?![^\\n]*\\b(?:issue|ticket|#\\d+)\\b)',
    rationale: 'an unreferenced marker in a high-tier module is work nobody has agreed to do',
    fix: 'link the marker to a tracked issue, or resolve it',
  },
];

/** Built-in rules, optionally extended/replaced by .claude/harness/fitness-rules.json. */
function loadFitnessRules() {
  const fp = path.join(projectRoot(), '.claude', 'harness', 'fitness-rules.json');
  if (!fs.existsSync(fp)) return DEFAULT_FITNESS_RULES;
  let raw;
  try { raw = JSON.parse(fs.readFileSync(fp, 'utf8')); } catch (_e) { return DEFAULT_FITNESS_RULES; }
  if (!raw || !Array.isArray(raw.rules)) return DEFAULT_FITNESS_RULES;
  const extra = raw.rules.filter(r => r && typeof r.id === 'string' && typeof r.forbid === 'string');
  return raw.replace === true ? extra : [...DEFAULT_FITNESS_RULES, ...extra];
}

/** True when the owner module declared one of the rule's attributes at >= rule.minimumTier. */
function meetsMinimumTier(module, rule) {
  if (!module) return false;
  const floor = TIER_RANK[rule.minimumTier] || 0;
  const declared = module.attributes || {};
  return (rule.attributes || []).some(attr => {
    const req = declared[attr];
    if (req === undefined) return false;
    return (TIER_RANK[normalizeTier(req).tier] || 0) >= floor;
  });
}

/** True when the owner module set every one of the rule's attributes to none. */
function ruleOptedOut(module, rule) {
  if (!module || !(rule.attributes || []).length) return false;
  const declared = module.attributes || {};
  return rule.attributes.every(attr => {
    const req = declared[attr];
    if (req === undefined) return false;
    return normalizeTier(req).tier === 'none';
  });
}

/**
 * Scan file contents against fitness rules (pure over provided contents; injectable for
 * selftest). Suppression marker on the finding line or the line above kills one finding.
 * @param {Array<{path:string,content:string}>} files
 * @param {Catalog|null} catalog     module scoping (minimumTier/opt-out); null = no scoping
 * @param {Array} rules
 * @returns {Array} findings
 */
function scanFitness(files, catalog, rules) {
  const findings = [];
  for (const f of files) {
    const owner = catalog ? (() => {
      const id = moduleForPath(f.path, catalog);
      return id ? (catalog.modules || []).find(m => m.id === id) : null;
    })() : null;
    const lines = f.content.split('\n');
    for (const rule of rules) {
      if (rule.appliesTo && rule.appliesTo.length && !matchAny(f.path, rule.appliesTo)) continue;
      if (owner && ruleOptedOut(owner, rule)) continue;
      if (rule.minimumTier && !meetsMinimumTier(owner, rule)) continue;
      let pattern;
      try { pattern = new RegExp(rule.forbid, 'gmi'); } catch (_e) { continue; }
      let m = pattern.exec(f.content);
      while (m) {
        const line = f.content.slice(0, m.index).split('\n').length;
        const suppressed = (lines[line - 1] || '').includes(FITNESS_IGNORE) || (lines[line - 2] || '').includes(FITNESS_IGNORE);
        if (!suppressed) {
          findings.push({
            rule: rule.id, attributes: rule.attributes || [], severity: rule.severity || 'warning',
            module: owner ? owner.id : null, path: f.path, line,
            excerpt: String(lines[line - 1] || '').trim().slice(0, 200),
            rationale: rule.rationale || '', fix: rule.fix || '',
          });
        }
        if (m.index === pattern.lastIndex) pattern.lastIndex++;
        m = pattern.exec(f.content);
      }
    }
  }
  return findings;
}

function cmdFitness(flags) {
  const loaded = loadCatalog(typeof flags.catalog === 'string' ? flags.catalog : undefined);
  const catalog = loaded.ok ? loaded.catalog : null;
  const rules = loadFitnessRules();
  const root = projectRoot();
  let subjects;
  if (typeof flags.paths === 'string') {
    subjects = parseCsv(flags.paths);
  } else if (flags.all === true) {
    if (!isGitRepo()) return emit({ ok: false, degraded: true, error: 'non-git', detail: 'fitness --all enumerates tracked files via git' }, 3);
    subjects = trackedFiles(catalog && catalog.maxTrackedPaths).paths;
  } else {
    const cp = changedPaths();
    subjects = Array.isArray(cp) ? cp : cp.paths;
  }
  const files = [];
  for (const p of subjects) {
    const ext = p.slice(p.lastIndexOf('.'));
    if (!SOURCE_EXTS.has(ext)) continue;
    if (isDenied(p) || isStateExcluded(p)) continue;
    let content;
    try {
      const st = fs.statSync(path.join(root, p));
      if (!st.isFile() || st.size > 1000000) continue;
      const buf = fs.readFileSync(path.join(root, p));
      if (buf.includes(0)) continue;   // binary
      content = buf.toString('utf8');
    } catch (_e) { continue; }
    files.push({ path: p.replace(/\\/g, '/'), content });
  }
  const findings = scanFitness(files, catalog, rules);
  const errors = findings.filter(f => f.severity === 'error');
  return emit({
    ok: errors.length === 0,
    scope: flags.all === true ? 'all-tracked' : (typeof flags.paths === 'string' ? 'explicit' : 'changed'),
    scannedFiles: files.length, rules: rules.length,
    counts: {
      error: errors.length,
      warning: findings.filter(f => f.severity === 'warning').length,
      info: findings.filter(f => f.severity === 'info').length,
    },
    findings: findings.slice(0, 200),
  }, errors.length === 0 ? 0 : 1);
}

// ===========================================================================
// S14 adapters  (curated external tools mapped to attributes; nothing bundled)
// ===========================================================================
// The harness installs nothing. `adapters list` shows curated command templates with the
// attributes they evidence and whether the executable is on PATH; `adapters add <id>`
// wires the check into catalog.checks. Wiring is only half the job: nothing selects the
// check until a module lists it in `verification` (or a riskChecks tier includes it).

function adaptersFilePath() {
  const local = path.join(projectRoot(), '.claude', 'harness', 'adapters.json');
  if (fs.existsSync(local)) return local;
  return path.join(HARNESS_DIR, 'adapters.json');
}

function loadAdapters() {
  let raw;
  try { raw = JSON.parse(fs.readFileSync(adaptersFilePath(), 'utf8')); } catch (_e) { return []; }
  return (raw && Array.isArray(raw.adapters)) ? raw.adapters : [];
}

function cmdAdapters(flags, positional = []) {
  const sub = positional[0] || 'list';
  const catalogue = loadAdapters();
  if (sub === 'list') {
    const want = typeof flags.attribute === 'string' ? flags.attribute : null;
    const loaded = loadCatalog(typeof flags.catalog === 'string' ? flags.catalog : undefined);
    const wiredIds = loaded.ok ? Object.keys(loaded.catalog.checks || {}) : [];
    const list = catalogue
      .filter(a => !want || (a.attributes || []).includes(want))
      .map(a => ({
        id: a.id, attributes: a.attributes || [], class: a.class, executable: a.executable,
        available: whichCmd(a.executable), wired: wiredIds.includes(a.id),
        install: a.install, rationale: a.rationale,
      }));
    return emit({ ok: true, adapters: list }, 0);
  }
  if (sub === 'add') {
    const id = positional[1] || (typeof flags.id === 'string' ? flags.id : '');
    const adapter = catalogue.find(a => a.id === id);
    if (!adapter) return emit({ ok: false, error: 'adapter-unknown', detail: id || null }, 1);
    const cp = typeof flags.catalog === 'string' ? flags.catalog : catalogFilePath();
    const loaded = loadCatalog(cp);
    if (!loaded.ok) return emit({ ok: false, degraded: true, error: loaded.error, detail: loaded.detail }, 3);
    const catalog = loaded.catalog;
    catalog.checks = catalog.checks || {};
    const already = !!catalog.checks[adapter.id];
    catalog.checks[adapter.id] = {
      command: adapter.command, class: adapter.class,
      ...(Array.isArray(adapter.attributes) ? { attributes: adapter.attributes } : {}),
    };
    if (flags['dry-run'] !== true && flags.dryRun !== true) {
      fs.writeFileSync(cp, JSON.stringify(catalog, null, 2) + '\n', 'utf8');
    }
    return emit({
      ok: true, id: adapter.id, changed: !already, dryRun: flags['dry-run'] === true || flags.dryRun === true,
      executableAvailable: whichCmd(adapter.executable), install: adapter.install,
      nextStep: 'add "' + adapter.id + '" to the verification list of every module that needs ' + (adapter.attributes || []).join('/') + ' evidence',
    }, 0);
  }
  return emit({ error: 'adapters-subcommand', detail: 'usage: adapters list|add <id>', got: sub || null }, 3);
}

// ===========================================================================
// S15 adr-check  (an architecture decision nothing checks is one the codebase drifts from)
// ===========================================================================
// Every active ADR must name how it is enforced. A phantom reference (naming a check or
// rule that does not exist) is worse than none, because it reads as enforced. Explicitly
// manual enforcement is accepted but reported separately -- an honest "a human guards
// this" beats a fake machine claim. Retired ADRs (superseded/deprecated/rejected) are
// exempt: they no longer bind anyone.
//
// Sources scanned: inline `### ADR-xxx` blocks in Architecture-Design.md (arch-designer
// format) and standalone docs/adr/*.md files (one record per file). Both optional.

const ADR_RETIRED_RE = /superseded|deprecated|rejected|retired|\u5df2\u5e9f\u5f03|\u5e9f\u5f03|\u5df2\u53d6\u4ee3|\u5df2\u5426\u51b3|\u5df2\u66ff\u4ee3/i;
const ADR_MANUAL_RE = /\u4eba\u5de5|\u8bc4\u5ba1|manual|review/i;
// Harness capabilities that ARE machine enforcement when named directly.
const ADR_HARNESS_CAPS = ['arch-check', 'forbiddendependencies', 'layers', 'catalog-lint', 'fitness', 'verify', 'receipt', 'attributes', 'stop-gate', 'pre-commit', 'supervisor', 'arch-trend'];

/** Strip markdown decoration and template brackets from a field value. */
function stripMdDecoration(s) {
  return String(s == null ? '' : s).replace(/\*\*|`|\[|\]/g, '').trim();
}

/** First `- **字段**：value` / `字段: value` style line for any of the given labels. */
function adrField(block, labels) {
  for (const label of labels) {
    const re = new RegExp('(?:^|\\n)\\s*[-*]?\\s*(?:\\*\\*)?' + label + '(?:\\*\\*)?\\s*[:\\uFF1A]\\s*([^\\n]+)', 'i');
    const m = re.exec(block);
    if (m) return stripMdDecoration(m[1]);
  }
  return '';
}

/**
 * Parse inline `### ADR-xxx` blocks out of a markdown document (pure; injectable).
 * @param {string} content
 * @returns {Array<{id:string,title:string,status:string,enforcedRaw:string}>}
 */
function parseInlineAdrs(content) {
  const text = String(content == null ? '' : content).replace(/\r\n?/g, '\n');
  const out = [];
  const heading = /^###\s*(ADR-[A-Za-z0-9._-]+)\s*[:\uFF1A]?\s*(.*)$/gm;
  const starts = [];
  let m = heading.exec(text);
  while (m) {
    starts.push({ id: m[1], title: stripMdDecoration(m[2]), at: m.index, bodyFrom: m.index + m[0].length });
    m = heading.exec(text);
  }
  for (let i = 0; i < starts.length; i++) {
    const from = starts[i].bodyFrom;
    // Block ends at the next heading of ### or shallower (##, #), or EOF.
    const nextHeading = text.slice(from).search(/\n#{1,3}\s/);
    const block = nextHeading === -1 ? text.slice(from) : text.slice(from, from + nextHeading);
    out.push({
      id: starts[i].id,
      title: starts[i].title,
      status: adrField(block, ['\u72b6\u6001', 'Status']) || 'accepted',
      enforcedRaw: adrField(block, ['\u6267\u6cd5\u65b9\u5f0f', 'Enforced-by', 'Enforced by']),
    });
  }
  return out;
}

/**
 * Resolve one enforcement fragment against known ids (pure).
 * Longest known token wins so "arch-check 禁边" resolves to arch-check, and a catalog
 * check id embedded in prose still counts.
 * @returns {{kind:('check'|'fitness-rule'|'harness'|'manual'|'unknown'),id?:string,text:string}|null}
 */
function resolveEnforcement(fragment, knownChecks, knownRules) {
  const f = stripMdDecoration(fragment);
  if (!f) return null;
  const lower = f.toLowerCase();
  let best = null;
  const consider = (kind, id) => {
    if (!id) return;
    if (lower.includes(String(id).toLowerCase())) {
      if (!best || String(id).length > String(best.id).length) best = { kind, id: String(id), text: f };
    }
  };
  for (const id of (knownChecks || [])) consider('check', id);
  for (const id of (knownRules || [])) consider('fitness-rule', id);
  for (const cap of ADR_HARNESS_CAPS) consider('harness', cap);
  if (best) return best;
  if (ADR_MANUAL_RE.test(f)) return { kind: 'manual', text: f };
  return { kind: 'unknown', text: f };
}

/**
 * Assess ADR records (pure): an active record passes when its enforcement resolves to at
 * least one known machine token or an explicit manual marker; zero recognizable tokens
 * (missing field, or only phantom names) fails. Unrecognized fragments riding along a
 * known one are surfaced, not failed -- prose is allowed, silence about it is not.
 * @param {Array<{id,title?,status,enforcedRaw,source?}>} records
 * @param {string[]} knownChecks
 * @param {string[]} knownRules
 */
function assessAdrRecords(records, knownChecks, knownRules) {
  const out = [];
  for (const r of (records || [])) {
    const retired = ADR_RETIRED_RE.test(String(r.status || ''));
    const fragments = String(r.enforcedRaw || '').split(/[,\uFF0C\u3001;\uFF1B/]+/).map(s => s.trim()).filter(Boolean);
    const resolved = fragments.map(f => resolveEnforcement(f, knownChecks, knownRules)).filter(Boolean);
    const machine = resolved.filter(t => t.kind === 'check' || t.kind === 'fitness-rule' || t.kind === 'harness');
    const manual = resolved.filter(t => t.kind === 'manual');
    const unknown = resolved.filter(t => t.kind === 'unknown');
    const recognized = machine.length + manual.length;
    const ok = retired || recognized > 0;
    out.push({
      id: r.id, source: r.source || null, status: r.status || 'accepted', retired,
      ok,
      machineEnforced: machine.map(t => ({ kind: t.kind, id: t.id })),
      manualOnly: !retired && machine.length === 0 && manual.length > 0,
      unrecognized: unknown.map(t => t.text),
      reason: retired ? 'retired; exempt'
        : recognized === 0 && fragments.length === 0 ? 'no enforcement declared (\u6267\u6cd5\u65b9\u5f0f/Enforced-by missing)'
        : recognized === 0 ? 'names nothing recognizable (phantom reference reads as enforced but is not)'
        : machine.length > 0 ? 'machine-enforced'
        : 'manual enforcement declared',
    });
  }
  return { records: out, failing: out.filter(r => !r.ok) };
}

/** Standalone ADR files: docs/adr/*.md, one record per file (cursor-style layout). */
function parseAdrDir(dir) {
  let names;
  try { names = fs.readdirSync(dir); } catch (_e) { return []; }
  const out = [];
  for (const n of names.sort()) {
    if (!n.endsWith('.md')) continue;
    let content;
    try { content = fs.readFileSync(path.join(dir, n), 'utf8'); } catch (_e) { continue; }
    out.push({
      id: n.replace(/\.md$/, ''),
      source: path.join(dir, n),
      status: adrField(content, ['\u72b6\u6001', 'Status']) || 'accepted',
      enforcedRaw: adrField(content, ['\u6267\u6cd5\u65b9\u5f0f', 'Enforced-by', 'Enforced by']),
    });
  }
  return out;
}

function cmdAdrCheck(flags) {
  const root = projectRoot();
  const file = typeof flags.file === 'string' ? flags.file : 'Architecture-Design.md';
  const dir = typeof flags.dir === 'string' ? flags.dir : 'docs/adr';
  const records = [];
  const filePath = path.join(root, file);
  if (fs.existsSync(filePath)) {
    let content = '';
    try { content = fs.readFileSync(filePath, 'utf8'); } catch (_e) { /* unreadable -> no records */ }
    for (const r of parseInlineAdrs(content)) records.push({ ...r, source: file });
  }
  for (const r of parseAdrDir(path.join(root, dir))) records.push(r);
  if (records.length === 0) {
    return emit({ ok: true, records: 0, note: 'no ADR records found (' + file + ' / ' + dir + '); nothing to enforce' }, 0);
  }
  const loaded = loadCatalog(typeof flags.catalog === 'string' ? flags.catalog : undefined);
  const knownChecks = loaded.ok ? Object.keys(loaded.catalog.checks || {}) : [];
  const knownRules = loadFitnessRules().map(r => r.id);
  const assessed = assessAdrRecords(records, knownChecks, knownRules);
  return emit({
    ok: assessed.failing.length === 0,
    records: assessed.records.length,
    machineEnforced: assessed.records.filter(r => r.ok && !r.retired && !r.manualOnly).length,
    manualOnly: assessed.records.filter(r => r.manualOnly).map(r => r.id),
    retired: assessed.records.filter(r => r.retired).map(r => r.id),
    failing: assessed.failing.map(r => ({ id: r.id, source: r.source, reason: r.reason, unrecognized: r.unrecognized })),
    details: assessed.records,
  }, assessed.failing.length === 0 ? 0 : 1);
}

// ===========================================================================
// S16 arch-trend  (drift ratchet: legacy debt may exist, new debt may not)
// ===========================================================================
// arch-check exits 1 on any undeclared edge, which is unusable as a gate on a legacy
// repository that starts life with drift. The trend ledger gives an adoption path:
// `arch-check --record` snapshots the drift metrics, and `arch-trend --gate` fails only
// when the latest snapshot exceeds the best (minimum) historical value -- the ratchet
// only turns one way. Records live in git-ignored runtime state and never perturb the
// diff fingerprint.

const TREND_METRICS = ['undeclared', 'forbidden', 'cycles', 'unused', 'unresolved'];
const TREND_MAX_LINES = 1000;
const TREND_KEEP_LINES = 500;

function trendFilePath() {
  return path.join(projectRoot(), '.claude', 'harness', 'trend', 'arch-trend.jsonl');
}

/** Append one snapshot; rewrite keeping the newest half when the ledger grows too long. */
function appendTrendRecord(snap) {
  const fp = trendFilePath();
  fs.mkdirSync(path.dirname(fp), { recursive: true });
  let lines = [];
  try { lines = fs.readFileSync(fp, 'utf8').split('\n').filter(Boolean); } catch (_e) { lines = []; }
  if (lines.length >= TREND_MAX_LINES) lines = lines.slice(-TREND_KEEP_LINES);
  lines.push(JSON.stringify(snap));
  fs.writeFileSync(fp, lines.join('\n') + '\n', 'utf8');
  return fp;
}

function loadTrend() {
  let lines;
  try { lines = fs.readFileSync(trendFilePath(), 'utf8').split('\n').filter(Boolean); } catch (_e) { return []; }
  const out = [];
  for (const l of lines) {
    try { out.push(JSON.parse(l)); } catch (_e) { /* skip bad line */ }
  }
  return out;
}

/**
 * Ratchet comparison (pure): latest vs the minimum over all prior records, per metric.
 * One record -> baseline established, nothing to compare. Regression = latest > min(prior).
 * @param {Array<Object>} records
 * @returns {{comparable:boolean,regressed:Array,improved:Array,summary:Object}}
 */
function compareRatchet(records) {
  const list = Array.isArray(records) ? records : [];
  if (list.length === 0) return { comparable: false, regressed: [], improved: [], summary: {} };
  const latest = list[list.length - 1];
  const summary = {};
  const regressed = [];
  const improved = [];
  for (const m of TREND_METRICS) {
    const series = list.map(r => Number(r[m] || 0));
    const latestV = series[series.length - 1];
    const prior = series.slice(0, -1);
    const minPrior = prior.length ? Math.min(...prior) : null;
    summary[m] = {
      baseline: series[0], latest: latestV,
      min: Math.min(...series),
      deltaVsPrev: prior.length ? latestV - series[series.length - 2] : 0,
    };
    if (minPrior === null) continue;
    // Only the drift metrics ratchet; unresolved/unused are context, not debt.
    if ((m === 'undeclared' || m === 'forbidden' || m === 'cycles') && latestV > minPrior) {
      regressed.push({ metric: m, latest: latestV, bestBefore: minPrior });
    } else if (latestV < minPrior) {
      improved.push({ metric: m, latest: latestV, bestBefore: minPrior });
    }
  }
  return { comparable: list.length >= 2, regressed, improved, summary };
}

function cmdArchTrend(flags) {
  const records = loadTrend();
  if (records.length === 0) {
    return emit({ ok: true, records: 0, note: 'no trend data; run `arch-check --record` to establish a baseline' }, 0);
  }
  const cmp = compareRatchet(records);
  const latest = records[records.length - 1];
  const gate = flags.gate === true;
  const ok = !gate || cmp.regressed.length === 0;
  return emit({
    ok,
    gate,
    records: records.length,
    comparable: cmp.comparable,
    latestAt: latest.at || null,
    latestCommit: latest.headCommit || null,
    truncatedMixed: records.some(r => r.truncated) !== records.every(r => r.truncated) ? records.some(r => r.truncated) : false,
    summary: cmp.summary,
    regressed: cmp.regressed,
    improved: cmp.improved,
    note: !cmp.comparable ? 'baseline established; ratchet activates from the second record'
      : cmp.regressed.length ? 'drift ratchet violated: new architectural debt exceeds the best recorded state'
      : 'no new drift beyond the best recorded state',
  }, ok ? 0 : 1);
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

main();
