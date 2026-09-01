// lib/selftest.mjs -- the inline regression assertions and their fixture. Kept apart from
// the CLI so the case list can grow without pushing the dispatch surface around; cmdSelftest
// in harness.mjs runs them. Imports from every other module, and nothing imports this one.

import assert from 'node:assert';
import path from 'node:path';
import { HARNESS_DIR, isDenied, matchAny, normalizeTier, specificity, splitNul } from './core.mjs';
import { classifyPath, lintCatalog, loadCatalog } from './catalog.mjs';
import {
  analyzeImpact, compareRatchet, extractImports, findCycles, layerViolation, moduleForSpecifier,
} from './graph.mjs';
import { buildPack } from './context.mjs';
import {
  aggregateStates, applyWaiver, assessAttributes, claimingChecks, contentHash, findWaiverForCheck,
  matchReceipts, receiptIntact, requiredChecks, runCheck, safeTaskId, validateWaiver, verifyPlan,
} from './quality.mjs';
import {
  DEFAULT_FITNESS_RULES, assessAdrRecords, parseInlineAdrs, resolveEnforcement, scanFitness,
} from './scan.mjs';

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
      const f = scanFitness([{ path: 'src/cfg.ts', content: 'const apiKey = "AKIAABCDEFGHIJKLMNOP";\n' }], null, DEFAULT_FITNESS_RULES);  // scan-secrets:ignore fixture
      assert.ok(f.some(x => x.rule === 'no-secret-literal' && x.severity === 'error'));
    }],
    ['fitness: suppression marker kills exactly that finding', () => {
      const content = '// harness-fitness:ignore\nconst password = "abcdefghijklmnop123456";\n';  // scan-secrets:ignore fixture
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

export { selftestCases, attrCatalog };
