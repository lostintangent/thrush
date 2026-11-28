// Rebuild reference states from the recorded PTY events. See shell-and-vim/README.md.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { applyPalette, reference as pinned, source, terminal, write } from './reference.mjs';
import { Pool as StatePool, pack } from './conformance/state.mjs';
import { state } from './conformance/xterm.mjs';
import { pointerInput, encodePointer } from './workflows/pointer.mjs';
import { hardwareKeys } from './workflows/hardware-keys.mjs';

const { evaluateKeyboardEvent } = await source('common/input/Keyboard');
const { bracketTextForPaste, prepareTextForTerminal } = await source('browser/Clipboard');
// Every terminal answers color queries with the browser package's own report handler and theme service.
const reference = {...pinned, colorReports:'@xterm/xterm CoreBrowserTerminal._handleColorEvent and ThemeService'};
const utf8 = s => Buffer.from(s, 'utf8');
const base64 = bytes => Buffer.from(bytes).toString('base64');
const focusReports = new Set(['\x1b[I', '\x1b[O']);
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
async function shellEdges() {
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
  output('SGR with indexed and RGB subparameters', utf8('\r\n\x1b[38:5:44;48:2::10:20:30;1mA\x1b[38:7:1;92;22mB\x1b[0m'));
  resize(8, 3);
  output('Erase the line through the cursor', utf8('\x1b[2J\x1b[Habove\r\nabcdef\x1b[2;3H\x1b[44m\x1b[1K\x1b[0m'));
  output('Erase the display through the cursor', utf8('\x1b[3;1Huvwxyz\x1b[3;3H\x1b[41m\x1b[1J\x1b[0m'));
  // Replay the recorded Readline session on a clean viewport at its actual PTY size.
  const capture = await readFile(new URL('shell-and-vim/bash-display.capture.json', import.meta.url));
  const display = JSON.parse(capture);
  resize(display.columns, display.rows);
  output('Clear viewport for Bash', utf8('\x1b[2J\x1b[H'));
  const offset = events.at(-1).offsetMicroseconds;
  for (const event of display.events) {
    events.push({...event, offsetMicroseconds:offset + event.offsetMicroseconds,
      reply:event.reply ?? ''});
  }
  return {name:'shell-edges', columns:1, rows:2, events, captureSHA256:sha256(capture)};
}
// A short shell transcript whose reads split a mode, a query, a UTF-8 scalar and a string terminator.
// The offsets are its delivery schedule, in microseconds from attach.
function firstBytes() {
  const events = [];
  const output = (offsetMicroseconds, name, bytes, pressUp = false) => {
    events.push({name, offsetMicroseconds, bytes:base64(typeof bytes === 'string' ? utf8(bytes) : bytes), checkpoint:true});
    if (pressUp) events.push({name:'Press Up', offsetMicroseconds, action:{kind:'key', value:'up'}});
  };
  output(0, 'Shell prompt', 'thrush$ ', true);
  output(2000, 'Begin cursor mode', '\x1b[?1');
  output(2200, 'Enable cursor mode', 'h', true);
  output(4000, 'Begin cursor query', '\x1b[6');
  output(5000, 'Answer cursor query', 'n');
  output(6000, 'Disable cursor mode', '\x1b[?1l', true);
  output(8000, 'Colored output', '\r\n\x1b[32mcaf');
  output(8100, 'Begin UTF-8 scalar', [0xc3]);
  output(8200, 'Finish UTF-8 scalar', [0xa9, ...utf8('\x1b[0m')]);
  output(9000, 'Backspace and overwrite', 'x\b!');
  output(10000, 'Unknown CSI and OSC', '\x1b[999z\x1b]777;hidden');
  output(10200, 'Begin string terminator', '\x1b');
  output(10400, 'Finish string and query', '\\>\x1b[6n');
  output(12000, 'Carriage return', '\rC');
  output(13000, 'Line feed and query', '\n$ \x1b[6n');
  return {name:'first-bytes', columns:80, rows:24, events};
}
const keyCodes = {up:38,left:37,right:39,down:40,escape:27,tab:9,backspace:8,enter:13,
  home:36,end:35,pageUp:33,pageDown:34,delete:46,'[':219,'\\':220,']':221};
// The reference doesn't know the kitty keyboard protocol, which Codex pushes flags for. Thrush keeps
// each screen's flags, answers the query and reports keys the way the program asked, as
// Tests/ThrushConformanceTests/ReferenceDefects.json records, so the recordings carry what Thrush sends.
const keyReports = {escape:27, enter:13, tab:9, backspace:127};
const keyboardReply = /^\x1b\[\?\d+u$/;
function keyboardFlags(t, reply) {
  let stacks = {normal:[], alternate:[]};
  const stack = () => stacks[t.buffer.active.type];
  const flags = () => stack().at(-1) ?? 0;
  const csi = (prefix, handler) => t.parser.registerCsiHandler({prefix, final:'u'}, params => (handler(params[0] || 0), true));
  csi('>', pushed => stack().push(pushed & 5) > 8 && stack().shift());
  csi('<', count => stack().splice(-Math.max(count, 1)));
  csi('=', () => assert.fail('Set keyboard flags when a recording sends CSI = u'));
  csi('?', () => reply(`\x1b[?${flags()}u`));
  const reset = () => (stacks = {normal:[], alternate:[]}, false);
  t.parser.registerEscHandler({final:'c'}, reset);
  t.parser.registerCsiHandler({intermediates:'!', final:'p'}, reset);
  return flags;
}
function encodedInput(t, action, flags = 0) {
  switch (action.kind) {
    case 'pointer': return encodePointer(t, action);
    case 'text': return utf8(action.value);
    case 'paste': return utf8(bracketTextForPaste(prepareTextForTerminal(action.value), t.modes.bracketedPasteMode));
    case 'key': {
      const key = action.value;
      const modifiers = new Set(action.modifiers);
      const keyCode = keyCodes[key] ?? (key.length === 1 ? key.toUpperCase().charCodeAt(0) : undefined);
      assert.notEqual(keyCode, undefined, 'Unknown recorded key ' + key);
      assert(flags === 0 || flags & 1, 'Report keys under alternate keys alone when a recording needs it');
      if (flags) {
        // Escape and chords that would send a control character report as CSI u.
        const code = keyReports[key] ?? (key.length === 1 ? key.codePointAt(0) : undefined);
        const bits = modifiers.has('shift') + 2 * modifiers.has('alt') + 4 * modifiers.has('control');
        if (code !== undefined && (key === 'escape' || bits & 6 || bits && keyReports[key])) {
          assert(!(bits & 1) || keyReports[key], 'Report the shifted key when a recording sends ' + key);
          return utf8(`\x1b[${code}${bits ? ';' + (bits + 1) : ''}u`);
        }
      }
      // Under keyboard flags, cursor keys report the same way in either cursor key mode.
      const result = evaluateKeyboardEvent({keyCode, key, altKey:modifiers.has('alt'),
        shiftKey:modifiers.has('shift'), ctrlKey:modifiers.has('control'), metaKey:false},
        t.modes.applicationCursorKeysMode && !flags, true, false);
      if (result.key === undefined && !action.modifiers?.length && key.length === 1) return utf8(key);
      // Local viewport commands such as Shift+PageUp have no outbound bytes.
      return utf8(result.key ?? '');
    }
    default: throw Error('Unknown input ' + action.kind);
  }
}
// Verify each renderer handoff can start from a clean grid at the requested size.
// Palette, stored cell styles, wrap flags and cursor come from the pinned emulator.
async function verifyStyledPaints(recording, events, cells, lines) {
  for (const [file, field] of [['Prompt.swift','sourceSHA256'], ['styled.vim','vimrcSHA256']]) {
    const bytes = await readFile(new URL('styled-vim/' + file, import.meta.url));
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
    const clean = terminal(...expected.size);
    applyPalette(clean, palette);
    for (const chunk of chunks) await write(clean, chunk);
    const painted = pack(state(clean, event.name, 'visible', ''), {cells, lines});
    assert.deepEqual(painted.active.visible, expected.active.visible, event.name + ' independent paint');
    assert.deepEqual(painted.cursor, expected.cursor);
    clean.dispose();
    chunks = [];
  }
}
// The host palette and Vim's replies, Vim's stock syntax groups sampled by token, and the text both
// appearances share.
const styledText = {};
function verifyHighlighting(theme, events, cells, lines) {
  const [foreground, background, gutter, comment, keyword, identifier, bold] = {
    dark: ['#e3eaf0', '#131d27', 11, 14, 81, 14, true], light: ['#233442', '#fbfdfe', 130, 4, 5, 6, false],
  }[theme];
  const palette = events.slice(0, events.findIndex(e => e.bytes) + 1).find(e => e.palette).palette;
  assert.deepEqual([palette.foreground.toLowerCase(), palette.background.toLowerCase()], [foreground, background]);
  const replies = Buffer.concat(events.map(e => Buffer.from(e.reply ?? '', 'base64'))).toString('latin1');
  for (const [command, color] of [[10, foreground], [11, background]]) {
    const rgb = [1, 3, 5].map(i => color.slice(i, i + 2).repeat(2)).join('/');
    assert(replies.includes(`\x1b]${command};rgb:${rgb}\x1b\\`), `${theme} OSC ${command} reply`);
  }

  // Each cell is [text, width, style], and a row omits its trailing blank cells.
  const color = ([, , style]) => Number(/(?:^| )fg=(\d+)/.exec(style)?.[1] ?? -1);
  const has = ([, , style], attribute) => style.split(' ').includes(attribute);
  const frames = {};
  for (const {name, checkpoint} of events.filter(e => e.name.startsWith('Styled Swift '))) {
    assert(checkpoint.buffer === 'alternate' && !frames[name], name);
    frames[name] = checkpoint.active.visible.map(id => {
      const [, ...stored] = lines.values[id].map(id => cells.values[id]);
      const text = stored.map(([text, width]) => width ? text || ' ' : '').join('');
      return {text, row: [...stored, ...Array(checkpoint.size[0] - stored.length).fill(['', 1, ''])]};
    });
  }
  assert.deepEqual(Object.entries(frames).map(([name, rows]) => [name, rows[0].row.length, rows.length]),
    [['Styled Swift buffer', 80, 24], ['Styled Swift portrait', 45, 18], ['Styled Swift landscape', 71, 11]]);

  const numbered = new Map(), numbers = [];
  for (const {text, row} of frames['Styled Swift buffer']) {
    const match = /^ *([0-9]+) (.*)$/.exec(text);
    if (!match) continue;
    numbers.push(Number(match[1]));
    assert.equal(color(row[text.indexOf(match[1])]), gutter, `${theme} line number`);
    numbered.set(match[2].trim(), {text, row});
  }
  assert.deepEqual(numbers, numbers.map((_, i) => i + 1), `${theme} sequential Swift line numbers`);
  assert(numbered.has(String.raw`return "\(cwd) \(mark) "`) && numbered.has('let mark = isRoot ? "#" : "$"'));
  for (const [source, token, expected] of [['// Format the current shell prompt.', '//', comment],
    ['struct Prompt {', 'struct', keyword], ['let width = 24', 'width', identifier]]) {
    const {text, row} = numbered.get(source);
    const span = row.slice(text.indexOf(token), text.indexOf(token) + token.length);
    assert.equal(span.map(([text]) => text).join(''), token);
    assert(span.every(cell => color(cell) === expected), `${theme} ${token} foreground`);
    if (token === 'width') assert(span.every(cell => has(cell, 'bold') === bold), `${theme} Swift binding weight`);
  }

  for (const rows of Object.values(frames)) {
    const status = rows.filter(({text}) => /^ *Prompt\.swift +\d+:\d+ *$/.test(text));
    assert.equal(status.length, 1, `${theme} Swift file status`);
    const start = status[0].text.indexOf('Prompt.swift');
    assert(status[0].row.slice(start, start + 'Prompt.swift'.length).every(cell => has(cell, 'inverse')), `${theme} status reverse`);
  }
  const glyphs = Object.values(frames).flat().flatMap(({row}) => row).filter(([text]) => text.trim());
  assert(glyphs.some(cell => color(cell) >= 0 && color(cell) < 16), `${theme} ANSI syntax colors`);
  assert(glyphs.some(cell => color(cell) >= 16), `${theme} extended indexed colors`);
  assert(glyphs.some(cell => has(cell, 'bold')), `${theme} bold glyphs`);

  styledText[theme] = Object.values(frames).map(rows => rows.map(({text}) => text));
  if (styledText.dark && styledText.light) assert.deepEqual(styledText.dark, styledText.light, 'Both appearances show the same text');
}

async function generate(path) {
  const name = path.replace(/^phone\//, '');
  const directory = workflows.includes(name) ? 'workflows/' : name.startsWith('vim-swift-') ? 'styled-vim/' : 'shell-and-vim/';
  const capture = name === 'zsh-clear' ? 'conformance/programs/zsh-clear.capture.json' : directory + path + '.capture.json';
  const captureBytes = ['first-bytes','shell-edges','prompt-bom','hardware-keys','pointer-input'].includes(name) ? null
    : await readFile(new URL(capture, import.meta.url));
  const recording = captureBytes ? JSON.parse(captureBytes) : name === 'prompt-bom'
    ? {name, columns:80, rows:24, events:[{name:'BOM before shell prompt',offsetMicroseconds:0,
        bytes:base64(Buffer.concat([Buffer.from([0xef,0xbb,0xbf]),utf8('thrush$ \x1b[6n')])),checkpoint:true}]}
    : name === 'first-bytes' ? firstBytes() : name === 'pointer-input' ? pointerInput()
    : name === 'hardware-keys' ? hardwareKeys() : await shellEdges();
  let replies, keyboard, predatesFlags = false;
  const open = (columns, rows) => {
    const t = terminal(columns, rows);
    t.onData(value => replies.push(utf8(value)));
    keyboard = keyboardFlags(t, value => replies.push(utf8(value)));
    return t;
  };
  let t = open(recording.columns, recording.rows);
  let palette;
  const cells = new StatePool(), lines = new StatePool();
  const events = [];
  const fullHistory = new Set([
    'Full normal history', 'Full normal history before desktop resize', 'Full history before alternate screen'
  ]);
  for (const source of recording.events) {
    const event = {...source};
    if (events.length) assert(event.offsetMicroseconds >= events.at(-1).offsetMicroseconds);
    if (event.lifecycle?.type === 'ready') {
      const {cols, rows} = t;
      t.dispose();
      t = open(cols, rows);
      if (palette) applyPalette(t, palette);
    }
    if (event.palette) {
      palette = event.palette;
      applyPalette(t, palette);
    }
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
    if (captureBytes || event.reply !== undefined) {
      // Programs in recordings that predate keyboard flags or focus reports never received them.
      const observed = event.reply ?? '';
      const keyboardless = replies.filter(value => !keyboardReply.test(value.toString()));
      const live = [replies, keyboardless, keyboardless.filter(value => !focusReports.has(value.toString()))]
        .map(sent => base64(Buffer.concat(sent))).find(sent => sent === observed) ?? reply;
      assert.equal(live, observed, event.name + ' live PTY reply');
      // A capture that never answered the keyboard query predates flags, so its keys sent the reference's bytes.
      if (keyboardless.length < replies.length) predatesFlags = live !== reply;
    }
    delete event.reply;
    if (reply) event.reply = reply;
    if (event.action) {
      const encoded = base64(encodedInput(t,event.action,keyboard()));
      const captured = predatesFlags ? base64(encodedInput(t,event.action)) : encoded;
      if (event.input) assert.equal(event.input, captured, event.name);
      event.input = encoded;
    }
    if (event.checkpoint) {
      // Each event carries its own replies, so the checkpoint leaves them out.
      const { replies: _, ...checkpoint } = pack(state(t, event.name, undefined, ''), {cells, lines});
      event.checkpoint = checkpoint;
      if (name === 'shell-log' && fullHistory.delete(event.name)) {
        assert.equal(event.checkpoint.buffer, 'normal', event.name);
        assert.equal(event.checkpoint.active.history.length, 1000, event.name);
      }
    }
    else delete event.checkpoint;
    events.push(event);
  }
  if (name === 'shell-log') assert.equal(fullHistory.size, 0, 'Missing full-history checkpoint');
  if (name.startsWith('vim-swift-')) {
    await verifyStyledPaints(recording, events, cells, lines);
    verifyHighlighting(recording.vimBackground, events, cells, lines);
  }
  t.dispose();
  // The Vim resume checkpoints come from the reference like every other recording. Only its reattachment
  // frame comes from a server's serializer, which workflows/README.md records.
  const overlay = recording.overlay;
  const vimReplay = name === 'vim-resume' ? {sourceCaptureSHA256:overlay.sourceCaptureSHA256,
    serializedSHA256:overlay.serializedSHA256} : undefined;
  const json = {version:1, name, reference, captureSHA256:captureBytes ? sha256(captureBytes) : recording.captureSHA256, vimReplay,
    vimBackground:recording.vimBackground, columns:recording.columns,rows:recording.rows,cells:cells.values,lines:lines.values,events};
  // Keep each checkpoint or recorded read on its own line to make diffs reviewable.
  const { cells:cellList, lines:rowList, events:eventList, ...header } = json;
  const linesOf = array => array.map(value => JSON.stringify(value)).join(',\n');
  const data = JSON.stringify(header).slice(0,-1)
    + ',\n"cells":[\n' + linesOf(cellList) + '\n],\n"lines":[\n' + linesOf(rowList)
    + '\n],\n"events":[\n' + linesOf(eventList) + '\n]}\n';
  await writeFile(new URL('../recordings/'+path+'.json',import.meta.url),data);
  console.log(path, events.length, sha256(data));
}
const workflows = ['shell-workflow', 'vim-resume', 'codex-session'];
const all = ['first-bytes', 'shell-log', 'vim-edit', 'shell-edges', 'prompt-bom', 'vim-swift-dark', 'vim-swift-light', 'hardware-keys','pointer-input', 'zsh-clear', ...workflows,
  'phone/vim-resume'];
const requested = process.argv.slice(2);
for (const path of requested.length ? requested : all) {
  assert(all.includes(path), 'Unknown recording: ' + path);
  await generate(path);
}

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
