// Resolve the copy gesture against the pinned browser's SelectionService.
// stdin contains the real PTY events through the return of the shell prompt.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { source, terminal, write } from '../reference.mjs';

const { SelectionService } = await source('browser/services/SelectionService');
const recording = JSON.parse(readFileSync(0, 'utf8'));
const t = terminal(recording.columns, recording.rows);
const commands = new Map([
  ['Typed command','thrush$ ./builx'],
  ['Edited command','thrush$ ./buil'],
  ['Pasted build command','thrush$ ./build 126 130']
]);
for (const event of recording.events) {
  if (event.resize) t.resize(event.resize.columns, event.resize.rows);
  if (event.bytes) await write(t, Buffer.from(event.bytes, 'base64'));
  if (event.action?.kind === 'paste') {
    assert(t.modes.bracketedPasteMode,'Readline must enable bracketed paste before host input.');
    assert.deepEqual(Buffer.from(event.input,'base64'),Buffer.from('\x1b[200~d 126 130\x1b[201~'));
  }
  if (commands.has(event.name)) {
    const buffer = t.buffer.active;
    const line = buffer.getLine(buffer.baseY + buffer.cursorY);
    assert.equal(line.translateToString(false,0,buffer.cursorX),commands.get(event.name),event.name);
    commands.delete(event.name);
  }
}
assert.equal(commands.size,0,'Missing command-line editing checkpoint.');
const buffer = t.buffer.normal;
const text = '0128  compile units/café/界/e\u0301/long-dependency/with/nested-source-folders/unit-0128.h';
const row = Array.from({length:buffer.length}, (_, i) => i).find(i =>
  buffer.getLine(i).translateToString(true).startsWith('0128  compile '));
assert.notEqual(row, undefined);
let last = row;
while (buffer.getLine(last + 1)?.isWrapped) last++;
assert(last > row && row >= buffer.baseY, 'The copied output must wrap within the visible viewport.');
let endColumn = t.cols;
while (endColumn > 0 && buffer.getLine(last).getCell(endColumn - 1).getChars() === '') endColumn--;
const selected = Object.getOwnPropertyDescriptor(SelectionService.prototype, 'selectionText').get.call({
  _model:{finalSelectionStart:[0,row], finalSelectionEnd:[endColumn,last]},
  _bufferService:t._core._bufferService
});
assert.equal(selected, text, 'The browser must copy the complete path with its exact Unicode and no inserted newline.');
const copy = {start:{row, column:0}, end:{row:last, column:endColumn}, text:selected};
if (recording.events.at(-1).copy) assert.deepEqual(copy,recording.events.at(-1).copy);
console.log(JSON.stringify(copy));
t.dispose();
process.exit(0);
