// Feeds one comparison workload to @xterm/headless and reports pass times and the final screen.
// Usage: bun|node xterm.mjs TOY_BOX WORKLOAD COLUMNS ROWS CHUNK WARMUPS PASSES HISTORY
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';

const [checkout, workload, ...numbers] = process.argv.slice(2);
const [columns, rows, chunk, warmups, passes, history] = numbers.map(Number);
const fromToyBox = createRequire(resolve(checkout, 'package.json'));
const versions = Object.fromEntries(
  ['@xterm/headless', '@xterm/addon-unicode11'].map(name => [name, fromToyBox(`${name}/package.json`).version])
);
assert.deepEqual(versions, { '@xterm/headless': '6.0.0', '@xterm/addon-unicode11': '0.9.0' });
const { Terminal } = fromToyBox('@xterm/headless');
const { Unicode11Addon } = fromToyBox('@xterm/addon-unicode11');
const bytes = new Uint8Array(readFileSync(workload));
const chunks = [];
for (let offset = 0; offset < bytes.length; offset += chunk || bytes.length) {
  chunks.push(bytes.subarray(offset, offset + (chunk || bytes.length)));
}

function makeTerminal() {
  const terminal = new Terminal({ cols: columns, rows, scrollback: history, allowProposedApi: true, logLevel: 'off' });
  terminal.loadAddon(new Unicode11Addon());
  terminal.unicode.activeVersion = '11';
  return terminal;
}

// The public write queues data and parses it in 12 ms slices between timers. writeSync parses the
// same bytes through the same handlers immediately, so the timing holds parsing and nothing else.
function feed(terminal) {
  for (const part of chunks) terminal._core.writeSync(part);
}

for (let i = 0; i < warmups; i++) {
  const terminal = makeTerminal();
  feed(terminal);
  terminal.dispose();
}
const results = [];
let terminal;
for (let i = 0; i < passes; i++) {
  terminal?.dispose();
  terminal = makeTerminal();
  const cpu = process.cpuUsage();
  const start = process.hrtime.bigint();
  feed(terminal);
  const wall = Number(process.hrtime.bigint() - start);
  const used = process.cpuUsage(cpu);
  results.push({ wall, cpu: (used.user + used.system) * 1000 });
}
const buffer = terminal.buffer.active;
const state = {
  cursor: [buffer.cursorY, buffer.cursorX],
  history: buffer.baseY,
  alternate: buffer.type === 'alternate',
  rows: Array.from({ length: rows }, (_, row) => buffer.getLine(buffer.baseY + row).translateToString(true)),
};
const runtime = typeof Bun === 'undefined' ? `node ${process.versions.node}` : `bun ${Bun.version}`;
process.stdout.write(JSON.stringify({ passes: results, state, runtime, versions }) + '\n');
