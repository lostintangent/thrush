// Answers a recording program's queries the way the pinned reference does, so a capture follows the
// replies a terminal would send. A recorder writes one JSON event per line and reads one answer per event.
//
//   { "resize": { columns, rows } } | { "palette": { foreground, background, ansi } } | { "bytes": base64 }
//   | { "inspect": true }
//     →  { "reply": base64, "applicationCursorKeys": boolean, "synchronizedOutput": boolean, "visible"?: [string] }
//
// The terminal starts at 80 × 24. The cursor key mode tells a recorder which arrow key bytes the program
// expects, and the synchronized output mode and the visible rows tell it when a paint is complete.
import { createInterface } from 'node:readline';
import { applyPalette, terminal, write } from './reference.mjs';

const t = terminal(80, 24);
t.options.logLevel = 'off'; // Only answers go to stdout.
let replies = [];
t.onData(data => replies.push(Buffer.from(data, 'utf8')));
for await (const line of createInterface({ input: process.stdin, crlfDelay: Infinity })) {
  const event = JSON.parse(line);
  replies = [];
  if (event.resize) t.resize(event.resize.columns, event.resize.rows);
  if (event.palette) applyPalette(t, event.palette);
  if (event.bytes) await write(t, Buffer.from(event.bytes, 'base64'));
  const buffer = t.buffer.active;
  const visible = event.inspect
    ? Array.from({ length: t.rows }, (_, y) => buffer.getLine(buffer.baseY + y).translateToString(true, 0, t.cols))
    : undefined;
  const { applicationCursorKeysMode: applicationCursorKeys, synchronizedOutputMode: synchronizedOutput } = t.modes;
  process.stdout.write(`${JSON.stringify({ reply: Buffer.concat(replies).toString('base64'), applicationCursorKeys, synchronizedOutput, visible })}\n`);
}
// The reference's browser theme service keeps a handle open, so leave explicitly.
process.exit(0);
