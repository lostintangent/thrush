// Feeds one comparison workload to the pinned @xterm/headless and reports pass times and the final screen.
// Usage: bun|node xterm.mjs WORKLOAD COLUMNS ROWS CHUNK WARMUPS PASSES HISTORY
import { readFileSync } from 'node:fs';
import { headless } from '../../Fixtures/reference/headless.mjs';

const [workload, ...numbers] = process.argv.slice(2);
const [columns, rows, chunk, warmups, passes, history] = numbers.map(Number);
const bytes = new Uint8Array(readFileSync(workload));
const chunks = [];
for (let offset = 0; offset < bytes.length; offset += chunk || bytes.length) {
  chunks.push(bytes.subarray(offset, offset + (chunk || bytes.length)));
}

function makeTerminal() {
  return headless(columns, rows, { scrollback: history, logLevel: 'off' });
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
process.stdout.write(JSON.stringify({ passes: results, state, runtime }) + '\n');
