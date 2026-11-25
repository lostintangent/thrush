// Add a scripted brief detach to the frozen real Vim PTY recording. The replay
// is the exact binary emitted by the pinned server for a same-size reattach.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { terminal, write } from '../m2/xterm-reference.mjs';

const checkout = resolve(process.argv[2] ?? '../toy-box');
const { ScrollbackBuffer } = await import(resolve(checkout, 'src/features/terminal/server/scrollback.ts'));
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const directory = fileURLToPath(new URL('.', import.meta.url));
const wideSource = resolve(directory, '../m2/vim-edit.capture.json');
const wideDestination = resolve(directory, 'vim-resume.capture.json');
const sourcePath = resolve(process.argv[3] ?? wideSource);
const destination = resolve(process.argv[4] ?? wideDestination);
assert(sourcePath === wideSource || destination !== wideDestination, 'Give a separate output for a new Vim source.');
const source = await readFile(sourcePath);
const recording = JSON.parse(source);
assert.equal(recording.name, 'vim-edit');
const server = new ScrollbackBuffer(recording.columns, recording.rows);
let client = terminal(recording.columns, recording.rows);
const clientId = 'r5-vim';
const gap = 250_000;
const events = [];
let replay;
let firstLive = false;

function screen(t) {
  const buffer = t.buffer.active;
  const normal = t.buffer.normal;
  return {
    screen:buffer.type, cursor:[buffer.cursorX,buffer.cursorY], history:buffer.baseY,
    lines:Array.from({length:t.rows}, (_, row) => {
      const line = buffer.getLine(buffer.baseY + row);
      return [line.translateToString(true),line.isWrapped];
    }),
    normalLines:Array.from({length:normal.length}, (_, row) => {
      const line = normal.getLine(row);
      return [line.translateToString(true),line.isWrapped];
    }),
    applicationCursor:t.modes.applicationCursorKeysMode, keypad:t.modes.applicationKeypadMode,
    bracketedPaste:t.modes.bracketedPasteMode
  };
}

for (const original of recording.events) {
  const event = {...original};
  if (replay) {
    event.offsetMicroseconds += gap;
    if (event.replyOffsetMicroseconds !== undefined) event.replyOffsetMicroseconds += gap;
    if (event.bytes && !firstLive) {
      event.name = 'Vim first live output after replay';
      firstLive = true;
    }
  }
  if (event.resize) {
    server.resize(event.resize.columns,event.resize.rows);
    client.resize(event.resize.columns,event.resize.rows);
  }
  if (event.bytes) {
    const bytes = Buffer.from(event.bytes,'base64');
    await write(server,bytes);
    await write(client,bytes);
  }
  if (event.name === 'Fresh prompt') {
    assert(screen(client).lines.some(([text]) => text === 'thrush$ '));
  }
  if (event.name === 'Vim opens alternate screen' || event.name === 'Edited scratch file') {
    const native = screen(client);
    assert.equal(native.screen,'alternate');
    const edited = event.name === 'Edited scratch file';
    assert.equal(native.lines[0][0],edited ? 'note: 界 e\u0301first line' : 'first line');
    assert.equal(native.lines[1][0],'second line');
  }
  if (event.name !== 'Restored alternate grid') {
    events.push(event);
    continue;
  }

  assert.equal(replay,undefined);
  const before = screen(client);
  assert.equal(before.screen,'alternate');
  assert(before.lines.some(([text]) => text.includes('note: 界 e\u0301first line')));
  events.push({...event,name:'Vim before detach'});
  events.push({name:'Vim detached',offsetMicroseconds:event.offsetMicroseconds,lifecycle:{type:'detach',clientId}});
  const resumedAt = event.offsetMicroseconds + gap;
  events.push({name:'Vim resumed ready',offsetMicroseconds:resumedAt,
    lifecycle:{type:'ready',resumed:true,clientId},checkpoint:true});
  client.dispose();
  client = terminal(server.cols,server.rows);
  assert.equal(client.buffer.active.type,'normal');
  assert(screen(client).lines.every(([text]) => text === ''));
  replay = Buffer.from(server.replay());
  assert(replay.length > 0);
  await write(client,replay);
  const restored = screen(client);
  // SerializeAddon 0.14.0 repositions this cursor one column left of its
  // pre-detach location on the edited wide/combining-text row.
  assert.deepEqual(before.cursor,[9,0]);
  assert.deepEqual(restored.cursor,[8,0]);
  assert.deepEqual({...restored,cursor:before.cursor},before,
    'The serialized frame must restore edited text, wraps, alternate screen and recorded input modes.');
  events.push({name:'Vim serialized replay',offsetMicroseconds:resumedAt,bytes:replay.toString('base64'),checkpoint:true});
}

assert(firstLive && replay);
assert.equal(events.at(-1).name,'Returned to shell');
const after = screen(client);
assert.equal(after.screen,'normal');
assert.equal(after.lines[after.cursor[1]][0], 'thrush$ ');
assert.deepEqual(after,screen(server),'The recorded save/quit must return both clients to the same shell.');
const savedText = 'note: 界 e\u0301first line\nsecond line\n';
const result = {...recording,name:'vim-resume',
  overlay:{sourceCapture:relative(directory,sourcePath),sourceCaptureSHA256:sha(source),clientId,
    scriptedDetachMicroseconds:gap,serializer:'src/features/terminal/server/scrollback.ts:ScrollbackBuffer.replay',
    serializedBytes:replay.length,serializedSHA256:sha(replay),
    cursor:{beforeDetach:{row:0,column:9},afterReplay:{row:0,column:8}},
    savedFile:{name:'scratch.txt',text:savedText,sha256:sha(Buffer.from(savedText)),
      verifiedBy:'Fixtures/reference/m2/capture.py checks the saved PTY scratch file before recording vim-edit.'}}};
delete result.events;
const data = JSON.stringify(result).slice(0,-1) + ',\n"events":[\n'
  + events.map(event => JSON.stringify(event)).join(',\n') + '\n]}\n';
await writeFile(destination,data);
console.log(events.length,'events,',replay.length,'serialized bytes,',sha(replay));
server.dispose();
client.dispose();
process.exit(0);
