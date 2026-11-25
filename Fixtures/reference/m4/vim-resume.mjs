// Add a scripted brief detach to the frozen real Vim PTY recording. The replay
// is the exact binary emitted by the selected server for a same-size reattach.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { parseArgs } from 'node:util';
import { readFile, writeFile } from 'node:fs/promises';
import { relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { reference, terminal, write } from '../m2/xterm-reference.mjs';
import { assertDefaultShellPrompt, assertSameVimScreen } from './vim-replay-state.mjs';

const checkout = resolve(process.argv[2] ?? '../toy-box');
const { positionals, values } = parseArgs({args:process.argv.slice(3), allowPositionals:true,
  options:{'serializer-checkout':{type:'string'}}});
assert(positionals.length <= 2, 'Expected optional Vim source and overlay output paths.');
const serializerCheckout = resolve(values['serializer-checkout'] ?? checkout);
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const serializerPath = resolve(serializerCheckout, 'src/features/terminal/server/scrollback.ts');
const serializerSourceSHA256 = sha(await readFile(serializerPath));
const { ScrollbackBuffer } = await import(serializerPath);
const directory = fileURLToPath(new URL('.', import.meta.url));
const wideSource = resolve(directory, '../m2/vim-edit.capture.json');
const wideDestination = resolve(directory, 'vim-resume.capture.json');
const sourcePath = resolve(positionals[0] ?? wideSource);
const destination = resolve(positionals[1] ?? wideDestination);
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
let cursor;
let firstLive = false;

function visible(t) {
  const buffer = t.buffer.active;
  return Array.from({length:t.rows}, (_, y) => buffer.getLine(buffer.baseY + y).translateToString(true, 0, t.cols));
}
function position(t) {
  const buffer = t.buffer.active;
  return {row:buffer.cursorY, column:buffer.cursorX};
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
  if (replay && (event.bytes || event.resize)) assertSameVimScreen(client, server);
  if (event.name === 'Fresh prompt') {
    assertDefaultShellPrompt(client);
  }
  if (event.name === 'Vim opens alternate screen' || event.name === 'Edited scratch file') {
    const lines = visible(client);
    assert.equal(client.buffer.active.type,'alternate');
    const edited = event.name === 'Edited scratch file';
    assert.equal(lines[0],edited ? 'note: 界 e\u0301first line' : 'first line');
    assert.equal(lines[1],'second line');
  }
  if (event.name !== 'Restored alternate grid') {
    events.push(event);
    continue;
  }

  assert.equal(replay,undefined);
  const before = client;
  assert.equal(before.buffer.active.type,'alternate');
  assert(visible(before).includes('note: 界 e\u0301first line'));
  assert.deepEqual(position(before), {row:0, column:9});
  assertSameVimScreen(server, before);
  events.push({...event,name:'Vim before detach'});
  events.push({name:'Vim detached',offsetMicroseconds:event.offsetMicroseconds,lifecycle:{type:'detach',clientId}});
  const resumedAt = event.offsetMicroseconds + gap;
  events.push({name:'Vim resumed ready',offsetMicroseconds:resumedAt,
    lifecycle:{type:'ready',resumed:true,clientId},checkpoint:true});
  client = terminal(server.cols,server.rows);
  assert.equal(client.buffer.active.type,'normal');
  assert(visible(client).every(text => text === ''));
  replay = Buffer.from(server.replay());
  assert(replay.length > 0);
  await write(client,replay);
  assertSameVimScreen(client, before);
  cursor = {beforeDetach:position(before), afterReplay:position(client)};
  before.dispose();
  events.push({name:'Vim serialized replay',offsetMicroseconds:resumedAt,bytes:replay.toString('base64'),checkpoint:true});
}

assert(firstLive && replay);
assert.equal(events.at(-1).name,'Returned to shell');
assertDefaultShellPrompt(server);
assertDefaultShellPrompt(client);
assertSameVimScreen(client, server);
assert.equal(sha(await readFile(serializerPath)), serializerSourceSHA256, 'Serializer changed during generation.');
const savedText = 'note: 界 e\u0301first line\nsecond line\n';
const result = {...recording,name:'vim-resume',
  overlay:{sourceCapture:relative(directory,sourcePath),sourceCaptureSHA256:sha(source),
    sourceReferenceRevision:reference.toyBoxRevision,serializerSourceSHA256,clientId,
    scriptedDetachMicroseconds:gap,serializer:'src/features/terminal/server/scrollback.ts:ScrollbackBuffer.replay',
    serializedBytes:replay.length,serializedSHA256:sha(replay),
    cursor,
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
