// Preserve the same ordered xterm parser, palette replies and Unicode-width behavior as the other PTY captures.
import { createInterface } from 'node:readline';
import { applyPalette, terminal, write } from '../reference.mjs';

const t = terminal(80, 24);
let replies = [];
t.onData(data => replies.push(Buffer.from(data)));
for await (const line of createInterface({input:process.stdin, crlfDelay:Infinity})) {
  const event = JSON.parse(line);
  replies = [];
  if (event.resize) t.resize(event.resize.columns, event.resize.rows);
  if (event.palette) applyPalette(t, event.palette);
  if (event.bytes) await write(t, Buffer.from(event.bytes, 'base64'));
  const buffer = t.buffer.active;
  const visible = event.inspect && Array.from({length:t.rows}, (_, y) =>
    buffer.getLine(buffer.baseY + y)?.translateToString(true, 0, t.cols) ?? '');
  const synchronizedOutput = t.modes.synchronizedOutputMode;
  process.stdout.write(JSON.stringify({reply:Buffer.concat(replies).toString('base64'), visible, synchronizedOutput}) + '\n');
}
t.dispose();
process.exit(0);
