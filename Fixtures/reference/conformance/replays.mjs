// Replays. A client that falls behind or reconnects gets ThrushCore's replay in place of the output it
// missed, so a replay has to rebuild everything the live terminal holds. For every recorded program, and
// the resizes docs/protocol.md lists as beyond a replay, this takes ThrushCore's replay after every write
// and resize, resumes a terminal from it in ThrushCore and in the reference, and holds each to a live
// terminal of its own kind: right after the replay, after every later step, and at the end.
//
//   bun Fixtures/reference/conformance/replays.mjs --thrush .build/release/ThrushConformance [--check]
//
// A program whose resumed terminals differ needs an entry in replay-gaps.json with a reason, and
// `--check` fails if the file would change.
import assert from 'node:assert/strict';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { parseArgs } from 'node:util';
import { collect, create, perform, state } from './xterm.mjs';
import { functionCases } from './functions.mjs';
import { programCases } from './programs.mjs';
import { Thrush, encodeCase } from './thrush.mjs';

const { values: options } = parseArgs({
  options: { thrush: { type: 'string' }, check: { type: 'boolean' } },
});
assert(options.thrush, 'Pass --thrush with a release build of ThrushConformance');

const here = import.meta.dir;
const root = resolve(here, '../../..');
const gapsFile = join(here, 'replay-gaps.json');

const ESC = '\x1b', CSI = `${ESC}[`, DCS = `${ESC}P`, OSC = `${ESC}]`, ST = `${ESC}\\`;
// What one screen keeps that a checkpoint can't show, in parts so nothing a part prints hides another's.
const screen = [
  // The pen, the character set and a pending wrap, as the next character shows them. Then the pen,
  // scroll margins and cursor style as answers, the keyboard flags and each entry below them, and every
  // mode either emulator might keep.
  `x${CSI}6n${['m', 'r', ' q'].map(setting => `${DCS}$q${setting}${ST}`).join('')}${`${CSI}?u${CSI}<u`.repeat(8)}`
    + [4, 20].map(mode => `${CSI}${mode}$p`).join('')
    + [1, 3, 5, 6, 7, 8, 9, 12, 25, 45, 47, 66, 67, 69, 1000, 1001, 1002, 1003, 1004, 1005, 1006, 1007, 1015, 1016,
      1047, 1048, 1049, 2004, 2026, 2027, 2031].map(mode => `${CSI}?${mode}$p`).join(''),
  // The saved cursor: its place, pen, character set, origin mode and wraparound.
  `${ESC}8${CSI}6nx${CSI}?6$p${CSI}?7$p`,
  // The character set in each slot, where DEC graphics draw q as a line and the British set draws # as £,
  // then tab stops, as where each tab lands.
  ['\x0f', '\x0e', `${ESC}n`, `${ESC}o`].map(shift => `${shift}#q`).join('') + `\x0f\r${`\t${CSI}6n`.repeat(32)}`,
];
// The probe runs on a copy of each terminal in parts, and each part ends with a visible checkpoint.
const probe = [
  // The text the cursor follows, which REP repeats and a combining mark joins. Any control ends it, so it
  // goes first. Then the colors programs set.
  `${CSI}b\u0301${OSC}10;?${ST}${OSC}11;?${ST}${OSC}12;?${ST}`
    + Array.from({ length: 256 }, (_, index) => `${OSC}4;${index};?${ST}`).join(''),
  // The screen the program is on, then the normal screen, which leaving the alternate one restores, and
  // the alternate one.
  ...screen,
  `${CSI}?1049l${screen[0]}`, ...screen.slice(1),
  `${CSI}?1049h${screen[0]}`, ...screen.slice(1),
].map(part => Buffer.from(part, 'utf8'));

// ThrushCore resumes every program in turn while the reference follows, and a second process describes
// differences so they don't wait behind it.
const thrush = new Thrush(resolve(options.thrush)), describer = new Thrush(resolve(options.thrush));
const started = performance.now();
const beyondReplay = ['resize · narrower after cutting a wide glyph', 'resize · on the alternate screen'];
const cases = [...programCases(resolve(here, '..')), ...functionCases.filter(testCase => beyondReplay.includes(testCase.name))];
const results = cases.map(testCase =>
  thrush.request({ replays: encodeCase(testCase), probe: probe.map(part => part.toString('base64')) }));
const found = {};
let points = 0;
for (const [index, testCase] of cases.entries()) {
  const result = await results[index];
  assert(!result.crashed, `ThrushCore crashed replaying ${testCase.program ?? testCase.name}: ${result.crashed}`);
  points += result.replays.length;
  const sides = {
    thrush: grouped(Object.fromEntries(result.replays.filter(replay => replay.divergence)
      .map(replay => [replay.step, replay.divergence]))),
    reference: grouped(await referenceDivergences(testCase, result.replays)),
  };
  const divergent = Object.fromEntries(Object.entries(sides).filter(([, groups]) => groups.length));
  if (Object.keys(divergent).length) found[testCase.program ?? testCase.name] = divergent;
}
thrush.close();
describer.close();
log(`Resumed ${points} replays of ${cases.length} cases in ThrushCore and the reference in ${seconds(performance.now() - started)}`);

// A gap's reason is written by hand, and its divergences are regenerated so a change on either side shows.
const listed = existsSync(gapsFile) ? JSON.parse(readFileSync(gapsFile, 'utf8')) : {};
const gaps = Object.fromEntries(Object.entries(found).sort(([a], [b]) => a.localeCompare(b))
  .map(([program, sides]) => [program, { ...(listed[program]?.reason && { reason: listed[program].reason }), ...sides }]));
const contents = `${JSON.stringify(gaps, null, 2)}\n`;
const current = existsSync(gapsFile) ? readFileSync(gapsFile, 'utf8') : undefined;
if (contents !== current) {
  if (options.check) {
    console.error(`Resumed terminals differ from the listed gaps in ${gapsFile.slice(root.length + 1)}:`);
    for (const [program, { reason, ...sides }] of Object.entries(gaps)) {
      if (JSON.stringify(sides) === JSON.stringify({ ...listed[program], reason: undefined })) continue;
      for (const [side, groups] of Object.entries(sides)) {
        for (const { 'after steps': steps, at, differences } of groups) {
          console.error(`  ${program}, ${side} resumed after steps ${steps}, differs at ${at}:\n${differences.map(line => `    ${line}`).join('\n')}`);
        }
      }
    }
    for (const program of Object.keys(listed).filter(program => !gaps[program])) console.error(`  ${program} no longer differs`);
    process.exit(1);
  }
  writeFileSync(gapsFile, contents);
  log(`Wrote ${gapsFile.slice(root.length + 1)}`);
}
const unexplained = Object.keys(gaps).filter(program => !gaps[program].reason);
assert.deepEqual(unexplained, [], 'Resumed terminals differ in these programs. Give each a reason in replay-gaps.json');
log(`Every replay resumes as listed`);
// The reference's browser theme service keeps a handle open, so leave explicitly.
process.exit(0);

/**
 * Resumes a reference terminal from each of ThrushCore's replays, and returns where each first differs
 * from the live reference terminal. The reference can't be copied, so the probe runs at the end only.
 */
async function referenceDivergences({ steps, size, palette }, replays) {
  const acting = steps.flatMap((step, index) => step.checkpoint ? [] : [index]);
  const taken = new Set(replays.map(replay => replay.step));
  // The live terminal: what each step showed, and its size, focus and full state where a replay was taken.
  const live = create(size, palette), liveReplies = collect(live);
  const shown = new Map(), points = new Map();
  let focused = false;
  for (const index of acting) {
    focused = steps[index].focus ?? focused;
    shown.set(index, shownAfter(live, perform(live, steps[index]), index, liveReplies));
    if (taken.has(index)) {
      points.set(index, { size: [live.cols, live.rows], focused, full: Bun.hash(JSON.stringify(full(live, 'replay'))),
        // Turning focus reporting on reports focus, so the program hears the resumed client's focus.
        report: live.modes.sendFocusMode ? `${CSI}${focused ? 'I' : 'O'}` : '' });
    }
  }
  const end = finish(live, liveReplies), ended = JSON.stringify(end);
  live.dispose();

  const divergences = {};
  for (const replay of replays) {
    const point = points.get(replay.step);
    const resumed = create(point.size, palette);
    try {
      const divergence = await resume(resumed, collect(resumed), replay, point);
      if (divergence) divergences[replay.step] = divergence;
    } finally {
      resumed.dispose();
    }
  }
  return divergences;

  async function resume(resumed, replies, replay, point) {
    perform(resumed, { focus: point.focused });
    const error = perform(resumed, { write: Buffer.from(replay.bytes, 'base64') });
    const sent = replies();
    const differences = [...(error ? [`error: ${error}`] : []),
      ...(sent !== point.report ? [`replies: live ${JSON.stringify(point.report)}, resumed ${JSON.stringify(sent)}`] : [])];
    const resumedFull = full(resumed, 'replay');
    if (Bun.hash(JSON.stringify(resumedFull)) !== point.full) {
      differences.push(...await describe([liveFull(replay.step)], [resumedFull]));
    }
    if (differences.length) return { at: 'replay', differences };
    for (const index of acting.filter(index => index > replay.step)) {
      const now = shownAfter(resumed, perform(resumed, steps[index]), index, replies);
      if (now !== shown.get(index)) {
        return { at: `step ${index}`, differences: await describe([JSON.parse(shown.get(index))], [JSON.parse(now)]) };
      }
    }
    const resumedEnd = finish(resumed, replies);
    if (JSON.stringify(resumedEnd) !== ended) return { at: 'end', differences: await describe(end, resumedEnd) };
  }

  // The live terminal's full state right after a step, replayed again since the reference can't be copied.
  function liveFull(step) {
    const t = create(size, palette);
    for (const index of acting.filter(index => index <= step)) perform(t, steps[index]);
    const result = full(t, 'replay');
    t.dispose();
    return result;
  }
}

/** What a step showed, as JSON, with what it sent back and what the reference threw. */
function shownAfter(t, error, index, replies) {
  return JSON.stringify({ ...state(t, `step ${index}`, 'visible', replies()), ...(error && { error }) });
}

function full(t, name) { return state(t, name, undefined, ''); }

/** The full state at the end, then what each part of the probe shows. */
function finish(t, replies) {
  const checkpoints = [full(t, 'end')];
  replies();
  probe.forEach((part, index) => {
    perform(t, { write: part });
    checkpoints.push(state(t, `probe ${index + 1}`, 'visible', replies()));
  });
  return checkpoints;
}

async function describe(live, resumed) { return (await describer.request({ compare: [live, resumed] })).differences; }
/** Divergences by the step each replay follows, with the steps of identical ones listed together. */
function grouped(divergences) {
  const groups = new Map();
  for (const [step, divergence] of Object.entries(divergences)) {
    const key = JSON.stringify(divergence);
    groups.set(key, [...groups.get(key) ?? [], step]);
  }
  return [...groups].map(([key, steps]) => ({ 'after steps': steps.join(' '), ...JSON.parse(key) }));
}

function seconds(milliseconds) { return `${(milliseconds / 1000).toFixed(1)} s`; }
function log(message) { console.error(message); }
