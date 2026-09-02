// lib/rules.mjs -- S22 the constitution audit: which rules point at something that runs,
// and which ones are only being asked nicely.
//
// Two 2026 results make this measurable rather than aesthetic. The first is that a rule set
// is not free even when it is ignored: agent rule files change behaviour in directions
// nobody wrote down, so a clause that enforces nothing is not neutral, it is a distortion
// with no upside. The second is the ceiling -- instruction adherence falls as the number of
// simultaneous instructions rises. Together they say the thing to minimise is not bytes and
// not clauses. It is the clauses that reach no enforcement point AND do not admit it.
//
// So a constitution where every line names a command is healthy at any length, and a short
// one full of exhortation is not. The four classes:
//
//   machine   the line quotes a token that resolves to something that exists -- a harness
//             subcommand, a hook, a script, a test. Somebody can run it.
//   prompt    the line says so itself: prompt-only, (P), [P], or the Chinese for "on the
//             honour system". An admitted gap is a managed one.
//   phantom   the line quotes a token shaped exactly like an enforcement point that is not
//             there. This is worse than silence: it reads as enforced, so nobody checks,
//             and the check it names will never run. The only class that fails the command.
//   unclassified  everything else. Not an accusation -- a worklist. Each of these either
//             gets wired to something, gets marked prompt-only, or gets deleted.
//
// The audit is deliberately shy about phantom. A token becomes one only when it could not
// be anything else: an explicit `harness.mjs <word>` whose word is not a subcommand, or a
// literal .sh/.ps1/.mjs path under .claude that is not on disk. Globs, placeholders, JSON
// field names, config keys and data files resolve to nothing and stay out of both machine
// and phantom -- a false phantom would send someone to fix a rule that was never broken,
// and a false machine is an automated phantom, which is the failure this file exists to
// name. When in doubt the token contributes nothing and the line lands in unclassified,
// where a human reads it.
//
// The subcommand table is passed in rather than imported: harness.mjs owns it and imports
// this module, so reaching back for it would close a cycle.
//
// Source is ASCII-only like the rest of the runtime; the one Chinese marker this scanner
// matches is written escaped, with its meaning in the comment beside it.

import fs from 'node:fs';
import path from 'node:path';
import { emit, projectRoot } from './core.mjs';

// ===========================================================================
// S22.1 what counts as a rule line, and what the four classes are
// ===========================================================================

const RULES_DOC = path.join('.claude', 'CLAUDE.md');
const RULES_DIR = path.join('.claude', 'rules');

// Directories whose contents are enforcement points, walked in full: a test helper two
// levels down enforces as much as one at the top. Only the executable extensions are
// indexed -- a fixture sitting beside a script is data, however official the path looks,
// and indexing it would let a rule claim enforcement by naming a JSON file.
const POINT_DIRS = [
  path.join('.claude', 'hooks'),
  path.join('.claude', 'scripts'),
  path.join('.claude', 'tests'),
  path.join('.claude', 'harness'),
];
const POINT_EXTS = ['.sh', '.ps1', '.mjs'];
const WALK_DEPTH = 4;

// A self-declared prompt-only clause. The Chinese marker is \u9760\u81ea\u89c9,
// "on the honour system".
const PROMPT_MARKERS = ['prompt-only', '\u9760\u81ea\u89c9', '(P)', '[P]'];
// A marker directly preceded by one of these is a denial, not an admission.
const NEGATIONS = ['\u4e0d', '\u975e'];

// Command words that precede a script path rather than being one.
const RUNNERS = ['node', 'bash', 'sh', 'pwsh', 'powershell'];

const TEXT_BUDGET = 90;
const DEFAULT_LIMIT = 100;

/**
 * Is this a rule line? List bullets, numbered steps and table rows carry the clauses;
 * headings, prose and fence contents do not. A row of dashes is a table separator and a
 * bullet with nothing after the marker is layout, so both are dropped.
 * Pure.
 * @returns {string|null} the clause text with its marker removed, or null.
 */
function ruleLineText(line) {
  const raw = String(line);
  const trimmed = raw.trim();
  if (!trimmed) return null;
  let body = null;
  // \u2022 and \u00b7 are the two bullets this repository's rule files use for nested
  // clauses; a scanner that only knows the ASCII dash would miss whole sub-lists.
  if (/^[-*\u2022\u00b7]\s+/.test(trimmed)) body = trimmed.replace(/^[-*\u2022\u00b7]\s+/, '');
  else if (/^\d+[.)]\s+/.test(trimmed)) body = trimmed.replace(/^\d+[.)]\s+/, '');
  else if (trimmed.startsWith('|')) {
    const cells = trimmed.split('|').map(c => c.trim()).filter(c => c.length > 0);
    if (cells.length === 0) return null;
    // A separator row is all dashes and colons; it carries no clause.
    if (cells.every(c => /^:?-{2,}:?$/.test(c))) return null;
    body = cells.join(' | ');
  }
  if (body === null) return null;
  // Substance: a marker plus one or two characters of decoration is not a rule.
  const bare = body.replace(/[*`_~#>\s]/g, '');
  if (bare.length < 4) return null;
  return body;
}

/** The `backtick` tokens on a line, in order. Pure. */
function backtickTokens(line) {
  const out = [];
  const re = /`([^`]*)`/g;
  let m;
  while ((m = re.exec(String(line))) !== null) {
    const t = m[1].trim();
    if (t) out.push(t);
  }
  return out;
}

/**
 * Does the line admit, in its own words, that nothing enforces it?
 * A negated marker is the opposite claim and must not be counted: this repository writes
 * \u4e0d + the marker ("not on the honour system") on exactly the clauses that were
 * mechanised, and a substring match would file the strongest rules under the weakest class.
 * Pure.
 */
function admitsPromptOnly(line) {
  const s = String(line);
  return PROMPT_MARKERS.some(mk => {
    let from = 0;
    for (;;) {
      const i = s.indexOf(mk, from);
      if (i < 0) return false;
      if (!NEGATIONS.includes(s.slice(Math.max(0, i - 1), i))) return true;
      from = i + 1;
    }
  });
}

// ===========================================================================
// S22.2 resolving one token against the things that actually exist
// ===========================================================================

/**
 * The enforcement points this checkout has: the subcommand table plus every executable
 * under the point directories, indexed by both relative path and bare basename so that
 * `stop-gate.sh` and `.claude/hooks/stop-gate.sh` resolve the same way.
 */
function collectPoints(subcommands, root = projectRoot()) {
  const files = new Set();
  const basenames = new Set();
  const counts = {};
  for (const dir of POINT_DIRS) {
    const rel = dir.split(path.sep).join('/');
    const before = files.size;
    walkPoints(path.join(root, dir), rel, files, basenames, WALK_DEPTH);
    counts[path.basename(dir)] = files.size - before;
  }
  return {
    subcommands: new Set(subcommands || []),
    files,
    basenames,
    counts: { subcommands: (subcommands || []).length, ...counts },
  };
}

/** Depth-bounded walk of one point directory. An unreadable directory contributes nothing. */
function walkPoints(abs, rel, files, basenames, depth) {
  if (depth < 0) return;
  let entries = [];
  try { entries = fs.readdirSync(abs, { withFileTypes: true }); } catch (_e) { return; }
  for (const e of entries) {
    if (e.name.startsWith('.')) continue;
    if (e.isDirectory()) {
      walkPoints(path.join(abs, e.name), rel + '/' + e.name, files, basenames, depth - 1);
      continue;
    }
    if (!POINT_EXTS.includes(path.extname(e.name))) continue;
    files.add(rel + '/' + e.name);
    basenames.add(e.name);
  }
}

/** A token the audit must not judge: a placeholder or a glob stands for many things. */
function isUnresolvable(word) {
  return word.includes('<') || word.includes('>') || word.includes('*') || word.includes('?');
}

/** Does this word name a file that only an enforcement point would be? Pure-ish. */
function looksExecutable(word) {
  const ext = path.extname(word);
  if (ext === '.sh' || ext === '.ps1') return true;
  if (ext === '.mjs' && word.includes('.claude/')) return true;
  return false;
}

/** Trim the decoration a document puts around a path: line ranges, alternates, quotes. */
function normalizeWord(word) {
  let w = word;
  if (w.includes('|')) w = w.slice(0, w.indexOf('|'));
  w = w.replace(/:\d+(-\d+)?$/, '');
  w = w.replace(/^["'(\[]+/, '').replace(/["')\].,;]+$/, '');
  return w;
}

/**
 * Classify one backtick token.
 * Pure given `points`.
 * @returns {{kind:'machine'|'phantom'|'none', target?:string, reason?:string}}
 */
function classifyToken(token, points) {
  const t = String(token).trim();
  if (!t) return { kind: 'none' };

  // An explicit harness invocation names its subcommand, wherever it is embedded -- inside
  // a JSON check definition as often as on its own. This branch is the only one that can
  // call a bare word phantom, because it is the only one where the word's role is stated.
  const inv = /harness\.mjs\s+([A-Za-z0-9][A-Za-z0-9._-]*)/.exec(t);
  if (inv) {
    const word = inv[1];
    if (points.subcommands.has(word)) return { kind: 'machine', target: word, reason: 'subcommand' };
    return { kind: 'phantom', target: word, reason: 'no such harness subcommand' };
  }

  let head = t;
  for (const r of RUNNERS) {
    if (head.startsWith(r + ' ')) { head = head.slice(r.length + 1).trim(); break; }
  }
  head = head.split(/\s+/)[0] || '';
  head = normalizeWord(head);
  if (!head || isUnresolvable(head)) return { kind: 'none' };

  if (points.subcommands.has(head)) return { kind: 'machine', target: head, reason: 'subcommand' };

  // Being under a point directory is not enough to be one: fixtures, catalogs and sample
  // JSON live there too, and calling a real fixture a phantom sends someone to fix a rule
  // that was never broken. Only an executable shape is judged, in either direction.
  const rel = head.replace(/^\.\//, '');
  if (!looksExecutable(rel)) return { kind: 'none' };
  if (points.files.has(rel)) return { kind: 'machine', target: rel, reason: 'file' };
  if (!rel.includes('/') && points.basenames.has(rel)) {
    return { kind: 'machine', target: rel, reason: 'file' };
  }
  return { kind: 'phantom', target: rel, reason: 'no such file' };
}

/**
 * Classify a whole rule line. Phantom outranks machine: a line that names one real check
 * and one imaginary one is a line somebody has to fix. Machine outranks the prompt-only
 * marker, because naming a runnable check is a stronger claim than admitting there is none.
 * Pure given `points`.
 */
function classifyRuleLine(text, points) {
  const tokens = backtickTokens(text);
  const machine = [];
  const phantom = [];
  for (const tok of tokens) {
    const r = classifyToken(tok, points);
    if (r.kind === 'machine') machine.push({ token: tok, target: r.target, reason: r.reason });
    else if (r.kind === 'phantom') phantom.push({ token: tok, target: r.target, reason: r.reason });
  }
  let klass;
  if (phantom.length > 0) klass = 'phantom';
  else if (machine.length > 0) klass = 'machine';
  else if (admitsPromptOnly(text)) klass = 'prompt';
  else klass = 'unclassified';
  return { klass, machine, phantom };
}

// ===========================================================================
// S22.3 the documents, the tally, and the command
// ===========================================================================

/** Rule documents in a stable order: the constitution first, then its sections by name. */
function ruleDocs(root = projectRoot()) {
  const docs = [];
  const main = path.join(root, RULES_DOC);
  if (fs.existsSync(main)) docs.push(RULES_DOC);
  const dir = path.join(root, RULES_DIR);
  let names = [];
  try { names = fs.readdirSync(dir); } catch (_e) { names = []; }
  for (const name of names.filter(n => n.endsWith('.md')).sort()) {
    docs.push('.claude/rules/' + name);
  }
  return docs;
}

/** Clause text, shortened for a report that has to stay one line of JSON. Pure. */
function clip(text, budget = TEXT_BUDGET) {
  const s = String(text).replace(/\s+/g, ' ').trim();
  return s.length <= budget ? s : s.slice(0, budget) + '...';
}

/**
 * Walk one document's lines and classify each rule line. Fenced code is skipped: a shell
 * snippet inside a fence is an example, not a clause, and counting it would let a file
 * lower its own unclassified ratio by pasting commands.
 * Pure given `points`.
 */
function auditDoc(rel, content, points) {
  const lines = String(content).split(/\r?\n/);
  const rules = [];
  let fenced = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (/^\s*(```|~~~)/.test(line)) { fenced = !fenced; continue; }
    if (fenced) continue;
    const text = ruleLineText(line);
    if (text === null) continue;
    const c = classifyRuleLine(text, points);
    rules.push({ at: rel + ':' + (i + 1), klass: c.klass, text, machine: c.machine, phantom: c.phantom });
  }
  return rules;
}

/** Tally the four classes and their share of the whole. Pure. */
function tally(rules) {
  const counts = { machine: 0, prompt: 0, phantom: 0, unclassified: 0 };
  for (const r of rules) counts[r.klass]++;
  const total = rules.length;
  const ratio = {};
  for (const k of Object.keys(counts)) {
    ratio[k] = total === 0 ? 0 : Math.round((counts[k] / total) * 1000) / 1000;
  }
  return { total, counts, ratio };
}

function positiveInt(v, fallback) {
  if (typeof v !== 'string') return fallback;
  const n = Number(v);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : fallback;
}

function cmdRulesAudit(flags = {}, subcommands = []) {
  const root = projectRoot();
  const docs = ruleDocs(root);
  if (docs.length === 0) {
    const note = 'no rule documents found (' + RULES_DOC + ' / ' + RULES_DIR
      + '); there is no constitution to audit, which is not the same as a clean one';
    process.stderr.write(note + '\n');
    return emit({ ok: false, degraded: true, error: 'no-rules', files: [], note }, 3);
  }
  const points = collectPoints(subcommands, root);
  const limit = positiveInt(flags.limit, DEFAULT_LIMIT);
  const rules = [];
  const perFile = [];
  const unreadable = [];
  for (const rel of docs) {
    let content = '';
    try {
      content = fs.readFileSync(path.join(root, rel), 'utf8');
    } catch (e) {
      unreadable.push({ file: rel, error: String(e && e.message ? e.message : e) });
      continue;
    }
    const found = auditDoc(rel, content, points);
    perFile.push({ file: rel, ...tally(found) });
    for (const r of found) rules.push(r);
  }
  const overall = tally(rules);
  const unclassified = rules.filter(r => r.klass === 'unclassified');
  const phantomRules = rules.filter(r => r.klass === 'phantom');

  for (const r of phantomRules) {
    for (const p of r.phantom) {
      process.stderr.write('PHANTOM ' + r.at + '  `' + p.token + '` -> ' + p.reason + '\n');
    }
  }
  process.stderr.write('rules ' + overall.total
    + '  machine ' + overall.counts.machine + ' (' + overall.ratio.machine + ')'
    + '  prompt ' + overall.counts.prompt + ' (' + overall.ratio.prompt + ')'
    + '  phantom ' + overall.counts.phantom
    + '  unclassified ' + overall.counts.unclassified + ' (' + overall.ratio.unclassified + ')\n');
  for (const r of unclassified.slice(0, 10)) {
    process.stderr.write('  U ' + r.at + '  ' + clip(r.text, 60) + '\n');
  }
  if (unclassified.length > 10) {
    process.stderr.write('  ... ' + (unclassified.length - 10) + ' more unclassified rule(s)\n');
  }

  return emit({
    ok: phantomRules.length === 0,
    files: perFile,
    unreadable,
    enforcementPoints: points.counts,
    rules: overall.total,
    counts: overall.counts,
    ratio: overall.ratio,
    phantom: phantomRules.slice(0, limit).map(r => ({
      at: r.at,
      tokens: r.phantom.map(p => ({ token: p.token, target: p.target, reason: p.reason })),
      text: clip(r.text),
    })),
    phantomOmitted: Math.max(0, phantomRules.length - limit),
    unclassified: unclassified.slice(0, limit).map(r => ({ at: r.at, text: clip(r.text) })),
    unclassifiedOmitted: Math.max(0, unclassified.length - limit),
    note: phantomRules.length === 0
      ? 'no phantom reference; the unclassified count is a worklist for a human, not a gate'
      : 'a rule names an enforcement point that does not exist; it reads as enforced and is not',
  }, phantomRules.length === 0 ? 0 : 1);
}

export {
  RULES_DOC, RULES_DIR, POINT_DIRS, POINT_EXTS, PROMPT_MARKERS, RUNNERS, TEXT_BUDGET,
  ruleLineText, backtickTokens, admitsPromptOnly, collectPoints, normalizeWord, looksExecutable,
  classifyToken, classifyRuleLine, ruleDocs, clip, auditDoc, tally, positiveInt, cmdRulesAudit,
};
