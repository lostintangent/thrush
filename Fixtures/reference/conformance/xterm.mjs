// The conformance view of the pinned reference: cases replay through it, and every checkpoint reads
// its state the same way. See ../reference.mjs for the reference itself.
import { terminal } from '../reference.mjs';
import { functionName } from './names.mjs';
import { emptyLine } from './state.mjs';

export { reference as description } from '../reference.mjs';

const mouseTracking = { none: 'off', x10: 'x10', vt200: 'press', drag: 'drag', any: 'all' };
const mouseEncoding = { DEFAULT: 'default', SGR: 'sgr', SGR_PIXELS: 'sgrPixels' };

export function create([columns, rows], palette) {
  const t = terminal(columns, rows, palette);
  t.options.logLevel = 'off'; // Malformed input is part of the corpus, and logging changes nothing else.
  return t;
}

/** Every handler identity the reference registers, such as `csi ?h` or `osc 4`, for coverage. */
export function registered() {
  const t = create([10, 4]);
  const parser = t._core._inputHandler._parser;
  const ids = handlers => Object.keys(handlers).map(key => parser.identToString(Number(key)));
  const result = [
    ...Object.keys(parser._executeHandlers).map(code => `execute ${code}`),
    ...ids(parser._escHandlers).map(identity => `esc ${identity}`),
    ...ids(parser._csiHandlers).map(identity => `csi ${identity}`),
    ...Object.keys(parser._oscParser._handlers).map(id => `osc ${id}`),
    ...ids(parser._dcsParser._handlers).map(identity => `dcs ${identity}`),
  ];
  t.dispose();
  return result;
}

/**
 * Runs a case: { size, palette?, steps: [{ write: Uint8Array } | { resize: [columns, rows] } |
 * { checkpoint: name, scope?: 'visible' }] }. A final checkpoint named "end" is implied.
 * With `observe`, each write also returns the names of the functions xterm dispatched, and the run
 * returns every handler identity it reached, for coverage.
 *
 * Writes go through xterm's synchronous write path, which runs the same parser action as `write`
 * without a timer per chunk. A write that throws inside xterm is a reference defect: the run records
 * the error on the next checkpoint and continues with whatever state xterm was left in.
 */
export function run(testCase, { observe = false } = {}) {
  const t = create(testCase.size, testCase.palette);
  let replies = '', error;
  t.onData(data => replies += Buffer.from(data, 'utf8').toString('latin1'));
  t.onBinary(data => replies += data);
  const observer = observe ? instrument(t) : undefined;
  const writes = t._core._writeBuffer;
  const checkpoints = [], functions = [];
  const steps = testCase.steps.at(-1)?.checkpoint === 'end' ? testCase.steps : [...testCase.steps, { checkpoint: 'end' }];
  for (const step of steps) {
    if (step.write) {
      try {
        writes.writeSync(step.write);
      } catch (thrown) {
        error ??= `${thrown.name}: ${thrown.message}`;
        writes._isSyncWriting = false;
        writes._writeBuffer.length = 0;
        writes._callbacks.length = 0;
      }
      if (observer) functions.push(observer.names.splice(0));
    } else if (step.resize) {
      t.resize(...step.resize);
    } else if (step.checkpoint) {
      checkpoints.push({ ...state(t, step.checkpoint, step.scope, replies), ...(error && { error }) });
      replies = '';
      error = undefined;
    }
  }
  t.dispose();
  return observe ? { checkpoints, functions, identities: observer.identities } : checkpoints;
}

// Count dispatches from xterm's own parser: each observer runs first and declines, so the real handler still runs.
function instrument(t) {
  const names = [], identities = new Set();
  const parser = t._core._inputHandler._parser;
  const record = (kind, identity, parameters) => {
    identities.add(`${kind} ${identity}`);
    names.push(...functionName(kind, identity, parameters));
    return false;
  };
  for (const [code, handler] of Object.entries(parser._executeHandlers)) {
    parser._executeHandlers[code] = () => { record('execute', Number(code)); return handler(); };
  }
  const executeFallback = parser._executeHandlerFb;
  parser._executeHandlerFb = code => { record('execute', code); return executeFallback(code); };
  for (const [key, handlers] of Object.entries(parser._escHandlers)) {
    const identity = parser.identToString(Number(key));
    handlers.push(() => record('esc', identity));
  }
  const escFallback = parser._escHandlerFb;
  parser._escHandlerFb = key => { record('esc', parser.identToString(key)); return escFallback(key); };
  for (const [key, handlers] of Object.entries(parser._csiHandlers)) {
    const identity = parser.identToString(Number(key));
    handlers.push(parameters => record('csi', identity, parameters.toArray()));
  }
  const csiFallback = parser._csiHandlerFb;
  parser._csiHandlerFb = (key, parameters) => { record('csi', parser.identToString(key), parameters.toArray()); return csiFallback(key, parameters); };
  for (const id of Object.keys(parser._oscParser._handlers)) {
    t.parser.registerOscHandler(Number(id), data => record('osc', Number(id), data));
  }
  const osc = parser._oscParser, oscFallback = osc._handlerFb;
  let payload = '';
  osc._handlerFb = (id, action, data) => {
    if (action === 'START') payload = '';
    else if (action === 'PUT') payload += data;
    else record('osc', id, payload);
    return oscFallback(id, action, data);
  };
  t.parser.registerDcsHandler({ intermediates: '$', final: 'q' }, () => record('dcs', '$q'));
  const dcs = parser._dcsParser, dcsFallback = dcs._handlerFb;
  dcs._handlerFb = (key, action, data) => {
    if (action === 'HOOK') record('dcs', parser.identToString(key));
    return dcsFallback(key, action, data);
  };
  return { names, identities };
}

function color(mode, value, kind) {
  if (mode === 0) return undefined;
  if (mode === 0x3000000) return `${kind}=#${value.toString(16).padStart(6, '0')}`;
  return `${kind}=${value}`;
}

function style(cell) {
  const parts = [color(cell.getFgColorMode(), cell.getFgColor(), 'fg'), color(cell.getBgColorMode(), cell.getBgColor(), 'bg')];
  if (cell.isBold()) parts.push('bold');
  if (cell.isDim()) parts.push('dim');
  if (cell.isItalic()) parts.push('italic');
  if (cell.isUnderline()) {
    const kind = cell.getUnderlineStyle();
    parts.push(kind > 1 ? `underline=${kind}` : 'underline');
    if (!cell.isUnderlineColorDefault()) parts.push(color(cell.getUnderlineColorMode(), cell.getUnderlineColor(), 'underlineColor'));
  }
  if (cell.isBlink()) parts.push('blink');
  if (cell.isInverse()) parts.push('inverse');
  if (cell.isInvisible()) parts.push('invisible');
  if (cell.isStrikethrough()) parts.push('strikethrough');
  if (cell.isOverline()) parts.push('overline');
  return parts.filter(Boolean).join(' ');
}

function line(bufferLine, columns, scratch) {
  const cells = [];
  for (let column = 0; column < columns; column++) {
    const cell = bufferLine.getCell(column, scratch);
    cells.push([cell.getChars(), cell.getWidth(), style(cell)]);
  }
  while (cells.length && emptyLine.isBlank(cells.at(-1))) cells.pop();
  return { wrapped: bufferLine.isWrapped, cells };
}

function screen(t, buffer, withHistory) {
  const scratch = buffer.getNullCell();
  const lines = (start, count) => Array.from({ length: count }, (_, row) => line(buffer.getLine(start + row), t.cols, scratch));
  return { ...(withHistory && { history: lines(0, buffer.baseY) }), visible: lines(buffer.baseY, t.rows) };
}

/** The canonical checkpoint. See state.mjs. */
export function state(t, name, scope, replies) {
  const core = t._core, modes = t.modes, dec = core.coreService.decPrivateModes;
  const buffer = t.buffer.active;
  const alternate = buffer.type === 'alternate';
  const full = scope !== 'visible';
  return {
    name,
    size: [t.cols, t.rows],
    cursor: {
      row: buffer.cursorY, column: buffer.cursorX, visible: !core.coreService.isCursorHidden,
      shape: dec.cursorStyle ?? t.options.cursorStyle, blink: dec.cursorBlink ?? t.options.cursorBlink,
    },
    buffer: alternate ? 'alternate' : 'normal',
    modes: {
      applicationCursorKeys: modes.applicationCursorKeysMode, applicationKeypad: modes.applicationKeypadMode,
      bracketedPaste: modes.bracketedPasteMode, insert: modes.insertMode, origin: modes.originMode,
      wraparound: modes.wraparoundMode, reverseWraparound: modes.reverseWraparoundMode,
      cursorBlink: t.options.cursorBlink, sendFocus: modes.sendFocusMode, synchronizedOutput: modes.synchronizedOutputMode,
      mouseTracking: mouseTracking[modes.mouseTrackingMode], mouseEncoding: mouseEncoding[core.coreMouseService.activeEncoding],
    },
    title: core._inputHandler._windowTitle,
    replies,
    active: screen(t, buffer, full),
    ...(alternate && full && { normal: screen(t, t.buffer.normal, true) }),
  };
}
