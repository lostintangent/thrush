// Replay the recorded PTY and server frames through the pinned reference terminal.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { parseArgs } from 'node:util';
import { reference, terminal, write } from './reference.mjs';

const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const { values } = parseArgs({options:{check:{type:'boolean', default:false}}});
const capture = JSON.parse(await readFile(new URL('window-title.capture.json', import.meta.url), 'utf8'));
const { columns, rows, replayFrames } = capture;
assert.equal(replayFrames.length, 2);
const [emptyReplay, titledReplay] = replayFrames.map(frame => Buffer.from(frame.bytes, 'base64'));
const utf8 = text => Buffer.from(text, 'utf8');
const osc = (id, payload) => utf8('\x1b]' + id + ';' + payload + '\x07');
const windowTitle = t => t._core._inputHandler._windowTitle;

for (const [bytes, title] of [[emptyReplay, ''], [titledReplay, 'build']]) {
  const prefix = osc(2, title);
  assert(bytes.subarray(0, prefix.length).equals(prefix), 'Expected a server OSC 2 prefix, including an empty title.');
}

async function observation(name, inputs) {
  const t = terminal(columns, rows);
  const steps = [];
  for (const input of inputs) {
    const bytes = Buffer.from(input);
    await write(t, bytes);
    steps.push({bytes:bytes.toString('base64'), title:windowTitle(t)});
  }
  t.dispose();
  return {name, steps};
}

const cases = [
  await observation('Initial title and OSC 2 at the beginning of the stream', ['', '\uFEFF\x1b]2;build 界e\u0301\x07']),
  await observation('ST commits on ESC, including a split OSC introducer and UTF-8 scalar', [
    osc(0, 'old'), '\x1b', ']2;', Uint8Array.of(0xE7), Uint8Array.of(0x95, 0x8C), '\x1b', '\\'
  ]),
  await observation('UTF-8-encoded C1 OSC and ST', ['\u009d0;check\u009c']),
  await observation('Cancelled titles preserve the previous title', [
    osc(2, 'retain'), '\x1b]0;cancelled\x18', '\x1b]2;cancelled\x1a'
  ]),
  await observation('OSC 1 and disabled window-title stack operations', [
    osc(2, 'original'), osc(1, 'icon'), '\x1b[22;2t', osc(0, 'replacement'), '\x1b[23;2t'
  ]),
  await observation('RIS retains the title and an empty server replay clears it', [
    osc(2, 'stale'), '\x1bc', emptyReplay
  ]),
  await observation('Server replay restores a nonempty title', [osc(0, 'stale'), titledReplay]),
];

const canonical = await readFile(new URL('../replays/codex-session.json', import.meta.url));
const recording = JSON.parse(canonical);
const t = terminal(recording.columns, recording.rows);
const checkpoints = [];
let previous;
for (const [eventIndex, event] of recording.events.entries()) {
  if (event.resize) t.resize(event.resize.columns, event.resize.rows);
  if (event.bytes) await write(t, Buffer.from(event.bytes,'base64'));
  const title = windowTitle(t);
  if (title !== previous || eventIndex === recording.events.length - 1) {
    checkpoints.push({eventIndex, title});
    previous = title;
  }
}
assert(checkpoints.some(event => event.title === 'List 12 songbirds | workspace'));
assert.equal(checkpoints.at(-1).title, '');
const clear = checkpoints.at(-2);
assert.equal(clear.title, '');
assert(Buffer.from(recording.events[clear.eventIndex].bytes, 'base64').includes(osc(0, '')),
  'The recording must explicitly clear the live title with an empty OSC 0.');
t.dispose();

const doc = {reference, cases, codex:{fixtureSHA256:digest(canonical), checkpoints}};
const output = new URL('../replays/metadata/window-title.json', import.meta.url);
const data = JSON.stringify(doc, null, 2) + '\n';
if (values.check) {
  assert.equal(data, await readFile(output, 'utf8'), 'Generated window-title oracle differs from the checked-in JSON.');
} else {
  await writeFile(output, data);
}
console.log(cases.length + ' title cases, ' + checkpoints.length + ' Codex checkpoints');
process.exit(0);
