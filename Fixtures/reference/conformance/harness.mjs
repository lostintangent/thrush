// The conformance harness. It replays every case through the pinned reference emulator, writes the
// cases the Swift tests replay through ThrushCore, and, given a built ThrushConformance, ranks every
// way Thrush still differs by how often real programs emit the functions involved.
//
//   bun Fixtures/reference/conformance/harness.mjs [--thrush .build/release/ThrushConformance]
//     [--report <file.md>] [--check]
//
// `--check` regenerates everything in memory and fails if a checked-in file would change.
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { execFileSync } from 'node:child_process';
import { parseArgs } from 'node:util';
import * as reference from './xterm.mjs';
import { functionCases } from './functions.mjs';
import { programCases } from './programs.mjs';
import { streamCases } from './streams.mjs';
import { Pool, pack } from './state.mjs';
import { Thrush, encodeCase } from './thrush.mjs';
import { Shrinker, kindOf } from './shrink.mjs';

const { values: options } = parseArgs({
  options: { thrush: { type: 'string' }, report: { type: 'string' }, check: { type: 'boolean' } },
});

const here = import.meta.dir;
const root = resolve(here, '../../..');
const tests = join(root, 'Tests/ThrushConformanceTests');
const files = {
  cases: corpus => join(tests, 'Cases', `${corpus}.json`),
  gaps: join(tests, 'KnownGaps.json'),
  defects: join(tests, 'ReferenceDefects.json'),
  reference: join(here, 'reference.json'),
};
// Handlers the reference registers that the function corpus deliberately leaves out, with why.
const unobservable = new Map([]);

const corpora = { functions: functionCases, programs: programCases(resolve(here, '..')), streams: streamCases };
for (const [corpus, cases] of Object.entries(corpora)) {
  const names = cases.map(testCase => testCase.name);
  assert.equal(new Set(names).size, names.length, `${corpus} case names must be unique`);
}

// 1. The reference's checkpoints, and which functions each write dispatched.
const started = performance.now();
const runs = Object.fromEntries(Object.entries(corpora).map(([corpus, cases]) =>
  [corpus, cases.map(testCase => ({ testCase, ...reference.run(testCase, { observe: true }) }))]));
log(`Reference replayed ${count(runs)} cases in ${seconds(started)}`);

// 2. Coverage: every handler the reference registers must be reached by some function case.
const reached = new Set(runs.functions.flatMap(run => [...run.identities]));
const uncovered = reference.registered().filter(identity => !reached.has(identity) && !unobservable.has(identity));
assert.deepEqual(uncovered, [], 'Every registered control function needs a function case');

// A case where the reference throws is a reference defect, and needs a reason why Thrush's result is right.
const defects = existsSync(files.defects) ? JSON.parse(readFileSync(files.defects, 'utf8')) : {};
const threw = Object.values(runs).flat().filter(run => run.checkpoints.some(checkpoint => checkpoint.error));
assert.deepEqual(threw.map(run => run.testCase.name).filter(name => !defects[name]?.reason), [],
  'The reference threw in these cases. List each in ReferenceDefects.json with a reason');

// 3. What real programs emit, by function name.
const emitted = Object.fromEntries(runs.programs.map(({ testCase, functions }) => {
  const counts = {};
  for (const name of functions.flat()) counts[name] = (counts[name] ?? 0) + 1;
  const resizes = testCase.steps.filter(step => step.resize).length;
  if (resizes) counts.resize = resizes;
  return [testCase.program, sorted(counts)];
}));

const generated = new Map();
for (const [corpus, corpusRuns] of Object.entries(runs)) generated.set(files.cases(corpus), caseFile(corpusRuns));
generated.set(files.reference, json({ reference: reference.description, emitted }));

// 4. Thrush's side: known gaps, reference defects and the ranked report.
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

  if (options.report) {
    const shrinker = new Shrinker(reference, thrush);
    const report = await gapReport(results, emitted, defects, gaps, shrinker);
    mkdirSync(dirname(resolve(options.report)), { recursive: true });
    writeFileSync(resolve(options.report), report);
    log(`Wrote the gap report to ${options.report} in ${seconds(started)}`);
  }
  thrush.close();
}

// 5. Write, or check that nothing would change.
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

async function gapReport(results, emitted, defects, gaps, shrinker) {
  const programs = Object.keys(emitted);
  const users = names => programs.filter(program => names.every(name => emitted[program][name]));
  const total = name => programs.reduce((sum, program) => sum + (emitted[program][name] ?? 0), 0);
  const counts = (list, { named = true } = {}) => list.length === programs.length ? `all ${programs.length}`
    : !list.length ? 'none' : named && list.length <= 6 ? `${list.length}: ${list.join(', ')}` : `${list.length} of ${programs.length}`;
  // A string terminator only ends the string function before it.
  const named = (testCase, steps) => shrinker.functions(testCase, steps).filter((name, _, all) => name !== 'ST' || all.length === 1);

  // 1. Each failing function case shrinks to the functions that still disagree. The cause is the case's
  // own function when it survives, and otherwise whatever its setup used that Thrush gets wrong.
  // Deliberate gaps aren't work to do, so they're listed apart from the ranking.
  const deliberate = Object.entries(sorted(gaps)).filter(([, gap]) => gap.reason);
  const causes = new Map();
  for (const result of results.functions.filter(result => result.failing && !defects[result.testCase.name]
    && !gaps[result.testCase.subject]?.reason)) {
    const { testCase } = result;
    const steps = testCase.steps.filter(step => !step.checkpoint);
    const shrunk = result.crashed ? undefined : await shrinker.shrink(testCase, steps, { tests: 300, scalars: false });
    const names = shrunk ? named(testCase, shrunk.steps) : [];
    const cause = names.includes(testCase.subject) || !names.length ? [testCase.subject] : names;
    const key = cause.join(' + ');
    const entry = causes.get(key) ?? { cause, failing: [] };
    entry.failing.push({ ...result, shrunk });
    causes.set(key, entry);
  }
  // A cause that includes a function failing on its own belongs to that function, such as CUP + CHA to CHA.
  const alone = cause => cause.length > 1 && cause.find(name => causes.get(name)?.cause.length === 1);
  for (const [key, entry] of causes) {
    if (!alone(entry.cause)) continue;
    causes.get(alone(entry.cause)).failing.push(...entry.failing);
    causes.delete(key);
  }
  const ranked = [...causes.values()].map(entry => ({ ...entry, users: users(entry.cause), emissions: Math.min(...entry.cause.map(total)) }))
    .sort((a, b) => b.users.length - a.users.length || b.emissions - a.emissions
      || b.failing.length - a.failing.length || a.cause.join().localeCompare(b.cause.join()));
  const rank = new Map(ranked.map((gap, index) => [gap.cause.join(' + '), index + 1]));
  log(`Shrunk the failing function cases in ${seconds(started)}`);

  // 2. Each program, for every kind of visible state that disagrees, from the first read where it does.
  const programFindings = [];
  for (const result of results.programs.filter(result => result.failing)) {
    const { testCase } = result;
    const { steps, kinds, crashed } = await shrinker.divergences(testCase);
    const findings = [];
    for (const [kind, { step, difference }] of kinds) {
      const shrunk = await shrinker.shrink(testCase, steps.slice(0, step + 1), { kind, tests: 1500 });
      const names = shrunk ? named(testCase, shrunk.steps) : [];
      findings.push({ kind, step, difference, shrunk, cause: alone(names) ? [alone(names)] : names });
    }
    const hidden = [...new Set(result.differences?.map(kindOf) ?? [])].filter(kind => !kinds.has(kind));
    programFindings.push({ result, steps, findings, hidden, crashed });
    log(`Shrunk ${testCase.name} in ${seconds(started)}`);
  }

  // 3. Random streams, shrunk and grouped by the functions left in each minimal input.
  const streamGroups = new Map();
  const failingStreams = results.streams.filter(result => result.failing && !defects[result.testCase.name]);
  for (const result of failingStreams.slice(0, 80)) {
    const shrunk = await shrinker.shrink(result.testCase, result.testCase.steps.filter(step => !step.checkpoint), { tests: 800 });
    const names = shrunk ? named(result.testCase, shrunk.steps) : [];
    const key = !shrunk ? 'history or the inactive screen' : (alone(names) || names.join(' + ') || 'printing');
    const group = streamGroups.get(key) ?? { streams: [], example: shrunk };
    group.streams.push(result.testCase.name);
    if (shrunk && (!group.example || length(shrunk.steps) < length(group.example.steps))) group.example = shrunk;
    streamGroups.set(key, group);
  }

  // 4. Every function real programs emit, with what the function corpus says about it.
  const exercised = new Map();
  for (const result of results.functions) {
    const writes = result.functions.length > 1 ? result.functions.slice(1) : result.functions;
    for (const name of new Set(writes.flat())) exercised.set(name, [...exercised.get(name) ?? [], result]);
  }
  const emittedNames = [...new Set(programs.flatMap(program => Object.keys(emitted[program])))]
    .map(name => ({ name, users: users([name]), emissions: total(name) }))
    .sort((a, b) => b.users.length - a.users.length || b.emissions - a.emissions || a.name.localeCompare(b.name));
  const status = name => {
    if (rank.has(name)) return `gap, row ${rank.get(name)}`;
    if (gaps[name]?.reason) return 'deliberate gap';
    const cases = exercised.get(name);
    if (!cases) return name === 'resize' ? 'matches' : '**no function case**';
    const failing = cases.filter(result => result.failing).length;
    const plural = count => `${count} case${count === 1 ? '' : 's'}`;
    return failing ? `${failing} of ${plural(cases.length)} differ, through other causes` : `matches in ${plural(cases.length)}`;
  };

  const passing = corpus => results[corpus].filter(result => !result.failing).length;
  const defectCount = Object.keys(defects).length;
  const revision = execFileSync('git', ['-C', root, 'rev-parse', '--short', 'HEAD'], { encoding: 'utf8' }).trim();
  const lines = [
    '# Conformance gap report', '',
    `Thrush \`${revision}\` against the pinned reference emulator, ${packageList(reference.description.packages)}, `
      + `with ${reference.description.options.scrollback} rows of history and Unicode ${reference.description.unicode} widths.`, '',
    '| Corpus | Cases | Match | Differ | Reference defects |', '| --- | ---: | ---: | ---: | ---: |',
    ...Object.keys(results).map(corpus => {
      const defective = results[corpus].filter(result => defects[result.testCase.name]).length;
      return `| ${corpus} | ${results[corpus].length} | ${passing(corpus)} | ${results[corpus].length - passing(corpus) - defective} | ${defective} |`;
    }),
    '',
    defectCount ? 'Reference defects are listed at the end, with why Thrush differs.' : '',
    '',
    '## Ranked function gaps', '',
    ...(ranked.length ? [
      'Each failing function case is shrunk to the fewest bytes that still disagree, and grouped by the functions left in them. '
        + `Rows rank by how many of the ${programs.length} recorded programs emit every function in the cause, then by how often they do.`, '',
      '| # | Cause | Failing cases | Programs | Emissions | Smallest input | First difference |',
      '| ---: | --- | ---: | --- | ---: | --- | --- |',
    ] : ['Every function case matches, except the deliberate gaps and reference defects.']),
    ...ranked.map((gap, index) => {
      const smallest = gap.failing.filter(result => result.shrunk).sort((a, b) => length(a.shrunk.steps) - length(b.shrunk.steps))[0];
      const first = smallest ?? gap.failing[0];
      const difference = first.crashed ? `Thrush crashed: ${first.crashed}` : describe((first.shrunk ?? first).differences[0]);
      return `| ${index + 1} | ${gap.cause.map(code).join(' + ')} | ${gap.failing.length} | ${counts(gap.users)} | ${gap.emissions} | `
        + `${smallest ? code(printable(smallest.shrunk.steps)) : ''} | ${cell(`${first.testCase.name}: ${difference}`)} |`;
    }),
    '',
    ...(deliberate.length ? [
      '## Deliberate gaps', '',
      'Thrush differs from the reference in these functions by choice, for the reason given in KnownGaps.json.', '',
      '| Function | Failing cases | Reason |', '| --- | ---: | --- |',
      ...deliberate.map(([subject, gap]) => `| ${code(subject)} | ${gap.cases.length} | ${cell(gap.reason)} |`),
      '',
    ] : []),
    '## Real programs', '',
    'Each program replays with a visible checkpoint after every read. For each kind of state that disagrees, the reads up to the first disagreement are shrunk to the fewest bytes that still disagree that way.', '',
    ...programFindings.flatMap(({ result, steps, findings, hidden, crashed }) => [
      `### ${result.testCase.program}`, '',
      ...(crashed ? [`Thrush crashed: ${crashed}`, ''] : []),
      ...(findings.length ? [
        '| State | First read | Cause | Smallest input | Difference |', '| --- | ---: | --- | --- | --- |',
        ...findings.sort((a, b) => a.step - b.step).map(finding =>
          `| ${finding.kind} | ${finding.step + 1} of ${steps.length} | ${finding.cause.length ? finding.cause.map(code).join(' + ') : 'printing'} | `
          + `${finding.shrunk ? code(printable(finding.shrunk.steps)) : 'not reproducible from visible state'} | ${cell(describe((finding.shrunk ?? finding).differences?.[0] ?? finding.difference))} |`),
        '',
      ] : []),
      ...(hidden.length ? [`The recorded checkpoints also differ in ${hidden.join(', ')}, which visible checkpoints can't show.`, ''] : []),
    ]),
    '## Random streams', '',
    `${failingStreams.length} of ${results.streams.length} seeded streams differ. The first ${Math.min(80, failingStreams.length)} were shrunk and grouped by the functions left in their minimal input.`, '',
    '| Cause | Streams | Smallest input |', '| --- | ---: | --- |',
    ...[...streamGroups].sort((a, b) => b[1].streams.length - a[1].streams.length || a[0].localeCompare(b[0])).map(([key, group]) =>
      `| ${rank.has(key) ? `${code(key)} (row ${rank.get(key)})` : cell(key)} | ${group.streams.length} | ${group.example ? code(printable(group.example.steps)) : ''} |`),
    '',
    '## What real programs emit', '',
    `Every function the ${programs.length} recorded programs emit, and how Thrush does on the function cases that exercise it.`, '',
    '| Function | Programs | Emissions | Thrush |', '| --- | --- | ---: | --- |',
    ...emittedNames.map(({ name, users: list, emissions }) => `| ${code(name)} | ${counts(list, { named: false })} | ${emissions} | ${status(name)} |`),
    '',
    ...(defectCount ? [
      '## Reference defects', '',
      '| Case | Reason | Differences |', '| --- | --- | --- |',
      ...Object.entries(defects).map(([name, defect]) =>
        `| ${cell(name)} | ${cell(defect.reason)} | ${cell(summarize(defect.differences ?? []))} |`),
      '',
    ] : []),
  ];
  return lines.join('\n').replace(/\n{3,}/g, '\n\n');
}

function describe(difference) {
  if (!difference) return undefined;
  return `${difference.path}: reference ${difference.reference}, Thrush ${difference.thrush}`;
}

function summarize(differences, shown = 4) {
  const more = differences.length - shown;
  return differences.slice(0, shown).map(describe).join('; ') + (more > 0 ? `; and ${more} more` : '');
}

function length(steps) { return steps.reduce((sum, step) => sum + (step.write?.length ?? 1), 0); }

function printable(steps) {
  return steps.map(step => step.resize ? `[resize ${step.resize.join('×')}]` : tokens(step.write)).join(' | ');
}

/** A readable rendering of bytes, for the report. The Swift side renders the same way in failures. */
function tokens(bytes) {
  const names = { 0: 'NUL', 7: 'BEL', 8: 'BS', 9: 'HT', 10: 'LF', 11: 'VT', 12: 'FF', 13: 'CR', 14: 'SO', 15: 'SI', 24: 'CAN', 26: 'SUB', 127: 'DEL' };
  let text = '';
  for (const scalar of new TextDecoder('utf-8').decode(bytes)) {
    const value = scalar.codePointAt(0);
    if (value === 0x1b) text += ' ESC';
    else if (names[value]) text += ` ${names[value]} `;
    else if (value < 0x20 || (value >= 0x80 && value < 0xa0)) text += ` 0x${value.toString(16).toUpperCase()} `;
    else text += scalar;
  }
  return text.replace(/\s+/g, ' ').trim();
}

function code(text) { return `\`${String(text).replaceAll('`', 'ˋ').replaceAll('|', '\\|')}\``; }
function cell(text) { return String(text).replaceAll('|', '\\|').replaceAll('\n', ' '); }
function packageList(packages) {
  const names = Object.entries(packages).map(([name, version]) => `${name} ${version}`);
  return `${names.slice(0, -1).join(', ')} and ${names.at(-1)}`;
}
function sorted(object) { return Object.fromEntries(Object.entries(object).sort(([a], [b]) => a.localeCompare(b))); }
function json(value, depth) { return `${JSON.stringify(value, null, depth === undefined ? 1 : depth)}\n`; }
function count(runs) { return Object.values(runs).reduce((sum, corpus) => sum + corpus.length, 0); }
function seconds(start) { return `${((performance.now() - start) / 1000).toFixed(1)} s`; }
function log(message) { console.error(message); }
