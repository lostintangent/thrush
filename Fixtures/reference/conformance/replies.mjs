// Answers a recording program's queries the way the pinned reference does, so a capture follows the replies
// a terminal would send. capture-programs.py writes one JSON event per line and reads one reply per event.
//
//   { "start": [columns, rows] } | { "bytes": base64 } | { "resize": [columns, rows] }
//     →  { "reply": base64, "applicationCursorKeys": boolean }
//
// The cursor key mode tells the recorder which arrow key bytes the program expects.
import { createInterface } from 'node:readline';
import * as reference from './xterm.mjs';

let terminal, replies = [];
for await (const line of createInterface({ input: process.stdin, crlfDelay: Infinity })) {
  const event = JSON.parse(line);
  replies = [];
  if (event.start) {
    terminal = reference.create(event.start);
    terminal.onData(data => replies.push(Buffer.from(data, 'utf8')));
    terminal.onBinary(data => replies.push(Buffer.from(data, 'latin1')));
  }
  if (event.resize) terminal.resize(...event.resize);
  if (event.bytes) terminal._core._writeBuffer.writeSync(Buffer.from(event.bytes, 'base64'));
  const applicationCursorKeys = terminal.modes.applicationCursorKeysMode;
  process.stdout.write(`${JSON.stringify({ reply: Buffer.concat(replies).toString('base64'), applicationCursorKeys })}\n`);
}
// The reference's browser theme service keeps a handle open, so leave explicitly.
process.exit(0);
