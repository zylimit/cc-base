// lib/spec.mjs -- S19 the specification layer: spec-lint (is the requirement document
// decidable), trace (does anything verify each requirement), spec (a budgeted view of the
// requirements a change actually touches) and dod (run every static governance check once).
//
// What this layer deliberately does NOT do, and why: the obvious move was to port the EARS
// lint from the sibling harness -- require a `REQ-XXX-001` id, a `SHALL`, a `WHEN/WHILE/IF`
// trigger. That grammar belongs to a repository whose requirements are written in it. The
// documents this framework actually produces are prose: product-spec-builder's template
// fixes the shape of a functional requirement as
//     <name>: <what the user does> -> <what the system does> -> <what comes out>
// which is already the trigger/response/outcome of EARS, minus the ceremony. A lint written
// against the other grammar would match nothing here, pass forever, and leave everyone
// believing the specification had been checked. A gate that cannot fail is worse than no
// gate, so this one is written against the shape that exists.
//
// Requirement ids are optional for the same reason and with the opposite consequence.
// Traceability needs a stable anchor; inventing one (line numbers, heading text, a hash of
// the prose) would produce links that break on the next edit and read as coverage. So
// `trace` degrades and says the anchor is missing rather than pretending. Five-minute
// prototypes keep writing prose; a project that wants traceability adds `[REQ-<mod>-<nnn>]`
// in front of each item and the capability turns on.
//
// TODO/TBD count as unfinished requirement text only in marker shape -- bracketed, suffixed
// with a colon, or standing alone as the whole item. In running prose they are subject matter:
// a specification for a to-do application is a thing people write, and a check that fires on
// the product's own topic is a check everyone learns to skip.
//
// Depends on core / catalog / graph. Nothing imports this module except harness.mjs and
// selftest, so the graph stays acyclic. dod runs the other subcommands as child processes
// instead of calling their cmd* functions, because every one of those ends in emit(), which
// exits the process -- and shelling out has the side benefit that dod asserts on the exit
// code contract the hooks consume rather than on some private return value.

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import {
  HARNESS_DIR,
  changedPaths, emit, isDenied, isGitRepo, isStateExcluded, matchAny, parseCsv, projectRoot,
  toPosixPath,
} from './core.mjs';
import { loadCatalog, moduleForPath, trackedFiles } from './catalog.mjs';
import { analyzeImpact } from './graph.mjs';

// ===========================================================================
// S19.1 document model  (fence-aware line scanning; everything below is pure)
// ===========================================================================

const DEFAULT_SPEC_FILE = 'Product-Spec.md';

// The four sections a Product Spec cannot be read without. UI/flow/AI sections are real but
// optional -- a CLI tool has no UI section -- so their absence is not a finding.
// Source is ASCII-only like the rest of the runtime, so the labels are escaped; the comment
// after each one is what it says.
const REQUIRED_SECTIONS = [
  '\u4ea7\u54c1\u6982\u8ff0',   // product overview
  '\u5e94\u7528\u573a\u666f',   // usage scenarios
  '\u529f\u80fd\u9700\u6c42',   // functional requirements
  '\u6280\u672f\u65b9\u5411',   // technical direction
];
const REQUIREMENT_SECTION = '\u529f\u80fd\u9700\u6c42';

// Unfinished-text markers. The ASCII pair is matched case-sensitively -- lowercase "todo" is
// ordinary English prose -- and on top of that only in marker shape, because uppercase TODO is
// also what a to-do application is called. The Chinese pair never names a product, so a bare
// occurrence of those is marker enough.
const PLACEHOLDER_TOKENS = ['TBD', 'TODO', '\u5f85\u5b9a', '\u5f85\u8865'];
const MARKER_SHAPE_TOKENS = new Set(['TBD', 'TODO']);

// Terms that cannot be decided, and therefore cannot be accepted. Scanned inside requirement
// items only: the overview and the scenarios are sales prose, where "quickly" is a fair thing
// to say and flagging it would train everyone to ignore the whole check.
const AMBIGUOUS_TERMS = [
  '\u9002\u5f53', '\u5408\u7406', '\u5feb\u901f', '\u53cb\u597d',
  '\u5c3d\u91cf', '\u7b49\u7b49', '\u82e5\u5e72', '\u4f18\u5316\u4f53\u9a8c',
];

// Angle brackets in a specification are template residue unless they are real markup, so the
// discriminator is an allowlist of tag names rather than a guess about the contents.
const HTML_TAGS = new Set([
  'a', 'abbr', 'audio', 'b', 'blockquote', 'br', 'button', 'code', 'details', 'div', 'em',
  'form', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'hr', 'i', 'iframe', 'img', 'input', 'kbd',
  'label', 'li', 'main', 'nav', 'ol', 'option', 'p', 'path', 'pre', 'script', 'section',
  'select', 'small', 'span', 'strong', 'style', 'sub', 'summary', 'sup', 'svg', 'table',
  'tbody', 'td', 'textarea', 'th', 'thead', 'tr', 'ul', 'video',
]);

// Declaration form: the id leads the item, in brackets. Reference form: the bare token,
// anywhere. Keeping them apart is what makes "declared here, referenced there" meaningful.
const REQ_ID_DECL_RE = /^\s{0,1}(?:[-*+]|\d+[.)])\s*\[(REQ-[A-Za-z0-9]{1,16}-\d{2,4})\]\s*/;
const REQ_ID_REF_RE = /\bREQ-[A-Za-z0-9]{1,16}-\d{2,4}\b/g;

// An arrow is the whole structural assertion: without one the item states no transition from
// what the user does to what comes out.
const ARROW_RE = /(?:\u2192|->|=>)/g;

const BULLET_RE = /^\s{0,1}(?:[-*+]|\d+[.)])\s+/;

/** Inline code spans hide type parameters and tag examples that are not placeholders. */
function stripCodeSpans(line) {
  return String(line).replace(/`[^`]*`/g, '``');
}

/**
 * Split a markdown document into level-2 sections, ignoring headings inside fenced blocks.
 * Content before the first `## ` heading belongs to no section (preamble). Pure.
 * @param {string} text
 * @returns {{lines:string[],fenced:boolean[],sections:Array<{title:string,line:number,from:number,to:number}>}}
 */
function splitSections(text) {
  const lines = String(text == null ? '' : text).replace(/\r\n?/g, '\n').split('\n');
  const fenced = [];
  const sections = [];
  let inFence = false;
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i];
    if (/^\s{0,3}(?:```|~~~)/.test(l)) {
      fenced.push(true);           // the fence marker itself counts as fenced
      inFence = !inFence;
      continue;
    }
    fenced.push(inFence);
    if (inFence) continue;
    const m = /^##\s+(.+?)\s*$/.exec(l);
    if (m) {
      if (sections.length) sections[sections.length - 1].to = i;
      sections.push({ title: m[1].replace(/[*`#]/g, '').trim(), line: i + 1, from: i + 1, to: lines.length });
    }
  }
  return { lines, fenced, sections };
}

/** The section whose title contains `label`, or null. Pure. */
function sectionNamed(doc, label) {
  return doc.sections.find(s => s.title.includes(label)) || null;
}

/** True when a section carries no content of its own (headings and blanks do not count). */
function sectionEmpty(doc, section) {
  for (let i = section.from; i < section.to; i++) {
    const l = doc.lines[i];
    if (doc.fenced[i]) return false;
    if (!l || !l.trim()) continue;
    if (/^#{1,6}\s/.test(l)) continue;
    return false;
  }
  return true;
}

/**
 * Requirement items = top-level bullets inside the functional-requirements section. Nested
 * bullets are detail lines of the item above them, so they are not items in their own right
 * and are not asked to carry the arrow shape. Pure.
 * @returns {Array<{line:number,raw:string,body:string,id:(string|null),arrows:number}>}
 */
function parseRequirements(doc) {
  const section = sectionNamed(doc, REQUIREMENT_SECTION);
  if (!section) return [];
  const out = [];
  for (let i = section.from; i < section.to; i++) {
    if (doc.fenced[i]) continue;
    const raw = doc.lines[i];
    if (!BULLET_RE.test(raw)) continue;
    const decl = REQ_ID_DECL_RE.exec(raw);
    const body = raw.replace(REQ_ID_DECL_RE, '').replace(BULLET_RE, '').trim();
    ARROW_RE.lastIndex = 0;
    const arrows = (raw.match(ARROW_RE) || []).length;
    out.push({ line: i + 1, raw: raw.trim(), body, id: decl ? decl[1] : null, arrows });
  }
  return out;
}

// ===========================================================================
// S19.2 spec-lint  (structure, residue, undecidable wording)
// ===========================================================================

/** Angle-bracket runs that are not recognizable markup. Pure. */
function placeholderBrackets(line) {
  const out = [];
  const re = /<([^<>\n]{1,200})>/g;
  let m = re.exec(line);
  while (m) {
    const inner = m[1].trim();
    const head = inner.replace(/^\//, '').split(/[\s/>]/)[0].toLowerCase();
    if (!HTML_TAGS.has(head)) out.push('<' + inner + '>');
    m = re.exec(line);
  }
  return out;
}

/**
 * True when `tok` sits on the line as a deferral marker rather than as subject matter. The
 * three shapes a marker takes: wrapped in angle brackets, followed by a colon, or standing
 * alone as the whole item. Tokens outside MARKER_SHAPE_TOKENS still match bare. Pure.
 */
function placeholderMarker(line, tok) {
  const text = String(line);
  if (!MARKER_SHAPE_TOKENS.has(tok)) return text.includes(tok);
  return new RegExp('<\\s*' + tok + '\\s*>').test(text)
    || new RegExp('\\b' + tok + '\\s*[:\\uff1a]').test(text)
    || new RegExp('^\\s*(?:[-*+]|\\d+[.)])?\\s*' + tok + '\\s*[.\\u3002]?\\s*$').test(text);
}

/**
 * Lint one requirement document. Errors: a required section missing or empty, template
 * residue, a requirement item with no arrow. Warnings: undecidable wording, partial
 * numbering. Pure over the text, so selftest exercises it without a filesystem.
 * @param {string} text
 * @param {string} file   reported in findings; not read
 */
function lintSpecDoc(text, file) {
  const doc = splitSections(text);
  const findings = [];
  const add = (severity, code, line, message, extra = {}) => {
    findings.push({ severity, code, file, line, message, ...extra });
  };

  const present = [];
  const missing = [];
  const empty = [];
  for (const label of REQUIRED_SECTIONS) {
    const s = sectionNamed(doc, label);
    if (!s) {
      missing.push(label);
      add('error', 'MISSING_SECTION', 0, 'required section "' + label + '" is absent; the document cannot be read as a specification without it');
      continue;
    }
    present.push(s.title);
    if (sectionEmpty(doc, s)) {
      empty.push(label);
      add('error', 'EMPTY_SECTION', s.line, 'section "' + s.title + '" has a heading and no content; an empty section reads as answered');
    }
  }

  for (let i = 0; i < doc.lines.length; i++) {
    if (doc.fenced[i]) continue;
    const line = stripCodeSpans(doc.lines[i]);
    for (const ph of placeholderBrackets(line)) {
      add('error', 'PLACEHOLDER', i + 1, 'template placeholder ' + JSON.stringify(ph) + ' was never filled in; a half-written requirement is worse than an absent one');
    }
    for (const tok of PLACEHOLDER_TOKENS) {
      if (placeholderMarker(line, tok)) {
        add('error', 'PLACEHOLDER', i + 1, 'unfinished marker "' + tok + '" in a requirement document; decide it or delete it');
      }
    }
  }

  const requirements = parseRequirements(doc);
  const ids = [];
  const seen = new Map();
  for (const r of requirements) {
    if (r.arrows === 0) {
      add('error', 'NO_FLOW', r.line, 'requirement states no flow (expected "<what the user does> ' + '\u2192'
        + ' <what the system does> ' + '\u2192' + ' <what comes out>"); as written it says neither what triggers it nor what it produces',
      { excerpt: r.raw.slice(0, 160) });
    }
    const hits = AMBIGUOUS_TERMS.filter(t => r.body.includes(t));
    if (hits.length) {
      add('warning', 'AMBIGUOUS', r.line, 'undecidable wording (' + hits.join(', ') + '); nobody can tell whether the built thing satisfies it',
        { excerpt: r.raw.slice(0, 160) });
    }
    if (r.id) {
      if (seen.has(r.id)) {
        add('error', 'DUPLICATE_ID', r.line, 'requirement id ' + r.id + ' is already declared at line ' + seen.get(r.id) + '; ids anchor traceability and cannot be reused');
      } else {
        seen.set(r.id, r.line);
        ids.push({ id: r.id, line: r.line });
      }
    }
  }
  if (ids.length && ids.length < requirements.length) {
    add('warning', 'PARTIAL_ID', 0, ids.length + ' of ' + requirements.length
      + ' requirements carry an id; trace would report coverage over the numbered subset only, which reads as coverage of all of them');
  }

  const errors = findings.filter(f => f.severity === 'error');
  return {
    ok: errors.length === 0,
    file,
    sections: { present, missing, empty },
    requirements: requirements.length,
    ids,
    counts: { error: errors.length, warning: findings.length - errors.length },
    findings: findings.slice(0, 200),
  };
}

/** Absolute path of the requirement document under test (--file overrides). */
function specFilePath(flags) {
  const rel = typeof flags.file === 'string' ? flags.file : DEFAULT_SPEC_FILE;
  return path.isAbsolute(rel) ? rel : path.join(projectRoot(), rel);
}

/** Read the spec document, or explain why there is nothing to lint. */
function readSpecDoc(flags) {
  const abs = specFilePath(flags);
  const rel = typeof flags.file === 'string' ? flags.file : DEFAULT_SPEC_FILE;
  if (!fs.existsSync(abs)) {
    return { ok: false, error: 'spec-missing', detail: rel, file: rel };
  }
  try {
    return { ok: true, file: rel, text: fs.readFileSync(abs, 'utf8') };
  } catch (e) {
    return { ok: false, error: 'spec-unreadable', detail: String(e && e.message || e), file: rel };
  }
}

function cmdSpecLint(flags) {
  const src = readSpecDoc(flags);
  if (!src.ok) {
    return emit({
      ok: false, degraded: true, error: src.error, detail: src.detail,
      note: 'no requirement document found at ' + src.file + '; nothing was checked (use --file to point elsewhere)',
    }, 3);
  }
  const r = lintSpecDoc(src.text, src.file);
  for (const f of r.findings) {
    process.stderr.write((f.severity === 'error' ? ' ERR  ' : ' warn ') + f.code + '  '
      + f.file + (f.line ? ':' + f.line : '') + ' :: ' + f.message + '\n');
  }
  return emit(r, r.ok ? 0 : 1);
}

// ===========================================================================
// S19.3 trace  (requirement id <-> test reference; no anchor, no answer)
// ===========================================================================

const DEFAULT_TEST_GLOBS = [
  '**/test/**', '**/tests/**', '**/*.test.*', '**/*_test.*', '**/*Test.*',
  '**/*.spec.*', '**/*_spec.*', '**/spec/**',
];

// Extensions whose bytes cannot carry a requirement reference worth reading.
const BINARY_EXTS = new Set([
  '.png', '.jpg', '.jpeg', '.gif', '.ico', '.webp', '.bmp', '.svgz', '.pdf', '.zip', '.gz',
  '.tgz', '.bz2', '.xz', '.7z', '.rar', '.woff', '.woff2', '.ttf', '.otf', '.eot', '.mp3',
  '.mp4', '.mov', '.avi', '.wasm', '.so', '.dylib', '.dll', '.exe', '.class', '.jar', '.pyc',
]);

const MAX_SCAN_BYTES = 512 * 1024;

/**
 * Collect requirement-id references out of already-read files (pure; injectable).
 * @param {Array<{path:string,content:string}>} files
 * @param {string[]} testGlobs
 * @param {Catalog|null} catalog     module attribution for the spec view
 * @returns {{refs:Map<string,{tests:string[],code:string[],modules:Set<string>}>,docs:Map<string,string[]>}}
 */
function collectReferences(files, testGlobs, catalog) {
  const refs = new Map();
  const docs = new Map();
  for (const f of files) {
    REQ_ID_REF_RE.lastIndex = 0;
    const hits = new Set();
    let m = REQ_ID_REF_RE.exec(f.content);
    while (m) { hits.add(m[0]); m = REQ_ID_REF_RE.exec(f.content); }
    if (!hits.size) continue;
    const isDoc = /\.(?:md|markdown|txt|rst)$/i.test(f.path);
    const isTest = matchAny(f.path, testGlobs);
    const moduleId = catalog ? moduleForPath(f.path, catalog) : null;
    for (const id of hits) {
      if (isDoc && !isTest) {
        if (!docs.has(id)) docs.set(id, []);
        docs.get(id).push(f.path);
        continue;
      }
      if (!refs.has(id)) refs.set(id, { tests: [], code: [], modules: new Set() });
      const rec = refs.get(id);
      if (isTest) rec.tests.push(f.path);
      else rec.code.push(f.path);
      if (moduleId) rec.modules.add(moduleId);
    }
  }
  return { refs, docs };
}

/**
 * Build the traceability report from declared ids and collected references (pure).
 * A reference from prose is reported, never failed: documentation legitimately cites an
 * example id. A reference from code or a test naming an id the specification does not
 * declare is a real break -- it points at a requirement that no longer exists.
 * @param {Array<{id:string,line:number}>} declared
 * @param {{refs:Map,docs:Map}} collected
 * @param {number} minCoverage
 */
function traceReport(declared, collected, minCoverage = 1) {
  const declaredIds = new Set(declared.map(d => d.id));
  const rows = declared.map(d => {
    const rec = collected.refs.get(d.id) || { tests: [], code: [], modules: new Set() };
    return {
      id: d.id, line: d.line,
      tests: rec.tests.slice(0, 10), testCount: rec.tests.length,
      codeCount: rec.code.length, modules: [...rec.modules],
      verified: rec.tests.length > 0,
      implemented: rec.code.length > 0,
    };
  });
  const dangling = [];
  for (const [id, rec] of collected.refs) {
    if (declaredIds.has(id)) continue;
    for (const p of rec.tests.concat(rec.code)) dangling.push({ id, file: p });
  }
  const danglingInDocs = [];
  for (const [id, files] of collected.docs) {
    if (declaredIds.has(id)) continue;
    for (const p of files) danglingInDocs.push({ id, file: p });
  }
  const unverified = rows.filter(r => !r.verified);
  const coverage = rows.length ? (rows.length - unverified.length) / rows.length : 0;
  return {
    ok: coverage >= minCoverage && dangling.length === 0,
    coverage: Number(coverage.toFixed(4)), minCoverage,
    total: rows.length, verified: rows.length - unverified.length,
    unverified: unverified.map(r => r.id),
    unimplemented: rows.filter(r => !r.implemented && !r.verified).map(r => r.id),
    dangling: dangling.slice(0, 50), danglingCount: dangling.length,
    danglingInDocs: danglingInDocs.slice(0, 50), danglingInDocsCount: danglingInDocs.length,
    rows,
  };
}

/** Read every tracked file that could carry a reference, minus the spec document itself. */
function referenceCorpus(catalog, specRel) {
  const root = projectRoot();
  const t = trackedFiles(catalog && catalog.maxTrackedPaths);
  const files = [];
  for (const p of t.paths) {
    const norm = toPosixPath(p);
    if (norm === specRel) continue;
    if (isDenied(norm) || isStateExcluded(norm)) continue;
    if (BINARY_EXTS.has(path.extname(norm).toLowerCase())) continue;
    let content;
    try {
      const st = fs.statSync(path.join(root, p));
      if (!st.isFile() || st.size > MAX_SCAN_BYTES) continue;
      const buf = fs.readFileSync(path.join(root, p));
      if (buf.includes(0)) continue;
      content = buf.toString('utf8');
    } catch (_e) { continue; }
    files.push({ path: norm, content });
  }
  return { files, truncated: t.truncated };
}

/** Shared by trace and spec: ids plus their references, or the reason there are none. */
function loadTrace(flags) {
  const src = readSpecDoc(flags);
  if (!src.ok) {
    return { ok: false, error: src.error, detail: src.detail, file: src.file,
      note: 'no requirement document found at ' + src.file + '; nothing to trace' };
  }
  const lint = lintSpecDoc(src.text, src.file);
  if (lint.ids.length === 0) {
    return { ok: false, error: 'no-requirement-ids', detail: src.file, file: src.file, lint,
      note: 'this specification declares no requirement ids, so traceability is unavailable and '
        + 'is not being approximated. To enable it, prefix each item under '
        + REQUIREMENT_SECTION + ' with [REQ-<module>-<nnn>].' };
  }
  if (!isGitRepo()) {
    return { ok: false, error: 'non-git', detail: 'trace enumerates references via git ls-files', file: src.file, lint,
      note: 'not a git repository; the set of files that could reference a requirement cannot be enumerated' };
  }
  const loaded = loadCatalog(typeof flags.catalog === 'string' ? flags.catalog : undefined);
  const catalog = loaded.ok ? loaded.catalog : null;
  const testGlobs = typeof flags.tests === 'string' ? parseCsv(flags.tests) : DEFAULT_TEST_GLOBS;
  const corpus = referenceCorpus(catalog, src.file);
  const collected = collectReferences(corpus.files, testGlobs, catalog);
  return { ok: true, file: src.file, lint, catalog, collected, truncated: corpus.truncated, scanned: corpus.files.length };
}

function cmdTrace(flags) {
  const t = loadTrace(flags);
  if (!t.ok) {
    process.stderr.write(t.note + '\n');
    return emit({ ok: false, degraded: true, error: t.error, detail: t.detail, note: t.note }, 3);
  }
  const min = typeof flags['min-coverage'] === 'string' ? Number(flags['min-coverage']) : 1;
  const r = traceReport(t.lint.ids, t.collected, Number.isFinite(min) ? min : 1);
  for (const id of r.unverified) process.stderr.write(' UNVERIFIED  ' + id + ' :: no test file references this id\n');
  for (const d of r.dangling) process.stderr.write(' DANGLING    ' + d.id + ' :: referenced in ' + d.file + ' but never declared\n');
  return emit({ ...r, file: t.file, scanned: t.scanned, truncated: t.truncated }, r.ok ? 0 : 1);
}

// ===========================================================================
// S19.4 spec  (a budgeted view: the requirements a change touches, not the document)
// ===========================================================================
// A requirement written three years ago still binds today, so the specification is the one
// document that only grows, and the only way to keep reading it affordable is to stop reading
// all of it. Narrowing runs through the same route the gate uses -- impact picks modules,
// trace maps ids onto modules, the intersection is rendered.
//
// Narrowing needs both an anchor and a catalog. When either is absent the whole requirement
// section is rendered within budget and `narrowed:false` says so, in the JSON and in the
// header of the rendered text. That is still the product asked for; what it is not allowed to
// do is stay quiet about having skipped the selection.

const SPEC_VIEW_BUDGET = 6000;

/**
 * Render the selected requirement items into a budgeted markdown block (pure).
 * @param {Array<{line:number,raw:string,id:(string|null)}>} items
 * @param {Map<string,{verified:boolean,tests:string[]}>} verification
 * @param {{budget:number,header:string}} opts
 */
function renderSpecView(items, verification, { budget = SPEC_VIEW_BUDGET, header = '' } = {}) {
  const blocks = [];
  let used = header.length;
  let omitted = 0;
  for (const it of items) {
    let block = '- ' + it.raw.replace(BULLET_RE, '') + '\n';
    const v = it.id ? verification.get(it.id) : null;
    if (v) block += '  _verified by: ' + (v.tests.join(', ') || 'NOTHING - unverified') + '_\n';
    if (used + block.length > budget) { omitted++; continue; }
    blocks.push(block);
    used += block.length;
  }
  return { view: header + blocks.join(''), rendered: blocks.length, omitted, chars: used };
}

function cmdSpec(flags) {
  const src = readSpecDoc(flags);
  if (!src.ok) {
    return emit({
      ok: false, degraded: true, error: src.error, detail: src.detail,
      note: 'no requirement document found at ' + src.file + '; there is no view to render',
    }, 3);
  }
  const budget = typeof flags.budget === 'string' && Number(flags.budget) > 0
    ? Math.floor(Number(flags.budget)) : SPEC_VIEW_BUDGET;
  const doc = splitSections(src.text);
  const items = parseRequirements(doc);
  const all = flags.all === true;

  let selected = items;
  let narrowed = false;
  let reason = '';
  let affected = [];
  const verification = new Map();

  if (all) {
    reason = '--all requested; the whole requirement section is in scope';
  } else {
    const t = loadTrace(flags);
    if (!t.ok) {
      reason = 'cannot narrow (' + t.error + '); rendering every requirement instead. ' + t.note;
    } else if (!t.catalog) {
      reason = 'cannot narrow (no module catalog); requirements cannot be mapped onto the changed modules';
    } else {
      const changed = typeof flags.paths === 'string' ? parseCsv(flags.paths)
        : (() => { const cp = changedPaths(); return Array.isArray(cp) ? cp : cp.paths; })();
      const imp = analyzeImpact(changed, t.catalog, { nonGit: !isGitRepo() });
      affected = imp.affected;
      const report = traceReport(t.lint.ids, t.collected, 1);
      for (const row of report.rows) verification.set(row.id, { verified: row.verified, tests: row.tests });
      if (imp.degraded) {
        reason = 'impact degraded (' + imp.expansionReasons.slice(0, 3).join(', ') + '); a degraded impact means every module, which would defeat the purpose of narrowing';
      } else {
        const set = new Set(affected);
        const byId = new Map(report.rows.map(r => [r.id, r]));
        selected = items.filter(it => it.id && byId.has(it.id) && byId.get(it.id).modules.some(m => set.has(m)));
        narrowed = true;
        reason = selected.length === 0
          ? 'no requirement id is cited by the code or tests of [' + affected.join(', ')
            + ']; put the id in what implements it, or this change cannot be traced to anything it was asked to do'
          : 'narrowed to the requirements cited by [' + affected.join(', ') + ']';
      }
    }
  }

  const header = '# Requirements in scope' + (narrowed ? ' for [' + affected.join(', ') + ']' : ' (all)') + '\n\n'
    + selected.length + ' of ' + items.length + ' requirement(s) selected; ' + reason + '.\n\n';
  const rendered = renderSpecView(selected, verification, { budget, header });
  return emit({
    ok: true, file: src.file, total: items.length, narrowed, reason,
    affected, selected: selected.map(it => it.id || ('line:' + it.line)),
    budget, chars: rendered.chars, rendered: rendered.rendered, omitted: rendered.omitted,
    view: rendered.view,
  }, 0);
}

// ===========================================================================
// S19.5 dod  (every static governance check, once, with one verdict)
// ===========================================================================
// Static only: nothing here executes a project's own test suite, so a satisfied Definition of
// Done means the governance surface is clean, not that the code works. `gate` still owns that
// half, and the note in the output says so rather than leaving it to be assumed.
//
// DEGRADED is not FAIL and does not block -- a repository without a catalog is not a
// repository that failed its architecture check. But a run in which no blocking step ever
// reached a verdict established nothing, and reporting that as satisfied is the same false
// green the empty verification plan already fails on, so it exits 3 rather than 0.

const DOD_STEPS = [
  { id: 'catalog-lint', argv: ['catalog-lint'], blocking: true },
  { id: 'spec-lint', argv: ['spec-lint'], blocking: true },
  { id: 'trace', argv: ['trace'], blocking: true },
  { id: 'attributes', argv: ['attributes'], blocking: true },
  { id: 'arch-check', argv: ['arch-check'], blocking: true },
  { id: 'adr-check', argv: ['adr-check'], blocking: true },
  { id: 'fitness', argv: ['fitness', '--all'], blocking: true },
  { id: 'ledger', argv: ['ledger'], blocking: true },
  { id: 'arch-trend', argv: ['arch-trend', '--gate'], blocking: true },
  // The constitution layer. All three fail on the same shape of defect: a rule, a skill or a
  // module boundary that reads as enforced and is not. `rules-audit` blocks on phantom
  // references only -- its unclassified count is a worklist for a human and must not decide
  // a build. The other two block on their findings, and all three degrade rather than fail
  // where their source is absent, which is why a repository with no catalog still passes.
  { id: 'rules-audit', argv: ['rules-audit'], blocking: true },
  { id: 'skills-lint', argv: ['skills-lint'], blocking: true },
  { id: 'claude-md-lint', argv: ['claude-md-lint'], blocking: true },
  // Signals, not verdicts. `budget` is documented as a split-or-escalate prompt and `risk`
  // reports decay that may be entirely expected; failing the build on either would get the
  // whole command switched off, which costs more than the two findings are worth.
  { id: 'risk', argv: ['risk'], blocking: false },
  { id: 'budget', argv: ['budget'], blocking: false },
];

function harnessEntry() {
  return path.join(HARNESS_DIR, 'harness.mjs');
}

/** Map one child exit code onto the three states dod reports. Pure. */
function dodStatus(code) {
  if (code === 0) return 'PASS';
  if (code === 3) return 'DEGRADED';
  return 'FAIL';
}

/** Aggregate the step list into a verdict (pure; the exit code follows from it). */
function dodVerdict(steps) {
  const blocking = steps.filter(s => s.blocking);
  const failed = blocking.filter(s => s.status === 'FAIL').map(s => s.id);
  const established = blocking.filter(s => s.status !== 'DEGRADED').length;
  if (failed.length) return { ok: false, exit: 2, blockingFailures: failed, established };
  if (blocking.length && established === 0) {
    return { ok: false, exit: 3, blockingFailures: [], established, degraded: true };
  }
  return { ok: true, exit: 0, blockingFailures: [], established };
}

function runDodStep(step) {
  const r = spawnSync(process.execPath, [harnessEntry(), ...step.argv], {
    cwd: projectRoot(),
    input: '',
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, CLAUDE_PROJECT_DIR: projectRoot() },
  });
  if (r.error) {
    return { id: step.id, argv: step.argv, blocking: step.blocking, status: 'FAIL', exit: null,
      error: 'spawn-failed', counts: null, detail: String(r.error.message) };
  }
  let out = null;
  try { out = JSON.parse(String(r.stdout || '').trim()); } catch (_e) { out = null; }
  const code = typeof r.status === 'number' ? r.status : null;
  return {
    id: step.id, argv: step.argv, blocking: step.blocking,
    status: code === null ? 'FAIL' : dodStatus(code),
    exit: code,
    error: out && typeof out.error === 'string' ? out.error : null,
    counts: out && out.counts && typeof out.counts === 'object' ? out.counts : null,
  };
}

function cmdDod(flags) {
  const only = typeof flags.only === 'string' ? new Set(parseCsv(flags.only)) : null;
  const steps = [];
  for (const step of DOD_STEPS) {
    if (only && !only.has(step.id)) continue;
    const r = runDodStep(step);
    steps.push(r);
    process.stderr.write(' ' + r.status.padEnd(9) + r.id
      + (r.error ? ' :: ' + r.error : '') + '\n');
  }
  const verdict = dodVerdict(steps);
  process.stderr.write(verdict.ok
    ? 'Definition of Done: satisfied (static governance only; behavioural proof is `gate`)\n'
    : 'Definition of Done: NOT satisfied'
      + (verdict.blockingFailures.length ? ' (' + verdict.blockingFailures.join(', ') + ')' : ' (no blocking step reached a verdict)') + '\n');
  return emit({
    ok: verdict.ok,
    ...(verdict.degraded ? { degraded: true } : {}),
    steps,
    blockingFailures: verdict.blockingFailures,
    established: verdict.established,
    note: 'static governance only; a satisfied result does not establish that the code works -- that is `gate`',
  }, verdict.exit);
}

export {
  DEFAULT_SPEC_FILE, REQUIRED_SECTIONS, REQUIREMENT_SECTION, PLACEHOLDER_TOKENS,
  AMBIGUOUS_TERMS, HTML_TAGS, DEFAULT_TEST_GLOBS, SPEC_VIEW_BUDGET, DOD_STEPS,
  stripCodeSpans, splitSections, sectionNamed, sectionEmpty, parseRequirements,
  placeholderBrackets, lintSpecDoc, specFilePath, readSpecDoc, cmdSpecLint,
  collectReferences, traceReport, referenceCorpus, loadTrace, cmdTrace,
  renderSpecView, cmdSpec,
  dodStatus, dodVerdict, runDodStep, cmdDod,
};
