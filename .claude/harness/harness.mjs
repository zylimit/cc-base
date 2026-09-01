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
//   lib/selftest.mjs  selftestCases() and its fixture
// Dependencies: core -> (nothing); catalog -> core; graph -> core, catalog; context and
// quality -> core, catalog, graph; scan -> core, catalog; selftest -> all of the above;
// this file -> all of the above. No cycles.
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
import { selftestCases } from './lib/selftest.mjs';

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
