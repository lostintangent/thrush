// Rebuild reference states from the recorded PTY events. See README.md.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { reference, server, terminal, write } from './xterm-reference.mjs';

const { evaluateKeyboardEvent } = await import(server.resolve('@xterm/xterm/src/common/input/Keyboard.ts'));
const { bracketTextForPaste, prepareTextForTerminal } = await import(server.resolve('@xterm/xterm/src/browser/Clipboard.ts'));
const utf8 = s => Buffer.from(s, 'utf8');
const base64 = bytes => Buffer.from(bytes).toString('base64');
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
// Intern rows and cells so the complete scrollback stays small across resize checkpoints.
class Pool {
  values = [];
  byEncoding = new Map();
  get(value) {
    const key = JSON.stringify(value);
    if (this.byEncoding.has(key)) return this.byEncoding.get(key);
    const id = this.values.length;
    this.values.push(value);
    this.byEncoding.set(key, id);
    return id;
  }
}
function color(isRGB, isDefault, code) {
  return isDefault ? -1 : isRGB ? 256 + code : code;
}
function cellValue(cell) {
  const flags = [cell.isBold(), cell.isDim(), cell.isItalic(), cell.isUnderline(), cell.isBlink(),
    cell.isInverse(), cell.isInvisible(), cell.isStrikethrough()]
    .reduce((bits, set, bit) => bits | ((set ? 1 : 0) << bit), 0);
  return {text:cell.getChars(), width:cell.getWidth(), flags,
    foreground:color(cell.isFgRGB(), cell.isFgDefault(), cell.getFgColor()),
    background:color(cell.isBgRGB(), cell.isBgDefault(), cell.getBgColor())};
}
function checkpoint(t, cells, lines) {
  const buffer = t.buffer.active;
  const scratch = buffer.getNullCell();
  const ids = [];
  for (let r = 0; r < buffer.baseY + t.rows; r++) {
    const line = buffer.getLine(r);
    const runs = [];
    for (let c = 0; c < t.cols; c++) {
      const id = cells.get(cellValue(line.getCell(c, scratch)));
      if (runs.length && runs.at(-1) === id) runs[runs.length - 2]++;
      else runs.push(1, id);
    }
    if (runs.at(-1) === 0) runs.splice(-2);
    ids.push(lines.get({wrapped:line.isWrapped, text:line.translateToString(true, 0, t.cols), runs}));
  }
  const modes = t.modes;
  return {columns:t.cols, rows:t.rows, cursorRow:buffer.cursorY, cursorColumn:buffer.cursorX,
    isAlternate:buffer.type === 'alternate',
    modes:{applicationCursorKeys:modes.applicationCursorKeysMode, bracketedPaste:modes.bracketedPasteMode,
      applicationKeypad:modes.applicationKeypadMode, insert:modes.insertMode, origin:modes.originMode,
      wraparound:modes.wraparoundMode, cursorVisible:!t._core.coreService.isCursorHidden,
      cursorBlink:t.options.cursorBlink, sendFocus:modes.sendFocusMode},
    history:ids.slice(0, buffer.baseY), visible:ids.slice(buffer.baseY)};
}

function shellEdges() {
  const events = [];
  const append = (name, fields) => events.push({name, offsetMicroseconds: events.length * 1000, ...fields});
  const output = (name, bytes, check = true) => append(name,{bytes:base64(bytes), checkpoint:check});
  const resize = (columns, rows) => append('Resize requested grid',{resize:{columns, rows},checkpoint:true});
  output('BOM before shell prompt', [0xef, 0xbb, 0xbf, 65, 66, ...utf8('\x1b[6n')]);
  resize(6, 3);
  resize(1, 2);
  output('Minimum grid cursor report', utf8('\rAB\x1b[6n'));
  resize(12, 4);
  output('Colored log and wrap', utf8('\r\n\x1b[1;38;5;202;48;2;24;32;40m0001 build 界e\u0301\x1b[0m'));
  output('Wide cell at right margin', utf8('\r\n12345678901界!'));
  // Move below the soft wrap before reflow, like the prompt below a completed log.
  output('Prompt below wrapped log', utf8('\r\n$ '));
  resize(7, 4);
  resize(12, 4);
  output('RGB foreground and indexed background', utf8('\r\n\x1b[38;2;11;22;33;48;5;44minfo\x1b[0m'));
  output('Alternate row before clipping', utf8('\x1b[?1049h\x1b[Hleft + right'));
  resize(6, 4);
  resize(12, 4);
  output('Restore normal after clipping', utf8('\x1b[?1049l'));
  output('Begin unknown OSC', utf8('\x1b]777;'), false);
  output('Ignore long OSC payload', Buffer.alloc(16_384, 120), false);
  output('Split ST before its final byte', utf8('\x1b'), false);
  output('Recover from OSC at ST', utf8('\\ok\x1b[6n'));
  output('Partial malformed UTF-8', [0xe2,0x82], false);
  output('ASCII after malformed prefix', utf8('Z\x1b[6n'));
  const action = (kind, value) => append(kind+' '+value, {action:{kind,value}});
  for (const key of ['up','left','right','down','escape','tab','backspace','enter']) action('key',key);
  action('paste','a\nb');
  output('Editor input modes', utf8('\x1b[?1h\x1b[?2004h\x1b[?1004h\x1b[?25l\x1b[?12h'));
  for (const key of ['up','left','right','down']) action('key',key);
  action('paste','a\nb');
  output('Shell input modes', utf8('\x1b[?1l\x1b[?2004l\x1b[?1004l\x1b[?25h\x1b[?12l\x1b[6n'));
  resize(5, 5);
  output('Wide cells on the active wrapped line', utf8('\x1b[2J\x1b[Habc中DEF中ghi'));
  resize(4, 5);
  output('Commit the clipped log line', utf8('\r\n'));
  resize(8, 5);
  return {name:'shell-edges', columns:1, rows:2, events};
}
const keyCodes = {up:38,left:37,right:39,down:40,escape:27,tab:9,backspace:8,enter:13};
function encodedInput(t, action) {
  switch (action.kind) {
    case 'text': return utf8(action.value);
    case 'paste': return utf8(bracketTextForPaste(prepareTextForTerminal(action.value), t.modes.bracketedPasteMode));
    case 'key': {
      const key = evaluateKeyboardEvent({ keyCode:keyCodes[action.value] }, t.modes.applicationCursorKeysMode, true, false).key;
      assert.equal(typeof key, 'string');
      return utf8(key);
    }
    default: throw Error('Unknown input ' + action.kind);
  }
}
async function generate(name) {
  const captureBytes = ['shell-edges','prompt-bom'].includes(name) ? null : await readFile(new URL(name+'.capture.json', import.meta.url));
  const recording = captureBytes ? JSON.parse(captureBytes) : name === 'prompt-bom'
    ? {name, columns:80, rows:24, events:[{name:'BOM before shell prompt',offsetMicroseconds:0,
        bytes:base64(Buffer.concat([Buffer.from([0xef,0xbb,0xbf]),utf8('thrush$ \x1b[6n')])),checkpoint:true}]}
    : shellEdges();
  const t = terminal(recording.columns, recording.rows);
  const cells = new Pool(), lines = new Pool();
  assert.equal(cells.get({text:'',width:1,flags:0,foreground:-1,background:-1}), 0);
  let replies;
  t.onData(value => replies.push(utf8(value)));
  const events = [];
  const fullHistory = new Set([
    'Full normal history', 'Full normal history before desktop resize', 'Full history before alternate screen'
  ]);
  for (const source of recording.events) {
    const event = {...source};
    if (events.length) assert(event.offsetMicroseconds >= events.at(-1).offsetMicroseconds);
    if (event.resize) {
      event.normalHistoryRowsBefore = t.buffer.normal.baseY;
      event.historyRowsBefore = t.buffer.active.baseY;
      if (name === 'shell-log' && t.buffer.active.type === 'normal') {
        assert.equal(t.buffer.normal.baseY, 1000, 'Full history before normal resize to ' + JSON.stringify(event.resize));
      }
      t.resize(event.resize.columns,event.resize.rows);
    }
    replies = [];
    if (event.bytes) await write(t, Buffer.from(event.bytes,'base64'));
    const reply = base64(Buffer.concat(replies));
    if (captureBytes) assert.equal(reply, event.observedReply ?? '', event.name + ' live PTY reply');
    if (reply) event.reply = reply;
    delete event.observedReply;
    if (event.action) {
      const encoded = base64(encodedInput(t,event.action));
      if (event.input) assert.equal(encoded, event.input, event.name);
      event.input = encoded;
    }
    if (event.checkpoint) {
      event.checkpoint = checkpoint(t,cells,lines);
      if (name === 'shell-log' && fullHistory.delete(event.name)) {
        assert.equal(event.checkpoint.isAlternate, false, event.name);
        assert.equal(event.checkpoint.history.length, 1000, event.name);
      }
    }
    else delete event.checkpoint;
    events.push(event);
  }
  if (name === 'shell-log') assert.equal(fullHistory.size, 0, 'Missing full-history checkpoint');
  t.dispose();
  const json = {version:1, name, reference, captureSHA256:captureBytes ? sha256(captureBytes) : undefined,
    columns:recording.columns,rows:recording.rows,cells:cells.values,lines:lines.values,events};
  // Keep each checkpoint or recorded read on its own line to make diffs reviewable.
  const { cells:cellList, lines:rowList, events:eventList, ...header } = json;
  const linesOf = array => array.map(value => JSON.stringify(value)).join(',\n');
  const data = JSON.stringify(header).slice(0,-1)
    + ',\n"cells":[\n' + linesOf(cellList) + '\n],\n"lines":[\n' + linesOf(rowList)
    + '\n],\n"events":[\n' + linesOf(eventList) + '\n]}\n';
  await writeFile(new URL('../../replays/'+name+'.json',import.meta.url),data);
  console.log(name, events.length, sha256(data));
}
for (const name of ['shell-log', 'vim-edit', 'shell-edges', 'prompt-bom']) await generate(name);

// Validate the benchmark's sustained, directly generated ASCII workload.
const line = 'abcdefghij'.repeat(8).slice(0,78);
const bulk = utf8((line+'\r\n').repeat(13_108));
assert.equal(bulk.length, 1_048_640);
for (const [columns, rows] of [[80,24],[40,32],[80,14]]) {
  const t = terminal(columns, rows), replies = [];
  t.onData(value => replies.push(value));
  for (let i=0; i<bulk.length; i+=4096) await write(t,bulk.subarray(i,i+4096));
  await write(t,'\x1b[6n');
  const b=t.buffer.active, prior=b.getLine(b.baseY+rows-2);
  assert.equal(b.baseY,1000);
  assert.equal(prior.translateToString(true),columns===40?line.slice(40):line);
  assert.equal(prior.isWrapped,columns===40);
  assert.equal(b.getLine(b.baseY+rows-1).translateToString(true),'');
  assert.deepEqual(replies,['\x1b['+rows+';1R']);
  t.dispose();
}
