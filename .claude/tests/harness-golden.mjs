// harness-golden.mjs -- golden baseline for .claude/harness/harness.mjs (zero npm deps).
// Node builtins only: node:child_process / node:crypto / node:fs / node:os / node:path /
// node:process / node:url.
// Source is ASCII-only (matches harness.mjs and the .ps1 pure-ASCII convention).
//
// Why this exists: harness.mjs is about to be split from one file into lib/*.mjs. That
// split must be behaviour-preserving, and "I read the diff and it looks fine" is not
// evidence. This tool records what every subcommand prints and returns across a matrix of
// repository states, then replays the matrix and compares byte for byte.
//
//   node .claude/tests/harness-golden.mjs --record   write .claude/tests/golden/harness/*.json
//   node .claude/tests/harness-golden.mjs --check    replay and diff against the baseline
//   node .claude/tests/harness-golden.mjs --probe    run the matrix 3x and report which
//                                                    fields move on their own (see below)
//   node .claude/tests/harness-golden.mjs --mutate   inject each mutation listed in
//                                                    .claude/tests/golden/MUTANTS.json, replay
//                                                    the matrix once per mutation, and report
//                                                    which ones this baseline can see (see S6b)
//   ... --check --strict                             same, but a skipped run exits 3 instead
//                                                    of 0, so a caller cannot read "never ran"
//                                                    as "passed" off the exit code alone
//   ... --mutate --mutants F --only N --scenario S   read a different manifest, run a single
//                                                    entry, restrict the replay to one
//                                                    scenario. All three are --mutate only:
//                                                    a filtered --check exiting 0 would read
//                                                    as a green full run off the exit code,
//                                                    which is exactly what this file refuses
//                                                    to let a caller do.
//
// Hermetic by construction. Every scenario runs against a throwaway git repository built
// under the system temp dir from .claude/tests/fixtures/golden/tree/, never against this
// checkout. That is deliberate: the lib split adds files to this repo, so any baseline
// that enumerated this repo's tracked files or working-tree diff would change for reasons
// that have nothing to do with behaviour, and a ruler that cries wolf gets ignored.
//
// -------------------------------------------------------------------------------------
// Normalization is deliberately narrow and keyed by field name, never by a blanket regex
// over every string. `--probe` runs the matrix three times with only path substitution
// applied and reports what moved. Two fields move on their own in every scenario, and those
// two are the only ones masked globally on observed movement (the evidence layer adds more,
// but each is scoped to one command -- see the `volatile` list further down):
//
//   <TS>    receipt `timestamp` and arch-trend `latestAt`. Wall clock, new value per run.
//   <HASH>  receipt `contentHash` only. It folds the receipt timestamp into the digest, so
//           it moves whenever the timestamp does.
//
// Four more are masked on argument rather than on observed movement, each because the
// field describes the environment rather than the harness's behaviour:
//
//   <TMP>   the sandbox path. mkdtemp picks a fresh directory per run, so a path the
//           harness echoed back differed by construction rather than by behaviour. The two
//           fields it was written for (waiver `path`, the catalog-missing `detail`) are now
//           repo-relative at the source and recorded verbatim, so this one currently fires
//           nowhere -- kept as a guard, and a guard that costs nothing here: it normalizes
//           rather than drops, so a field going back to an absolute path still lands in the
//           diff as `<TMP>/...` against a recorded relative string.
//   <SHA>   git commit ids (headCommit / baseCommit / latestCommit). Pinned author and
//           committer dates make these stable run to run, but the object id is a function
//           of git's own encoding, so a git upgrade would move it and read as a harness
//           change. Not something this tool should assert on.
//   <NODE>  process.version from `doctor`. Same argument: a node upgrade would otherwise
//           surface as "the split changed something", the exact false alarm this exists
//           to avoid.
//   <ENV>   `adapters list` -> `available` and `adapters add` -> `executableAvailable`.
//           Both are live PATH probes. The runner pins PATH to git's directory plus
//           /usr/bin:/bin, but /usr/bin is a shared system directory: the recorded
//           mutation-stryker=true comes from a root-owned /usr/bin/npx that has nothing
//           to do with the node this tool runs under, and installing semgrep would flip
//           another. Same argument as <NODE>, and masking costs nothing, because whether
//           whichCmd works at all is asserted far harder elsewhere -- catalog-rich wires
//           a check to a binary named so it can never exist, and `verify` has to report
//           BLOCKED command-missing for it. The sibling field `wired` is catalog state,
//           not environment, and stays byte for byte.
//
// Some fields are masked for a single command rather than globally, through the `volatile`
// map on a COMMANDS entry. `waiver create` stamps created_at from the wall clock, while the
// checked-in waiver fixture carries a fixed one that is worth asserting, so that mask is
// attached to the two waiver-create entries and every other record still compares
// created_at verbatim. The evidence layer adds four of the same kind, all wall-clock
// derived and none of them describing behaviour:
//
//   at            the gate record's timestamp, and the ledger break timestamps that echo it.
//   chain / head  the hash chain folds that timestamp in, so both move whenever it does.
//                 What the chain actually proves is asserted far harder in selftest, which
//                 links a real chain and then tampers with it four different ways.
//   evidence      the evidence log path carries the epoch it was written at.
//   evidenceSha256  digests the check's real output. Every fixture check is hermetic now
//                 (see the note on the checks below), so the digest no longer moves run to
//                 run -- but it is taken before any path substitution can see the text, so
//                 the moment a fixture check says anything about its own sandbox the digest
//                 goes back to being a fact about the environment. The mask stays for that.
//   startedAt / completedAt   the task record's clock fields, and the review session's.
//   at (again)    the authorship record, the backlog entry and the verdict all stamp one.
//
// Both evidence masks only fire on a non-empty value, so a check that produced no log still
// records null and "wrote evidence" stays distinguishable from "never ran" -- which is the
// assertion that actually matters here, BLOCKED and SKIPPED checks writing no log at all.
//
// planHash and diffHash on the gate record stay verbatim, for the same reason packHash
// does: they are the digests a re-record would most easily hide a change behind.
//
// <MS> now fires on the gate record's per-check durationMs, which is wall clock by
// definition. <ROOT> (this checkout's path) fires on one field: the `file` the spec layer
// echoes back, which is the absolute `--file <SPEC>` this runner handed it rather than
// anything the engine composed. Neither mask can hide a newly added field, because the diff
// compares each object's key set explicitly.
//
// What is deliberately left VERBATIM matters more than what is masked:
//   - diffHash and packHash. The probe proves both are stable for a fixed tree across
//     different sandbox paths, so they are compared byte for byte. These are the whole
//     point: canonicalDiff / gitFingerprint / buildPack are exactly the code paths a lib
//     split is most likely to perturb, and masking their digests would gut the ruler.
//     Read one caveat with them: both digest a real `git diff --binary` rendering, so a
//     git upgrade that moves a byte of that rendering moves the digest too. If these are
//     the only fields that changed and nothing in harness.mjs did, check `git --version`
//     against the recording machine before re-recording anything.
//   - waiver `expiry` and `created_at`. Fixed in the fixture, therefore stable, therefore
//     asserted -- this is what proves waiver fields still round-trip.
//   - `review-pack` -> packPath, and the stderr line that names it. The probe caught this
//     one moving: the pack was named from the clock. It is now named from the base ref and
//     the tree fingerprint, which makes it a fact about what was packed rather than about
//     when, so it is asserted instead of masked -- and re-packing the same change overwrites
//     one file instead of leaving retention a pile of identical ones.
//   - everything else: field names, key sets, array lengths, ordering, exit codes, counts,
//     findings, messages and stderr.
//
// The eight-scenario matrix is hermetic, and the price of that is that nothing in it
// asserts anything about THIS checkout. S6b closes that hole with a small set of in-repo
// assertions chosen so the lib split cannot move them: exit codes, key sets, the
// subcommand list, and one determinism check. Nothing there asserts a file count or a
// working-tree digest, because both change on every ordinary commit.
//
// Two files outside the sandbox are baked into the baseline. The sandbox ships no local
// adapters.json, so adaptersFilePath() falls back to .claude/harness/adapters.json in this
// checkout and `adapters list` asserts on the shipped tool table. Editing that table is a
// legitimate reason for --check to fail; re-record when it happens. The second is
// fixtures/golden/product-spec-sample.md, reached through `--file <SPEC>`: the sandbox tree
// deliberately carries no Product-Spec.md (adding one would land as an unmapped path in every
// catalog fixture and force the whole matrix into degraded full fan-out), so without the
// fixture the specification layer would only ever be recorded saying "no document found" --
// a lint whose passing path is recorded nowhere is a lint nobody has proved can pass.
//
// stderr is captured and compared, minus node's own runtime warnings (ExperimentalWarning
// and friends are emitted by the runtime, not by the harness).

import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

// ===========================================================================
// S0  paths and layout
// ===========================================================================

const THIS_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(THIS_DIR, '..', '..');
const HARNESS = path.join(REPO_ROOT, '.claude', 'harness', 'harness.mjs');
const HARNESS_FIXTURES = path.join(THIS_DIR, 'fixtures', 'harness');
const GOLDEN_FIXTURES = path.join(THIS_DIR, 'fixtures', 'golden');
const TREE_DIR = path.join(GOLDEN_FIXTURES, 'tree');
const WAIVER_FIXTURE = path.join(GOLDEN_FIXTURES, 'waiver-valid.json');
const SPEC_FIXTURE = path.join(GOLDEN_FIXTURES, 'product-spec-sample.md');
const GOLDEN_DIR = path.join(THIS_DIR, 'golden', 'harness');
const MUTANTS_FILE = path.join(THIS_DIR, 'golden', 'MUTANTS.json');
const MUTANT_SCOPE = '.claude/harness/lib/';

// ===========================================================================
// S1  scenario matrix
// ===========================================================================
// Dimension one is catalog state -- catalog presence is the harness's only feature switch.
// Dimension two is git state, which drives the rc 3 degraded paths.

const SCENARIOS = [
  { name: 'no-catalog', catalog: null, git: true },
  { name: 'catalog-good', catalog: path.join(HARNESS_FIXTURES, 'catalog-good.json'), git: true },
  { name: 'catalog-rich', catalog: path.join(GOLDEN_FIXTURES, 'catalog-rich.json'), git: true },
  // Every check passes and every declared attribute has a claiming check that passed, so
  // this is the only scenario where `verify` reaches gate PASS exit 0. Two hooks consume
  // that exit code as the commit gate, and without this row the whole PASS branch was
  // recorded nowhere: the matrix only ever produced FAIL, BLOCKED and DEGRADED.
  { name: 'catalog-pass', catalog: path.join(GOLDEN_FIXTURES, 'catalog-pass.json'), git: true },
  { name: 'catalog-bad-catchall', catalog: path.join(HARNESS_FIXTURES, 'catalog-bad-catchall.json'), git: true },
  { name: 'catalog-bad-dangling', catalog: path.join(HARNESS_FIXTURES, 'catalog-bad-dangling.json'), git: true },
  { name: 'catalog-bad-overlap', catalog: path.join(HARNESS_FIXTURES, 'catalog-bad-overlap.json'), git: true },
  { name: 'catalog-bad-unmapped', catalog: path.join(HARNESS_FIXTURES, 'catalog-bad-unmapped.json'), git: true },
  { name: 'non-git', catalog: path.join(GOLDEN_FIXTURES, 'catalog-rich.json'), git: false },
];

// All twenty-nine subcommands plus the sub-forms that take a different code path.
// Order matters three times: `receipt write` must precede every `receipt verify` (verify
// checks the receipt the write just bound to the current diff), `arch-check --record`
// must precede the arch-trend pair (the ratchet needs a ledger entry to compare against),
// and it runs twice because one record can only ever report comparable:false -- the whole
// ratchet comparison was unreachable with a single snapshot. All of those write only into
// .claude/harness/{receipts,trend}/, which the harness excludes from the diff fingerprint,
// so none of them perturbs a later command.
//
// The tail of the list is different in kind and is fenced off below: those entries carry
// a `mutate` hook that moves the working tree on purpose, which moves diffHash for
// everything after them. Nothing may be appended after that fence without thinking about
// what it is now being run against.
const RECEIPT_INPUT = JSON.stringify({
  taskId: 'golden-task',
  reviewer: 'golden-baseline',
  verdict: 'pass',
  scope: 'sandbox fixture tree',
});

// A complete six-field envelope, and one missing four of them. The second is the point:
// `task start` has to name each absent field rather than answer "incomplete".
const TASK_INPUT = JSON.stringify({
  id: 'golden-task',
  goal: 'exercise the task envelope end to end',
  scope: 'the sandbox fixture tree',
  outOfScope: 'anything outside the sandbox',
  existingPattern: 'core/util.ts',
  verification: 'harness.mjs gate -> expect exit 0 and gate PASS',
  escalation: 'stop and report if the catalog itself needs changing',
});
const TASK_INPUT_INCOMPLETE = JSON.stringify({ id: 'golden-task', goal: 'the rest is missing' });

// The review layer's stdin payloads. Each rejection has a matching acceptance beside it,
// because a refusal recorded on its own only proves the command can say no.
const AUTHORSHIP_INPUT = JSON.stringify({
  agentId: 'golden-implementer',
  agentType: 'implementer',
  files: ['core/util.ts'],
});
const BLUE_INPUT = JSON.stringify({
  claims: [{ statement: 'the sandbox tree still parses', evidence: 'node --check core/util.ts -> exit 0' }],
});
const BLUE_INPUT_NO_EVIDENCE = JSON.stringify({ claims: [{ statement: 'it works' }] });
const LENS_INPUT = JSON.stringify({ findings: [] });
const LENS_INPUT_UNLOCATED = JSON.stringify({ findings: [{ severity: 'error', summary: 'feels wrong' }] });
const BACKLOG_INPUT = JSON.stringify({
  owner: '@golden', expiry: '2099-01-01T00:00:00.000Z',
  summary: 'the legacy route has no bound on its retry loop', lens: 'reliability',
  location: 'api/legacy.ts:1',
});
const BACKLOG_INPUT_PROTECTED = JSON.stringify({
  owner: '@golden', expiry: '2099-01-01T00:00:00.000Z',
  summary: 'the legacy route has no bound on its retry loop', lens: 'security',
});

const COMMANDS = [
  { id: 'doctor', argv: ['doctor'] },
  { id: 'diff-hash', argv: ['diff-hash'] },
  { id: 'selftest', argv: ['selftest'] },
  { id: 'catalog-lint', argv: ['catalog-lint'] },
  { id: 'impact', argv: ['impact'] },
  { id: 'impact--changed', argv: ['impact', '--changed', 'core/util.ts,api/legacy.ts'] },
  { id: 'context-pack', argv: ['context-pack', '--task', 'golden-task'] },
  { id: 'receipt-write', argv: ['receipt', 'write'], stdin: RECEIPT_INPUT },
  { id: 'receipt-verify', argv: ['receipt', 'verify', '--task', 'golden-task'] },
  { id: 'verify', argv: ['verify'] },
  { id: 'waiver-list', argv: ['waiver', 'list'] },
  { id: 'waiver-check', argv: ['waiver', 'check', '--file', '<WAIVER>'] },
  { id: 'attributes', argv: ['attributes'] },
  { id: 'arch-check', argv: ['arch-check'] },
  { id: 'arch-check--record', argv: ['arch-check', '--record'] },
  { id: 'arch-check--record-2', argv: ['arch-check', '--record'] },
  { id: 'fitness', argv: ['fitness'] },
  { id: 'fitness--all', argv: ['fitness', '--all'] },
  { id: 'adapters-list', argv: ['adapters', 'list'] },
  { id: 'adr-check', argv: ['adr-check'] },
  { id: 'arch-trend', argv: ['arch-trend'] },
  { id: 'arch-trend--gate', argv: ['arch-trend', '--gate'] },

  // Co-change reads committed history, and the sandbox has exactly one commit, so the default
  // run records the honest empty answer: nothing can reach --min-support 5, and the note has
  // to say so rather than let an empty result read as a clean boundary. The second entry drops
  // the threshold to 1, which is the only way one commit can produce a finding at all -- the
  // base commit touched every module, so every pair without a dependsOn between them is
  // undeclared and --gate exits 1. Recording only the empty half would pin a command that has
  // never been seen finding anything.
  { id: 'cochange', argv: ['cochange'] },
  { id: 'cochange--gate', argv: ['cochange', '--gate', '--min-support', '1'] },

  // The evidence layer. Order is load-bearing here too: `gate` must run before anything
  // that reads the ledger, it runs twice so the chain has a real predecessor link to
  // verify rather than just a genesis line, and the task trio runs start -> status ->
  // complete. All of it writes only into .claude/harness/{state,evidence}, which the
  // harness excludes from the diff fingerprint, so none of it perturbs a later command.
  // `task complete` reaches exit 0 in catalog-pass (PASS gate + the receipt written
  // above, both bound to this diff) and is blocked everywhere else -- both halves of the
  // hard gate are recorded, which is the only way the blocked half can be trusted.
  { id: 'gate', volatile: { at: '<TS>', evidence: '<EVIDENCE>', evidenceSha256: '<HASH>', chain: '<HASH>' }, argv: ['gate'] },
  { id: 'gate-2', volatile: { at: '<TS>', evidence: '<EVIDENCE>', evidenceSha256: '<HASH>', chain: '<HASH>' }, argv: ['gate'] },
  { id: 'ledger', volatile: { head: '<HASH>', at: '<TS>' }, argv: ['ledger'] },
  { id: 'gate-audit', argv: ['gate-audit'] },
  { id: 'retention', argv: ['retention'] },
  { id: 'budget', argv: ['budget'] },
  { id: 'task-start', volatile: { startedAt: '<TS>' }, argv: ['task', 'start'], stdin: TASK_INPUT },
  { id: 'task-start--incomplete', argv: ['task', 'start'], stdin: TASK_INPUT_INCOMPLETE },
  { id: 'task-status', volatile: { startedAt: '<TS>' }, argv: ['task', 'status'] },
  { id: 'task-complete', volatile: { startedAt: '<TS>', completedAt: '<TS>' }, argv: ['task', 'complete'] },
  { id: 'task--bad-sub', argv: ['task', 'bogus'] },
  { id: 'risk', volatile: { at: '<TS>' }, argv: ['risk'] },

  // The specification layer. Each of the three lints is recorded twice: once against the
  // sandbox, which has no requirement document and must therefore degrade rather than answer,
  // and once against the checked-in sample through `--file <SPEC>`. The second half is the
  // one that matters -- it is where spec-lint reaching zero findings on a well-formed document
  // and trace naming three unreferenced ids are pinned, and neither could be reached from a
  // tree that has no specification in it at all. `dod` writes nothing and runs no project
  // command, so it can sit anywhere before the mutation fence.
  { id: 'spec-lint', argv: ['spec-lint'] },
  { id: 'spec-lint--file', argv: ['spec-lint', '--file', '<SPEC>'] },
  { id: 'trace', argv: ['trace'] },
  { id: 'trace--file', argv: ['trace', '--file', '<SPEC>'] },
  { id: 'spec', argv: ['spec'] },
  { id: 'spec--file', argv: ['spec', '--file', '<SPEC>', '--all', '--budget', '600'] },
  { id: 'dod', argv: ['dod'] },

  // Release readiness. Two of its seven checks reach outside the process, and both are pinned
  // to a determinate degraded answer here by the sandbox rather than by a mask: the sandbox
  // has no remote, and `release` answers no-origin before it ever looks for `gh` -- so a
  // machine with gh on PATH and one without record the same bytes. (The runner pins PATH to
  // git's directory plus /usr/bin:/bin, and /usr/bin is exactly where a system gh lives, so
  // this ordering is doing real work.) The other five are local: the mutations applied at
  // sandbox build make `worktree` fail, the sandbox ships no FRAMEWORK-MANIFEST.txt so
  // `manifest` degrades, and the two flag files are absent so the review queue and fast mode
  // both pass. `dod` runs as a child and its verdict per scenario is already pinned by the
  // entry above. It writes nothing, so like `dod` it can sit anywhere before the fence.
  //
  // Not added to the in-repo assertions below, deliberately: against this checkout the same
  // command asks the network and the live CI, and an assertion whose value depends on whether
  // a push landed is a ruler that goes red for reasons that are not behaviour.
  { id: 'release', argv: ['release'] },

  // The review layer. It writes only into .claude/harness/{state,receipts}, both excluded
  // from the diff fingerprint, so a session cannot stale itself and none of this perturbs a
  // later command. Order is the protocol: pack the evidence, record who wrote the code, open
  // the review, blue self-reports, the lenses report, then the verdict is computed.
  // The two halves of the author rule are both recorded, and that pairing is the point of the
  // sequence: `review-lens` reports as golden-red, who wrote nothing, so the verdict may
  // conclude; `review-lens--by-author` re-reports the same lens as golden-implementer, who
  // `authorship-record` just named as the author of core/util.ts, and the verdict that follows
  // has to refuse. A recording of only the refusal would not show the rule can ever pass, and
  // one of only the pass would not show it can ever fire.
  // What each scenario actually convenes differs, and that is worth recording rather than
  // engineering away: the team profile drops a lens whose attribute no affected module
  // declares, so the fixtures without attributes convene correctness alone (verdict reaches
  // ACCEPT and writes a receipt) while the richer ones convene more and the verdict has to
  // refuse until they report.
  { id: 'review-pack', argv: ['review-pack'] },
  { id: 'authorship-record', volatile: { at: '<TS>' }, argv: ['authorship', 'record'], stdin: AUTHORSHIP_INPUT },
  { id: 'authorship-show', argv: ['authorship', 'show'] },
  { id: 'review-team', argv: ['review', 'team'] },
  { id: 'review-start', argv: ['review', 'start', '--scope', 'golden sandbox'] },
  { id: 'review-blue--no-evidence', argv: ['review', 'blue'], stdin: BLUE_INPUT_NO_EVIDENCE },
  { id: 'review-blue', argv: ['review', 'blue'], stdin: BLUE_INPUT },
  { id: 'review-lens--unlocated', argv: ['review', 'lens', 'correctness'], stdin: LENS_INPUT_UNLOCATED },
  { id: 'review-lens', argv: ['review', 'lens', 'correctness', '--agent', 'golden-red'], stdin: LENS_INPUT },
  { id: 'review-lens--gated', argv: ['review', 'lens', 'testing', '--agent', 'golden-red'], stdin: LENS_INPUT },
  { id: 'review-status', volatile: { startedAt: '<TS>' }, argv: ['review', 'status'] },
  { id: 'review-backlog-add--protected', argv: ['review', 'backlog', 'add'], stdin: BACKLOG_INPUT_PROTECTED },
  { id: 'review-backlog-add', volatile: { at: '<TS>' }, argv: ['review', 'backlog', 'add'], stdin: BACKLOG_INPUT },
  { id: 'review-backlog-list', volatile: { at: '<TS>' }, argv: ['review', 'backlog', 'list'] },
  { id: 'review-verdict', volatile: { at: '<TS>' }, argv: ['review', 'verdict', '--reviewer', 'golden-judge'] },
  { id: 'review-lens--by-author', argv: ['review', 'lens', 'correctness', '--agent', 'golden-implementer'], stdin: LENS_INPUT },
  { id: 'review-verdict--self-reviewed', volatile: { at: '<TS>' }, argv: ['review', 'verdict', '--reviewer', 'golden-judge'] },

  // The memory layer. The sandbox tree carries no CLAUDE.md, progress.md or specification,
  // so what these four record here is the contract rather than the rendering: which exit
  // code a missing source produces, that a missing source is named instead of rendered
  // around, and -- for `invariants` -- that the live state is still derived and returned
  // when the constitution is absent, because the state is the half a compaction destroys.
  // The rendering itself is asserted in selftest, over text, where a budget and a
  // move-not-rewrite can be checked without a filesystem. `sync-check` runs both ways: the
  // worktree has the mutations applied at sandbox build and the index has nothing, and both
  // are quiet here for the same reason -- a tree with no memory file is not a tree behind on
  // its memory, and reporting one would be the false positive that gets the gate switched off.
  { id: 'invariants', argv: ['invariants'] },
  { id: 'invariants--budget', argv: ['invariants', '--budget', '200'] },
  { id: 'recap', argv: ['recap'] },
  { id: 'archive', argv: ['archive'] },
  { id: 'sync-check', argv: ['sync-check'] },
  { id: 'sync-check--staged', argv: ['sync-check', '--staged'] },

  // S22. The sandbox carries no CLAUDE.md and no .claude/rules, so what is pinned here is
  // the refusal: a tree with no constitution reports that it has none rather than reporting
  // a clean one. An audit that answered 0 rules / 0 phantom / ok:true for a repository it
  // never read would be the exact failure the command exists to name.
  { id: 'rules-audit', argv: ['rules-audit'] },

  // S23. Same tree, opposite contract: the sandbox carries no .claude/skills either, and
  // that is a state this framework installs into all the time, so the answer pinned here is
  // exit 0 with the absence stated. "No skills directory" and "no skill parsed" have to stay
  // two different answers -- a lint that degraded on every project without skills would be
  // switched off by the first person who saw it, and one that called the absence clean would
  // be claiming something about files nobody opened.
  { id: 'skills-lint', argv: ['skills-lint'] },

  // S24. The fixture tree carries no CLAUDE.md in any module directory, so what the catalog
  // scenarios pin here is the finding: a module the catalog itself calls high risk, with
  // nothing stating its boundaries where the work happens. The two catalogs whose modules
  // are all medium or low pin the other end -- nothing in scope is exit 0 with both counts
  // in the answer, not a degradation, because a catalog that declares no high-risk module
  // owes no directory constitution. Adding the file to the fixture tree would land as an
  // unmapped path in every catalog and force the whole matrix into degraded full fan-out,
  // so the passing path is pinned in selftest's temporary trees instead.
  { id: 'claude-md-lint', argv: ['claude-md-lint'] },

  // S25. Dry run only, and deliberately so: `--apply` would write a catalog into the sandbox,
  // and in the no-catalog scenario that would switch the whole large-repo layer on for every
  // command recorded after it -- the one scenario whose entire job is to record the layer off.
  // The refusal to overwrite and the write itself are pinned in selftest's temporary trees.
  // What this entry buys is that the inference over a fixed tree is reproducible to the byte:
  // the draft, its module ids, the reference edges and the counts all have to land identically
  // or the baseline goes red, which is the property a bootstrap command most needs and most
  // easily loses (a Map iterated in insertion order, a clock, an absolute path).
  { id: 'init', argv: ['init'] },

  // Sub-forms and error paths that no earlier entry reaches. Three of them are the only
  // way anything in this file produces stderr at all: harness.mjs writes to stderr in
  // exactly three places (die(), the waiver-create rejection, the arch-check trend-record
  // failure) and the first two are here. Until they were added, every recorded stderr in
  // every scenario was the empty array, so the whole channel asserted nothing.
  { id: 'receipt-verify--missing', argv: ['receipt', 'verify', '--task', 'golden-absent'] },
  { id: 'receipt-verify--tampered', argv: ['receipt', 'verify', '--task', 'golden-tampered'] },
  { id: 'receipt--bad-sub', argv: ['receipt', 'bogus'] },
  { id: 'waiver-create--dry-run', volatile: { created_at: '<TS>' },
    argv: ['waiver', 'create', '--dry-run', '--owner', '@team-db',
      '--reason', 'sandbox fixture for the create path', '--scope', 'always-fail',
      '--expiry', '2099-01-01T00:00:00.000Z', '--compensation', 'nightly suite runs it'] },
  // Rejected on the forbidden-keyword rule ("security" in reason), which is also the only
  // path that exercises the stderr line in `waiver create`.
  { id: 'waiver-create--rejected', volatile: { created_at: '<TS>' },
    argv: ['waiver', 'create', '--dry-run', '--owner', '@team-db',
      '--reason', 'security exception, just this once', '--scope', 'always-fail',
      '--expiry', '2099-01-01T00:00:00.000Z', '--compensation', 'none'] },
  { id: 'waiver--bad-sub', argv: ['waiver', 'bogus'] },
  { id: 'adapters-add--dry-run', argv: ['adapters', 'add', 'secrets-gitleaks', '--dry-run'] },
  { id: 'adapters-add--unknown', argv: ['adapters', 'add', 'cc-base-golden-absent-adapter'] },
  { id: 'adapters--bad-sub', argv: ['adapters', 'bogus'] },
  { id: 'review--bad-sub', argv: ['review', 'bogus'] },
  { id: 'review-backlog--bad-act', argv: ['review', 'backlog', 'bogus'] },
  { id: 'authorship--bad-sub', argv: ['authorship', 'bogus'] },
  { id: 'unknown-subcommand', argv: ['cc-base-golden-absent-subcommand'] },
  { id: 'missing-subcommand', argv: [] },

  // ---- fence: everything below moves the working tree before it runs ----
  // The two STALE notes left are diff-moved and no-matching-receipt, and both need the
  // tree to have moved since `receipt write` bound its receipt. One append buys both.
  { id: 'receipt-verify--diff-moved', argv: ['receipt', 'verify', '--task', 'golden-task'],
    mutate: root => fs.appendFileSync(path.join(root, 'core', 'util.ts'), '\nexport const REVISION = 3;\n', 'utf8') },
  { id: 'receipt-verify--no-match', argv: ['receipt', 'verify'] },
];

// Applied after the sandbox commit so there is a working-tree diff for diff-hash,
// impact, context-pack, verify and the changed-scope fitness run to chew on.
// The .pem is the only changed path context-pack must refuse: `denied` was an empty array
// in all eight scenarios, so the DENY list -- a security rule -- had no coverage at all.
// It sits under db/ rather than at the root so the catalogs that map db/** still map it,
// and its bytes are irrelevant on purpose: DENY is a path rule, not a content rule.
const MUTATIONS = [
  { path: 'core/util.ts', append: '\nexport const REVISION = 2;\n' },
  { path: 'auth/login.ts', append: '\nexport const LOGIN_REVISION = 2;\n' },
  { path: 'api/new-route.ts', create: "import { handleLogin } from './server';\n\nexport const route = handleLogin;\n" },
  { path: 'db/server.pem', create: 'no key material here; DENY matches the path, never the bytes\n' },
];

// A receipt whose stored contentHash does not match its body. `receipt verify --task`
// answers STALE/tampered for it, which is the anti-forgery branch: without this file the
// check could be deleted outright and the baseline stayed green.
const TAMPERED_RECEIPT = {
  taskId: 'golden-tampered',
  baseCommit: '0000000000000000000000000000000000000000',
  diffHash: '0000000000000000000000000000000000000000000000000000000000000000',
  reviewer: 'golden-baseline',
  verdict: 'pass',
  scope: 'forged',
  timestamp: '2020-01-01T00:00:00.000Z',
  contentHash: 'not-the-hash-of-this-object',
};

// ===========================================================================
// S2  sandbox construction
// ===========================================================================

/** Fixture file names encode their destination: `a__b.ts.txt` -> `a/b.ts`. */
function decodeFixtureName(name) {
  return name.slice(0, -'.txt'.length).split('__').join('/');
}

function readFixtureTree() {
  return fs.readdirSync(TREE_DIR)
    .filter(n => n.endsWith('.txt'))
    .sort()
    .map(n => ({ dest: decodeFixtureName(n), content: fs.readFileSync(path.join(TREE_DIR, n), 'utf8') }));
}

function writeFileDeep(target, content) {
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, content, 'utf8');
}

/**
 * Git env pinned hard: fixed identity and dates, and global/system config switched off so
 * a developer's ~/.gitconfig (autocrlf, hooks, gpg signing, templates) cannot leak in and
 * make the sandbox differ between two machines.
 */
function gitEnv() {
  return {
    GIT_AUTHOR_NAME: 'golden',
    GIT_AUTHOR_EMAIL: 'golden@example.invalid',
    GIT_COMMITTER_NAME: 'golden',
    GIT_COMMITTER_EMAIL: 'golden@example.invalid',
    GIT_AUTHOR_DATE: '2020-01-01T00:00:00+0000',
    GIT_COMMITTER_DATE: '2020-01-01T00:00:00+0000',
    GIT_CONFIG_GLOBAL: '/dev/null',
    GIT_CONFIG_SYSTEM: '/dev/null',
    GIT_CONFIG_NOSYSTEM: '1',
  };
}

function runGit(cwd, args) {
  const r = spawnSync('git', args, {
    cwd,
    encoding: 'utf8',
    env: { ...process.env, ...gitEnv(), LC_ALL: 'C', TZ: 'UTC' },
  });
  if (r.status !== 0) {
    throw new Error('git ' + args.join(' ') + ' failed (' + r.status + '): ' + String(r.stderr || '').trim());
  }
  return r;
}

const SANDBOX_PREFIX = 'ccbase-golden-';
const STALE_AFTER_MS = 2 * 60 * 60 * 1000;

/**
 * Sweep sandboxes an earlier run failed to remove. A run killed mid-flight (SIGPIPE from
 * piping this tool into `head`, for instance) skips its own cleanup, and nobody enjoys a
 * /tmp full of orphaned git repositories. The age guard keeps a concurrent run's live
 * directories out of reach.
 */
function sweepStaleSandboxes() {
  const tmp = os.tmpdir();
  let names;
  try { names = fs.readdirSync(tmp); } catch (_e) { return; }
  const cutoff = Date.now() - STALE_AFTER_MS;
  for (const n of names) {
    if (!n.startsWith(SANDBOX_PREFIX)) continue;
    const p = path.join(tmp, n);
    try {
      if (fs.statSync(p).mtimeMs < cutoff) fs.rmSync(p, { recursive: true, force: true });
    } catch (_e) { /* another run may own it; leaving it is the safe outcome */ }
  }
}

/** Build one throwaway repository for a scenario; returns its realpath. */
function buildSandbox(scenario) {
  const made = fs.mkdtempSync(path.join(os.tmpdir(), SANDBOX_PREFIX));
  const root = fs.realpathSync(made);
  try {
    return populateSandbox(scenario, root);
  } catch (e) {
    // Never leave a half-built repository behind just because setup blew up.
    fs.rmSync(root, { recursive: true, force: true });
    throw e;
  }
}

function populateSandbox(scenario, root) {
  for (const f of readFixtureTree()) writeFileDeep(path.join(root, f.dest), f.content);
  fs.mkdirSync(path.join(root, '.home'), { recursive: true });

  if (scenario.catalog) {
    writeFileDeep(path.join(root, '.claude', 'harness', 'module-catalog.json'),
      fs.readFileSync(scenario.catalog, 'utf8'));
  }
  // Waiver lands in the runtime dir the harness reads, so `waiver list`/`verify` see it.
  writeFileDeep(path.join(root, '.claude', 'harness', 'waivers', 'golden.json'),
    fs.readFileSync(WAIVER_FIXTURE, 'utf8'));
  writeFileDeep(path.join(root, '.claude', 'harness', 'receipts', 'golden-tampered.json'),
    JSON.stringify(TAMPERED_RECEIPT, null, 2) + '\n');

  if (scenario.git) {
    runGit(root, ['-c', 'init.defaultBranch=main', 'init', '-q']);
    runGit(root, ['config', 'core.autocrlf', 'false']);
    // .git/info/exclude keeps .claude/ invisible to git without adding a tracked
    // .gitignore -- a tracked .gitignore would itself need a home in every catalog
    // fixture, and an untracked catalog would land in impact as an unmapped path and
    // force every scenario into degraded full fan-out.
    writeFileDeep(path.join(root, '.git', 'info', 'exclude'), '.claude/\n.home/\n');
    runGit(root, ['add', '-A']);
    runGit(root, ['commit', '-q', '-m', 'golden sandbox base']);
  }

  for (const m of MUTATIONS) {
    const target = path.join(root, m.path);
    if (m.create !== undefined) writeFileDeep(target, m.create);
    else fs.appendFileSync(target, m.append, 'utf8');
  }
  return root;
}

// ===========================================================================
// S3  runner
// ===========================================================================
// PATH is pinned to git's own directory plus /usr/bin:/bin. That keeps three things
// deterministic at once: which binaries `verify` can find (catalog-rich leans on this to
// produce a real BLOCKED for a missing binary), what `adapters list` reports as available,
// and the fact that a stray npm/node on the developer's PATH cannot be spawned by a check.
//
// Pinning PATH is only half of it, and the half that misleads. A pinned PATH still asks the
// machine a question -- "is this tool installed in /usr/bin?" -- and the two answers land in
// different states. catalog-good's checks used to be `npm run lint` / `npm test` / `npm audit`:
// a dev box with a distro npm in /usr/bin ran them and recorded FAIL, while a hosted runner
// keeps npm under /opt/hostedtoolcache and got BLOCKED command-missing, so the baseline was
// green only on the machine that recorded it. Every fixture check is therefore written to be
// hermetic by construction: a state it always produces, from a command whose answer cannot
// vary. PASS from `true`, FAIL from `false` and `sh -c 'exit N'`, and BLOCKED from
// `cc-base-golden-absent-binary` -- a name reserved to never exist, which is the only honest
// way to source BLOCKED. A real tool that merely happens to be missing sources it by accident,
// and flips the moment someone installs it. This is the second time the fixtures leaked a
// machine dependency (selftest's runCheck had the same bug with `node`, fixed by spawning
// process.execPath); if a check here ever needs a real tool again, that is the bug.
//
// Only `sh`, `true` and `false` are used, and not because they felt safe: the CI run that
// caught the npm leak had catalog-rich passing, which means its `true` and `false` checks
// both resolved and ran on the runner, and running any check at all goes through
// spawnSync('sh', ['-c', ...]). Those three are the binaries the runner is on record as
// having. `sh -c 'exit N'` carries the multi-token, quoted command string that the npm
// checks used to be the only source of, and security's exit 9 pins that the recorded `exit`
// is the check's real status rather than a normalised 1.

let cachedPath = null;
function sandboxPath() {
  if (cachedPath !== null) return cachedPath;
  const r = spawnSync('sh', ['-c', 'command -v git'], { encoding: 'utf8' });
  const gitDir = r.status === 0 ? path.dirname(String(r.stdout).trim()) : '/usr/bin';
  cachedPath = [gitDir, '/usr/bin', '/bin'].join(path.delimiter);
  return cachedPath;
}

function runHarness(root, cmd) {
  const argv = cmd.argv.map(a => {
    if (a === '<WAIVER>') return path.join(root, '.claude', 'harness', 'waivers', 'golden.json');
    if (a === '<SPEC>') return SPEC_FIXTURE;
    return a;
  });
  const r = spawnSync(process.execPath, [HARNESS, ...argv], {
    cwd: root,
    input: cmd.stdin || '',
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
    env: {
      ...gitEnv(),
      PATH: sandboxPath(),
      HOME: path.join(root, '.home'),
      CLAUDE_PROJECT_DIR: root,
      LC_ALL: 'C',
      TZ: 'UTC',
    },
  });
  if (r.error) throw new Error('spawn failed for ' + cmd.id + ': ' + r.error.message);
  return { code: r.status, stdout: String(r.stdout || ''), stderr: String(r.stderr || '') };
}

/** Node's own runtime chatter is not harness output. */
function isRuntimeNoise(line) {
  return /^\(node:\d+\)/.test(line) || /ExperimentalWarning|DeprecationWarning/.test(line);
}

function shapeResult(raw) {
  const text = raw.stdout.trim();
  const out = { exitCode: raw.code };
  if (text === '') {
    out.stdout = null;
  } else {
    try {
      out.stdout = JSON.parse(text);
    } catch (_e) {
      out.stdoutText = text.split('\n');
      out.stdout = null;
    }
  }
  out.stderr = raw.stderr.split('\n').map(l => l.trimEnd()).filter(l => l !== '' && !isRuntimeNoise(l));
  return out;
}

/** Run the whole command matrix for one scenario against a fresh sandbox. */
function runScenario(scenario) {
  const root = buildSandbox(scenario);
  try {
    const commands = COMMANDS.map(cmd => {
      if (cmd.mutate) cmd.mutate(root);
      return {
        id: cmd.id,
        argv: cmd.argv,
        ...shapeResult(runHarness(root, cmd)),
      };
    });
    return { record: { scenario: scenario.name, commands }, root };
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

// ===========================================================================
// S4  normalization
// ===========================================================================

// Exact field names only. A `/hash$/` style rule would also swallow diffHash and packHash,
// and an ISO-timestamp regex over every string would swallow the waiver's fixed expiry --
// all three are stable, all three are assertions worth keeping.
const KEY_RULES = [
  { re: /^(headCommit|baseCommit|latestCommit|commit|sha)$/, token: '<SHA>' },
  { re: /^contentHash$/, token: '<HASH>' },
  { re: /^(timestamp|latestAt)$/, token: '<TS>' },
  // Anchored at both ends. `/Ms$/` alone would also swallow any future field whose name
  // merely ends in Ms, which is precisely the blanket-regex mistake this list avoids.
  { re: /^(ms|\w+Ms)$/, token: '<MS>' },
  { re: /^node$/, token: '<NODE>' },
  { re: /^(available|executableAvailable)$/, token: '<ENV>' },
];

/** Literal (non-regex) replacement, longest needle first. */
function substitutePaths(s, subs) {
  let out = s;
  for (const [needle, token] of subs) {
    if (needle) out = out.split(needle).join(token);
  }
  return out;
}

function normalizeString(s, ctx) {
  return substitutePaths(String(s), ctx.pathSubs);
}

/** Key-driven replacement only fires on a non-empty primitive, so null/'' stay themselves. */
function normalizeByKey(key, value, ctx) {
  if (ctx.pathsOnly) return undefined;
  if (value === null || value === undefined || value === '') return undefined;
  if (typeof value !== 'string' && typeof value !== 'number' && typeof value !== 'boolean') return undefined;
  if (ctx.volatile && Object.prototype.hasOwnProperty.call(ctx.volatile, key)) return ctx.volatile[key];
  for (const rule of KEY_RULES) {
    if (rule.re.test(key)) return rule.token;
  }
  return undefined;
}

function normalize(value, ctx, key = '') {
  const byKey = key === '' ? undefined : normalizeByKey(key, value, ctx);
  if (byKey !== undefined) return byKey;
  if (typeof value === 'string') return normalizeString(value, ctx);
  if (Array.isArray(value)) return value.map(v => normalize(v, ctx, ''));
  if (value && typeof value === 'object') {
    const out = {};
    for (const k of Object.keys(value)) out[k] = normalize(value[k], ctx, k);
    return out;
  }
  return value;
}

function makeCtx(pathsOnly) {
  const tmp = fs.realpathSync(os.tmpdir());
  return {
    pathsOnly: !!pathsOnly,
    // Longest first: a sandbox path lives under tmpdir, so tmpdir must not win.
    pathSubs: [[REPO_ROOT, '<ROOT>'], [tmp, '<TMP>']],
  };
}

// The sandbox directory name changes per run, so it is substituted per record with the
// concrete root before the generic rules run. Commands are normalized one at a time so a
// per-command `volatile` map can add a mask that must not apply to the rest of the matrix.
function normalizeRecord(record, root, pathsOnly) {
  const base = makeCtx(pathsOnly);
  base.pathSubs = [[root, '<TMP>'], ...base.pathSubs];
  const specById = new Map(COMMANDS.map(c => [c.id, c]));
  return {
    scenario: normalize(record.scenario, base, ''),
    commands: record.commands.map(c => {
      const spec = specById.get(c.id);
      return normalize(c, { ...base, volatile: (spec && spec.volatile) || null }, '');
    }),
  };
}

// ===========================================================================
// S5  flattening and diffing
// ===========================================================================
// Flattening records `.keys` for every object and `.length` for every array, so a field
// that appears or disappears is a diff in its own right rather than something that has to
// be inferred from a changed leaf.

function flatten(value, prefix, out) {
  if (Array.isArray(value)) {
    out.set(prefix + '.length', value.length);
    value.forEach((v, i) => flatten(v, prefix + '[' + i + ']', out));
  } else if (value && typeof value === 'object') {
    const keys = Object.keys(value);
    out.set(prefix + '.keys', keys.join(','));
    for (const k of keys) flatten(value[k], (prefix ? prefix + '.' : '') + k, out);
  } else {
    out.set(prefix, value);
  }
  return out;
}

function flattenCommand(cmd) {
  const subject = { exitCode: cmd.exitCode, stdout: cmd.stdout, stderr: cmd.stderr };
  if (cmd.stdoutText !== undefined) subject.stdoutText = cmd.stdoutText;
  return flatten(subject, '', new Map());
}

function show(v) {
  if (v === undefined) return '(absent)';
  return JSON.stringify(v);
}

/** Compare two normalized scenario records; returns {diffs, assertions}. */
function diffScenario(expected, actual) {
  const diffs = [];
  let assertions = 0;

  const expIds = expected.commands.map(c => c.id);
  const actIds = actual.commands.map(c => c.id);
  assertions++;
  if (expIds.join(',') !== actIds.join(',')) {
    diffs.push({ path: 'commands', expected: expIds.join(','), actual: actIds.join(',') });
    return { diffs, assertions };
  }

  for (let i = 0; i < expected.commands.length; i++) {
    const e = flattenCommand(expected.commands[i]);
    const a = flattenCommand(actual.commands[i]);
    const id = expected.commands[i].id;
    const keys = new Set([...e.keys(), ...a.keys()]);
    for (const k of keys) {
      assertions++;
      const ev = e.get(k);
      const av = a.get(k);
      if (JSON.stringify(ev) !== JSON.stringify(av)) {
        diffs.push({ path: id + ' ' + k, expected: ev, actual: av });
      }
    }
  }
  return { diffs, assertions };
}

// ===========================================================================
// S5b  in-repo assertions
// ===========================================================================
// Structure-independent by construction: adding lib/*.mjs changes this repository's file
// count, tracked set and working-tree diff, so anything derived from those would go red on
// the split for reasons that are not behaviour. What is asserted here survives it -- exit
// codes, key sets, the subcommand list, and the fact that diff-hash is a function of the
// tree and nothing else.
//
// The catalog-missing expectations assume this checkout ships no module-catalog.json,
// which is deliberate (the large-repo layer is opt-in). Adding one is a real change of
// state and these three assertions are meant to notice it.

const REPO_DOCTOR_KEYS = 'node,catalogPresent,gitRepo,headCommit,harnessDir,subcommands,'
  + 'waiversDirExists,activeWaivers,attributesDeclared,modulesWithLayer,forbiddenEdges,adaptersPresent';
const REPO_SUBCOMMANDS = 'doctor,diff-hash,selftest,catalog-lint,impact,context-pack,receipt,'
  + 'verify,waiver,attributes,arch-check,fitness,adapters,adr-check,arch-trend,'
  + 'gate,ledger,gate-audit,retention,risk,task,budget,spec-lint,trace,spec,dod,'
  + 'review,review-pack,authorship,invariants,recap,archive,sync-check,rules-audit,skills-lint,'
  + 'claude-md-lint,init,cochange,release';
const REPO_SELFTEST_FLOOR = 106;

/** Run the harness against this checkout rather than a sandbox. */
function runHarnessInRepo(argv) {
  const r = spawnSync(process.execPath, [HARNESS, ...argv], {
    cwd: REPO_ROOT,
    input: '',
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, CLAUDE_PROJECT_DIR: REPO_ROOT, LC_ALL: 'C', TZ: 'UTC' },
  });
  if (r.error) throw new Error('spawn failed for ' + argv.join(' ') + ': ' + r.error.message);
  let stdout = null;
  try { stdout = JSON.parse(String(r.stdout || '').trim()); } catch (_e) { stdout = null; }
  return { code: r.status, stdout, raw: String(r.stdout || '') };
}

/** @returns {{assertions:number,failures:string[]}} */
function checkInRepo() {
  const failures = [];
  let assertions = 0;
  const eq = (label, actual, expected) => {
    assertions++;
    if (JSON.stringify(actual) !== JSON.stringify(expected)) {
      failures.push(label + ': expected ' + show(expected) + ', got ' + show(actual));
    }
  };
  const keysOf = o => (o && typeof o === 'object' ? Object.keys(o).join(',') : null);

  const doctor = runHarnessInRepo(['doctor']);
  eq('doctor exit', doctor.code, 0);
  eq('doctor keys', keysOf(doctor.stdout), REPO_DOCTOR_KEYS);
  eq('doctor subcommands', (doctor.stdout && doctor.stdout.subcommands || []).join(','), REPO_SUBCOMMANDS);

  // A floor rather than an equality: cases get added over time and that must not be a
  // failure, but the split silently dropping a case must be.
  const selftest = runHarnessInRepo(['selftest']);
  eq('selftest exit', selftest.code, 0);
  eq('selftest ok', selftest.stdout && selftest.stdout.ok, true);
  assertions++;
  const testCount = selftest.stdout && selftest.stdout.tests;
  if (!(typeof testCount === 'number' && testCount >= REPO_SELFTEST_FLOOR)) {
    failures.push('selftest tests: expected a number >= ' + REPO_SELFTEST_FLOOR + ', got ' + show(testCount));
  }

  // Two runs, one process, nothing touched in between. Compares the digests to each other
  // and never to a recorded value, so an ordinary commit cannot move it -- but a split
  // that made canonicalDiff order-dependent would fail here immediately.
  const d1 = runHarnessInRepo(['diff-hash']);
  const d2 = runHarnessInRepo(['diff-hash']);
  eq('diff-hash exit', d1.code, 0);
  eq('diff-hash keys', keysOf(d1.stdout), 'diffHash,baseCommit,nonGit');
  eq('diff-hash is deterministic', d1.raw, d2.raw);

  const lint = runHarnessInRepo(['catalog-lint']);
  eq('catalog-lint exit', lint.code, 3);
  eq('catalog-lint keys', keysOf(lint.stdout), 'ok,degraded,error,detail');
  eq('catalog-lint error', lint.stdout && lint.stdout.error, 'catalog-missing');

  const impact = runHarnessInRepo(['impact']);
  eq('impact exit', impact.code, 3);
  eq('impact keys', keysOf(impact.stdout), 'affected,direct,expansionReasons,verification,degraded');

  const verify = runHarnessInRepo(['verify']);
  eq('verify exit', verify.code, 3);
  eq('verify keys', keysOf(verify.stdout), 'state,degraded,error,detail,checks,affected');

  const arch = runHarnessInRepo(['arch-check']);
  eq('arch-check exit', arch.code, 3);
  eq('arch-check keys', keysOf(arch.stdout), 'ok,degraded,error,detail');

  // This checkout is the framework itself and ships no Product-Spec.md -- its specification
  // is CLAUDE.md. Same argument as the three catalog assertions above: adding one is a real
  // change of state, and this is what notices.
  const specLint = runHarnessInRepo(['spec-lint']);
  eq('spec-lint exit', specLint.code, 3);
  eq('spec-lint keys', keysOf(specLint.stdout), 'ok,degraded,error,detail,note');
  eq('spec-lint error', specLint.stdout && specLint.stdout.error, 'spec-missing');

  return { assertions, failures };
}

// ===========================================================================
// S6  modes
// ===========================================================================

function goldenPath(name) {
  return path.join(GOLDEN_DIR, name + '.json');
}

/** Baseline names present on disk, so a scenario can neither vanish nor appear unnoticed. */
function baselineNames() {
  let names;
  try { names = fs.readdirSync(GOLDEN_DIR); } catch (_e) { return []; }
  return names.filter(n => n.endsWith('.json')).map(n => n.slice(0, -'.json'.length)).sort();
}

function writeJson(file, obj) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(obj, null, 2) + '\n', 'utf8');
}

function collect(scenario, pathsOnly = false) {
  const { record, root } = runScenario(scenario);
  return normalizeRecord(record, root, pathsOnly);
}

function cmdRecord() {
  let commandCount = 0;
  for (const scenario of SCENARIOS) {
    const normalized = collect(scenario);
    writeJson(goldenPath(scenario.name), normalized);
    commandCount += normalized.commands.length;
    const codes = normalized.commands.map(c => c.exitCode).join(',');
    console.log('  recorded ' + scenario.name + ' (' + normalized.commands.length + ' commands, rc: ' + codes + ')');
  }
  let assertions = 0;
  for (const scenario of SCENARIOS) {
    const rec = JSON.parse(fs.readFileSync(goldenPath(scenario.name), 'utf8'));
    for (const c of rec.commands) assertions += flattenCommand(c).size + 1;
  }
  console.log('');
  console.log('RECORDED: ' + SCENARIOS.length + ' scenarios, ' + commandCount
    + ' command runs, ' + assertions + ' assertions -> ' + path.relative(REPO_ROOT, GOLDEN_DIR));
  return 0;
}

// A sample of the differing field paths, not all of them: a mutation that moves the whole
// matrix produces thousands, and --mutate's stdout is one line. The full count travels
// beside it as diffCount, so the sample can never read as the whole story.
const DIFF_SAMPLE = 5;

function pushSample(list, entry) {
  if (list.length < DIFF_SAMPLE) list.push(entry);
}

/**
 * Replay the matrix and diff it against the recorded baseline. This is what --check is,
 * and what --mutate runs once per injected mutation.
 *
 * Two knobs, both for --mutate and neither reachable from --check. `scenarioFilter` replays
 * a single scenario and drops the in-repo subject, because one mutation times nine scenarios
 * plus in-repo is minutes of wall clock per manifest entry. `quiet` routes every line away
 * from the console: --mutate's own machine channel is one line of JSON on stdout, and the
 * per-scenario PASS/FAIL chatter of an inner run would sit on top of it.
 *
 * @returns {{rc:number,assertions:number,failedSubjects:string[],diffPaths:string[],
 *            diffCount:number,fatal:(string|null)}}
 */
function checkMatrix({ scenarioFilter = null, quiet = false } = {}) {
  const say = quiet ? () => {} : (line => console.log(line));
  const sayErr = quiet ? () => {} : (line => console.error(line));
  const out = { rc: 0, assertions: 0, failedSubjects: [], diffPaths: [], diffCount: 0, fatal: null };

  const scenarios = scenarioFilter === null
    ? SCENARIOS
    : SCENARIOS.filter(s => s.name === scenarioFilter);
  if (scenarios.length === 0) {
    out.fatal = 'unknown scenario: ' + scenarioFilter
      + ' (known: ' + SCENARIOS.map(s => s.name).join(', ') + ')';
    sayErr('FAIL: ' + out.fatal);
    out.rc = 2;
    return out;
  }

  // Both directions, because only one of them was ever checked. Commenting a scenario out
  // of SCENARIOS used to leave its baseline sitting on disk and print GOLDEN OK for the
  // rest, exit 0: a whole slice of the matrix could be switched off and the machine
  // channel still read green. Only meaningful for a full run -- a filtered one is a
  // deliberate slice, and asserting the set there would fail by construction.
  if (scenarioFilter === null) {
    const wanted = SCENARIOS.map(s => s.name).sort();
    const onDisk = baselineNames();
    if (wanted.join(',') !== onDisk.join(',')) {
      const missing = wanted.filter(n => !onDisk.includes(n));
      const orphan = onDisk.filter(n => !wanted.includes(n));
      sayErr('FAIL: scenario set and baseline set disagree.');
      if (missing.length) sayErr('      no baseline for: ' + missing.join(', ') + '  (record it)');
      if (orphan.length) sayErr('      baseline with no scenario: ' + orphan.join(', ')
        + '  (a scenario was removed or renamed -- restore it, or delete the file on purpose)');
      out.fatal = 'scenario set and baseline set disagree'
        + (missing.length ? '; no baseline for: ' + missing.join(', ') : '')
        + (orphan.length ? '; baseline with no scenario: ' + orphan.join(', ') : '');
      out.rc = 1;
      return out;
    }
  }

  let assertions = 0;
  let failed = 0;
  for (const scenario of scenarios) {
    let expected;
    try {
      expected = JSON.parse(fs.readFileSync(goldenPath(scenario.name), 'utf8'));
    } catch (e) {
      // A truncated or hand-edited baseline used to come out as a raw parse stack, which
      // reads like the tool is broken rather than the file.
      sayErr('FAIL: baseline ' + scenario.name + ' is corrupt: ' + String(e && e.message || e));
      sayErr('      re-record it, or restore it from git.');
      out.fatal = 'baseline ' + scenario.name + ' is corrupt: ' + String(e && e.message || e);
      out.assertions = assertions;
      out.rc = 1;
      return out;
    }
    const actual = collect(scenario);
    const { diffs, assertions: n } = diffScenario(expected, actual);
    assertions += n;
    if (diffs.length === 0) {
      say('  [PASS] ' + scenario.name + ' (' + n + ' assertions)');
      continue;
    }
    failed++;
    out.failedSubjects.push(scenario.name);
    out.diffCount += diffs.length;
    for (const d of diffs) pushSample(out.diffPaths, scenario.name + ' ' + d.path);
    say('  [FAIL] ' + scenario.name + ' (' + diffs.length + ' of ' + n + ' assertions differ)');
    for (const d of diffs.slice(0, 25)) {
      say('    --- ' + d.path);
      say('    - expected: ' + show(d.expected));
      say('    + actual:   ' + show(d.actual));
    }
    if (diffs.length > 25) say('    ... ' + (diffs.length - 25) + ' more differences suppressed');
  }

  if (scenarioFilter === null) {
    const repo = checkInRepo();
    assertions += repo.assertions;
    if (repo.failures.length === 0) {
      say('  [PASS] in-repo (' + repo.assertions + ' assertions)');
    } else {
      failed++;
      out.failedSubjects.push('in-repo');
      out.diffCount += repo.failures.length;
      for (const f of repo.failures) pushSample(out.diffPaths, 'in-repo ' + f);
      say('  [FAIL] in-repo (' + repo.failures.length + ' of ' + repo.assertions + ' assertions differ)');
      for (const f of repo.failures) say('    --- ' + f);
    }
  }

  const subjects = scenarios.length + (scenarioFilter === null ? 1 : 0);
  const label = scenarioFilter === null
    ? SCENARIOS.length + ' scenarios + in-repo'
    : 'scenario ' + scenarioFilter + ' only';
  out.assertions = assertions;
  say('');
  if (failed === 0) {
    say('GOLDEN OK: ' + label + ', ' + assertions + ' assertions match the recorded baseline.');
    out.rc = 0;
    return out;
  }
  say('GOLDEN FAILED: ' + failed + ' of ' + subjects
    + ' subjects differ from the recorded baseline.');
  say('If the change is intended, re-record and review the baseline diff in git.');
  out.rc = 1;
  return out;
}

function cmdCheck() {
  return checkMatrix().rc;
}

/**
 * Developer mode. Runs the matrix three times with only path substitution applied and
 * reports every field that moved on its own. Anything it lists must be covered by the
 * normalization list at the top of this file; anything it does not list is compared
 * verbatim. This is how that list was derived, and how it should be re-derived if a
 * subcommand starts emitting something new.
 */
function cmdProbe() {
  const runs = [1, 2, 3];
  let unstable = 0;
  for (const scenario of SCENARIOS) {
    const maps = runs.map(() => {
      const rec = collect(scenario, true);
      const m = new Map();
      for (const c of rec.commands) for (const [k, v] of flattenCommand(c)) m.set(c.id + ' ' + k, v);
      return m;
    });
    const keys = new Set(maps.flatMap(m => [...m.keys()]));
    const moved = [];
    for (const k of keys) {
      const vals = maps.map(m => JSON.stringify(m.get(k)));
      if (vals[0] !== vals[1] || vals[1] !== vals[2]) moved.push({ k, vals });
    }
    if (moved.length === 0) {
      console.log('  ' + scenario.name + ': stable across 3 raw runs');
      continue;
    }
    unstable += moved.length;
    console.log('  ' + scenario.name + ': ' + moved.length + ' field(s) move on their own');
    for (const m of moved) console.log('    ' + m.k + '  ' + m.vals.join('  |  '));
  }
  console.log('');
  console.log('PROBE: ' + unstable + ' unstable field(s) across ' + SCENARIOS.length + ' scenarios.');
  return 0;
}

// ===========================================================================
// S6b  mutation ruler
// ===========================================================================
// Who measures the ruler. --check asserts twenty thousand fields, and the only evidence
// those assertions can catch anything was an experiment run by hand on the day the baseline
// was first recorded: three mutations typed into the engine, three reds, then the mutations
// were undone. That is a belief with a shelf life -- the engine has been split into
// lib/*.mjs and grown twenty subcommands since, and nobody has re-run it. --mutate turns
// the experiment into a command, so "the baseline can see a real change" becomes something
// this repository re-proves on a schedule instead of something it remembers.
//
// Each entry in .claude/tests/golden/MUTANTS.json names one behaviour change in
// .claude/harness/lib/*.mjs -- an exit code flipped, a field renamed, an aggregation
// inverted, a path stripped of a segment. The tool injects one, replays the matrix, and
// reads the verdict off the diff: a mutation the baseline notices is `killed`, one it
// sleeps through is `survived`. A survivor is a hole in the ruler rather than a bug in the
// engine, and it is the whole reason to run this: it names, precisely, a behaviour change
// that --check would wave through.
//
// killRate is only honest if the manifest keeps naming changes that MATTER. A manifest of
// comment edits would score a perfect zero-kill run and prove nothing, and one of comment
// edits inverted (every entry trivially fatal) would score 100% and prove just as little.
// Every entry carries a `why` for that reason: it has to state which contract the entry
// is testing the ruler against, and an entry whose `why` cannot be written is an entry
// that should not be in the list.
//
// Three safety properties, because unlike every other mode this one writes to the checkout
// on purpose:
//   - The target file must have no uncommitted changes. Mutating a file somebody is midway
//     through editing would push their work through a replace-and-restore cycle, and the
//     restore is only ever byte-exact against what this process read a moment earlier.
//     A dirty target refuses the whole run with rc 2 and names the file. Refusing is a
//     guard for that work, never a licence to clean it up: nothing is written, discarded
//     or checked out on the refusal path.
//   - Restore is immediate and verified. The original bytes go back the instant the replay
//     returns, and the sha256 of what is on disk afterwards is compared against the sha256
//     of what was read before. A restore that silently failed would leave a mutated engine
//     in the tree, which is the one outcome worse than a survivor -- every later command in
//     the session would be running the mutant.
//   - Restore also runs from the exit handler and from the SIGINT/SIGTERM handlers below.
//     A replay is minutes of wall clock; ^C and CI timeouts land in the middle of one, and
//     an interrupted run that skipped the restore would leave the mutant on disk and say
//     nothing about it. (Deliberately not spelled as a call here: test-golden-mutate.sh
//     locates the first exit-hook registration in this file and asserts the code right
//     after it really restores something, and a prose mention would satisfy that scan
//     without any handler existing at all.)
//
// `find` must match exactly once. Zero matches means the manifest has rotted against the
// source, and the entry is reported not-applicable rather than skipped quietly -- a manifest
// entry that no longer applies is measuring nothing, and silence there would let the kill
// rate slowly become a rate over fewer and fewer live entries. More than one match means the
// injection site is ambiguous and the result would not describe what it claims to. Either
// case exits 2, which is deliberately not the exit code a survivor produces: "the manifest
// is broken" and "the ruler is blind here" are different problems with different owners.

/** Repo-relative posix path, the form the manifest and every message use. */
function relToRepo(abs) {
  const rel = path.relative(REPO_ROOT, abs).split(path.sep).join('/');
  // A manifest handed in from outside the checkout prints as a stack of ../.. that names
  // nothing useful; show it as given instead. Mutant targets are in-repo by construction
  // (loadMutants rejects anything outside lib/), so they always take the relative branch.
  return (rel === '' || rel.startsWith('../')) ? abs : rel;
}

function sha256Hex(text) {
  return createHash('sha256').update(text, 'utf8').digest('hex');
}

// Set only while a mutation is on disk, and cleared the moment it comes back off. The exit
// handlers below are the reason it lives at module scope: they have to be able to see an
// injection that a throw, a ^C or a CI timeout left behind.
let activeInjection = null;

function restoreActiveInjection() {
  if (!activeInjection) return null;
  const { file, original } = activeInjection;
  activeInjection = null;
  try {
    fs.writeFileSync(file, original, 'utf8');
  } catch (e) {
    // Nothing left to try. Say which file and what it should contain, loudly.
    process.stderr.write('FATAL: could not restore ' + file + ': ' + String(e && e.message || e) + '\n');
    process.stderr.write('       recover it with: git checkout -- ' + relToRepo(file) + '\n');
    return null;
  }
  return file;
}

let restoreHandlersInstalled = false;
function installRestoreHandlers() {
  if (restoreHandlersInstalled) return;
  restoreHandlersInstalled = true;
  // Synchronous by necessity: an exit handler cannot await, and writeFileSync is the only
  // way the original bytes get back before the process is gone.
  process.on('exit', () => {
    const file = restoreActiveInjection();
    if (file) process.stderr.write('  [restored] ' + relToRepo(file) + ' (run ended mid-mutation)\n');
  });
  for (const sig of ['SIGINT', 'SIGTERM']) {
    process.on(sig, () => {
      const file = restoreActiveInjection();
      if (file) process.stderr.write('  [restored] ' + relToRepo(file) + ' (' + sig + ')\n');
      process.exit(130);
    });
  }
}

/** @returns {{list:object[]}|{error:string}} */
function loadMutants(file) {
  let raw;
  try {
    raw = fs.readFileSync(file, 'utf8');
  } catch (e) {
    return { error: 'cannot read ' + relToRepo(file) + ': ' + String(e && e.code || e) };
  }
  let list;
  try {
    list = JSON.parse(raw);
  } catch (e) {
    return { error: relToRepo(file) + ' is not valid JSON: ' + String(e && e.message || e) };
  }
  if (!Array.isArray(list)) return { error: relToRepo(file) + ' must hold an array of mutants' };

  // Validated up front rather than per entry mid-run: half a manifest applied and the
  // other half rejected is a kill rate computed over a set nobody chose.
  const required = ['name', 'file', 'find', 'replace', 'why'];
  const seen = new Set();
  for (let i = 0; i < list.length; i++) {
    const m = list[i];
    const label = (m && typeof m.name === 'string' && m.name.trim() !== '') ? m.name : '#' + i;
    for (const k of required) {
      if (!m || typeof m[k] !== 'string' || m[k].trim() === '') {
        return { error: 'mutant ' + label + ' has no non-empty "' + k + '"' };
      }
    }
    if (seen.has(m.name)) return { error: 'duplicate mutant name: ' + m.name };
    seen.add(m.name);
    const posix = m.file.split(path.sep).join('/');
    if (!posix.startsWith(MUTANT_SCOPE)) {
      // The scope is the engine, and only the engine. A manifest that could name any path
      // in the tree would be a rewrite-any-file primitive wearing a test's clothes.
      return { error: 'mutant ' + label + ' targets ' + m.file + ' -- only ' + MUTANT_SCOPE + ' is in scope' };
    }
  }
  return { list };
}

/** Every selected target that git reports as changed, staged or untracked. */
function dirtyTargets(relFiles) {
  const dirty = [];
  for (const rel of relFiles) {
    const r = spawnSync('git', ['status', '--porcelain', '--', rel], { cwd: REPO_ROOT, encoding: 'utf8' });
    if (r.error || r.status !== 0) {
      // Cannot prove it is clean, so treat it as dirty. The failure mode of guessing wrong
      // in the other direction is overwriting somebody's work.
      dirty.push({ file: rel, reason: 'git status failed: ' + String((r.error && r.error.message) || r.stderr || r.status).trim() });
      continue;
    }
    const first = String(r.stdout || '').split('\n').map(l => l.trim()).filter(l => l !== '')[0];
    if (first) dirty.push({ file: rel, reason: first });
  }
  return dirty;
}

/** One line of JSON on stdout, always, whatever happened. */
function emitMutation(body) {
  process.stdout.write(JSON.stringify(body) + '\n');
}

function mutationSummary(extra) {
  return Object.assign({
    ok: false,
    mutants: [],
    killed: 0,
    survived: 0,
    notApplicable: 0,
    killRate: '0/0',
  }, extra || {});
}

function cmdMutate(opts) {
  const manifestPath = opts.mutants === null ? MUTANTS_FILE : path.resolve(opts.mutants);
  const bail = (message, extra) => {
    console.error('FAIL: ' + message);
    emitMutation(mutationSummary(Object.assign({ error: message }, extra || {})));
    return 2;
  };

  const loaded = loadMutants(manifestPath);
  if (loaded.error) return bail(loaded.error);

  let list = loaded.list;
  if (opts.only !== null) {
    list = list.filter(m => m.name === opts.only);
    if (list.length === 0) {
      return bail('no mutant named ' + opts.only + ' in ' + relToRepo(manifestPath)
        + ' (have: ' + loaded.list.map(m => m.name).join(', ') + ')');
    }
  }
  if (list.length === 0) return bail(relToRepo(manifestPath) + ' lists no mutants -- nothing was measured');
  if (opts.scenario !== null && !SCENARIOS.some(sc => sc.name === opts.scenario)) {
    return bail('unknown scenario: ' + opts.scenario + ' (known: ' + SCENARIOS.map(sc => sc.name).join(', ') + ')');
  }

  // Every target, before a single byte is written anywhere. Refusing halfway through would
  // already have put one file through a cycle.
  const targets = [...new Set(list.map(m => m.file.split(path.sep).join('/')))];
  const dirty = dirtyTargets(targets);
  if (dirty.length) {
    for (const d of dirty) console.error('  [refused] ' + d.file + ' has uncommitted changes: ' + d.reason);
    console.error('REFUSED: --mutate replaces and restores these files in place, and the restore is only');
    console.error('         byte-exact against what it read. Commit or stash the changes above first.');
    console.error('         Nothing was written: the work in those files is untouched.');
    emitMutation(mutationSummary({ refused: dirty }));
    return 2;
  }

  installRestoreHandlers();
  console.error('  manifest ' + relToRepo(manifestPath) + ': ' + list.length + ' mutant(s)'
    + (opts.scenario === null ? ', full matrix' : ', scenario ' + opts.scenario + ' only'));

  const results = [];
  let killed = 0;
  let survived = 0;
  let notApplicable = 0;

  for (const m of list) {
    const abs = path.resolve(REPO_ROOT, m.file);
    const rel = relToRepo(abs);
    let original;
    try {
      original = fs.readFileSync(abs, 'utf8');
    } catch (e) {
      notApplicable++;
      results.push({ name: m.name, file: rel, status: 'not-applicable', scenarios: [],
        detail: 'cannot read: ' + String(e && e.code || e) });
      console.error('  [not-applicable] ' + m.name + '  ' + rel + '  cannot read the target file');
      continue;
    }

    const parts = original.split(m.find);
    const hits = parts.length - 1;
    if (hits !== 1) {
      notApplicable++;
      results.push({ name: m.name, file: rel, status: 'not-applicable', scenarios: [],
        detail: 'find occurs ' + hits + 'x, expected exactly 1' });
      console.error('  [not-applicable] ' + m.name + '  ' + rel + '  find occurs ' + hits
        + 'x, expected exactly 1 -- the manifest has rotted against the source, this entry measured nothing');
      continue;
    }

    const beforeSha = sha256Hex(original);
    activeInjection = { file: abs, original };
    fs.writeFileSync(abs, parts.join(m.replace), 'utf8');

    let outcome;
    try {
      outcome = checkMatrix({ scenarioFilter: opts.scenario, quiet: true });
    } catch (e) {
      // A mutation that makes the replay itself blow up is still a mutation the baseline
      // did not sleep through, which is the question being asked -- mutation testing counts
      // an errored run as killed. The message is carried so it never reads as a real diff.
      outcome = { rc: 1, assertions: 0, failedSubjects: ['<runner-error>'], diffCount: 1,
        diffPaths: ['runner threw: ' + String(e && e.message || e)], fatal: null };
    }

    restoreActiveInjection();
    let afterSha = null;
    try { afterSha = sha256Hex(fs.readFileSync(abs, 'utf8')); } catch (_e) { afterSha = null; }
    if (afterSha !== beforeSha) {
      console.error('FATAL: ' + rel + ' did not come back byte for byte after ' + m.name + '.');
      console.error('       expected sha256 ' + beforeSha + ', found ' + String(afterSha));
      console.error('       restore it with: git checkout -- ' + rel);
      emitMutation(mutationSummary({ mutants: results, killed, survived, notApplicable,
        killRate: killed + '/' + (killed + survived), error: 'restore of ' + rel + ' failed' }));
      return 2;
    }

    if (outcome.fatal) {
      console.error('FAIL: the baseline itself is unusable, so nothing can be measured: ' + outcome.fatal);
      emitMutation(mutationSummary({ mutants: results, killed, survived, notApplicable,
        killRate: killed + '/' + (killed + survived), error: outcome.fatal }));
      return 2;
    }

    if (outcome.failedSubjects.length > 0) {
      killed++;
      results.push({ name: m.name, file: rel, status: 'killed',
        scenarios: outcome.failedSubjects, diffCount: outcome.diffCount, diffs: outcome.diffPaths });
      console.error('  [killed] ' + m.name + '  ' + rel + '  seen by ' + outcome.failedSubjects.join(', ')
        + ' (' + outcome.diffCount + ' assertion(s) differ)');
    } else {
      survived++;
      results.push({ name: m.name, file: rel, status: 'survived', scenarios: [] });
      console.error('  [survived] ' + m.name + '  ' + rel + '  the baseline did not notice');
      console.error('             what it should have caught: ' + m.why);
    }
  }

  const applicable = killed + survived;
  const killRate = killed + '/' + applicable;
  const ok = survived === 0 && notApplicable === 0 && applicable > 0;
  emitMutation({ ok, mutants: results, killed, survived, notApplicable, killRate });

  console.error('');
  console.error('MUTATION ' + (ok ? 'OK' : 'INCOMPLETE') + ': killRate ' + killRate
    + (survived ? ', ' + survived + ' survived (the baseline is blind there)' : '')
    + (notApplicable ? ', ' + notApplicable + ' not applicable (the manifest has rotted)' : '') + '.');
  if (notApplicable > 0) return 2;
  if (survived > 0) return 1;
  return 0;
}

// ===========================================================================
// S7  entry point
// ===========================================================================

function preflight() {
  // Not executed != passed. Saying so out loud was never the problem; the exit code was,
  // because 0 is what a caller reads as "verified". --strict returns 3 instead, matching
  // the harness's own convention that 3 means degraded rather than green, and leaving the
  // decision to fail or to report a skip with the caller instead of with this file.
  if (process.platform === 'win32') {
    return 'SKIPPED: win32 -- the sandbox fixture tree and PATH pinning are POSIX-only; '
      + 'the recorded baseline is POSIX-only too, so comparing on Windows would be meaningless.';
  }
  const git = spawnSync('sh', ['-c', 'command -v git'], { encoding: 'utf8' });
  if (git.status !== 0) {
    return 'SKIPPED: no git on PATH -- every scenario needs a throwaway repository.';
  }
  return null;
}

const MODES = ['--record', '--check', '--probe', '--mutate'];
const VALUE_FLAGS = { '--mutants': 'mutants', '--only': 'only', '--scenario': 'scenario' };
const USAGE = 'usage: node .claude/tests/harness-golden.mjs '
  + MODES.join('|') + ' [--strict]\n'
  + '       --mutate also takes [--mutants <file>] [--only <name>] [--scenario <name>]';

/**
 * Hand-rolled, because a four-flag grammar is not worth a dependency in a file whose whole
 * point is that it has none. Two decisions worth stating:
 *   - The three value flags are rejected outside --mutate. `--check --scenario x` would
 *     exit 0 having replayed a ninth of the matrix, and an exit code a caller reads as
 *     "the baseline holds" must never come out of a partial run.
 *   - An unrecognized trailing argument is an error rather than something to ignore. The
 *     old parser took the first non---strict token as the mode and dropped the rest, so a
 *     typo'd flag ran the full check and reported success for a run nobody asked for.
 */
function parseArgs(argv) {
  const out = { mode: null, strict: false, mutants: null, only: null, scenario: null, error: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--strict') { out.strict = true; continue; }
    if (Object.prototype.hasOwnProperty.call(VALUE_FLAGS, a)) {
      const v = argv[i + 1];
      if (v === undefined || v.startsWith('--')) { out.error = a + ' needs a value'; return out; }
      out[VALUE_FLAGS[a]] = v;
      i++;
      continue;
    }
    if (out.mode === null) { out.mode = a; continue; }
    out.error = 'unexpected argument: ' + a;
    return out;
  }
  if (!MODES.includes(out.mode)) {
    out.error = out.mode === null ? 'no mode given' : 'unknown mode: ' + out.mode;
    return out;
  }
  if (out.mode !== '--mutate') {
    for (const flag of Object.keys(VALUE_FLAGS)) {
      if (out[VALUE_FLAGS[flag]] !== null) { out.error = flag + ' applies to --mutate only'; return out; }
    }
  }
  return out;
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.error) {
    console.error('FAIL: ' + opts.error);
    console.error(USAGE);
    return 2;
  }
  const mode = opts.mode;
  if (!fs.existsSync(HARNESS)) {
    console.error('FAIL: harness.mjs not found at ' + HARNESS);
    return 1;
  }
  const skip = preflight();
  if (skip) {
    // Every other mode reports a skip in prose on stdout. --mutate cannot: its stdout is a
    // machine channel and a caller parsing it should not have to special-case "not today".
    if (mode === '--mutate') {
      console.error(skip);
      emitMutation(mutationSummary({ skipped: skip }));
    } else {
      console.log(skip);
    }
    return opts.strict ? 3 : 0;
  }
  if (mode === '--mutate') {
    // Same reason the skip above moved: stdout belongs to the single JSON line.
    console.error('===== harness-golden --mutate =====');
    sweepStaleSandboxes();
    return cmdMutate(opts);
  }
  console.log('===== harness-golden ' + mode + ' =====');
  sweepStaleSandboxes();
  if (mode === '--record') return cmdRecord();
  if (mode === '--probe') return cmdProbe();
  return cmdCheck();
}

process.exit(main());
