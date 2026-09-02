// harness.mjs -- cc-base monorepo governance runtime: CLI surface, zero npm deps.
// Node builtins only: node:crypto / node:fs / node:path / node:child_process / node:process.
// Default-off: catalog presence (.claude/harness/module-catalog.json) is the only switch.
// All subcommands: stdout single-line JSON + exit code; human diagnostics -> stderr.
// Source is ASCII-only (matches the .ps1 pure-ASCII convention) to avoid cross-platform encoding traps.
//
// This file holds the CLI only: argument parsing, the dispatch table, and the three
// subcommands that belong to no section (doctor / diff-hash / selftest). Every other
// subcommand ships with its own section under lib/ -- the sections outgrew one file once
// the next batch of capabilities was queued, and a 3000-line file was already the limit of
// what could be edited without collateral damage.
//
// Module map (import direction is one-way, so nothing has to be resolved at load time):
//   lib/core.mjs      S1 common, S2 git, S3 glob, S9 config + the vocabulary shared across
//                     sections (typedefs, attribute tiers, parseCsv, DENY/isDenied,
//                     SOURCE_EXTS, whichCmd). Imports node builtins only.
//   lib/catalog.mjs   S4 catalog        loadCatalog / validateSchema / classifyPath / lintCatalog
//   lib/graph.mjs     S5 impact + S12 arch-check + S16 arch-trend
//   lib/quality.mjs   S7 receipt + S8 quality gate + S10 waiver + S11 attributes
//   lib/scan.mjs      S13 fitness + S14 adapters + S15 adr-check
//   lib/context.mjs   S6 context-pack
//   lib/evidence.mjs  S17 gate + ledger + gate-audit + retention + risk
//   lib/task.mjs      S18 task envelope + budget
//   lib/spec.mjs      S19 spec-lint + trace + spec + dod
//   lib/review.mjs    S20 review engine + review-pack + the authorship ledger
//   lib/memory.mjs    S21 invariants + recap + archive + sync-check
//   lib/rules.mjs     S22 rules-audit + S23 skills-lint + S24 claude-md-lint
//   lib/init.mjs      S25 init
//   lib/selftest.mjs  selftestCases() and its fixture
// Dependencies: core -> (nothing); catalog -> core; graph -> core, catalog; context and
// quality -> core, catalog, graph; scan -> core, catalog; evidence -> core, catalog, graph,
// quality; task -> the same plus evidence; spec -> core, catalog, graph; review -> core,
// catalog, graph, quality, evidence; memory -> core, quality, evidence, task, spec;
// rules -> core, catalog; init -> core, catalog, graph, evidence; selftest -> all of the
// above; this file -> all of the above. No cycles.
//
// Scale target: 600k+ LOC repositories. Hot paths (classifyPath / lintCatalog / impact)
// go through a compiled-regex cache; git path listings are NUL-separated so non-ASCII
// names survive; tracked listings are capped (maxTrackedPaths) and a truncated listing
// degrades conservatively instead of under-reporting.

import fs from 'node:fs';
import process from 'node:process';
import {
  canonicalDiff, die, emit, headCommit, isGitRepo, loadHarnessConfig, sha256,
} from './lib/core.mjs';
import { cmdCatalogLint, loadCatalog } from './lib/catalog.mjs';
import { cmdArchCheck, cmdArchTrend, cmdImpact } from './lib/graph.mjs';
import { cmdContextPack } from './lib/context.mjs';
import { cmdAttributes, cmdReceipt, cmdVerify, cmdWaiver, loadWaivers, waiversDir } from './lib/quality.mjs';
import { adaptersFilePath, cmdAdapters, cmdAdrCheck, cmdFitness } from './lib/scan.mjs';
import { cmdGate, cmdGateAudit, cmdLedger, cmdRetention, cmdRisk } from './lib/evidence.mjs';
import { cmdBudget, cmdTask } from './lib/task.mjs';
import { cmdDod, cmdSpec, cmdSpecLint, cmdTrace } from './lib/spec.mjs';
import { cmdAuthorship, cmdReview, cmdReviewPack } from './lib/review.mjs';
import { cmdArchive, cmdInvariants, cmdRecap, cmdSyncCheck } from './lib/memory.mjs';
import { cmdClaudeMdLint, cmdRulesAudit, cmdSkillsLint } from './lib/rules.mjs';
import { cmdInit } from './lib/init.mjs';
import { selftestCases } from './lib/selftest.mjs';

// ===========================================================================
// S0 CLI dispatch
// ===========================================================================
const IMPLEMENTED_SUBCOMMANDS = ['doctor', 'diff-hash', 'selftest', 'catalog-lint', 'impact', 'context-pack', 'receipt', 'verify', 'waiver', 'attributes', 'arch-check', 'fitness', 'adapters', 'adr-check', 'arch-trend', 'gate', 'ledger', 'gate-audit', 'retention', 'risk', 'task', 'budget', 'spec-lint', 'trace', 'spec', 'dod', 'review', 'review-pack', 'authorship', 'invariants', 'recap', 'archive', 'sync-check', 'rules-audit', 'skills-lint', 'claude-md-lint', 'init'];
const NOT_IMPLEMENTED_SUBCOMMANDS = [];

// Which flags each subcommand actually reads. parseArgs collects any `--x` it is handed, and
// without this table it collected a misspelling just as happily: `impact --paths x` (--paths
// belongs to fitness, impact's flag is --changed) exited 0 with a full JSON body having
// measured the wrong thing, and a baseline recorded that way looks normal while asserting
// nothing. An unread flag is a usage error, so it exits 2 -- not 3, which means degraded, and
// not 1, which means something was found.
//
// Each row is the set of `flags.<key>` reads reachable from that subcommand's entry point,
// taken from the source rather than from the documentation, and it is a union over the
// sub-forms (`review` covers start/lens/verdict/team, `waiver` covers list/check/create).
// Two spellings of one switch both appear where the source reads both. A row that is missing
// a flag turns a correct invocation into a usage error, which is worse than the silence it
// replaces, so the two directions are pinned in selftest: every implemented subcommand has a
// row, every row names an implemented subcommand, and every flag in every row survives a real
// invocation. A subcommand with no row accepts no flags, which fails loudly on the day one is
// added without its row rather than quietly going back to collecting anything.
//
// There is no global group: no flag is read by every subcommand. `--catalog` comes closest and
// is still absent from eighteen of them, and listing it globally would advertise a switch that
// `doctor`, `ledger` or `recap` would then silently ignore -- the same defect one level up.
const SUBCOMMAND_FLAGS = {
  'doctor': [],
  'diff-hash': [],
  'selftest': [],
  'catalog-lint': ['catalog', 'tracked'],
  'impact': ['catalog', 'changed'],
  'context-pack': ['budget-chars', 'catalog', 'changed', 'task'],
  'receipt': ['task'],
  'verify': ['catalog', 'changed'],
  'waiver': ['compensation', 'dry-run', 'dryRun', 'expiry', 'file', 'owner', 'reason', 'scope', 'sub'],
  'attributes': ['catalog', 'module'],
  'arch-check': ['catalog', 'max-files', 'record'],
  'fitness': ['all', 'catalog', 'paths'],
  'adapters': ['attribute', 'catalog', 'dry-run', 'dryRun', 'id'],
  'adr-check': ['catalog', 'dir', 'file'],
  'arch-trend': ['gate'],
  'gate': ['catalog', 'changed'],
  'ledger': ['no-verify-evidence'],
  'gate-audit': ['catalog'],
  'retention': ['apply', 'max-age-days', 'max-evidence', 'max-packs'],
  'risk': ['catalog'],
  // `task complete` rejects --changed with its own message and exit 3 (the scope of a
  // completion is not the caller's to state), which is a stricter answer than this table's.
  // Dropping it here would replace that answer with a flat usage error and lose the reason.
  'task': ['catalog', 'changed'],
  'budget': ['catalog'],
  'spec-lint': ['file'],
  'trace': ['catalog', 'file', 'min-coverage', 'tests'],
  'spec': ['all', 'budget', 'catalog', 'file', 'paths', 'tests'],
  'dod': ['only'],
  'review': ['agent', 'catalog', 'notes', 'pack', 'reviewer', 'scope'],
  'review-pack': ['base', 'max-diff-lines'],
  'authorship': [],
  'invariants': ['budget', 'file', 'rules'],
  'recap': ['budget', 'changelog', 'file', 'spec'],
  'archive': ['apply', 'archive', 'file', 'max-entries'],
  'sync-check': ['staged'],
  'rules-audit': ['limit'],
  'skills-lint': ['limit'],
  'claude-md-lint': ['catalog', 'limit'],
  'init': ['apply', 'catalog', 'max-modules'],
};

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

/**
 * Flags the named subcommand does not read, in the order they were given.
 * An unrecognised subcommand answers nothing here: usage() already names that, and reporting
 * its flags too would bury the one thing wrong with the line.
 * @param {string} cmd
 * @param {Object} flags
 * @returns {string[]}
 */
function unknownFlags(cmd, flags) {
  if (!IMPLEMENTED_SUBCOMMANDS.includes(cmd)) return [];
  const allowed = SUBCOMMAND_FLAGS[cmd] || [];
  return Object.keys(flags).filter(k => !allowed.includes(k));
}

/**
 * Name the flags that were not understood, then name the ones that would have been. The
 * second half is the part that matters: a bare rejection sends the reader to the source,
 * and the flag they wanted is usually one line away from the one they typed.
 */
function flagUsage(cmd, unknown) {
  const allowed = SUBCOMMAND_FLAGS[cmd] || [];
  return (unknown.length === 1 ? 'unknown flag for ' : 'unknown flags for ') + cmd + ': '
    + unknown.map(f => '--' + f).join(', ') + '\n'
    + (allowed.length
      ? cmd + ' reads: ' + allowed.map(f => '--' + f).join(', ') + '\n'
      : cmd + ' reads no flags\n')
    + 'a flag no subcommand reads used to be collected and ignored, which left the command\n'
    + 'running in its no-argument shape and reporting success over something it never measured\n';
}

function main() {
  const { cmd, flags, positional } = parseArgs(process.argv.slice(2));
  const unknown = unknownFlags(cmd, flags);
  if (unknown.length) return die(flagUsage(cmd, unknown), 2);
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
    case 'gate':         return cmdGate(flags);
    case 'ledger':       return cmdLedger(flags);
    case 'gate-audit':   return cmdGateAudit(flags);
    case 'retention':    return cmdRetention(flags);
    case 'risk':         return cmdRisk(flags);
    case 'task':         return cmdTask(flags, positional);
    case 'budget':       return cmdBudget(flags);
    case 'spec-lint':    return cmdSpecLint(flags);
    case 'trace':        return cmdTrace(flags);
    case 'spec':         return cmdSpec(flags);
    case 'dod':          return cmdDod(flags);
    case 'review':       return cmdReview(flags, positional);
    case 'review-pack':  return cmdReviewPack(flags);
    case 'authorship':   return cmdAuthorship(flags, positional);
    case 'invariants':   return cmdInvariants(flags);
    case 'recap':        return cmdRecap(flags);
    case 'archive':      return cmdArchive(flags);
    case 'sync-check':   return cmdSyncCheck(flags);
    case 'rules-audit':  return cmdRulesAudit(flags, IMPLEMENTED_SUBCOMMANDS);
    case 'skills-lint':  return cmdSkillsLint(flags);
    case 'claude-md-lint': return cmdClaudeMdLint(flags);
    case 'init':         return cmdInit(flags);
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
    '  gate        verify plus evidence: each check output on disk, planHash, scope provenance, one ledger entry\n' +
    '  ledger      recompute the hash chain and re-verify evidence digests (--no-verify-evidence to skip); any break fails closed\n' +
    '  gate-audit  catalog checks that never failed, and the ones a waiver suppressed (hook gates: .claude/scripts/gate-audit.sh)\n' +
    '  retention   prune evidence/packs by age and count; refuses to sweep unless the chain verifies\n' +
    '  risk        state decay: broken chain, expired waiver, unwired attribute, fail streak, fast-mode debt, stale task\n' +
    '  task        start|status|complete: six-field envelope in, four blocking conditions out\n' +
    '  budget      blast radius vs catalog.budget; over the line is a split-or-escalate signal\n' +
    '  spec-lint   requirement document must be decidable: section shape, template residue, arrow form, undecidable wording\n' +
    '  trace       requirement id <-> test reference coverage; no ids declared means traceability is unavailable, not passing\n' +
    '  spec        budgeted view of the requirements a change touches (--paths / --all / --budget)\n' +
    '  dod         every static governance check once; blocking failure exits 2, nothing established exits 3\n' +
    '  review      start|blue|lens <name>|verdict|backlog|status|team: staged structured disagreement, verdict computed not asserted\n' +
    '  review-pack evidence for a reviewer, with what the change removed in a section of its own\n' +
    '  authorship  record|show: who wrote which files, so a verdict can refuse a lens reported by the author\n' +
    '  invariants  re-derive what cannot be traded away plus the live state, inside a small budget\n' +
    '  recap       the situation derived from the memory files, on a budget; never from a summary\n' +
    '  archive     move the oldest entries out of the memory file verbatim; --apply to write\n' +
    '  sync-check  memory behind code / spec changed without its changelog (--staged reads the index)\n' +
    '  rules-audit which rule lines reach a real enforcement point, and which only read as if they do\n' +
    '  skills-lint SKILL.md frontmatter the loader can read: a malformed one drops the skill in silence\n' +
    '  claude-md-lint  a high-risk module states its boundaries in its own directory: purpose / boundaries / invariants / verification\n' +
    '  init        infer a catalog draft from the tracked tree; prints it, --apply writes it, and never overwrites one\n' +
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

function cmdSelftest() {
  const cases = selftestCases();
  const failed = [];
  for (const [name, fn] of cases) {
    try { fn(); } catch (e) { failed.push({ name, error: String(e && e.message || e) }); }
  }
  if (failed.length) return emit({ ok: false, tests: cases.length, failed }, 1);
  return emit({ ok: true, tests: cases.length }, 0);
}

main();
