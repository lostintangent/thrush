// Rebuild reference states from the recorded PTY events. See README.md.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { applyPalette, reference, server, terminal, write } from './xterm-reference.mjs';

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
  // Match xterm's renderer: DECSCUSR overrides the option until the application resets it.
  const cursor = t._core.coreService.decPrivateModes;
  return {columns:t.cols, rows:t.rows, cursorRow:buffer.cursorY, cursorColumn:buffer.cursorX,
    cursorShape:cursor.cursorStyle ?? t.options.cursorStyle, cursorBlink:cursor.cursorBlink ?? t.options.cursorBlink,
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
  for (const [parameter, name] of [
    [1, 'Blinking block'], [2, 'Steady block'], [3, 'Blinking underline'],
    [4, 'Steady underline'], [5, 'Blinking bar'], [6, 'Steady bar'],
    [7, 'Unsupported odd cursor style'], [8, 'Unsupported even cursor style']
  ]) output(name, utf8('\x1b[' + parameter + ' q'));
  output('Enable default blink with an explicit steady cursor', utf8('\x1b[?12h\x1b[?12$p'));
  output('Restore cursor defaults with zero', utf8('\x1b[0 q'));
  output('Override the blinking default with steady underline', utf8('\x1b[4 q'));
  output('Restore cursor defaults with omitted parameter', utf8('\x1b[ q'));
  output('Restore steady shell cursor', utf8('\x1b[?12l'));
  resize(5, 5);
  output('Wide cells on the active wrapped line', utf8('\x1b[2J\x1b[Habc中DEF中ghi'));
  resize(4, 5);
  output('Commit the clipped log line', utf8('\r\n'));
  resize(8, 5);
  const osc = body => utf8('\x1b]' + body + '\x07');
  const ansiQuery = '4;' + Array.from({length:16}, (_, i) => i + ';?').join(';');
  output('Indexed text before host palette changes', utf8('\r\n\x1b[31;44mwarn\x1b[0m'));
  output('Default foreground and background', osc('10;?;?'));
  output('Default ANSI colors', osc(ansiQuery));
  output('Extended palette limits', osc('4;16;?;231;?;232;?;255;?'));
  output('Skip an out-of-range index between valid indexes', osc('4;1;?;256;?;15;?'));
  output('Ignore a nonnumeric index and unsupported color query', Buffer.concat([osc('4;no;?'), osc('13;?')]));
  output('Cancel foreground query before its terminator', utf8('\x1b]10;?\x18'));
  output('Cancel indexed query before its terminator', utf8('\x1b]4;1;?\x1a'));
  const custom = {
    foreground:'#d9e6f1', background:'#122434',
    ansi:['#091321','#a64152','#25835b','#b2832c','#4277aa','#98619b','#367d81','#acb8c2',
          '#566d7a','#db697a','#61b985','#d6ae52','#739cdd','#c68cc2','#71b8c4','#e6f1ff']
  };
  output('Begin foreground query before host changes the palette', utf8('\x1b]10;?'), false);
  append('Host applies custom palette and finishes the query', {palette:custom,bytes:base64([7]),checkpoint:true});
  output('Custom ANSI colors', osc(ansiQuery));
  output('Custom default background before split ST', utf8('\x1b]11;?'));
  output('Escape in custom background query terminator', utf8('\x1b'));
  output('Finish custom background query terminator', utf8('\\'));
  output('Custom foreground and background', osc('10;?;?'), false);
  const reversed = {foreground:custom.background, background:custom.foreground, ansi:[...custom.ansi].reverse()};
  append('Host reverses palette and queries both defaults', {
    palette:reversed, bytes:base64(osc('10;?;?')), checkpoint:true
  });
  output('Reversed ANSI colors', osc(ansiQuery));
  output('Extended colors with reversed ANSI palette', osc('4;16;?;231;?;232;?;255;?'));
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
// Verify each renderer handoff can start from a clean grid at the requested size.
// Palette, stored cell styles, wrap flags and cursor come from the pinned emulator.
async function verifyStyledPaints(recording, events, cells, lines) {
  for (const [file, field] of [['Prompt.swift','sourceSHA256'], ['styled.vim','vimrcSHA256']]) {
    const bytes = await readFile(new URL('../m3/' + file, import.meta.url));
    assert.equal(sha256(bytes), recording[field], file + ' differs from the captured input');
  }
  assert.equal(recording.vimBackground, recording.name.slice('vim-swift-'.length));
  assert.equal(recording.vimFiletype, 'swift');
  assert.equal(recording.vimSyntax, 'swift');
  assert.equal(recording.vimColorCount, 256);

  const palette = events.find(e => e.palette).palette;
  let chunks = [];
  for (const event of events) {
    if (event.bytes && (event.name === 'Paint Swift buffer' || event.name === 'Redraw after resize')) {
      chunks.push(Buffer.from(event.bytes, 'base64'));
    }
    if (!event.name.startsWith('Styled Swift ')) continue;
    const expected = event.checkpoint;
    const clean = terminal(expected.columns, expected.rows);
    applyPalette(clean, palette);
    for (const chunk of chunks) await write(clean, chunk);
    const painted = checkpoint(clean, cells, lines);
    assert.deepEqual(painted.visible, expected.visible, event.name + ' independent paint');
    assert.deepEqual([painted.cursorRow, painted.cursorColumn], [expected.cursorRow, expected.cursorColumn]);
    clean.dispose();
    chunks = [];
  }
}

async function generate(name) {
  const directory = name.startsWith('vim-swift-') ? '../m3/' : '';
  const captureBytes = ['shell-edges','prompt-bom'].includes(name) ? null
    : await readFile(new URL(directory + name + '.capture.json', import.meta.url));
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
    if (event.palette) applyPalette(t, event.palette);
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
  if (name.startsWith('vim-swift-')) await verifyStyledPaints(recording, events, cells, lines);
  t.dispose();
  const json = {version:1, name, reference, captureSHA256:captureBytes ? sha256(captureBytes) : undefined,
    vimBackground:recording.vimBackground, columns:recording.columns,rows:recording.rows,cells:cells.values,lines:lines.values,events};
  // Keep each checkpoint or recorded read on its own line to make diffs reviewable.
  const { cells:cellList, lines:rowList, events:eventList, ...header } = json;
  const linesOf = array => array.map(value => JSON.stringify(value)).join(',\n');
  const data = JSON.stringify(header).slice(0,-1)
    + ',\n"cells":[\n' + linesOf(cellList) + '\n],\n"lines":[\n' + linesOf(rowList)
    + '\n],\n"events":[\n' + linesOf(eventList) + '\n]}\n';
  await writeFile(new URL('../../replays/'+name+'.json',import.meta.url),data);
  console.log(name, events.length, sha256(data));
}
for (const name of ['shell-log', 'vim-edit', 'shell-edges', 'prompt-bom', 'vim-swift-dark', 'vim-swift-light']) await generate(name);

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
// The browser bundle retains its process-wide scheduler after terminal disposal.
process.exit(0);
