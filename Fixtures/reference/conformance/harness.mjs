// The conformance harness. It replays every case through the pinned reference emulator and writes the
// cases the Swift tests replay through ThrushCore. Given a built ThrushConformance, it also lists the
// cases Thrush doesn't match, as known gaps and reference defects.
//
//   bun Fixtures/reference/conformance/harness.mjs [--thrush .build/release/ThrushConformance] [--check]
//
// `--check` regenerates everything in memory and fails if a checked-in file would change.
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { parseArgs } from 'node:util';
import * as reference from './xterm.mjs';
import { functionCases } from './functions.mjs';
import { programCases } from './programs.mjs';
import { streamCases } from './streams.mjs';
import { Pool, pack } from './state.mjs';
import { Thrush, encodeCase } from './thrush.mjs';

const { values: options } = parseArgs({
  options: { thrush: { type: 'string' }, check: { type: 'boolean' } },
});

const here = import.meta.dir;
const root = resolve(here, '../../..');
const tests = join(root, 'Tests/ThrushConformanceTests');
const files = {
  cases: corpus => join(tests, 'Cases', `${corpus}.json`),
  gaps: join(tests, 'KnownGaps.json'),
  defects: join(tests, 'ReferenceDefects.json'),
};

const corpora = { functions: functionCases, programs: programCases(resolve(here, '..')), streams: streamCases };
for (const [corpus, cases] of Object.entries(corpora)) {
  const names = cases.map(testCase => testCase.name);
  assert.equal(new Set(names).size, names.length, `${corpus} case names must be unique`);
}

// 1. The reference's checkpoints, and which of its handlers each case reached.
const started = performance.now();
const runs = Object.fromEntries(Object.entries(corpora).map(([corpus, cases]) =>
  [corpus, cases.map(testCase => ({ testCase, ...reference.run(testCase, { observe: true }) }))]));
log(`Reference replayed ${count(runs)} cases in ${seconds(started)}`);

// 2. Coverage: every handler the reference registers must be reached by some function case.
const reached = new Set(runs.functions.flatMap(run => [...run.identities]));
const uncovered = reference.registered().filter(identity => !reached.has(identity));
assert.deepEqual(uncovered, [], 'Every registered control function needs a function case');

// A case where the reference throws is a reference defect, and needs a reason why Thrush's result is right.
const defects = existsSync(files.defects) ? JSON.parse(readFileSync(files.defects, 'utf8')) : {};
const threw = Object.values(runs).flat().filter(run => run.checkpoints.some(checkpoint => checkpoint.error));
assert.deepEqual(threw.map(run => run.testCase.name).filter(name => !defects[name]?.reason), [],
  'The reference threw in these cases. List each in ReferenceDefects.json with a reason');

const generated = new Map();
for (const [corpus, corpusRuns] of Object.entries(runs)) generated.set(files.cases(corpus), caseFile(corpusRuns));

// 3. Thrush's side: known gaps and reference defects.
if (options.thrush) {
  const thrush = new Thrush(resolve(options.thrush));
  const results = {};
  for (const [corpus, corpusRuns] of Object.entries(runs)) {
    results[corpus] = [];
    for (const run of corpusRuns) {
      const result = await thrush.run(run.testCase, run.checkpoints);
      results[corpus].push({ ...run, ...result, failing: Boolean(result.crashed || result.differences.length) });
    }
  }
  log(`Thrush replayed the same cases in ${seconds(started)}`);

  // A gap's reason is written by hand, and marks it as a choice rather than work still to do.
  const listedGaps = existsSync(files.gaps) ? JSON.parse(readFileSync(files.gaps, 'utf8')) : {};
  const gaps = {};
  for (const corpusResults of Object.values(results)) {
    for (const result of corpusResults) {
      const { name, subject } = result.testCase;
      // The reason is written by hand, and the differences are regenerated so a change on either side shows.
      if (defects[name]) {
        defects[name] = { reason: defects[name].reason, differences: result.differences };
        continue;
      }
      if (!result.failing) continue;
      const reason = listedGaps[subject]?.reason;
      (gaps[subject] ??= reason ? { reason, cases: [] } : { cases: [] }).cases.push(name);
    }
  }
  for (const [name, defect] of Object.entries(defects)) {
    assert(Object.values(corpora).some(cases => cases.some(testCase => testCase.name === name)), `Defect ${name} names no case`);
    assert(defect.differences.length, `Defect ${name} matches the reference`);
  }
  generated.set(files.gaps, json(sorted(gaps), 1));
  generated.set(files.defects, json(sorted(defects), 2));

  thrush.close();
}

// 4. Write, or check that nothing would change.
let stale = [];
for (const [path, contents] of generated) {
  const current = existsSync(path) ? readFileSync(path, 'utf8') : undefined;
  if (current === contents) continue;
  if (options.check) stale.push(path);
  else { mkdirSync(dirname(path), { recursive: true }); writeFileSync(path, contents); }
}
if (stale.length) {
  console.error(`Regenerating would change:\n${stale.map(path => `  ${path.slice(root.length + 1)}`).join('\n')}`);
  process.exit(1);
}
log(options.check ? 'Every generated file is current' : `Wrote ${generated.size} files`);
// The reference's browser theme service keeps a handle open, so leave explicitly.
process.exit(0);

function caseFile(corpusRuns) {
  const pools = { cells: new Pool(), lines: new Pool() };
  const cases = corpusRuns.map(({ testCase, checkpoints }) =>
    JSON.stringify(encodeCase(testCase, checkpoints.map(checkpoint => pack(checkpoint, pools)))));
  return `{\n"cells": [\n${pools.cells.values.map(cell => JSON.stringify(cell)).join(',\n')}\n],\n`
    + `"lines": [\n${pools.lines.values.map(line => JSON.stringify(line)).join(',\n')}\n],\n`
    + `"cases": [\n${cases.join(',\n')}\n]\n}\n`;
}

function sorted(object) { return Object.fromEntries(Object.entries(object).sort(([a], [b]) => a.localeCompare(b))); }
function json(value, depth) { return `${JSON.stringify(value, null, depth === undefined ? 1 : depth)}\n`; }
function count(runs) { return Object.values(runs).reduce((sum, corpus) => sum + corpus.length, 0); }
function seconds(start) { return `${((performance.now() - start) / 1000).toFixed(1)} s`; }
function log(message) { console.error(message); }
