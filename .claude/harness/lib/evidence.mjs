// lib/evidence.mjs -- S17 the evidence layer: a gate that records what it actually ran, a
// hash-chained ledger that makes those records tamper-evident, and three readers that keep
// the pile honest as it ages (gate-audit / retention / risk).
//
// How this differs from S8 verify, and why verify is left untouched: verify answers "does
// the gate pass right now" and three hook pairs consume its stdout and exit codes, so its
// shape is a contract. `gate` answers the same question through the same verifyPlan() --
// four-state aggregation, waivers, the quality-attribute gate -- and additionally leaves
// behind something that can be re-read later: each executed check's raw output on disk
// with its digest, a digest of the resolved plan, and one append-only ledger line binding
// all of it to a diff. A green with no retrievable output is a claim; this is evidence.
//
// The ledger fails closed on purpose. A broken chain means every earlier verification is
// treated as unproven (task complete blocks, risk reports LEDGER_BROKEN), and there is
// deliberately no "repair the ledger" command: the chain IS the evidence, so a repair tool
// would be a forgery tool. The only honest recovery is to re-run the gates that mattered.
//
// Depends on core / catalog / graph / quality. Nothing here imports task.mjs (task.mjs
// imports this one for the state paths and the chain check), so the graph stays acyclic.

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import {
  TIER_ENFORCEMENT,
  changedPaths, emit, gitFingerprint, headCommit, normalizeTier, parseCsv, projectRoot, sha256,
} from './core.mjs';
import { loadCatalog } from './catalog.mjs';
import { analyzeImpact } from './graph.mjs';
import {
  claimingChecks, fastModeActive, loadWaivers, requiredChecks, resolveCheck, runCheck,
  verifyPlan, waiversDir,
} from './quality.mjs';

// ---------------------------------------------------------------------------
// S17.1 runtime state locations + atomic write
// ---------------------------------------------------------------------------
// Both directories are git-ignored, excluded from the diff fingerprint (running the engine
// must not stale its own evidence) and excluded from context-pack (runtime state never
// reaches a delegate). Those three exclusions live in core.mjs beside the existing ones.

function stateDir() {
  return path.join(projectRoot(), '.claude', 'harness', 'state');
}
function ledgerFilePath() {
  return path.join(stateDir(), 'ledger.jsonl');
}
function taskFilePath() {
  return path.join(stateDir(), 'task.json');
}
function evidenceDir() {
  return path.join(projectRoot(), '.claude', 'harness', 'evidence');
}
function contextPackDir() {
  return path.join(stateDir(), 'context');
}

/** Project-relative, forward-slashed path -- what goes into a record a human will read. */
function relFromRoot(p) {
  return path.relative(projectRoot(), p).split(path.sep).join('/');
}

/** Write through a temp file + rename, so a killed process never leaves half a record. */
function writeAtomic(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = file + '.tmp-' + process.pid;
  fs.writeFileSync(tmp, data, 'utf8');
  fs.renameSync(tmp, file);
}

/**
 * sha256 over LF-normalized text. A CRLF checkout must not produce a different digest for
 * the same content, or the chain would break for a reason that has nothing to do with
 * tampering -- the exact false alarm that gets a control switched off.
 */
function sha256Lf(text) {
  return sha256(String(text).replace(/\r\n/g, '\n'));
}

/** Read a JSON file, or return the fallback (never throws). */
function readJsonFile(file, fallback = null) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_e) { return fallback; }
}

/** The active task record, or null. Lives here because task.json is state-dir state. */
function readTaskRecord() {
  return readJsonFile(taskFilePath(), null);
}

// ---------------------------------------------------------------------------
// S17.2 ledger  (append-only, hash-chained; a break fails closed)
// ---------------------------------------------------------------------------
//   contentHash = sha256(LF(JSON.stringify(record)))
//   chain       = sha256(prev + NUL + contentHash)
//   prev        = the previous line's chain, 64 zeros for the first line
//   line        = { ...record, contentHash, prev, chain }

const GENESIS = '0'.repeat(64);

/** One chain link. Pure. */
function chainHash(prev, contentHash) {
  return sha256(String(prev) + '\0' + String(contentHash));
}

/** Build the line for a record given the previous line's chain. Pure. */
function ledgerLine(record, prev) {
  const contentHash = sha256Lf(JSON.stringify(record));
  return { ...record, contentHash, prev, chain: chainHash(prev, contentHash) };
}

/** Read the ledger; an unparseable line is kept as {corrupt:true,raw} rather than dropped. */
function readLedger() {
  let raw;
  try { raw = fs.readFileSync(ledgerFilePath(), 'utf8'); } catch (_e) { return []; }
  return raw.split('\n').filter(Boolean).map(l => {
    try { return JSON.parse(l); } catch (_e) { return { corrupt: true, raw: l }; }
  });
}

/** Append one record and return the written line. */
function appendLedger(record) {
  const entries = readLedger();
  const last = entries.length ? entries[entries.length - 1] : null;
  const prev = (last && typeof last.chain === 'string') ? last.chain : GENESIS;
  const line = ledgerLine(record, prev);
  fs.mkdirSync(stateDir(), { recursive: true });
  fs.appendFileSync(ledgerFilePath(), JSON.stringify(line) + '\n', 'utf8');
  return line;
}

/**
 * Recompute the whole chain and name every break. Pure + injectable so selftest can feed
 * a forged history without touching disk.
 * Break kinds: unparseable-line / content-hash-mismatch / chain-predecessor-mismatch /
 * chain-hash-mismatch. Line numbers are 1-based, because that is how a person counts them
 * when they open the file.
 * @param {Array<Object>} entries
 * @returns {{ok:boolean,entries:number,breaks:Array,head:string}}
 */
function verifyLedgerChain(entries) {
  const list = Array.isArray(entries) ? entries : [];
  const breaks = [];
  let prev = GENESIS;
  list.forEach((e, i) => {
    const line = i + 1;
    if (!e || typeof e !== 'object' || e.corrupt) {
      breaks.push({ line, reason: 'unparseable-line', at: null });
      return;
    }
    const { contentHash, prev: recordedPrev, chain, ...rest } = e;
    const at = typeof e.at === 'string' ? e.at : null;
    if (sha256Lf(JSON.stringify(rest)) !== contentHash) {
      breaks.push({ line, reason: 'content-hash-mismatch', at });
    }
    if (recordedPrev !== prev) {
      breaks.push({ line, reason: 'chain-predecessor-mismatch', at });
    }
    if (chainHash(prev, contentHash) !== chain) {
      breaks.push({ line, reason: 'chain-hash-mismatch', at });
    }
    prev = typeof chain === 'string' ? chain : prev;
  });
  return { ok: breaks.length === 0, entries: list.length, breaks, head: prev };
}

/**
 * `ledger` subcommand: recompute the chain, report every break, exit 1 on any.
 * There is no repair mode, and that is the design: a command that rewrites the chain into
 * agreement is a forgery tool. Re-run the gates instead.
 */
function cmdLedger(_flags) {
  const res = verifyLedgerChain(readLedger());
  if (!res.ok) {
    process.stderr.write('ledger chain broken (' + res.breaks.length + ' break(s)) at ' + relFromRoot(ledgerFilePath()) + '\n');
    for (const b of res.breaks.slice(0, 10)) {
      process.stderr.write('  line ' + b.line + ': ' + b.reason + (b.at ? ' (' + b.at + ')' : '') + '\n');
    }
    if (res.breaks.length > 10) process.stderr.write('  ... ' + (res.breaks.length - 10) + ' more break(s)\n');
    process.stderr.write('every verification recorded here is unproven until the gates are re-run; do not hand-repair the file\n');
  }
  return emit({ ...res, path: relFromRoot(ledgerFilePath()) }, res.ok ? 0 : 1);
}

// ---------------------------------------------------------------------------
// S17.3 gate  (verify + evidence on disk + planHash + one ledger entry)
// ---------------------------------------------------------------------------

/**
 * The resolved verification plan for a set of affected modules: which check ids will run,
 * and for which modules. Sorted by check id with module lists sorted too, so planHash is a
 * function of the plan and not of catalog key order.
 * @returns {{entries:Array<{checkId:string,modules:string[]}>,hash:string,empty:boolean}}
 */
function buildPlan(affected, catalog) {
  const byId = new Map(((catalog && catalog.modules) || []).map(m => [m.id, m]));
  const planned = new Map();
  for (const id of (affected || [])) {
    const m = byId.get(id);
    if (!m) continue;
    for (const ref of requiredChecks(m.riskTier, m, catalog)) {
      const spec = resolveCheck(ref, catalog);
      const checkId = String(spec.id || spec.command || ref);
      if (!planned.has(checkId)) planned.set(checkId, { checkId, modules: [] });
      const entry = planned.get(checkId);
      if (!entry.modules.includes(id)) entry.modules.push(id);
    }
  }
  const cmp = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
  const entries = [...planned.values()]
    .map(e => ({ checkId: e.checkId, modules: e.modules.slice().sort(cmp) }))
    .sort((a, b) => cmp(a.checkId, b.checkId));
  return {
    entries,
    hash: sha256Lf(JSON.stringify(entries.map(e => [e.checkId, e.modules]))),
    empty: entries.length === 0,
  };
}

// A check id can legitimately run once per affected module, and four of those land in the
// same millisecond, so the epoch alone is not a unique name. First collision falls back to
// a suffix rather than silently overwriting one check's output with another's.
function evidenceFilePath(id) {
  const safeId = String(id == null ? '' : id).replace(/[^A-Za-z0-9._-]/g, '_').slice(0, 120) || 'check';
  const base = path.join(evidenceDir(), safeId + '-' + Date.now());
  let file = base + '.log';
  for (let n = 1; fs.existsSync(file); n++) file = base + '-' + n + '.log';
  return file;
}

/**
 * The gate's check runner: the same four-state decision as verify (runCheck is reused
 * verbatim, not reimplemented) plus the raw output written to .claude/harness/evidence/.
 * Checks that never ran -- BLOCKED for a missing binary, SKIPPED by fast-mode -- get no
 * evidence file, because an empty log reads exactly like a command that ran and said
 * nothing, and those two states must stay distinguishable.
 */
function runCheckWithEvidence(spec, opts) {
  const started = Date.now();
  const res = runCheck(spec, { ...opts, capture: true });
  const durationMs = Date.now() - started;
  const { stdout, stderr, ...rest } = res;
  const out = { ...rest, durationMs };
  if (res.state !== 'PASS' && res.state !== 'FAIL') {
    return { ...out, evidence: null, evidenceSha256: null };
  }
  const output = String(stdout || '') + (stderr ? '\n--- stderr ---\n' + String(stderr) : '');
  try {
    const file = evidenceFilePath(res.id);
    writeAtomic(file, output);
    return { ...out, evidence: relFromRoot(file), evidenceSha256: sha256Lf(output) };
  } catch (e) {
    // The check itself already produced its verdict; failing to persist the log must be
    // visible in the record rather than swallowed, and must not rewrite that verdict.
    return { ...out, evidence: null, evidenceSha256: null, evidenceError: String(e && e.message || e) };
  }
}

/** Human-readable why behind a gate state. Pure. */
function gateReason(gate, run) {
  if (gate === 'FAIL') return 'at-least-one-check-failed';
  if (gate === 'BLOCKED') {
    return run.emptyPlan
      ? 'empty-plan: modules were affected but no check resolved, so nothing was established'
      : 'at-least-one-check-blocked';
  }
  if (gate === 'BLOCKED_BY_ATTRIBUTES') {
    return run.attributeGaps.length + ' blocking quality-attribute gap(s): checks that prove '
      + 'nothing about a critical/high attribute do not close the gate';
  }
  if (!run.checks.length) return 'no-affected-module';
  if (run.checks.every(c => c.state === 'SKIPPED')) return 'every-check-skipped';
  return 'all-executed-checks-passed';
}

/** Which waivers actually fired, with the file that granted them. */
function waiversApplied(checks, waivers) {
  const out = [];
  for (const c of (checks || [])) {
    if (typeof c.reason !== 'string' || !c.reason.startsWith('waiver:')) continue;
    const scope = c.reason.slice('waiver:'.length);
    const w = (waivers || []).find(x => x && x.scope === scope) || null;
    out.push({
      check: c.id,
      scope,
      waiver: (w && w._path) ? relFromRoot(w._path) : null,
      expiry: (w && typeof w.expiry === 'string') ? w.expiry : null,
    });
  }
  return out;
}

/**
 * `gate` subcommand. Exit convention is verify's, unchanged:
 *   PASS -> 0; FAIL / BLOCKED / blocking attribute gap -> 2; no catalog or non-git -> 3.
 * Note one inherited semantic: cc-base's verifyPlan aggregates an all-SKIPPED run to PASS
 * (fast-mode and waivers do not block), so the gate reports every-check-skipped as the
 * reason while still exiting 0. That debt is surfaced by `risk` (FAST_MODE_DEBT), which is
 * where a deferred-evidence problem belongs -- not silently inside a green.
 */
function cmdGate(flags) {
  const loaded = loadCatalog(typeof flags.catalog === 'string' ? flags.catalog : undefined);
  if (!loaded.ok) {
    return emit({
      gate: 'DEGRADED', degraded: true, reason: loaded.error, detail: loaded.detail,
      modules: [], results: [],
    }, 3);
  }
  const catalog = loaded.catalog;

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
    return emit({ gate: 'DEGRADED', degraded: true, reason: 'non-git', modules: [], results: [] }, 3);
  }

  const fastActive = fastModeActive();
  const imp = analyzeImpact(changed, catalog, { nonGit });
  const plan = buildPlan(imp.affected, catalog);
  const run = verifyPlan(changed, catalog, { fastActive, nonGit, runCheckFn: runCheckWithEvidence });

  const attrBlocked = Array.isArray(run.attributeGaps) && run.attributeGaps.length > 0;
  const gate = (run.state === 'FAIL' || run.state === 'BLOCKED') ? run.state
    : attrBlocked ? 'BLOCKED_BY_ATTRIBUTES' : 'PASS';
  const cmp = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
  const record = {
    command: 'gate',
    at: new Date().toISOString(),
    gate,
    reason: gateReason(gate, run),
    baseCommit: headCommit(),
    diffHash: gitFingerprint(),
    planHash: plan.hash,
    modules: run.affected.slice().sort(cmp),
    degraded: !!run.degraded,
    fastActive,
    skippedByFastMode: run.checks.filter(c => c.reason === 'fast-mode').map(c => c.id),
    results: run.checks.map(c => ({
      id: c.id,
      module: c.module === undefined ? null : c.module,
      state: c.state,
      reason: c.reason === undefined ? null : c.reason,
      exit: c.exit === undefined ? null : c.exit,
      durationMs: c.durationMs === undefined ? null : c.durationMs,
      evidence: c.evidence === undefined ? null : c.evidence,
      evidenceSha256: c.evidenceSha256 === undefined ? null : c.evidenceSha256,
    })),
    attributeCoverage: run.attributes,
    attributeGaps: run.attributeGaps,
    waivers: waiversApplied(run.checks, loadWaivers()),
  };
  const line = appendLedger(record);
  return emit({ ...record, ledger: { path: relFromRoot(ledgerFilePath()), chain: line.chain } },
    gate === 'PASS' ? 0 : 2);
}

// ---------------------------------------------------------------------------
// S17.4 gate-audit  (a control that has never intervened is cost plus false confidence)
// ---------------------------------------------------------------------------
// Scope note: this audits CATALOG CHECKS against the harness ledger. The framework also
// ships .claude/scripts/gate-audit.sh, which audits HOOK gates against
// .claude/evidence/gate-block.log. Different subjects, different evidence files, neither
// replaces the other -- and neither should be merged into the other, or the answer to
// "which gate never fired" would quietly cover only half the gates.

/** Pure: fold a ledger into per-check execution/intervention history. */
function auditGates(entries, catalog) {
  const declared = Object.keys((catalog && catalog.checks) || {});
  const executed = new Set();
  const intervened = new Set();
  let gateRuns = 0;
  for (const e of (entries || [])) {
    if (!e || e.corrupt || e.command !== 'gate') continue;
    gateRuns++;
    for (const r of (e.results || [])) {
      if (r.state === 'PASS' || r.state === 'FAIL') executed.add(r.id);
      if (r.state === 'FAIL' || r.state === 'BLOCKED') intervened.add(r.id);
    }
  }
  const cmp = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
  const neverIntervened = declared.filter(id => !intervened.has(id)).sort(cmp);
  const neverExecuted = declared.filter(id => !executed.has(id)).sort(cmp);
  return {
    scope: 'catalog checks in the harness ledger (hook gates are audited by .claude/scripts/gate-audit.sh)',
    gateRuns,
    declaredChecks: declared.length,
    neverIntervened,
    neverExecuted,
    advice: neverIntervened.length
      ? 'These checks have never failed or blocked. Either they are genuinely stable, or they never actually run. '
        + 'Confirm with evidence before keeping them -- a gate that has caught nothing is cost plus false confidence.'
      : 'Every declared check has intervened at least once.',
  };
}

/** `gate-audit` subcommand: report only, always exit 0 (no catalog -> 3). */
function cmdGateAudit(flags) {
  const loaded = loadCatalog(typeof flags.catalog === 'string' ? flags.catalog : undefined);
  if (!loaded.ok) {
    return emit({ ok: false, degraded: true, error: loaded.error, detail: loaded.detail }, 3);
  }
  return emit({ ok: true, ...auditGates(readLedger(), loaded.catalog) }, 0);
}

// ---------------------------------------------------------------------------
// S17.5 retention  (privacy includes disposal; runtime state must not only accumulate)
// ---------------------------------------------------------------------------

/**
 * Which files a sweep would remove, newest first: the `keep` newest survive on count,
 * anything older than the cutoff goes, and a file the ledger references is never a
 * candidate -- deleting it would destroy the only proof behind a recorded green.
 * Pure + injectable.
 * @param {Array<{path:string,mtimeMs:number}>} files
 * @param {{protectedPaths?:Set<string>,keep?:number,cutoffMs?:number}} [opts]
 */
function planRetention(files, { protectedPaths = new Set(), keep = 0, cutoffMs = 0 } = {}) {
  const sorted = (files || []).slice().sort((a, b) => (b.mtimeMs - a.mtimeMs)
    || (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
  const out = [];
  sorted.forEach((f, i) => {
    if (protectedPaths.has(f.path)) return;
    const overCount = i >= keep;
    const overAge = f.mtimeMs < cutoffMs;
    if (!overCount && !overAge) return;
    out.push({ path: f.path, reason: overCount ? 'over-count' : 'over-age' });
  });
  return out;
}

/** Every evidence path any ledger record points at. These are never sweep candidates. */
function ledgerReferencedEvidence(entries) {
  const out = new Set();
  for (const e of (entries || [])) {
    if (!e || e.corrupt) continue;
    for (const r of (e.results || [])) {
      if (r && typeof r.evidence === 'string' && r.evidence) out.add(r.evidence);
    }
  }
  return out;
}

/** Files directly inside a directory, as {path (project-relative), mtimeMs}. */
function listDirFiles(dir) {
  let names;
  try { names = fs.readdirSync(dir); } catch (_e) { return []; }
  const out = [];
  for (const n of names.sort()) {
    const abs = path.join(dir, n);
    try {
      const st = fs.statSync(abs);
      if (st.isFile()) out.push({ path: relFromRoot(abs), mtimeMs: st.mtimeMs });
    } catch (_e) { /* vanished between readdir and stat; nothing to prune */ }
  }
  return out;
}

function intFlag(v, dflt) {
  if (typeof v !== 'string') return dflt;
  const n = parseInt(v, 10);
  return (Number.isNaN(n) || n < 0) ? dflt : n;
}

/**
 * `retention` subcommand: prune evidence logs and context packs by age and count.
 * Dry-run by default -- it reports what it would remove and removes nothing until --apply,
 * because a pruning tool that deletes on the first accidental invocation is worse than the
 * pile it cleans. Exit 0, or 1 if --apply could not remove something it planned to.
 */
function cmdRetention(flags) {
  const apply = flags.apply === true || flags.apply === 'true';
  const maxAgeDays = intFlag(flags['max-age-days'], 30);
  const maxEvidence = intFlag(flags['max-evidence'], 400);
  const maxPacks = intFlag(flags['max-packs'], 60);
  const cutoffMs = Date.now() - maxAgeDays * 86400000;
  const protectedPaths = ledgerReferencedEvidence(readLedger());

  const plan = [
    ...planRetention(listDirFiles(evidenceDir()), { protectedPaths, keep: maxEvidence, cutoffMs }),
    ...planRetention(listDirFiles(contextPackDir()), { protectedPaths, keep: maxPacks, cutoffMs }),
  ];

  let removed = 0;
  const errors = [];
  if (apply) {
    for (const item of plan) {
      try { fs.unlinkSync(path.join(projectRoot(), item.path)); removed++; }
      catch (e) { errors.push({ path: item.path, error: String(e && e.message || e) }); }
    }
    for (const err of errors) process.stderr.write('retention could not remove ' + err.path + ': ' + err.error + '\n');
  }
  return emit({
    ok: errors.length === 0,
    applied: apply,
    candidates: plan.length,
    removed,
    protectedByLedger: protectedPaths.size,
    limits: { maxAgeDays, maxEvidence, maxPacks },
    dirs: {
      evidence: relFromRoot(evidenceDir()),
      // context-pack currently streams to stdout rather than writing packs to disk, so
      // this sweep is a no-op until packs land here. Wired now so the disposal rule does
      // not have to be remembered later.
      contextPacks: relFromRoot(contextPackDir()),
    },
    plan: plan.slice(0, 100),
    errors,
  }, errors.length === 0 ? 0 : 1);
}

// ---------------------------------------------------------------------------
// S17.6 risk  (state decay: the things that rot while nobody is looking at them)
// ---------------------------------------------------------------------------

/** Waiver files as written on disk -- including expired ones, which loadWaivers drops. */
function readWaiverFiles() {
  const dir = waiversDir();
  let names;
  try { names = fs.readdirSync(dir); } catch (_e) { return []; }
  const out = [];
  for (const n of names.sort()) {
    if (!n.endsWith('.json')) continue;
    const fp = path.join(dir, n);
    const obj = readJsonFile(fp, null);
    if (obj && typeof obj === 'object') out.push({ ...obj, _path: fp });
  }
  return out;
}

/**
 * Decay scan over injected state (pure, so selftest can construct each finding without a
 * repository). Error severity closes the exit code; warnings are reported and do not.
 * @param {{ledgerEntries?:Array,catalog?:Object|null,waivers?:Array,task?:Object|null,
 *          fastActive?:boolean,now?:number}} [input]
 */
function riskFindings({ ledgerEntries = [], catalog = null, waivers = [], task = null,
  fastActive = false, now = Date.now() } = {}) {
  const findings = [];

  const chain = verifyLedgerChain(ledgerEntries);
  if (!chain.ok) {
    findings.push({
      severity: 'error', code: 'LEDGER_BROKEN',
      message: 'the verification ledger chain is broken (' + chain.breaks.length
        + ' break(s), first at line ' + chain.breaks[0].line + ': ' + chain.breaks[0].reason
        + '); treat every recorded green as unproven and re-run the gates',
    });
  }

  for (const w of waivers) {
    const expiryMs = Date.parse(w && w.expiry);
    if (!Number.isNaN(expiryMs) && expiryMs <= now) {
      findings.push({
        severity: 'error', code: 'EXPIRED_WAIVER',
        message: 'waiver ' + (w._path ? relFromRoot(w._path) : (w.scope || 'unknown'))
          + ' expired on ' + w.expiry + ' and is now inert; delete it or renew it with a fresh justification',
      });
    }
  }

  if (catalog) {
    for (const m of (catalog.modules || [])) {
      for (const [attr, req] of Object.entries(m.attributes || {})) {
        const { tier } = normalizeTier(req);
        if (TIER_ENFORCEMENT[tier] !== 'block') continue;
        if (claimingChecks(m, catalog, attr).length > 0) continue;
        findings.push({
          severity: 'error', code: 'UNWIRED_ATTRIBUTE', module: m.id, attribute: attr, tier,
          message: 'module "' + m.id + '" declares ' + attr + ' at tier ' + tier
            + ' but no check in its verification plan claims that attribute',
        });
      }
    }
  }

  // Consecutive failures per check over the recent ledger. A PASS resets the streak; a
  // BLOCKED or SKIPPED result establishes nothing either way and leaves it alone.
  const streak = new Map();
  for (const e of ledgerEntries.slice(-30)) {
    if (!e || e.corrupt || e.command !== 'gate') continue;
    for (const r of (e.results || [])) {
      if (r.state === 'FAIL') streak.set(r.id, (streak.get(r.id) || 0) + 1);
      else if (r.state === 'PASS') streak.set(r.id, 0);
    }
  }
  const streakIds = [...streak.keys()].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  for (const id of streakIds) {
    const n = streak.get(id);
    if (n < 3) continue;
    findings.push({
      severity: 'warning', code: 'FAIL_STREAK', check: id,
      message: 'check "' + id + '" failed ' + n + ' times in a row; stop re-running it and go find the root cause',
    });
  }

  const gates = ledgerEntries.filter(e => e && !e.corrupt && e.command === 'gate');
  const latestGate = gates.length ? gates[gates.length - 1] : null;
  if (latestGate && latestGate.fastActive && (latestGate.skippedByFastMode || []).length) {
    findings.push({
      severity: 'error', code: 'FAST_MODE_DEBT',
      message: 'the newest gate ran under Fast Mode and skipped ['
        + latestGate.skippedByFastMode.join(', ') + ']; that evidence was deferred, not waived -- '
        + 'turn Fast Mode off and run a full gate before treating the work as verified',
    });
  }
  if (fastActive) {
    findings.push({
      severity: 'warning', code: 'FAST_MODE_OPEN',
      message: 'Fast Mode is open; evidence is being deferred, and the window closes on its own expiry, not on the work being done',
    });
  }

  if (task && task.state === 'active') {
    const startedMs = Date.parse(task.startedAt);
    if (!Number.isNaN(startedMs)) {
      const ageH = Math.round((now - startedMs) / 3600000);
      if (ageH > 72) {
        findings.push({
          severity: 'warning', code: 'STALE_TASK', task: task.id || null,
          message: 'task "' + (task.id || 'unknown') + '" has been active for ' + ageH
            + 'h; close it or restate the goal -- a task nobody finished is a plan nobody follows',
        });
      }
    }
  }

  const errorCount = findings.filter(f => f.severity === 'error').length;
  return {
    ok: errorCount === 0,
    findings,
    counts: { error: errorCount, warning: findings.length - errorCount },
  };
}

/** `risk` subcommand: catalog optional; any error-severity finding exits 1. */
function cmdRisk(flags) {
  const loaded = loadCatalog(typeof flags.catalog === 'string' ? flags.catalog : undefined);
  const catalog = loaded.ok ? loaded.catalog : null;
  const res = riskFindings({
    ledgerEntries: readLedger(),
    catalog,
    waivers: readWaiverFiles(),
    task: readTaskRecord(),
    fastActive: fastModeActive(),
  });
  if (!res.ok) {
    for (const f of res.findings.filter(x => x.severity === 'error')) {
      process.stderr.write(f.code + ': ' + f.message + '\n');
    }
  }
  return emit({ ...res, catalogPresent: loaded.ok }, res.ok ? 0 : 1);
}

export {
  GENESIS,
  stateDir, ledgerFilePath, taskFilePath, evidenceDir, contextPackDir, relFromRoot,
  writeAtomic, sha256Lf, readJsonFile, readTaskRecord,
  chainHash, ledgerLine, readLedger, appendLedger, verifyLedgerChain, cmdLedger,
  buildPlan, evidenceFilePath, runCheckWithEvidence, gateReason, waiversApplied, cmdGate,
  auditGates, cmdGateAudit,
  planRetention, ledgerReferencedEvidence, listDirFiles, cmdRetention,
  readWaiverFiles, riskFindings, cmdRisk,
};
