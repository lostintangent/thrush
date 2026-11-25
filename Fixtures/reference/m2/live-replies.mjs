// The PTY recorder hands the server emulator and browser color service each read and writes its replies back to Vim.
import { createInterface } from 'node:readline';
import { applyPalette, terminal, write } from './xterm-reference.mjs';

const t = terminal(80, 24);
let replies = [];
t.onData(value => replies.push(Buffer.from(value, 'utf8')));
for await (const line of createInterface({ input:process.stdin, crlfDelay:Infinity })) {
  const event = JSON.parse(line);
  replies = [];
  if (event.palette) applyPalette(t, event.palette);
  if (event.resize) t.resize(event.resize.columns, event.resize.rows);
  if (event.bytes) await write(t, Buffer.from(event.bytes, 'base64'));
  process.stdout.write(JSON.stringify({reply:Buffer.concat(replies).toString('base64')}) + '\n');
}
t.dispose();
// xterm's browser bundle retains its process-wide scheduler after terminal disposal.
process.exit(0);
