// lib/selftest.mjs -- the inline regression assertions and their fixture. Kept apart from
// the CLI so the case list can grow without pushing the dispatch surface around; cmdSelftest
// in harness.mjs runs them. Imports from every other module, and nothing imports this one.

import assert from 'node:assert';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import {
  HARNESS_DIR, isDenied, matchAny, normalizeTier, specificity, splitNul, withDirLock,
} from './core.mjs';
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
import {
  GENESIS, appendLedger, auditGates, buildPlan, chainHash, endsWithNewline, evidenceFindings,
  gateReason, ledgerFilePath, ledgerLine, ledgerReferencedEvidence, ledgerReport,
  parseLedgerLines, planRetention, retentionRefusal, riskFindings, sha256Lf, suppressionOf,
  verifyLedgerChain, waiversApplied,
} from './evidence.mjs';
import {
  acceptingReceipt, assessBudget, buildTaskRecord, completeBlockers, latestGateRecord,
  validateEnvelope,
} from './task.mjs';
import {
  AMBIGUOUS_TERMS, PLACEHOLDER_TOKENS, REQUIRED_SECTIONS, REQUIREMENT_SECTION,
  collectReferences, dodStatus, dodVerdict, lintSpecDoc, parseRequirements, placeholderBrackets,
  renderSpecView, splitSections, traceReport,
} from './spec.mjs';
import {
  REVIEW_PROFILES, authorSetFor, authorshipStatus, backlogViolations, computeVerdict,
  currentStage, deletionAudit, freshness, lensExclusions, parseAuthorshipLines, parseNameStatus,
  reviewLenses, selfReviewedLenses, stagePassed, validateClaims, validateFindings,
} from './review.mjs';
import {
  ARCHIVABLE_SECTIONS, IRON_LAW_MARK, SECTION_PINNED,
  applyArchivePlan, entryOrder, extractIronLaws, headline, isTrackedWork, planArchive,
  renderView, sectionEntries, stateLines, syncFindings,
} from './memory.mjs';

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
  // The interpreter already running, by absolute path. whichCmd resolves a name containing a
  // separator with existsSync and a bare name against PATH, so a bare "node" here would make
  // these cases depend on where the machine keeps node -- and the golden runner pins PATH to
  // git's directory plus /usr/bin:/bin, which on a hosted runner has no node in it. The PATH
  // lookup branch stays covered by the "missing binary -> BLOCKED" case below.
  const NODE = process.execPath;

  const good = loadFx('catalog-good.json');
  // A tracked set where every path is claimed by a module/global/ignored (no unmapped/overlap).
  const goodTracked = ['core/index.ts', 'db/schema.ts', 'auth/login.ts', 'api/routes.ts', 'package.json', 'README.md', 'docs/guide.md'];

  // S17/S18 fixtures. chainLines() links records exactly the way appendLedger does, so the
  // tamper cases below start from a chain that is genuinely valid rather than one hand-built
  // to pass -- a forgery detector proved against a forged baseline detects nothing.
  const chainLines = (records) => {
    const out = [];
    let prev = GENESIS;
    for (const r of records) { const line = ledgerLine(r, prev); prev = line.chain; out.push(line); }
    return out;
  };
  const gateRec = (over = {}) => ({
    command: 'gate', at: '2020-01-01T00:00:00.000Z', gate: 'PASS',
    reason: 'all-executed-checks-passed', diffHash: 'D0', planHash: 'P0',
    scopeSource: 'computed', scopeRequested: null,
    modules: ['pay'], degraded: false, fastActive: false, skippedByFastMode: [], results: [],
    ...over,
  });
  const envelope = (over = {}) => ({
    id: 'T1', goal: 'g', scope: 's', outOfScope: 'o',
    existingPattern: 'p', verification: 'v', escalation: 'e', ...over,
  });
  const okReceipt = (over = {}) => {
    const r = { taskId: 'T1', baseCommit: 'c0', diffHash: 'D0', reviewer: 'rev', verdict: 'ACCEPT', scope: 's', timestamp: '2020-01-01T00:00:00.000Z', ...over };
    r.contentHash = contentHash(r);
    return r;
  };
  const budgetCat = { maxChangedFiles: 3, maxChangedLines: 100, maxModulesTouched: 2, maxNewFiles: 1 };

  // S20 fixtures. A session is built from the same shape review start writes, and a lens
  // report from the shape recordLens stores, so a change to either surface breaks these
  // rather than leaving them asserting against a shape nothing produces any more.
  const lensRec = (over = {}) => ({ at: '2020-01-01T00:00:00.000Z', agentId: null, unable: false, unableReason: null, findings: [], ...over });
  const errFinding = { severity: 'error', location: 'src/a.js:12', reproduction: null, summary: 'off by one' };
  const reviewSession = (over = {}) => ({
    version: 1, diffHash: 'D0', baseCommit: 'c0', startedAt: '2020-01-01T00:00:00.000Z',
    scope: '', packPath: null, profile: 'regulated', catalogPresent: true, affected: ['core'],
    requiredLenses: ['correctness', 'architecture', 'testing', 'security'],
    excludedLenses: [], lineage: [], blue: { at: '2020-01-01T00:00:00.000Z', claims: [{ statement: 's', evidence: 'e' }] },
    lenses: {}, backlog: [], verdict: null, ...over,
  });
  const allClean = { correctness: lensRec(), architecture: lensRec(), testing: lensRec(), security: lensRec() };

  // S19 fixture. The section labels come from the module rather than being re-escaped here:
  // the runtime source is ASCII-only, and a second hand-escaped copy of four Chinese headings
  // is a transcription error waiting to happen. What the labels ARE is asserted where it can
  // be read -- the checked-in sample document under tests/fixtures/golden, which the golden
  // matrix runs spec-lint against for real.
  const [S_OVERVIEW, S_SCENARIO, S_REQUIREMENT, S_TECH] = REQUIRED_SECTIONS;
  const specDoc = (requirementLines, over = {}) => [
    '# Product Spec',
    '',
    '## ' + S_OVERVIEW,
    over.overview === undefined ? 'a tool for small teams; the user is the part-time bookkeeper' : over.overview,
    '',
    '## ' + S_SCENARIO,
    over.scenario === undefined ? '- month end: import the statement, read the report' : over.scenario,
    '',
    '## ' + S_REQUIREMENT,
    ...requirementLines,
    '',
    '## ' + S_TECH,
    over.tech === undefined ? '| dimension | choice | reason |' : over.tech,
    '',
  ].join('\n');
  const codesOf = (r) => r.findings.map(f => f.code);

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
      const r = runCheck({ id: 'ver', command: NODE + ' --version' }, {});
      assert.equal(r.state, 'PASS');
      assert.equal(r.exit, 0);
    }],
    ['runCheck present + exit != 0 -> FAIL with exit code', () => {
      const r = runCheck({ id: 'boom', command: NODE + ' -e "process.exit(3)"' }, {});
      assert.equal(r.state, 'FAIL');
      assert.equal(r.exit, 3);
    }],
    ['runCheck fast + non-security + allowFastSkip -> SKIPPED', () => {
      const r = runCheck({ id: 'lint', command: NODE + ' --version', allowFastSkip: true }, { fastActive: true });
      assert.equal(r.state, 'SKIPPED');
      assert.equal(r.reason, 'fast-mode');
    }],
    ['runCheck fast + security -> still runs (never SKIPPED)', () => {
      const r = runCheck({ id: 'audit', command: NODE + ' --version', class: 'security', allowFastSkip: true }, { fastActive: true });
      assert.notEqual(r.state, 'SKIPPED');
      assert.equal(r.state, 'PASS');
    }],
    ['runCheck fast + non-security without allowFastSkip -> still runs', () => {
      const r = runCheck({ id: 'build', command: NODE + ' --version' }, { fastActive: true });
      assert.notEqual(r.state, 'SKIPPED');
      assert.equal(r.state, 'PASS');
    }],
    ['aggregateStates: any FAIL -> FAIL', () => assert.equal(aggregateStates(['PASS', 'FAIL', 'BLOCKED']), 'FAIL')],
    ['aggregateStates: no FAIL, has BLOCKED -> BLOCKED', () => assert.equal(aggregateStates(['PASS', 'BLOCKED', 'SKIPPED']), 'BLOCKED')],
    ['aggregateStates: all PASS/SKIPPED -> PASS', () => assert.equal(aggregateStates(['PASS', 'SKIPPED', 'PASS']), 'PASS')],
    ['runCheck fast + privacy class -> never SKIPPED (runs for real)', () => {
      const r = runCheck({ id: 'pii-scan', command: NODE + ' --version', class: 'privacy', allowFastSkip: true }, { fastActive: true });
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
      const r = runCheck({ id: 'haz', command: NODE + ' --version', class: 'safety', allowFastSkip: true }, { fastActive: true });
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

    // S13 -- fitness rules (pure over injected contents). The fixtures below are the very
    // patterns the rules hunt for, so each one carries an inline suppression marker: without
    // it fitness reports this file on every run, and a gate that is red forever is a gate
    // nobody reads. The marker is per line -- the rules themselves stay in force here.
    ['fitness: secret literal is an error finding', () => {
      const f = scanFitness([{ path: 'src/cfg.ts', content: 'const apiKey = "AKIAABCDEFGHIJKLMNOP";\n' }], null, DEFAULT_FITNESS_RULES);  // scan-secrets:ignore harness-fitness:ignore fixture
      assert.ok(f.some(x => x.rule === 'no-secret-literal' && x.severity === 'error'));
    }],
    ['fitness: suppression marker kills exactly that finding', () => {
      const content = '// harness-fitness:ignore\nconst password = "abcdefghijklmnop123456";\n';  // scan-secrets:ignore fixture
      const f = scanFitness([{ path: 'src/cfg.ts', content }], null, DEFAULT_FITNESS_RULES);
      assert.ok(!f.some(x => x.rule === 'no-secret-literal'));
    }],
    ['fitness: pii in log call flagged', () => {
      const f = scanFitness([{ path: 'src/a.ts', content: 'logger.info("user " + email + " ssn " + ssn)\n' }], null, DEFAULT_FITNESS_RULES);  // harness-fitness:ignore fixture
      assert.ok(f.some(x => x.rule === 'no-pii-in-logs'));
    }],
    ['fitness: empty catch flagged as silent failure', () => {
      const f = scanFitness([{ path: 'src/a.ts', content: 'try { x() } catch (e) {}\n' }], null, DEFAULT_FITNESS_RULES);  // harness-fitness:ignore fixture
      assert.ok(f.some(x => x.rule === 'no-silent-failure'));
    }],
    ['fitness: unbounded retry loop flagged', () => {
      const f = scanFitness([{ path: 'src/a.ts', content: 'while (true) {\n  await fetch(url);\n}\n' }], null, DEFAULT_FITNESS_RULES);  // harness-fitness:ignore fixture
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
      const f = scanFitness([{ path: 'gen/a.ts', content: 'try { x() } catch (e) {}\n' }], cat, DEFAULT_FITNESS_RULES);  // harness-fitness:ignore fixture
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

    // S17.2 ledger -- the chain is the evidence, so every way of editing it must be named.
    ['ledger: chain = sha256(prev + NUL + contentHash)', () => {
      const line = ledgerLine({ a: 1 }, GENESIS);
      assert.equal(line.contentHash, sha256Lf(JSON.stringify({ a: 1 })));
      assert.equal(line.chain, chainHash(GENESIS, line.contentHash));
    }],
    ['ledger: contentHash is LF-normalized (CRLF checkout cannot break the chain)', () => {
      assert.equal(sha256Lf('a\r\nb'), sha256Lf('a\nb'));
    }],
    ['ledger: an untouched three-line chain verifies, head is the last link', () => {
      const lines = chainLines([gateRec(), gateRec({ gate: 'FAIL' }), gateRec()]);
      const r = verifyLedgerChain(lines);
      assert.ok(r.ok, JSON.stringify(r.breaks));
      assert.equal(r.entries, 3);
      assert.equal(r.head, lines[2].chain);
    }],
    ['ledger: empty ledger is intact and sits at genesis', () => {
      const r = verifyLedgerChain([]);
      assert.ok(r.ok);
      assert.equal(r.head, GENESIS);
    }],
    ['ledger: editing a recorded field -> content-hash-mismatch on that line', () => {
      const lines = chainLines([gateRec(), gateRec({ gate: 'FAIL' }), gateRec()]);
      lines[1].gate = 'PASS';                       // the interesting forgery: turn a red green
      const r = verifyLedgerChain(lines);
      assert.ok(!r.ok);
      assert.ok(r.breaks.some(b => b.line === 2 && b.reason === 'content-hash-mismatch'), JSON.stringify(r.breaks));
    }],
    ['ledger: an unparseable line is reported by line number', () => {
      const lines = chainLines([gateRec(), gateRec()]);
      lines.splice(1, 0, { corrupt: true, raw: 'not json' });
      const r = verifyLedgerChain(lines);
      assert.ok(!r.ok);
      assert.ok(r.breaks.some(b => b.line === 2 && b.reason === 'unparseable-line'));
    }],
    ['ledger: reordering two lines breaks the predecessor link', () => {
      const lines = chainLines([gateRec(), gateRec({ gate: 'FAIL' }), gateRec()]);
      const swapped = [lines[0], lines[2], lines[1]];
      const r = verifyLedgerChain(swapped);
      assert.ok(!r.ok);
      assert.ok(r.breaks.some(b => b.line === 2 && b.reason === 'chain-predecessor-mismatch'));
    }],
    ['ledger: a forged chain value -> chain-hash-mismatch', () => {
      const lines = chainLines([gateRec(), gateRec()]);
      lines[1].chain = 'f'.repeat(64);
      const r = verifyLedgerChain(lines);
      assert.ok(!r.ok);
      assert.ok(r.breaks.some(b => b.line === 2 && b.reason === 'chain-hash-mismatch'));
    }],
    ['ledger: deleting a middle line is visible (the chain does not silently re-link)', () => {
      const lines = chainLines([gateRec(), gateRec({ gate: 'FAIL' }), gateRec()]);
      const r = verifyLedgerChain([lines[0], lines[2]]);
      assert.ok(!r.ok);
      assert.ok(r.breaks.some(b => b.line === 2 && b.reason === 'chain-predecessor-mismatch'));
    }],
    // The link is asserted against an independently computed digest rather than against
    // chainHash itself. Checking a function with the same function is how the predecessor
    // could be dropped from the formula and every case above still pass: `prev` would stay
    // recorded as a field, so the reordering and deletion cases keep working off that field
    // while the chain quietly stops binding anything.
    ['ledger: the link folds in the predecessor, computed independently of chainHash', () => {
      const expected = createHash('sha256').update('PREV\0CONTENT').digest('hex');
      assert.equal(chainHash('PREV', 'CONTENT'), expected);
    }],
    ['ledger: an identical record at a different position gets a different link', () => {
      const first = ledgerLine({ a: 1 }, GENESIS);
      const later = ledgerLine({ a: 1 }, 'f'.repeat(64));
      assert.equal(first.contentHash, later.contentHash, 'same record, same content hash');
      assert.notEqual(first.chain, later.chain, 'different predecessor must give a different link');
    }],
    ['ledger: an unparseable line is kept as corrupt, never dropped', () => {
      const raw = JSON.stringify(ledgerLine(gateRec(), GENESIS)) + '\n{"command":"gate","gate":"PA\n';
      const entries = parseLedgerLines(raw);
      assert.equal(entries.length, 2, 'a line that cannot be parsed must survive as a record');
      assert.equal(entries[1].corrupt, true);
      assert.ok(!verifyLedgerChain(entries).ok, 'and it must break the chain rather than vanish from it');
    }],
    ['ledger: blank lines are framing, not records', () => {
      assert.equal(parseLedgerLines('\n\n').length, 0);
      assert.equal(parseLedgerLines('').length, 0);
    }],

    // S17.2b ledger verdict -- the exit code is the whole answer for a caller that never
    // reads stdout, so it is asserted here rather than only in the golden matrix.
    ['ledger verdict: an intact chain is ok at exit 0', () => {
      const r = ledgerReport({ entries: chainLines([gateRec(), gateRec()]) });
      assert.equal(r.code, 0);
      assert.ok(r.result.ok);
      assert.equal(r.result.evidence, null, 'evidence:null means the digests were not checked this run');
    }],
    ['ledger verdict: a break is a failure at exit 1', () => {
      const lines = chainLines([gateRec(), gateRec()]);
      lines[1].gate = 'FAIL';
      const r = ledgerReport({ entries: lines });
      assert.equal(r.code, 1);
      assert.equal(r.result.ok, false);
    }],
    ['ledger verdict: an unreadable ledger degrades at exit 3, never a clean empty chain', () => {
      const r = ledgerReport({ entries: [], unreadable: 'EACCES' });
      assert.equal(r.code, 3, 'unknown is not intact');
      assert.equal(r.result.ok, false);
      assert.equal(r.result.entries, null, 'and it must not report zero entries as if the file were empty');
      assert.equal(r.result.unreadable, 'EACCES');
    }],
    ['ledger verdict: intact chain + tampered evidence is still a failure', () => {
      const r = ledgerReport({
        entries: chainLines([gateRec()]),
        evidence: { ok: false, checked: 1, breaks: [{ line: 1, reason: 'evidence-tampered' }] },
      });
      assert.equal(r.code, 1);
      assert.equal(r.result.ok, false);
    }],

    // S17.2c evidence digests -- a hash that is written and never read is decoration.
    ['evidence: a log whose bytes moved is evidence-tampered', () => {
      const rec = gateRec({ results: [{ id: 'unit', evidence: 'e/unit.log', evidenceSha256: sha256Lf('original') }] });
      const r = evidenceFindings(chainLines([rec]), { readFile: () => 'rewritten' });
      assert.equal(r.ok, false);
      assert.equal(r.checked, 1);
      assert.equal(r.breaks[0].reason, 'evidence-tampered');
      assert.equal(r.breaks[0].check, 'unit');
    }],
    ['evidence: a log that cannot be read is evidence-missing, not skipped', () => {
      const rec = gateRec({ results: [{ id: 'unit', evidence: 'e/unit.log', evidenceSha256: sha256Lf('original') }] });
      const r = evidenceFindings(chainLines([rec]), {
        readFile: () => { const e = new Error('nope'); e.code = 'ENOENT'; throw e; },
      });
      assert.equal(r.ok, false);
      assert.equal(r.breaks[0].reason, 'evidence-missing');
      assert.equal(r.breaks[0].detail, 'ENOENT');
    }],
    ['evidence: an untouched log verifies, and a check that wrote none is not counted', () => {
      const rec = gateRec({ results: [
        { id: 'unit', evidence: 'e/unit.log', evidenceSha256: sha256Lf('output') },
        { id: 'blocked', evidence: null, evidenceSha256: null },
      ] });
      const r = evidenceFindings(chainLines([rec]), { readFile: () => 'output' });
      assert.ok(r.ok);
      assert.equal(r.checked, 1, 'a check that never ran has nothing to verify');
    }],

    // S17.3 gate plan -- planHash must describe the plan, not the catalog's key order.
    ['buildPlan: entries sorted by check id, modules sorted, empty flag', () => {
      const p = buildPlan(['pay'], attrCatalog({ verification: ['sec-audit', 'sec-scan'] }));
      assert.deepEqual(p.entries.map(e => e.checkId), ['sec-audit', 'sec-scan']);
      assert.deepEqual(p.entries[0].modules, ['pay']);
      assert.equal(p.empty, false);
      assert.equal(buildPlan([], attrCatalog()).empty, true);
    }],
    ['buildPlan: planHash is independent of the order checks were declared in', () => {
      const a = buildPlan(['pay'], attrCatalog({ verification: ['sec-scan', 'sec-audit'] }));
      const b = buildPlan(['pay'], attrCatalog({ verification: ['sec-audit', 'sec-scan'] }));
      assert.equal(a.hash, b.hash);
    }],
    ['buildPlan: planHash moves when a check joins the plan', () => {
      const a = buildPlan(['pay'], attrCatalog({ verification: ['sec-scan'] }));
      const b = buildPlan(['pay'], attrCatalog({ verification: ['sec-scan', 'sec-audit'] }));
      assert.notEqual(a.hash, b.hash);
    }],
    ['gateReason: every gate state gets its own why', () => {
      assert.equal(gateReason('FAIL', { checks: [], attributeGaps: [], emptyPlan: false }), 'at-least-one-check-failed');
      assert.equal(gateReason('BLOCKED', { checks: [], attributeGaps: [], emptyPlan: false }), 'at-least-one-check-blocked');
      assert.ok(gateReason('BLOCKED', { checks: [], attributeGaps: [], emptyPlan: true }).startsWith('empty-plan:'));
      assert.ok(gateReason('BLOCKED_BY_ATTRIBUTES', { checks: [], attributeGaps: [1], emptyPlan: false }).startsWith('1 blocking'));
      assert.equal(gateReason('PASS', { checks: [], attributeGaps: [], emptyPlan: false }), 'no-affected-module');
      assert.equal(gateReason('PASS', { checks: [{ state: 'SKIPPED' }], attributeGaps: [], emptyPlan: false }), 'every-check-skipped');
      assert.equal(gateReason('PASS', { checks: [{ state: 'PASS' }], attributeGaps: [], emptyPlan: false }), 'all-executed-checks-passed');
    }],
    ['waiversApplied: only waiver-downgraded checks are recorded, with the granting file', () => {
      const out = waiversApplied(
        [{ id: 'a', reason: 'waiver:a' }, { id: 'b', reason: 'fast-mode' }, { id: 'c' }],
        [{ scope: 'a', expiry: '2099-01-01T00:00:00.000Z', _path: '/x/.claude/harness/waivers/a.json' }],
      );
      assert.equal(out.length, 1);
      assert.equal(out[0].check, 'a');
      assert.equal(out[0].expiry, '2099-01-01T00:00:00.000Z');
    }],

    // S17.4 gate-audit -- a control that never intervened is cost plus false confidence.
    ['gate-audit: a check that never failed is listed as neverIntervened', () => {
      const cat = { checks: { 'sec-scan': {}, 'unit': {} } };
      const r = auditGates(chainLines([gateRec({ results: [{ id: 'sec-scan', state: 'PASS' }] })]), cat);
      assert.equal(r.gateRuns, 1);
      assert.deepEqual(r.neverIntervened, ['sec-scan', 'unit']);
      assert.deepEqual(r.neverExecuted, ['unit']);
    }],
    ['gate-audit: one failure drops a check off neverIntervened', () => {
      const cat = { checks: { 'sec-scan': {} } };
      const r = auditGates(chainLines([gateRec({ results: [{ id: 'sec-scan', state: 'FAIL' }] })]), cat);
      assert.deepEqual(r.neverIntervened, []);
      assert.ok(r.advice.includes('intervened at least once'));
    }],
    ['gate-audit: BLOCKED counts as intervention but not as execution', () => {
      const cat = { checks: { 'sec-scan': {} } };
      const r = auditGates(chainLines([gateRec({ results: [{ id: 'sec-scan', state: 'BLOCKED' }] })]), cat);
      assert.deepEqual(r.neverIntervened, []);
      assert.deepEqual(r.neverExecuted, ['sec-scan']);
    }],
    ['gate-audit: non-gate and corrupt ledger lines are not counted as gate runs', () => {
      const r = auditGates([{ corrupt: true, raw: 'x' }, { command: 'other' }], { checks: {} });
      assert.equal(r.gateRuns, 0);
    }],
    // The record says SKIPPED because a waiver rewrote it. The check still ran and still
    // failed, and counting it by the rewrite puts a suppressed failure in the same bucket as
    // a check nobody ever wired up -- then advises that both are probably stable.
    ['gate-audit: a waiver-suppressed failure counts as executed and as an intervention', () => {
      const cat = { checks: { unit: {} } };
      const rec = gateRec({ results: [{ id: 'unit', state: 'SKIPPED', reason: 'waiver:unit', suppressed: { by: 'waiver', scope: 'unit', from: 'FAIL' } }] });
      const r = auditGates(chainLines([rec]), cat);
      assert.deepEqual(r.neverExecuted, []);
      assert.deepEqual(r.neverIntervened, []);
      assert.deepEqual(r.suppressed, [{ check: 'unit', occurrences: 1, by: ['waiver'], suppressedStates: ['FAIL'] }]);
      assert.ok(r.advice.includes('suppressed'), 'the advice must not stop at "genuinely stable"');
    }],
    ['gate-audit: a fast-mode skip is deferred, not a suppressed verdict', () => {
      const cat = { checks: { unit: {} } };
      const rec = gateRec({ results: [{ id: 'unit', state: 'SKIPPED', reason: 'fast-mode', suppressed: { by: 'fast-mode', scope: null, from: null } }] });
      const r = auditGates(chainLines([rec]), cat);
      assert.deepEqual(r.neverExecuted, ['unit'], 'it genuinely did not run');
      assert.deepEqual(r.suppressed.map(s => s.by), [['fast-mode']], 'but it is still not silence');
    }],
    ['suppression: a waiver records the verdict it replaced, fast mode has none to replace', () => {
      assert.deepEqual(suppressionOf({ reason: 'waiver:unit' }, { state: 'FAIL' }), { by: 'waiver', scope: 'unit', from: 'FAIL' });
      assert.deepEqual(suppressionOf({ reason: 'fast-mode' }, { state: 'SKIPPED' }), { by: 'fast-mode', scope: null, from: null });
      assert.equal(suppressionOf({ reason: 'command-missing:semgrep' }, { state: 'BLOCKED' }), null);
      assert.equal(suppressionOf({}, undefined), null);
    }],

    // S17.5 retention -- privacy includes disposal, but never of the proof behind a green.
    ['retention: a ledger-referenced evidence file is never a candidate', () => {
      const files = [{ path: 'e/a.log', mtimeMs: 10 }, { path: 'e/b.log', mtimeMs: 5 }];
      const plan = planRetention(files, { protectedPaths: new Set(['e/b.log']), keep: 0, cutoffMs: 0 });
      assert.deepEqual(plan.map(p => p.path), ['e/a.log']);
    }],
    ['retention: the newest `keep` files survive, the rest are over-count', () => {
      const files = [{ path: 'a', mtimeMs: 30 }, { path: 'b', mtimeMs: 20 }, { path: 'c', mtimeMs: 10 }];
      const plan = planRetention(files, { keep: 2, cutoffMs: 0 });
      assert.deepEqual(plan, [{ path: 'c', reason: 'over-count' }]);
    }],
    ['retention: a file past the cutoff is over-age even inside the keep window', () => {
      const files = [{ path: 'a', mtimeMs: 30 }, { path: 'b', mtimeMs: 5 }];
      const plan = planRetention(files, { keep: 10, cutoffMs: 20 });
      assert.deepEqual(plan, [{ path: 'b', reason: 'over-age' }]);
    }],
    ['retention: evidence paths are collected from gate records', () => {
      const set = ledgerReferencedEvidence(chainLines([
        gateRec({ results: [{ id: 'a', evidence: 'e/a.log' }, { id: 'b', evidence: null }] }),
      ]));
      assert.deepEqual([...set], ['e/a.log']);
    }],
    // The protected set is derived from the ledger, so a ledger nobody can read or verify
    // makes it unknown -- and an unknown protected set treated as an empty one is how a
    // sweep deletes the only proof behind a recorded green.
    ['retention: an unreadable ledger stops the sweep before it plans anything', () => {
      const r = retentionRefusal('EACCES', null);
      assert.equal(r.reason, 'ledger-unreadable');
      assert.equal(r.detail, 'EACCES');
    }],
    ['retention: a broken chain stops the sweep and names the first break', () => {
      const lines = chainLines([gateRec(), gateRec()]);
      lines[1].gate = 'FAIL';
      const r = retentionRefusal(null, verifyLedgerChain(lines));
      assert.equal(r.reason, 'ledger-chain-broken');
      assert.ok(r.detail.includes('line 2'));
    }],
    ['retention: an intact chain does not refuse', () => {
      assert.equal(retentionRefusal(null, verifyLedgerChain(chainLines([gateRec()]))), null);
    }],

    // S17.6 risk -- each decay code must fire on its own trigger and stay quiet otherwise.
    ['risk: clean state produces no findings', () => {
      const r = riskFindings({ ledgerEntries: chainLines([gateRec()]), catalog: null, waivers: [], task: null });
      assert.ok(r.ok);
      assert.equal(r.findings.length, 0);
    }],
    ['risk: a broken chain is LEDGER_BROKEN at error severity', () => {
      const lines = chainLines([gateRec(), gateRec()]);
      lines[1].gate = 'FAIL';
      const r = riskFindings({ ledgerEntries: lines });
      assert.ok(!r.ok);
      assert.ok(r.findings.some(f => f.code === 'LEDGER_BROKEN' && f.severity === 'error'));
    }],
    ['risk: an expired waiver is EXPIRED_WAIVER, a future one is silent', () => {
      const expired = riskFindings({ waivers: [{ scope: 'x', expiry: '2020-01-01T00:00:00.000Z' }], now: Date.parse('2026-01-01T00:00:00.000Z') });
      assert.ok(expired.findings.some(f => f.code === 'EXPIRED_WAIVER' && f.severity === 'error'));
      const live = riskFindings({ waivers: [{ scope: 'x', expiry: '2099-01-01T00:00:00.000Z' }] });
      assert.ok(live.ok);
    }],
    ['risk: a blocking attribute with no claiming check is UNWIRED_ATTRIBUTE', () => {
      const gap = riskFindings({ catalog: attrCatalog({ attributes: { privacy: 'critical' } }) });
      assert.ok(gap.findings.some(f => f.code === 'UNWIRED_ATTRIBUTE' && f.attribute === 'privacy'));
      const wired = riskFindings({ catalog: attrCatalog() });    // security:critical, sec-scan claims it
      assert.ok(!wired.findings.some(f => f.code === 'UNWIRED_ATTRIBUTE'));
    }],
    ['risk: three consecutive failures are FAIL_STREAK; a pass resets the count', () => {
      const three = [1, 2, 3].map(() => gateRec({ gate: 'FAIL', results: [{ id: 'unit', state: 'FAIL' }] }));
      assert.ok(riskFindings({ ledgerEntries: chainLines(three) }).findings.some(f => f.code === 'FAIL_STREAK'));
      const reset = chainLines(three.concat([gateRec({ results: [{ id: 'unit', state: 'PASS' }] })]));
      assert.ok(!riskFindings({ ledgerEntries: reset }).findings.some(f => f.code === 'FAIL_STREAK'));
    }],
    ['risk: an unreadable ledger is LEDGER_UNREADABLE, distinct from a broken chain', () => {
      const r = riskFindings({ ledgerEntries: [], ledgerUnreadable: 'EACCES' });
      assert.ok(!r.ok);
      assert.ok(r.findings.some(f => f.code === 'LEDGER_UNREADABLE' && f.severity === 'error'));
      assert.ok(!r.findings.some(f => f.code === 'LEDGER_BROKEN'), 'an empty entry list is not a break');
    }],
    ['risk: tampered and missing evidence are their own error findings', () => {
      const r = riskFindings({
        evidenceBreaks: [
          { reason: 'evidence-tampered', check: 'unit', evidence: 'e/unit.log' },
          { reason: 'evidence-missing', check: 'lint', evidence: 'e/lint.log' },
        ],
      });
      assert.ok(!r.ok);
      assert.deepEqual(r.findings.map(f => f.code), ['EVIDENCE_TAMPERED', 'EVIDENCE_MISSING']);
    }],
    ['risk: a waiver-suppressed failure still counts toward the streak and is reported', () => {
      const suppressedFail = () => gateRec({
        results: [{ id: 'unit', state: 'SKIPPED', reason: 'waiver:unit', suppressed: { by: 'waiver', scope: 'unit', from: 'FAIL' } }],
      });
      const r = riskFindings({ ledgerEntries: chainLines([suppressedFail(), suppressedFail(), suppressedFail()]) });
      assert.ok(r.findings.some(f => f.code === 'FAIL_STREAK'), 'a streak that stops counting when waived runs forever unheard');
      const supp = r.findings.find(f => f.code === 'SUPPRESSED_FAILURE');
      assert.ok(supp && supp.check === 'unit' && supp.occurrences === 3);
      assert.ok(r.ok, 'a filed waiver is a decision, not an error: warning severity, exit code untouched');
    }],
    ['risk: fast-mode skips in the newest gate are FAST_MODE_DEBT (deferred, not waived)', () => {
      const lines = chainLines([gateRec({ fastActive: true, skippedByFastMode: ['unit'] })]);
      const r = riskFindings({ ledgerEntries: lines });
      assert.ok(!r.ok);
      assert.ok(r.findings.some(f => f.code === 'FAST_MODE_DEBT' && f.severity === 'error'));
    }],
    ['risk: a task active past 72h is STALE_TASK at warning severity', () => {
      const now = Date.parse('2026-01-05T00:00:00.000Z');
      const stale = riskFindings({ task: { id: 'T1', state: 'active', startedAt: '2026-01-01T00:00:00.000Z' }, now });
      assert.ok(stale.ok, 'a warning must not close the exit code');
      assert.ok(stale.findings.some(f => f.code === 'STALE_TASK'));
      const fresh = riskFindings({ task: { id: 'T1', state: 'active', startedAt: '2026-01-04T23:00:00.000Z' }, now });
      assert.equal(fresh.findings.length, 0);
    }],

    // S18.1 task envelope -- a missing field must be named, not summarised.
    ['envelope: a complete six-field envelope validates', () => {
      const v = validateEnvelope(envelope());
      assert.ok(v.ok);
      assert.deepEqual(v.missing, []);
    }],
    ['envelope: missing fields are named one by one', () => {
      const v = validateEnvelope(envelope({ outOfScope: undefined, escalation: undefined }));
      assert.ok(!v.ok);
      assert.deepEqual(v.missing, ['outOfScope', 'escalation']);
    }],
    ['envelope: a whitespace-only field counts as missing', () => {
      assert.deepEqual(validateEnvelope(envelope({ goal: '   ' })).missing, ['goal']);
    }],
    ['envelope: a non-object is missing everything', () => {
      const v = validateEnvelope('not an envelope');
      assert.equal(v.missing.length, 7);
      assert.ok(v.detail.includes('JSON object'));
    }],
    ['envelope: an id of only illegal characters is rejected by name', () => {
      assert.deepEqual(validateEnvelope(envelope({ id: '..' })).missing, ['id']);
    }],
    ['task record: id is sanitized and capped, engine fields are added', () => {
      // Separators are what escape a directory, so those are the characters that die;
      // dots survive, and the result can no longer name anything outside one segment.
      const rec = buildTaskRecord(envelope({ id: '../../etc/passwd' }), { now: 'T', baseCommit: 'c0' });
      assert.equal(rec.id, '.._.._etc_passwd');
      assert.equal(rec.state, 'active');
      assert.equal(rec.baseCommit, 'c0');
      assert.equal(rec.startedAt, 'T');
      const long = buildTaskRecord(envelope({ id: 'a'.repeat(200) }), { now: 'T', baseCommit: null });
      assert.equal(long.id.length, 120);
    }],

    // S18.1 task complete -- four conditions, each blocking on its own.
    ['task complete: all four conditions met -> no blockers', () => {
      const blockers = completeBlockers({
        latestGate: gateRec({ gate: 'PASS', diffHash: 'D0' }), currentDiffHash: 'D0',
        receipts: [okReceipt()], ledgerOk: true, planEmpty: false,
      });
      assert.deepEqual(blockers, []);
    }],
    ['task complete: a gate bound to another diff blocks', () => {
      const blockers = completeBlockers({
        latestGate: gateRec({ gate: 'PASS', diffHash: 'OTHER' }), currentDiffHash: 'D0',
        receipts: [okReceipt()], ledgerOk: true, planEmpty: false,
      });
      assert.equal(blockers.length, 1);
      assert.ok(blockers[0].includes('no PASS gate record bound to the current diffHash'));
    }],
    ['task complete: a failing gate blocks even when it is the current diff', () => {
      const blockers = completeBlockers({
        latestGate: gateRec({ gate: 'FAIL', diffHash: 'D0' }), currentDiffHash: 'D0',
        receipts: [okReceipt()], ledgerOk: true, planEmpty: false,
      });
      assert.equal(blockers.length, 1);
    }],
    ['task complete: no accepting receipt for this diff blocks', () => {
      const stale = completeBlockers({
        latestGate: gateRec(), currentDiffHash: 'D0',
        receipts: [okReceipt({ diffHash: 'OTHER' })], ledgerOk: true, planEmpty: false,
      });
      assert.ok(stale.some(b => b.includes('accepting review receipt')));
      const rejected = completeBlockers({
        latestGate: gateRec(), currentDiffHash: 'D0',
        receipts: [okReceipt({ verdict: 'FIX_REQUIRED' })], ledgerOk: true, planEmpty: false,
      });
      assert.ok(rejected.some(b => b.includes('accepting review receipt')));
    }],
    ['task complete: a broken chain blocks (prior evidence is unproven)', () => {
      const blockers = completeBlockers({
        latestGate: gateRec(), currentDiffHash: 'D0', receipts: [okReceipt()],
        ledgerOk: false, planEmpty: false,
      });
      assert.equal(blockers.length, 1);
      assert.ok(blockers[0].includes('ledger chain is broken'));
    }],
    ['task complete: an empty verification plan blocks', () => {
      const blockers = completeBlockers({
        latestGate: gateRec(), currentDiffHash: 'D0', receipts: [okReceipt()],
        ledgerOk: true, planEmpty: true,
      });
      assert.equal(blockers.length, 1);
      assert.ok(blockers[0].includes('verification plan is empty'));
    }],
    ['task complete: a tampered receipt does not accept', () => {
      const forged = { ...okReceipt(), scope: 'rewritten after signing' };
      assert.equal(acceptingReceipt([forged], 'D0'), null);
    }],
    // A PASS is not one fact. `gate --changed <a path the catalog ignores>` yields PASS with
    // an empty module list and a genuine diffHash beside it: a real signature over a subject
    // the caller picked. These three conditions are what stop that record closing a task.
    ['task complete: a caller-scoped PASS gate does not close anything', () => {
      const blockers = completeBlockers({
        latestGate: gateRec({ scopeSource: 'caller', scopeRequested: ['docs/x.md'] }),
        currentDiffHash: 'D0', receipts: [okReceipt()], ledgerOk: true, planEmpty: false,
      });
      assert.equal(blockers.length, 1);
      assert.ok(blockers[0].includes('--changed'));
    }],
    ['task complete: a gate record with no scope provenance is not trusted either', () => {
      const { scopeSource, ...noProvenance } = gateRec();
      const blockers = completeBlockers({
        latestGate: noProvenance, currentDiffHash: 'D0', receipts: [okReceipt()],
        ledgerOk: true, planEmpty: false,
      });
      assert.equal(blockers.length, 1);
      assert.ok(blockers[0].includes('unrecorded provenance'));
    }],
    ['task complete: a gate that verified a different plan does not close the task', () => {
      const blockers = completeBlockers({
        latestGate: gateRec({ planHash: 'P0' }), currentDiffHash: 'D0', currentPlanHash: 'P-OTHER',
        receipts: [okReceipt()], ledgerOk: true, planEmpty: false,
      });
      assert.equal(blockers.length, 1);
      assert.ok(blockers[0].includes('resolves to plan'));
      // Same plan, no complaint.
      assert.deepEqual(completeBlockers({
        latestGate: gateRec({ planHash: 'P0' }), currentDiffHash: 'D0', currentPlanHash: 'P0',
        receipts: [okReceipt()], ledgerOk: true, planEmpty: false,
      }), []);
    }],
    ['task complete: a PASS in which every check was skipped established nothing', () => {
      const allSkipped = gateRec({ reason: 'every-check-skipped', fastActive: true, skippedByFastMode: ['unit'],
        results: [{ id: 'unit', state: 'SKIPPED', reason: 'fast-mode' }] });
      const blockers = completeBlockers({
        latestGate: allSkipped, currentDiffHash: 'D0', receipts: [okReceipt()],
        ledgerOk: true, planEmpty: false,
      });
      assert.equal(blockers.length, 1);
      assert.ok(blockers[0].includes('deferred, not obtained'));
      // One executed check among the skips is enough to have established something.
      assert.deepEqual(completeBlockers({
        latestGate: gateRec({ results: [{ id: 'unit', state: 'SKIPPED' }, { id: 'lint', state: 'PASS' }] }),
        currentDiffHash: 'D0', receipts: [okReceipt()], ledgerOk: true, planEmpty: false,
      }), []);
    }],
    ['task complete: evidence that no longer matches its digest blocks', () => {
      const blockers = completeBlockers({
        latestGate: gateRec(), currentDiffHash: 'D0', receipts: [okReceipt()],
        ledgerOk: true, evidenceOk: false, planEmpty: false,
      });
      assert.equal(blockers.length, 1);
      assert.ok(blockers[0].includes('recorded digest'));
    }],
    ['task complete: the broken-chain blocker recommends no command (there is none that mends it)', () => {
      const blockers = completeBlockers({
        latestGate: gateRec(), currentDiffHash: 'D0', receipts: [okReceipt()],
        ledgerOk: false, planEmpty: false,
      });
      assert.equal(blockers.length, 1);
      assert.ok(!/harness\.mjs/.test(blockers[0]), 'records only append past a break, so no rerun clears it');
    }],
    ['task complete: the newest gate record decides, not the first one', () => {
      const entries = chainLines([
        gateRec({ diffHash: 'OLD' }),
        { command: 'other', at: 'x' },
        gateRec({ diffHash: 'NEW', gate: 'FAIL' }),
      ]);
      const latest = latestGateRecord(entries);
      assert.equal(latest.diffHash, 'NEW');
      assert.equal(latest.gate, 'FAIL');
      assert.equal(latestGateRecord([{ corrupt: true, raw: 'x' }, { command: 'other' }]), null);
    }],

    // S18.2 budget -- over the line is a signal, so the finding must carry the numbers.
    ['budget: within every limit -> ok', () => {
      const r = assessBudget({ changedFiles: 2, changedLines: 10, modulesTouched: 1, newFiles: 0 }, budgetCat);
      assert.ok(r.ok);
      assert.deepEqual(r.findings, []);
    }],
    ['budget: over a limit reports metric, actual and limit', () => {
      const r = assessBudget({ changedFiles: 9, changedLines: 10, modulesTouched: 1, newFiles: 0 }, budgetCat);
      assert.ok(!r.ok);
      assert.deepEqual(r.findings, [{ metric: 'changedFiles', actual: 9, limit: 3 }]);
    }],
    ['budget: all four metrics can trip independently', () => {
      const r = assessBudget({ changedFiles: 9, changedLines: 900, modulesTouched: 7, newFiles: 4 }, budgetCat);
      assert.deepEqual(r.findings.map(f => f.metric), ['changedFiles', 'changedLines', 'modulesTouched', 'newFiles']);
    }],
    ['budget: a non-numeric limit is report-only, never a finding', () => {
      const r = assessBudget({ changedFiles: 999 }, { ...budgetCat, maxChangedFiles: null });
      assert.ok(r.ok);
    }],

    // S1b lock -- what keeps a burst of concurrent gates from breaking the chain. These two
    // touch the filesystem (a lock that is not a real filesystem object proves nothing) and
    // clean up after themselves; everything else in this file stays in memory.
    ['lock: a held lock is not handed out twice, and a waiter gives up instead of hanging', () => {
      const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ccbase-selftest-lock-'));
      const lock = path.join(dir, 'x.lock');
      try {
        let second = null;
        const held = withDirLock(lock, () => {
          assert.ok(fs.existsSync(lock), 'the lock exists while it is held');
          try { withDirLock(lock, () => { second = 'acquired twice'; }, { timeoutMs: 40, pollMs: 5 }); }
          catch (e) { second = String(e && e.message || e); }
          return 'body ran';
        });
        assert.equal(held, 'body ran');
        assert.ok(/could not acquire lock/.test(String(second)), 'second acquire must fail: ' + second);
        assert.ok(!fs.existsSync(lock), 'and the lock is released when the body returns');
        assert.throws(() => withDirLock(lock, () => { throw new Error('boom'); }), /boom/);
        assert.ok(!fs.existsSync(lock), 'a throwing body must not leave the lock behind');
      } finally {
        fs.rmSync(dir, { recursive: true, force: true });
      }
    }],
    ['ledger append: a killed write costs one line, not the record that follows it', () => {
      // The only case in this file that drives appendLedger end to end, because the bug it
      // locks is in the framing rather than in any of the pure parts: a fragment with no
      // terminator used to have the next record appended straight onto it, so one
      // interrupted write destroyed two records, the good one included.
      const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ccbase-selftest-ledger-'));
      const saved = process.env.CLAUDE_PROJECT_DIR;
      try {
        process.env.CLAUDE_PROJECT_DIR = dir;
        appendLedger({ command: 'gate', at: 'T1' });
        fs.appendFileSync(ledgerFilePath(), '{"command":"gate","at":"T2","gate":"PA', 'utf8');
        appendLedger({ command: 'gate', at: 'T3' });
        const entries = parseLedgerLines(fs.readFileSync(ledgerFilePath(), 'utf8'));
        assert.equal(entries.length, 3);
        assert.equal(entries.filter(e => e.corrupt).length, 1, 'exactly one line is unreadable');
        assert.equal(entries[2].at, 'T3', 'the record after the fragment survives intact');
      } finally {
        if (saved === undefined) delete process.env.CLAUDE_PROJECT_DIR;
        else process.env.CLAUDE_PROJECT_DIR = saved;
        fs.rmSync(dir, { recursive: true, force: true });
      }
    }],
    ['ledger append: the terminator check reads the last byte, and an absent file needs none', () => {
      const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ccbase-selftest-eol-'));
      try {
        const f = path.join(dir, 'l.jsonl');
        fs.writeFileSync(f, '');
        assert.equal(endsWithNewline(f), true, 'an empty file has nothing to repair');
        fs.writeFileSync(f, '{"a":1}\n');
        assert.equal(endsWithNewline(f), true);
        fs.writeFileSync(f, '{"a":1}\n{"b":');
        assert.equal(endsWithNewline(f), false);
        assert.equal(endsWithNewline(path.join(dir, 'absent.jsonl')), true);
      } finally {
        fs.rmSync(dir, { recursive: true, force: true });
      }
    }],
    ['lock: a lock left behind by a killed process is reclaimed once it is stale', () => {
      const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ccbase-selftest-lock-'));
      const lock = path.join(dir, 'x.lock');
      try {
        fs.mkdirSync(lock);
        const old = (Date.now() - 5000) / 1000;
        fs.utimesSync(lock, old, old);
        let ran = false;
        withDirLock(lock, () => { ran = true; }, { timeoutMs: 200, staleMs: 1000, pollMs: 5 });
        assert.ok(ran, 'a stale lock must be reclaimed rather than bricking the file forever');
      } finally {
        fs.rmSync(dir, { recursive: true, force: true });
      }
    }],

    // S19 spec-lint -- the checks are written against the shape product-spec-builder
    // actually emits, so every case below starts from a document in that shape. A lint that
    // cannot fire on a real document is the failure mode this whole section exists to avoid,
    // which is why the accept cases (one arrow is enough, prose may say "quickly", markup is
    // not residue) carry as much weight here as the reject cases.
    ['spec-lint: the requirement section is the third of the four required ones', () => {
      assert.equal(REQUIRED_SECTIONS.length, 4);
      assert.equal(REQUIREMENT_SECTION, REQUIRED_SECTIONS[2]);
    }],
    ['spec-lint: a well-formed document is clean, and one arrow is enough', () => {
      const r = lintSpecDoc(specDoc([
        '- import: the user uploads a CSV -> the system parses it -> the row count is shown',
        '- export: the user clicks export -> a CSV is downloaded',
      ]), 'Product-Spec.md');
      assert.ok(r.ok, 'clean document produced ' + JSON.stringify(codesOf(r)));
      assert.equal(r.requirements, 2);
      assert.equal(r.counts.error, 0);
      assert.equal(r.counts.warning, 0);
    }],
    ['spec-lint: a requirement with no arrow states no flow', () => {
      const r = lintSpecDoc(specDoc([
        '- import: the user uploads a CSV -> the row count is shown',
        '- reporting, with several formats',
      ]), 'Product-Spec.md');
      const flow = r.findings.filter(f => f.code === 'NO_FLOW');
      assert.equal(flow.length, 1, 'exactly the arrowless item must be named');
      assert.ok(flow[0].excerpt.includes('reporting'));
      assert.equal(r.ok, false);
    }],
    ['spec-lint: a nested detail bullet is not a requirement of its own', () => {
      const doc = splitSections(specDoc([
        '- import: the user uploads a CSV -> the row count is shown',
        '    - the delimiter is configurable',
      ]));
      assert.equal(parseRequirements(doc).length, 1);
    }],
    ['spec-lint: a missing section and an empty one are both errors', () => {
      const withoutScenario = specDoc(['- a: b -> c']).replace('## ' + REQUIRED_SECTIONS[1], '## other');
      assert.ok(codesOf(lintSpecDoc(withoutScenario, 'f.md')).includes('MISSING_SECTION'));
      const emptied = specDoc(['- a: b -> c'], { overview: '' });
      assert.ok(codesOf(lintSpecDoc(emptied, 'f.md')).includes('EMPTY_SECTION'));
    }],
    ['spec-lint: template residue is residue, markup is markup', () => {
      assert.deepEqual(placeholderBrackets('- <target user> uses <br> and <div class="x">'), ['<target user>']);
      assert.deepEqual(placeholderBrackets('closing tags are markup too: </section>'), []);
      const r = lintSpecDoc(specDoc(['- a: b -> c'], { tech: 'product type: <Web / Desktop / CLI>' }), 'f.md');
      assert.ok(codesOf(r).includes('PLACEHOLDER'));
    }],
    ['spec-lint: a marker is an error, subject matter is not, a fenced block is not scanned', () => {
      const marked = lintSpecDoc(specDoc(['- a: b -> c'], { tech: 'storage: ' + PLACEHOLDER_TOKENS[3] }), 'f.md');
      assert.ok(codesOf(marked).includes('PLACEHOLDER'));
      // A specification for a to-do application says TODO about its own product, in the
      // overview and in the requirement items. None of that is a deferral.
      const subject = lintSpecDoc(specDoc([
        '- add: the user types a title -> the app stores it -> a new todo item appears',
        '- TODO list: the user opens the app -> the list loads -> every todo item shows',
      ], { overview: 'a TODO app for managing your todo items' }), 'f.md');
      assert.ok(!codesOf(subject).includes('PLACEHOLDER'), 'subject matter produced ' + JSON.stringify(codesOf(subject)));
      // The three shapes that are a deferral: bracketed, colon-suffixed, alone on the item.
      for (const shape of ['storage: <TODO>', 'TODO: pick one', '- TBD']) {
        const r = lintSpecDoc(specDoc(['- a: b -> c'], { tech: shape }), 'f.md');
        assert.ok(codesOf(r).includes('PLACEHOLDER'), 'missed marker shape ' + JSON.stringify(shape));
      }
      const fenced = lintSpecDoc(specDoc([
        '- a: b -> c',
        '',
        '```ts',
        'const x: Array<Thing> = [];',
        '```',
      ]), 'f.md');
      assert.ok(fenced.ok, 'code fence produced ' + JSON.stringify(codesOf(fenced)));
    }],
    ['spec-lint: undecidable wording is a warning, and only inside requirement items', () => {
      const AMB = AMBIGUOUS_TERMS[2];
      const r = lintSpecDoc(specDoc([
        '- export: the user clicks export -> the file arrives ' + AMB,
      ], { overview: 'the product is ' + AMB + ' to adopt' }), 'f.md');
      const amb = r.findings.filter(f => f.code === 'AMBIGUOUS');
      assert.equal(amb.length, 1, 'sales prose must not be linted for decidability');
      assert.equal(amb[0].severity, 'warning');
      assert.ok(r.ok, 'a warning must not fail the document');
    }],
    ['spec-lint: ids are optional, partial numbering is a warning, reuse is an error', () => {
      const none = lintSpecDoc(specDoc(['- a: b -> c']), 'f.md');
      assert.equal(none.ids.length, 0);
      assert.ok(none.ok, 'an unnumbered specification is valid; trace is what degrades');
      const partial = lintSpecDoc(specDoc([
        '- [REQ-IMP-001] import: a -> b',
        '- export: a -> b',
      ]), 'f.md');
      assert.deepEqual(partial.ids.map(x => x.id), ['REQ-IMP-001']);
      assert.ok(codesOf(partial).includes('PARTIAL_ID'));
      assert.ok(partial.ok, 'partial numbering is a warning, not a rejection');
      const dup = lintSpecDoc(specDoc([
        '- [REQ-IMP-001] import: a -> b',
        '- [REQ-IMP-001] export: a -> b',
      ]), 'f.md');
      assert.ok(codesOf(dup).includes('DUPLICATE_ID'));
      assert.equal(dup.ok, false);
    }],

    // S19 trace -- an anchor that nothing references is the finding; an anchor that does not
    // exist is a degraded answer, never an invented one (that half is the cmdTrace rc 3 path
    // the golden matrix records).
    ['trace: a test reference verifies, a code reference only implements', () => {
      const collected = collectReferences([
        { path: 'tests/import.test.js', content: '// covers REQ-IMP-001' },
        { path: 'src/report.js', content: '// implements REQ-REP-002' },
      ], ['**/tests/**', '**/*.test.*'], null);
      const r = traceReport([{ id: 'REQ-IMP-001', line: 1 }, { id: 'REQ-REP-002', line: 2 }], collected, 1);
      assert.deepEqual(r.unverified, ['REQ-REP-002']);
      assert.equal(r.verified, 1);
      assert.equal(r.coverage, 0.5);
      assert.equal(r.ok, false);
    }],
    ['trace: a dangling id in code fails, the same id in prose only reports', () => {
      const collected = collectReferences([
        { path: 'src/report.js', content: 'REQ-GONE-009' },
        { path: 'docs/notes.md', content: 'see REQ-ALSO-010 for history' },
      ], ['**/tests/**'], null);
      const r = traceReport([], collected, 1);
      assert.deepEqual(r.dangling.map(d => d.id), ['REQ-GONE-009']);
      assert.deepEqual(r.danglingInDocs.map(d => d.id), ['REQ-ALSO-010']);
      assert.equal(r.ok, false, 'zero declared requirements is not full coverage');
    }],
    ['trace: module attribution follows the catalog, so the spec view can narrow', () => {
      const cat = { version: 1, modules: [{ id: 'reporting', paths: ['src/**'] }] };
      const collected = collectReferences([{ path: 'src/report.js', content: 'REQ-REP-002' }], ['**/tests/**'], cat);
      const r = traceReport([{ id: 'REQ-REP-002', line: 1 }], collected, 1);
      assert.deepEqual(r.rows[0].modules, ['reporting']);
    }],
    ['spec view: budget drops whole items rather than half a sentence', () => {
      const items = [
        { line: 1, raw: '- one: a -> b', id: null },
        { line: 2, raw: '- two: a -> b', id: null },
        { line: 3, raw: '- three: a -> b', id: null },
      ];
      const full = renderSpecView(items, new Map(), { budget: 400, header: 'H\n' });
      assert.equal(full.rendered, 3);
      assert.equal(full.omitted, 0);
      const tight = renderSpecView(items, new Map(), { budget: 20, header: 'H\n' });
      assert.ok(tight.omitted > 0, 'a tight budget must omit, not truncate');
      assert.ok(tight.view.split('\n').every(l => l === '' || l === 'H' || /-> b$/.test(l)));
    }],

    // S19 dod -- degraded is not failed, but a run where nothing was established is not a
    // pass either. Same rule the empty verification plan already follows.
    ['dod: exit codes map to the three states', () => {
      assert.equal(dodStatus(0), 'PASS');
      assert.equal(dodStatus(3), 'DEGRADED');
      assert.equal(dodStatus(1), 'FAIL');
      assert.equal(dodStatus(2), 'FAIL');
    }],
    ['dod: a degraded blocking step does not block, a failing one does', () => {
      const mixed = dodVerdict([
        { id: 'catalog-lint', blocking: true, status: 'DEGRADED' },
        { id: 'adr-check', blocking: true, status: 'PASS' },
      ]);
      assert.deepEqual([mixed.ok, mixed.exit, mixed.blockingFailures], [true, 0, []]);
      const failing = dodVerdict([
        { id: 'catalog-lint', blocking: true, status: 'DEGRADED' },
        { id: 'fitness', blocking: true, status: 'FAIL' },
      ]);
      assert.deepEqual([failing.ok, failing.exit, failing.blockingFailures], [false, 2, ['fitness']]);
    }],
    ['dod: a non-blocking failure is a signal, not a verdict', () => {
      const r = dodVerdict([
        { id: 'adr-check', blocking: true, status: 'PASS' },
        { id: 'budget', blocking: false, status: 'FAIL' },
      ]);
      assert.deepEqual([r.ok, r.exit], [true, 0]);
    }],
    ['dod: every blocking step degraded is degraded, never satisfied', () => {
      const r = dodVerdict([
        { id: 'catalog-lint', blocking: true, status: 'DEGRADED' },
        { id: 'trace', blocking: true, status: 'DEGRADED' },
        { id: 'risk', blocking: false, status: 'PASS' },
      ]);
      assert.deepEqual([r.ok, r.exit, r.degraded, r.established], [false, 3, true, 0]);
    }],

    // S20 review -- the team is chosen from what the change touches, and attributes may only
    // shrink it. A project that declared everything would otherwise convene everybody, which
    // is the nitpick flood that stops a review loop from being believed.
    ['review team: an explicit catalog list wins over the profile', () => {
      const cat = { version: 1, modules: [], review: { profile: 'personal', lenses: ['correctness', 'windows'] } };
      assert.deepEqual(reviewLenses(cat, {}), ['correctness', 'windows']);
      assert.deepEqual(lensExclusions(cat, null), [], 'an explicit list excludes nothing implicitly');
    }],
    ['review team: an undeclared attribute drops its lens, correctness never drops', () => {
      const cat = {
        version: 1,
        modules: [{ id: 'core', paths: ['src/**'], attributes: { reliability: 'high' } }],
        review: { profile: 'production' },
      };
      const kept = reviewLenses(cat, { affected: ['core'] });
      assert.ok(kept.includes('correctness'), 'correctness is the floor of every review');
      assert.ok(kept.includes('testing'), 'reliability is declared high, so testing stays');
      assert.ok(!kept.includes('security'), 'nothing declares security, so no security lens');
      assert.deepEqual(lensExclusions(cat, ['core']).map(x => x.lens).sort(), ['architecture', 'performance', 'security']);
      // No affected list at all means no basis for subtracting: convene the whole profile.
      assert.deepEqual(reviewLenses(cat, {}), REVIEW_PROFILES.production);
    }],
    ['review stage: reporting is not passing, and a failed stage holds the gate shut', () => {
      const reported = reviewSession({ lenses: { correctness: lensRec(), architecture: lensRec() } });
      assert.equal(stagePassed(reported, 1), true);
      assert.equal(currentStage(reported), 2, 'a clean stage 1 opens stage 2');
      const failed = reviewSession({ lenses: { correctness: lensRec({ findings: [errFinding] }), architecture: lensRec() } });
      assert.equal(stagePassed(failed, 1), false);
      assert.equal(currentStage(failed), 1, 'expensive lenses must not open on code the cheap ones rejected');
      const unable = reviewSession({ lenses: { correctness: lensRec({ unable: true }), architecture: lensRec() } });
      assert.equal(currentStage(unable), 1, 'a lens that could not conclude has not passed either');
      const silent = reviewSession({ lenses: { correctness: lensRec() } });
      assert.equal(currentStage(silent), 1, 'stage 1 is not done while one of its lenses is silent');
    }],
    ['review stage: a stage this profile never convenes is stepped over, not waited on', () => {
      const s = reviewSession({ requiredLenses: ['correctness', 'security'], lenses: { correctness: lensRec() } });
      assert.equal(currentStage(s), 3, 'there is no stage 2 lens to wait for');
    }],

    // S20 report shape -- a finding nobody can locate cannot be acted on, and a claim with no
    // evidence is an opinion. Both reject the whole report rather than half-recording it.
    ['review lens: a finding needs a file:line or a reproduction, or the report is refused', () => {
      const bad = validateFindings({ findings: [{ severity: 'error', summary: 'feels wrong' }] });
      assert.equal(bad.ok, false);
      assert.deepEqual(bad.unlocated, [0]);
      const byLine = validateFindings({ findings: [{ severity: 'warning', location: 'src/a.js:3', summary: 'x' }] });
      assert.equal(byLine.ok, true);
      const byRepro = validateFindings({ findings: [{ severity: 'info', reproduction: 'node t.js -> exit 1', summary: 'x' }] });
      assert.equal(byRepro.ok, true);
      // A path with no line number is not a location: "somewhere in this file" is an impression.
      const noLine = validateFindings({ findings: [{ severity: 'error', location: 'src/a.js', summary: 'x' }] });
      assert.equal(noLine.ok, false);
      const sev = validateFindings({ findings: [{ severity: 'critical', location: 'src/a.js:3', summary: 'x' }] });
      assert.deepEqual([sev.ok, sev.badSeverity], [false, [0]]);
      assert.equal(validateFindings({ findings: [] }).ok, true, 'a clean lens reports nothing, and that is a report');
    }],
    ['review blue: every claim carries evidence or the whole self-report is rejected', () => {
      assert.equal(validateClaims({ claims: [] }).ok, false, 'blue must say something');
      const bad = validateClaims({ claims: [{ statement: 'it works', evidence: '' }] });
      assert.deepEqual([bad.ok, bad.bad[0].why], [false, 'no evidence']);
      const good = validateClaims({ claims: [{ statement: 'tsc is clean', evidence: 'tsc --noEmit -> exit 0' }] });
      assert.deepEqual([good.ok, good.claims.length], [true, 1]);
    }],

    // S20 verdict -- computed, never asserted. The line that separates this from a consensus
    // review is that there is no vote anywhere in it.
    ['review verdict: every lens clean and final gives ACCEPT', () => {
      const v = computeVerdict(reviewSession({ lenses: allClean }));
      assert.deepEqual([v.ok, v.verdict, v.stage, v.isFinal, v.errorCount], [true, 'ACCEPT', 3, true, 0]);
    }],
    ['review verdict: one located error is not outvoted by the lenses that found nothing', () => {
      const s = reviewSession({ lenses: { ...allClean, correctness: lensRec({ findings: [errFinding] }) } });
      const v = computeVerdict(s);
      assert.deepEqual([v.ok, v.verdict, v.errorCount, v.stage], [true, 'FIX_REQUIRED', 1, 1]);
      assert.equal(v.recordedLenses.length, 4, 'three clean reports beside it change nothing');
    }],
    ['review verdict: a lens that could not conclude asks for evidence, not acceptance', () => {
      const s = reviewSession({ lenses: { ...allClean, security: lensRec({ unable: true }) } });
      const v = computeVerdict(s);
      assert.deepEqual([v.verdict, v.unableLenses], ['NEEDS_MORE_EVIDENCE', ['security']]);
    }],
    ['review verdict: no blue and no current-stage report are refusals, not verdicts', () => {
      const noBlue = computeVerdict(reviewSession({ blue: null, lenses: allClean }));
      assert.deepEqual([noBlue.ok, noBlue.verdict], [false, null]);
      assert.ok(noBlue.blockers.some(b => b.includes('blue')));
      const silent = computeVerdict(reviewSession({ lenses: { correctness: lensRec() } }));
      assert.deepEqual([silent.ok, silent.verdict, silent.missingLenses], [false, null, ['architecture']]);
    }],
    ['review verdict: the round limit stops the loop instead of repeating it', () => {
      const withErr = { ...allClean, correctness: lensRec({ findings: [errFinding] }) };
      const first = computeVerdict(reviewSession({ lenses: withErr }), { maxRounds: 3 });
      assert.deepEqual([first.round, first.escalate], [1, false]);
      const third = computeVerdict(reviewSession({ lenses: withErr, lineage: [{}, {}] }), { maxRounds: 3 });
      assert.deepEqual([third.round, third.verdict, third.escalate], [3, 'FIX_REQUIRED', true]);
      // The limit only fires on repeated rejection: a clean third round still accepts.
      const clean = computeVerdict(reviewSession({ lenses: allClean, lineage: [{}, {}] }), { maxRounds: 3 });
      assert.deepEqual([clean.verdict, clean.escalate], ['ACCEPT', false]);
    }],

    // S20 authorship -- the rule the sibling engine has to leave as prose, made decidable.
    ['authorship: only a record naming a file this diff touches makes anyone an author', () => {
      const records = [
        { agentId: 'impl-1', agentType: 'implementer', files: ['src/a.js', 'src/b.js'] },
        { agentId: 'impl-2', agentType: 'implementer', files: ['docs/old.md'] },
        { corrupt: true, raw: '{' },
        { agentType: 'implementer', files: ['src/a.js'] },
      ];
      const authors = authorSetFor(records, new Set(['src/a.js']));
      assert.deepEqual([...authors.keys()], ['impl-1'], 'a record about an untouched file says nothing here');
      assert.deepEqual(authors.get('impl-1').files, ['src/a.js']);
    }],
    ['authorship: a lens reported by an author cannot carry an ACCEPT', () => {
      const authors = authorSetFor([{ agentId: 'impl-1', files: ['src/a.js'] }], new Set(['src/a.js']));
      const s = reviewSession({ lenses: { ...allClean, correctness: lensRec({ agentId: 'impl-1' }) } });
      assert.deepEqual(selfReviewedLenses(s, authors).map(x => x.lens), ['correctness']);
      const v = computeVerdict(s, { authors });
      assert.deepEqual([v.ok, v.verdict], [false, null]);
      assert.ok(v.blockers[0].includes('self-review is not independent review'));
      // An outsider reporting the same lens is exactly what the rule asks for.
      const clean = computeVerdict(reviewSession({ lenses: { ...allClean, correctness: lensRec({ agentId: 'red-1' }) } }), { authors });
      assert.equal(clean.verdict, 'ACCEPT');
    }],
    ['authorship: an unenforceable rule reports itself unenforced, with which half is missing', () => {
      const s = reviewSession({ lenses: { ...allClean, correctness: lensRec({ agentId: 'red-1' }) } });
      const none = authorshipStatus(s, new Map(), { records: 0 });
      assert.equal(none.enforced, false);
      assert.ok(none.reason.includes('no authorship was ever recorded'));
      const elsewhere = authorshipStatus(s, new Map(), { records: 4 });
      assert.ok(elsewhere.reason.includes('none of them names a file this diff touches'));
      const authors = authorSetFor([{ agentId: 'impl-1', files: ['src/a.js'] }], new Set(['src/a.js']));
      const anonymous = authorshipStatus(reviewSession({ lenses: allClean }), authors, { records: 1 });
      assert.deepEqual([anonymous.enforced, anonymous.lensesWithoutAgent.length], [false, 4]);
      assert.ok(anonymous.reason.includes('no lens was reported with --agent'));
      const enforced = authorshipStatus(s, authors, { records: 1 });
      assert.deepEqual([enforced.enforced, enforced.reason], [true, null]);
      const unreadable = authorshipStatus(s, new Map(), { unreadable: 'EACCES', records: 0 });
      assert.equal(unreadable.enforced, false);
      assert.ok(unreadable.reason.includes('could not be read'));
    }],
    ['authorship: an unparseable ledger line is kept and counted, never dropped', () => {
      const parsed = parseAuthorshipLines('{"agentId":"a","files":["x"]}\nnot json\n');
      assert.deepEqual([parsed.length, !!parsed[1].corrupt], [2, true]);
    }],

    // S20 backlog -- a finding may be carried, never deleted, and three kinds may not even be
    // carried: the backlog would be the waiver this engine refuses everywhere else.
    ['review backlog: security, safety and privacy are never backloggable', () => {
      const base = { owner: '@me', expiry: '2099-01-01T00:00:00.000Z', summary: 'a missing bound', lens: 'reliability' };
      assert.deepEqual(backlogViolations(base), []);
      assert.equal(backlogViolations({ ...base, lens: 'security' }).length, 1);
      assert.equal(backlogViolations({ ...base, lens: 'privacy' }).length, 1);
      assert.equal(backlogViolations({ ...base, summary: 'a credential is logged' }).length, 1);
      assert.ok(backlogViolations({ ...base, expiry: '2000-01-01T00:00:00.000Z' })[0].includes('future'));
      assert.ok(backlogViolations({ owner: '@me' })[0].includes('expiry'), 'missing fields are named');
    }],

    // S20 review-pack -- reviewers systematically read what arrived and skip what left, so a
    // rename has to appear beside the deletions rather than only inside the diff.
    ['review-pack: deletions and the old side of a rename are both what left', () => {
      const entries = parseNameStatus(['M', 'src/a.js', 'D', 'src/gone.js', 'R100', 'src/old.js', 'src/new.js', 'A', 'src/added.js']);
      assert.deepEqual(entries.map(e => e.status), ['M', 'D', 'R', 'A']);
      const audit = deletionAudit(entries);
      assert.deepEqual(audit.deleted, ['src/gone.js']);
      assert.deepEqual(audit.movedAway, ['src/old.js -> src/new.js']);
    }],

    // S20 freshness -- a session is evidence about the tree it was opened against and no other.
    ['review session: a moved tree stales the review, an absent one is not a stale one', () => {
      assert.deepEqual(freshness(reviewSession(), 'D0').ok, true);
      const stale = freshness(reviewSession(), 'D1');
      assert.deepEqual([stale.ok, !!stale.stale], [false, true]);
      const none = freshness(null, 'D0');
      assert.deepEqual([none.ok, !!none.missing, !!none.stale], [false, true, false]);
    }],

    // S21 invariants -- the non-negotiable set is read off the bold label, not off the line.
    // Several paragraphs in the constitution cite an iron rule while stating something else;
    // pulling those in would make the injected set longer and less true at the same time.
    ['invariants: an iron rule is a bold label carrying the mark, not any line mentioning it', () => {
      const doc = [
        '# main',
        '    - **flat orchestration(' + IRON_LAW_MARK + ')**: only the main agent orchestrates',
        '    - **two dispatch shapes**: judged by the flat orchestration ' + IRON_LAW_MARK + ' above',
        '    - a plain bullet naming the ' + IRON_LAW_MARK + ' with no label at all',
        '    - **evidence' + IRON_LAW_MARK + '**: ran it or it did not happen',
        '    - **flat orchestration(' + IRON_LAW_MARK + ')**: duplicated verbatim further down',
      ].join('\n');
      const laws = extractIronLaws(doc);
      assert.deepEqual(laws, [
        'flat orchestration(' + IRON_LAW_MARK + ')',
        'evidence' + IRON_LAW_MARK,
      ], 'body citations and unlabelled bullets are not rules, and a repeat is not a second rule');
      assert.deepEqual(extractIronLaws(''), []);
    }],

    // S21 invariants budget -- this text is re-injected at a compaction boundary, so it has
    // to fit inside one. The state block is rendered first on purpose: the budget eats from
    // the tail, and "where this tree stands" is the part a compaction most reliably destroys.
    ['invariants: the budget is honoured and what it dropped is stated, not swallowed', () => {
      const state = {
        task: { id: 'T-1', state: 'active', stale: true },
        fastMode: { active: true, remainingHours: 3.5 },
        gate: { verdict: 'PASS', boundToCurrentDiff: false },
        ledger: 'broken',
        pendingReview: 2,
      };
      const lines = stateLines(state);
      assert.ok(lines.join('\n').includes('stale >72h'), 'a stale task is named as stale');
      assert.ok(lines.join('\n').includes('NOT bound to the current diff'),
        'a PASS that does not bind this diff must not read as a PASS for it');
      assert.ok(lines.join('\n').includes('unproven until the gates are re-run'),
        'a broken ledger says what it costs, not just that it is broken');

      const laws = [];
      for (let i = 0; i < 60; i++) laws.push('- law number ' + i + ' with enough text to matter');
      const header = '# INVARIANTS\n\n';
      const view = renderView(header, [
        { title: '## State', items: lines },
        { title: '## Non-negotiable', items: laws },
      ], 600);
      assert.ok(view.chars <= 600, 'rendered ' + view.chars + ' chars against a 600 budget');
      assert.ok(view.omitted > 0 && view.text.includes('omitted by the 600-char budget'),
        'a view that stopped at the budget without saying so reads as complete');
      assert.ok(view.text.includes('- active task: T-1'), 'the state block outranks the rule list');
      const whole = renderView(header, [{ title: '## State', items: lines }], 1200);
      assert.deepEqual(whole.omitted, 0);
      assert.ok(whole.chars <= 1200);
    }],

    // S21 recap -- an entry becomes one line, and a cut is marked as a cut. The point of the
    // budget is that recovery costs the same on a two-year-old project as on a new one, and
    // that only holds if long entries shrink instead of being dropped at random.
    ['recap: entries reduce to a marked headline, and the budget cuts whole items', () => {
      assert.deepEqual(headline('- **the label**: and then a long tail of prose', 60), '**the label**');
      const long = '- ' + 'x'.repeat(200);
      const cut = headline(long, 40);
      assert.deepEqual([cut.length, cut.endsWith('...')], [40, true], 'a cut says it was cut');
      const view = renderView('# RECAP\n\n', [
        { title: '## A', items: ['- one', '- two'] },
        { title: '## B', items: ['- ' + 'y'.repeat(400)] },
      ], 200);
      assert.ok(view.chars <= 200);
      assert.deepEqual(view.omitted, 1, 'the oversized item is dropped whole, not truncated silently');
      assert.ok(!view.text.includes('## B'), 'a block whose items all dropped prints no heading');
    }],

    // S21 archive -- which end is the old end is read off the dates rather than assumed.
    // Guessing wrong archives the newest work and keeps the history nobody needs, and the
    // writer would not notice until the recap went strange.
    ['archive: the older end is decided by the dates, in either writing order', () => {
      const newestFirst = ['- 2026-03-03: c', '- 2026-02-02: b', '- 2026-01-01: a']
        .map(raw => ({ raw, date: /(\d{4}-\d{2}-\d{2})/.exec(raw)[1] }));
      assert.deepEqual(entryOrder(newestFirst), 'newest-first');
      assert.deepEqual(entryOrder(newestFirst.slice().reverse()), 'oldest-first');
      assert.deepEqual(entryOrder([{ raw: '- x', date: null }]), 'unknown');

      const text = ['# P', '', '## ' + SECTION_PINNED, '- **keep me**: standing', '',
        '## ' + ARCHIVABLE_SECTIONS[0], '- 2026-03-03: newest', '- 2026-02-02: middle',
        '- 2026-01-01: oldest', '', '## ' + ARCHIVABLE_SECTIONS[1], '- 2026-03-03: only note', ''].join('\n');
      const plan = planArchive(text, { maxEntries: 1 });
      const done = plan.plans.find(p => p.section === ARCHIVABLE_SECTIONS[0]);
      const notes = plan.plans.find(p => p.section === ARCHIVABLE_SECTIONS[1]);
      assert.deepEqual([done.entries, done.moving, done.order, done.at], [3, 2, 'newest-first', 'tail']);
      assert.deepEqual(notes.moving, 0, 'a section inside the cap does not move');
      assert.deepEqual(plan.total, 4);

      const flipped = planArchive(text.replace('- 2026-03-03: newest\n- 2026-02-02: middle\n- 2026-01-01: oldest',
        '- 2026-01-01: oldest\n- 2026-02-02: middle\n- 2026-03-03: newest'), { maxEntries: 1 });
      const flippedDone = flipped.plans.find(p => p.section === ARCHIVABLE_SECTIONS[0]);
      assert.deepEqual([flippedDone.order, flippedDone.at], ['oldest-first', 'head'],
        'written oldest-first, the old end is the head');
    }],

    // S21 archive -- moving is not editing. A correction belongs in a new entry, so every
    // byte that leaves has to arrive unchanged and every byte that stays has to be untouched.
    ['archive: entries move verbatim and leave a pointer, never a rewrite', () => {
      const text = ['# P', '', '## ' + ARCHIVABLE_SECTIONS[0],
        '- 2026-03-03: **newest** stays', '- 2026-02-02: middle goes',
        '  detail line belonging to the middle entry', '- 2026-01-01: oldest goes', ''].join('\n');
      const plan = planArchive(text, { maxEntries: 1 });
      const out = applyArchivePlan(text, plan, { now: '2026-04-04T00:00:00.000Z' });
      assert.ok(out.progress.includes('- 2026-03-03: **newest** stays'), 'the kept entry is byte-identical');
      assert.ok(!out.progress.includes('middle goes'), 'the moved entry left the memory file');
      assert.ok(!out.progress.includes('detail line belonging'), 'its detail line went with it');
      assert.ok(out.archiveAppend.includes('- 2026-02-02: middle goes\n  detail line belonging to the middle entry'),
        'the moved entry arrives byte for byte, detail lines included');
      assert.ok(out.archiveAppend.includes('- 2026-01-01: oldest goes'));
      assert.ok(out.archiveAppend.includes('Archived from ' + ARCHIVABLE_SECTIONS[0] + ' on 2026-04-04'));
      const pointers = out.progress.split('\n').filter(l => l.includes('progress.archive.md'));
      assert.deepEqual(pointers.length, 1, 'exactly one pointer marks the move');
      assert.ok(pointers[0].includes('2026-01-01') && pointers[0].includes('2026-02-02'),
        'the pointer names the range that left, so the reader knows where to look');
      // Every surviving line of the original is still present, unedited.
      for (const l of text.split('\n')) {
        if (!l.trim() || l.includes('goes') || l.includes('detail line')) continue;
        assert.ok(out.progress.split('\n').includes(l), 'line was rewritten: ' + JSON.stringify(l));
      }
      // A second pointer is not counted as an entry, so re-running cannot cascade.
      const again = planArchive(out.progress, { maxEntries: 1 });
      assert.deepEqual(again.plans.find(p => p.section === ARCHIVABLE_SECTIONS[0]).entries, 1);
    }],

    // S21 sync-check -- the decidable half of the three-file rule. It can tell whether the
    // files moved together; it cannot tell whether what was written is true, and it does not
    // pretend to. Runtime state changing is not work anyone has to remember.
    ['sync-check: memory behind code, spec without changelog, and the quiet case', () => {
      const present = { progressPresent: true, specPresent: true, changelogPresent: true };
      const codes = fs => fs.map(f => f.code);

      assert.deepEqual(codes(syncFindings(['src/a.ts'], present)), ['MEMORY_BEHIND_CODE']);
      assert.deepEqual(codes(syncFindings(['src/a.ts', 'progress.md'], present)), [],
        'code and memory in the same change set is the whole point');
      assert.deepEqual(codes(syncFindings(['Product-Spec.md', 'progress.md'], present)),
        ['SPEC_WITHOUT_CHANGELOG']);
      assert.deepEqual(codes(syncFindings(['Product-Spec.md', 'Product-Spec-CHANGELOG.md', 'progress.md'], present)), []);
      assert.deepEqual(codes(syncFindings(['src/a.ts'], { ...present, progressPresent: false })), [],
        'a project with no memory file is not a project behind on its memory');
      assert.deepEqual(codes(syncFindings([], present)), [], 'nothing changed, nothing to record');
      const both = syncFindings(['src/a.ts', 'Product-Spec.md'], present);
      assert.deepEqual(codes(both), ['MEMORY_BEHIND_CODE', 'SPEC_WITHOUT_CHANGELOG']);
      assert.ok(both[0].sample.includes('src/a.ts'), 'the finding names what it saw');

      assert.deepEqual(['src/a.ts', '.claude/hooks/x.sh', 'lib/y.mjs', 'setup.ps1'].filter(isTrackedWork).length, 4);
      assert.deepEqual(['README.md', 'progress.md', '.claude/evidence/log.txt',
        '.claude/harness/state/task.json', 'node_modules/x/index.js', '.env'].filter(isTrackedWork), [],
        'documents and runtime state are not the code the memory has to keep up with');
      assert.deepEqual(codes(syncFindings(['.claude/harness/state/task.json'], present)), [],
        'the harness writing its own state must not fire the gate');
    }],

    // S21 sections -- an entry is its bullet plus the lines under it, and a pointer left by
    // an earlier archive run is bookkeeping rather than a memory entry.
    ['progress sections: an entry carries its detail lines; a pointer is not an entry', () => {
      const doc = splitSections(['# P', '', '## ' + SECTION_PINNED,
        '- first', '  continued here', '- second', '',
        '- _archived 3 earlier entries into progress.archive.md_', '',
        '## Other', '- elsewhere'].join('\n'));
      const entries = sectionEntries(doc, SECTION_PINNED);
      assert.deepEqual(entries.length, 3);
      assert.deepEqual(entries[0].text, '- first\n  continued here');
      assert.deepEqual(entries.map(e => e.pointer), [false, false, true]);
      assert.deepEqual(sectionEntries(doc, 'Nowhere'), []);
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
