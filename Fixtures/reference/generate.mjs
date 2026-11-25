// Run with Bun against the Toy Box checkout listed in README.md.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import { writeFile } from 'node:fs/promises';

const checkout = resolve(process.argv[2] ?? '../toy-box');
const revision = 'b9d0eca3c5f4e9036e58327ba633eff52474bb92';
assert.equal(execFileSync('git', ['-C', checkout, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(), revision);
const fromServer = createRequire(resolve(checkout, 'package.json'));
const versions = Object.fromEntries(
  ['@xterm/headless', '@xterm/xterm', '@xterm/addon-unicode11'].map(
    name => [name, fromServer(name + '/package.json').version]
  )
);
assert.deepEqual(versions, { '@xterm/headless': '6.0.0', '@xterm/xterm': '6.0.0', '@xterm/addon-unicode11': '0.9.0' });
const { Terminal } = fromServer('@xterm/headless');
const { emulatorOptions, loadUnicode11 } = await import(resolve(checkout, 'src/features/terminal/model/emulator.ts'));
const { evaluateKeyboardEvent } = await import(fromServer.resolve('@xterm/xterm/src/common/input/Keyboard.ts'));

const columns = 80;
const rows = 24;
const terminal = new Terminal({ ...emulatorOptions, cols: columns, rows });
loadUnicode11(terminal);
const utf8 = value => Array.from(new TextEncoder().encode(value));
const reference = { toyBoxRevision: revision, packages: versions, scrollback: emulatorOptions.scrollback, unicode: terminal.unicode.activeVersion };
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
