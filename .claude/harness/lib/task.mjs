// lib/task.mjs -- S18 the task envelope and the blast-radius budget: the two places where
// "what am I allowed to do here" stops being a paragraph in a prompt and becomes something
// a command can answer.
//
// The envelope is CLAUDE.md's six fields (Goal / Scope / Out of Scope / Existing Pattern /
// Verification / Escalation) plus an id, checked by the engine rather than by whoever
// remembers to check it. A missing field is named, not summarised: "incomplete envelope"
// tells a fresh instance nothing it can act on. Fields that genuinely do not apply are
// written "N/A" -- an explicit nothing, which is a decision, unlike an absent key.
//
// `task complete` is the hard end of it. Four conditions must hold before a task may be
// called done, and each one that does not is returned by name in blockers[]. This is the
// machine form of the acceptance rule: a subagent reporting DONE is a claim about itself,
// while a PASS gate bound to this exact diff, an accepting receipt bound to the same diff,
// an intact chain and a non-empty plan are claims that can be re-checked by someone else.
//
// `budget` is deliberately the softest thing in the file. Going over is not a violation to
// be punished; it is a signal to split the work or to escalate it on purpose. Wide changes
// are sometimes correct, and a budget that forbids them just teaches people to disable it.
//
// Depends on core / catalog / graph / quality / evidence. Nothing imports this module
// except the CLI and selftest, so the graph stays acyclic.

import process from 'node:process';
import {
  changedPaths, emit, git, gitFingerprint, headCommit, isGitRepo, isStateExcluded, parseCsv,
  readStdin, splitNul,
} from './core.mjs';
import { loadCatalog } from './catalog.mjs';
import { analyzeImpact } from './graph.mjs';
import { loadReceipts, receiptIntact, safeTaskId } from './quality.mjs';
import {
  buildPlan, readLedger, readTaskRecord, relFromRoot, taskFilePath, verifyLedgerChain, writeAtomic,
} from './evidence.mjs';

// ---------------------------------------------------------------------------
// S18.1 task envelope
// ---------------------------------------------------------------------------

// existingPattern is required here even though the sibling engine this borrows from treats
// it as prompt-only. The whole point of the envelope is that a fresh instance with no
// session history is told which existing implementation to follow; leaving that field
// optional is how a delegate ends up inventing a second way to do something the repository
// already does. "N/A" satisfies it when there genuinely is no precedent.
const TASK_REQUIRED_FIELDS = ['id', 'goal', 'scope', 'outOfScope', 'existingPattern', 'verification', 'escalation'];

/**
 * Validate an envelope. Pure. Returns which required fields are missing, by name.
 * @param {any} input
 * @returns {{ok:boolean,missing:string[],detail:string|null}}
 */
function validateEnvelope(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) {
    return { ok: false, missing: TASK_REQUIRED_FIELDS.slice(), detail: 'envelope must be a JSON object' };
  }
  const missing = TASK_REQUIRED_FIELDS.filter(f => typeof input[f] !== 'string' || !input[f].trim());
  if (missing.length === 0 && !safeTaskId(input.id)) {
    return { ok: false, missing: ['id'], detail: 'id must contain at least one of [A-Za-z0-9._-]' };
  }
  return { ok: missing.length === 0, missing, detail: null };
}

/**
 * The record the engine stores: the caller's envelope with a sanitized id and the three
 * fields only the engine can know. Caller-supplied extras are kept -- dropping them would
 * silently discard context somebody chose to write down.
 * @param {Object} envelope
 * @param {{now:string,baseCommit:string|null}} ctx
 */
function buildTaskRecord(envelope, { now, baseCommit }) {
  return {
    ...envelope,
    // Sanitized and length-capped even though the id is not a filename today: it is echoed
    // into the ledger and read back by other tools, and an id that can carry a separator is
    // a path traversal waiting for the first tool that does turn it into a filename.
    id: safeTaskId(envelope.id).slice(0, 120),
    state: 'active',
    baseCommit,
    startedAt: now,
  };
}

/** True if a receipt accepts the review of exactly this diff. */
function acceptingReceipt(receipts, diffHash) {
  const accepting = new Set(['accept', 'pass']);
  for (const r of (receipts || [])) {
    if (!receiptIntact(r)) continue;
    if (r.diffHash !== diffHash) continue;
    if (accepting.has(String(r.verdict || '').trim().toLowerCase())) return r;
  }
  return null;
}

/**
 * The four blocking conditions of `task complete`, each returned by name when it fails.
 * Pure + injectable so selftest can trip them one at a time.
 * @param {{latestGate?:Object|null,currentDiffHash?:string,receipts?:Array,
 *          ledgerOk?:boolean,planEmpty?:boolean}} [input]
 * @returns {string[]}
 */
function completeBlockers({ latestGate = null, currentDiffHash = '', receipts = [],
  ledgerOk = true, planEmpty = true } = {}) {
  const blockers = [];
  const gateFresh = !!latestGate && latestGate.gate === 'PASS' && latestGate.diffHash === currentDiffHash;
  if (!gateFresh) {
    blockers.push('no PASS gate record bound to the current diffHash'
      + (latestGate ? ' (newest gate: ' + latestGate.gate + ' on ' + String(latestGate.diffHash).slice(0, 12) + ')' : ' (no gate has ever run)')
      + '; run: harness.mjs gate');
  }
  if (!acceptingReceipt(receipts, currentDiffHash)) {
    blockers.push('no fresh accepting review receipt bound to the current diffHash; '
      + 'have the reviewer write one: harness.mjs receipt write');
  }
  if (!ledgerOk) {
    blockers.push('the ledger chain is broken, so every recorded verification is unproven; '
      + 're-run the gates rather than repairing the file');
  }
  if (planEmpty) {
    blockers.push('the verification plan is empty: nothing would have run, so nothing was established');
  }
  return blockers;
}

/** The newest gate record in the ledger, or null. */
function latestGateRecord(entries) {
  const gates = (entries || []).filter(e => e && !e.corrupt && e.command === 'gate');
  return gates.length ? gates[gates.length - 1] : null;
}

/**
 * CLI: task start | status | complete.
 *   start     stdin JSON envelope -> writes state/task.json (exit 3 names missing fields)
 *   status    the record plus the current diffHash (always exit 0)
 *   complete  exit 0 only when all four conditions hold; otherwise exit 2 + blockers[]
 */
function cmdTask(flags = {}, positional = []) {
  const sub = positional[0] || 'status';

  if (sub === 'start') {
    const raw = readStdin();
    let input;
    try { input = raw.trim() ? JSON.parse(raw) : {}; } catch (e) {
      return emit({ error: 'task-parse-error', detail: String(e && e.message || e) }, 3);
    }
    const v = validateEnvelope(input);
    if (!v.ok) {
      process.stderr.write('task envelope is incomplete; missing: ' + v.missing.join(', ')
        + (v.detail ? ' (' + v.detail + ')' : '') + '\n');
      return emit({ error: 'task-envelope-incomplete', missing: v.missing, detail: v.detail }, 3);
    }
    const record = buildTaskRecord(input, { now: new Date().toISOString(), baseCommit: headCommit() });
    writeAtomic(taskFilePath(), JSON.stringify(record, null, 2) + '\n');
    return emit({ ok: true, path: relFromRoot(taskFilePath()), task: record }, 0);
  }

  if (sub === 'status') {
    const task = readTaskRecord();
    return emit({
      ok: !!task,
      active: !!(task && task.state === 'active'),
      task,
      diffHash: isGitRepo() ? gitFingerprint() : null,
      note: task ? null : 'no-task-record',
    }, 0);
  }

  if (sub === 'complete') {
    const loaded = loadCatalog(typeof flags.catalog === 'string' ? flags.catalog : undefined);
    if (!loaded.ok) {
      return emit({ ok: false, degraded: true, error: loaded.error, detail: loaded.detail }, 3);
    }
    const task = readTaskRecord();
    if (!task || task.state !== 'active') {
      return emit({
        ok: false, task: task ? task.id : null,
        blockers: ['no active task: run "harness.mjs task start" with a six-field envelope first'],
      }, 2);
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
    const entries = readLedger();
    const imp = analyzeImpact(changed, loaded.catalog, { nonGit });
    const plan = buildPlan(imp.affected, loaded.catalog);
    const currentDiffHash = gitFingerprint();
    const blockers = completeBlockers({
      latestGate: latestGateRecord(entries),
      currentDiffHash,
      receipts: loadReceipts(),
      ledgerOk: verifyLedgerChain(entries).ok,
      planEmpty: plan.empty,
    });
    if (blockers.length) {
      for (const b of blockers) process.stderr.write('task complete blocked: ' + b + '\n');
      return emit({ ok: false, task: task.id, diffHash: currentDiffHash, blockers }, 2);
    }
    const done = { ...task, state: 'complete', completedAt: new Date().toISOString() };
    writeAtomic(taskFilePath(), JSON.stringify(done, null, 2) + '\n');
    return emit({ ok: true, task: done.id, diffHash: currentDiffHash, blockers: [] }, 0);
  }

  return emit({ error: 'task-subcommand', detail: 'usage: task start|status|complete', got: sub || null }, 3);
}

// ---------------------------------------------------------------------------
// S18.2 budget  (blast radius: a signal to split or escalate, never a prohibition)
// ---------------------------------------------------------------------------

// Defaults sized as "stop and think" rather than "stop". catalog.budget overrides any of
// them, and setting one to null turns that metric into a report-only number.
const BUDGET_DEFAULTS = {
  maxChangedFiles: 30,
  maxChangedLines: 1000,
  maxModulesTouched: 5,
  maxNewFiles: 15,
};

const BUDGET_METRICS = [
  ['changedFiles', 'maxChangedFiles'],
  ['changedLines', 'maxChangedLines'],
  ['modulesTouched', 'maxModulesTouched'],
  ['newFiles', 'maxNewFiles'],
];

/**
 * Compare measured blast radius against the declared limits. Pure.
 * @param {Object} metrics
 * @param {Object} limits
 * @returns {{ok:boolean,findings:Array<{metric:string,actual:number,limit:number}>}}
 */
function assessBudget(metrics, limits) {
  const findings = [];
  for (const [metric, key] of BUDGET_METRICS) {
    const limit = limits ? limits[key] : undefined;
    const actual = metrics ? metrics[metric] : undefined;
    if (typeof limit !== 'number' || typeof actual !== 'number') continue;
    if (actual > limit) findings.push({ metric, actual, limit });
  }
  return { ok: findings.length === 0, findings };
}

/** Added + removed line counts from git numstat (binary files report '-' and are skipped). */
function countDiffLines() {
  let added = 0;
  let removed = 0;
  const args = ['diff', '--numstat'];
  if (headCommit()) args.push('HEAD');
  const out = (git(args).stdout || Buffer.alloc(0)).toString('utf8');
  for (const line of out.split('\n')) {
    const m = /^(\d+)\t(\d+)\t/.exec(line);
    if (m) { added += Number(m[1]); removed += Number(m[2]); }
  }
  return { added, removed };
}

/**
 * `budget` subcommand: measure the blast radius of the working tree and compare it with
 * catalog.budget. Over a limit exits 1 -- read that as "split this, or escalate it on
 * purpose", not as a refusal.
 */
function cmdBudget(flags) {
  const loaded = loadCatalog(typeof flags.catalog === 'string' ? flags.catalog : undefined);
  if (!loaded.ok) {
    return emit({ ok: false, degraded: true, error: loaded.error, detail: loaded.detail }, 3);
  }
  if (!isGitRepo()) {
    return emit({ ok: false, degraded: true, reason: 'non-git' }, 3);
  }
  const cp = changedPaths();
  const changed = (Array.isArray(cp) ? cp : cp.paths).filter(p => !isStateExcluded(p));
  const untracked = splitNul(git(['-c', 'core.quotePath=false', 'ls-files', '-z', '--others', '--exclude-standard']).stdout)
    .filter(p => !isStateExcluded(p));
  const imp = analyzeImpact(changed, loaded.catalog, {});
  const { added, removed } = countDiffLines();
  const metrics = {
    changedFiles: changed.length,
    changedLines: added + removed,
    added,
    removed,
    modulesTouched: imp.direct.length,
    newFiles: untracked.length,
    affectedModules: imp.affected.length,
  };
  const limits = { ...BUDGET_DEFAULTS, ...(loaded.catalog.budget || {}) };
  const res = assessBudget(metrics, limits);
  if (!res.ok) {
    for (const f of res.findings) {
      process.stderr.write('budget: ' + f.metric + ' = ' + f.actual + ' (limit ' + f.limit + ')\n');
    }
  }
  return emit({
    ...res,
    metrics,
    limits,
    degraded: !!imp.degraded,
    advice: res.ok
      ? 'blast radius is within the declared budget'
      : 'blast radius is past the declared budget: split this into smaller tasks, or widen the '
        + 'scope deliberately (plan + ADR + owner). This is a signal to stop and think for a '
        + 'second, not a prohibition -- a wide change is sometimes the right one.',
  }, res.ok ? 0 : 1);
}

export {
  TASK_REQUIRED_FIELDS, validateEnvelope, buildTaskRecord, acceptingReceipt, completeBlockers,
  latestGateRecord, cmdTask,
  BUDGET_DEFAULTS, BUDGET_METRICS, assessBudget, countDiffLines, cmdBudget,
};
