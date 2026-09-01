// lib/graph.mjs -- everything that reasons over the module graph: S5 impact (reverse
// dependency closure), S12 arch-check (real import edges vs the declared graph) and
// S16 arch-trend (the drift ratchet those edges feed). Depends on core.mjs + catalog.mjs.

import fs from 'node:fs';
import path from 'node:path';
import {
  SOURCE_EXTS,
  changedPaths, emit, headCommit, isGitRepo, isStateExcluded, parseCsv, projectRoot,
} from './core.mjs';
import { classifyPath, loadCatalog, moduleForPath, trackedFiles } from './catalog.mjs';

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
// S12 arch-check  (declared graph vs real import edges; boundaries become executable)
// ===========================================================================
// The module graph is only a guardrail if the declaration is checked against what the
// code actually imports. A stale dependsOn under-reports impact, so the tests that should
// have run silently do not; a forbidden edge (privacy/layer boundary) that only lives in
// a document is crossed without anyone noticing. This makes both machine-checked.
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

export {
  reverseClosure, analyzeImpact, cmdImpact,
  extractImports, resolveRelativeImport, moduleForSpecifier, layerViolation, findCycles, cmdArchCheck,
  appendTrendRecord, loadTrend, compareRatchet, cmdArchTrend,
};
