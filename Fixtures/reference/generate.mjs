// Generates Fixtures/first-bytes.json with Bun. See README.md.
import assert from 'node:assert/strict';
import { writeFile } from 'node:fs/promises';
import { reference, source, terminal as referenceTerminal } from './reference.mjs';

const { evaluateKeyboardEvent } = await source('common/input/Keyboard');

const columns = 80;
const rows = 24;
const terminal = referenceTerminal(columns, rows);
const utf8 = value => Array.from(new TextEncoder().encode(value));
const events = [];
let reply = [];
terminal.onData(value => reply.push(...utf8(value)));

// These offsets are the scripted delivery schedule, in microseconds from attach.
async function deliver(offsetMicroseconds, name, value, pressUp = false) {
  const bytes = typeof value === 'string' ? utf8(value) : value;
  reply = [];
  await new Promise(done => terminal.write(Uint8Array.from(bytes), done));
  const buffer = terminal.buffer.active;
  const row = buffer.cursorY;
  const line = buffer.getLine(buffer.viewportY + row);
  const event = { name, offsetMicroseconds, bytes, reply, row, text: line.translateToString(true) };
  if (pressUp) {
    const key = evaluateKeyboardEvent({ keyCode: 38, key: 'ArrowUp' }, terminal.modes.applicationCursorKeysMode, true, false);
    event.up = utf8(key.key);
    assert.equal(event.up.length, 3);
  }
  events.push(event);
}

await deliver(0, 'Shell prompt', 'thrush$ ', true);
await deliver(2000, 'Begin cursor mode', '\x1b[?1');
await deliver(2200, 'Enable cursor mode', 'h', true);
await deliver(4000, 'Begin cursor query', '\x1b[6');
await deliver(5000, 'Answer cursor query', 'n');
await deliver(6000, 'Disable cursor mode', '\x1b[?1l', true);
await deliver(8000, 'Colored output', '\r\n\x1b[32mcaf');
await deliver(8100, 'Begin UTF-8 scalar', [0xc3]);
await deliver(8200, 'Finish UTF-8 scalar', [0xa9, ...utf8('\x1b[0m')]);
await deliver(9000, 'Backspace and overwrite', 'x\b!');
await deliver(10000, 'Unknown CSI and OSC', '\x1b[999z\x1b]777;hidden');
await deliver(10200, 'Begin string terminator', '\x1b');
await deliver(10400, 'Finish string and query', '\\>\x1b[6n');
await deliver(12000, 'Carriage return', '\rC');
await deliver(13000, 'Line feed and query', '\n$ \x1b[6n');
terminal.dispose();

// Keep one short chunk and its checkpoint on each line for review in Git.
const json = [
  '{', '  "version": 1,', `  "reference": ${JSON.stringify(reference)},`,
  `  "columns": ${columns},`, `  "rows": ${rows},`, '  "events": [',
  events.map(event => '    ' + JSON.stringify(event)).join(',\n'), '  ]', '}', ''
].join('\n');
await writeFile(new URL('../first-bytes.json', import.meta.url), json);
// The browser package retains its process-wide scheduler after terminal disposal.
process.exit(0);
