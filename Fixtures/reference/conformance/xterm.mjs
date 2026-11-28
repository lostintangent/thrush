// The conformance view of the pinned reference: cases replay through it, and every checkpoint reads
// its state the same way. See ../reference.mjs for the reference itself.
import { setFocus, terminal } from '../reference.mjs';
import { withEnd } from './state.mjs';

const mouseTracking = { none: 'off', x10: 'x10', vt200: 'press', drag: 'drag', any: 'all' };
const mouseEncoding = { DEFAULT: 'default', SGR: 'sgr', SGR_PIXELS: 'sgrPixels' };

/** A reference terminal for a case. */
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
 * { focus: boolean } | { checkpoint: name, scope?: 'visible' }] }. A final checkpoint named "end" is implied.
 * With `observe`, the run also returns every handler identity it reached, for coverage.
 *
 * Writes go through xterm's synchronous write path, which runs the same parser action as `write`
 * without a timer per chunk. A write that throws inside xterm is a reference defect: the run records
 * the error on the next checkpoint and continues with whatever state xterm was left in.
 */
export function run(testCase, { observe = false } = {}) {
  const t = create(testCase.size, testCase.palette);
  const replies = collect(t);
  let error;
  const identities = observe ? instrument(t) : undefined;
  const checkpoints = [];
  for (const step of withEnd(testCase.steps)) {
    if (step.checkpoint) {
      checkpoints.push({ ...state(t, step.checkpoint, step.scope, replies()), ...(error && { error }) });
      error = undefined;
      continue;
    }
    error ??= perform(t, step);
  }
  t.dispose();
  return observe ? { checkpoints, identities } : checkpoints;
}

/** Applies a write, resize or focus step, and returns what xterm threw, if anything. */
export function perform(t, step) {
  if (step.write) return write(t, step.write);
  if (step.resize) t.resize(...step.resize);
  else if (step.focus !== undefined) setFocus(t, step.focus);
}

/** Writes through xterm's synchronous write path, and returns what xterm threw, if anything. */
function write(t, bytes) {
  const writes = t._core._writeBuffer;
  try {
    writes.writeSync(bytes);
  } catch (thrown) {
    writes._isSyncWriting = false;
    writes._writeBuffer.length = 0;
    writes._callbacks.length = 0;
    return `${thrown.name}: ${thrown.message}`;
  }
}

/** Collects what the terminal sends back, and returns a function that takes it, one character per byte. */
export function collect(t) {
  let replies = '';
  t.onData(data => replies += Buffer.from(data, 'utf8').toString('latin1'));
  t.onBinary(data => replies += data);
  return () => { const taken = replies; replies = ''; return taken; };
}

// Record which registered handlers run. Each observer runs first and declines, so the real handler still runs.
function instrument(t) {
  const identities = new Set();
  const parser = t._core._inputHandler._parser;
  const reach = identity => { identities.add(identity); return false; };
  for (const [code, handler] of Object.entries(parser._executeHandlers)) {
    parser._executeHandlers[code] = () => { reach(`execute ${code}`); return handler(); };
  }
  for (const [kind, handlers] of [['esc', parser._escHandlers], ['csi', parser._csiHandlers]]) {
    for (const [key, list] of Object.entries(handlers)) {
      const identity = `${kind} ${parser.identToString(Number(key))}`;
      list.push(() => reach(identity));
    }
  }
  for (const id of Object.keys(parser._oscParser._handlers)) t.parser.registerOscHandler(Number(id), () => reach(`osc ${id}`));
  t.parser.registerDcsHandler({ intermediates: '$', final: 'q' }, () => reach('dcs $q'));
  return identities;
}

function color(mode, value, kind) {
  if (mode === 0) return undefined;
  if (mode === 0x3000000) return `${kind}=#${value.toString(16).padStart(6, '0')}`;
  return `${kind}=${value}`;
}

// The reference's cell flags. A cell's extended attributes hold its underline style, underline color
// and link, and are only its own while it has the extended flag.
const UNDERLINE = 0x10000000, HAS_EXTENDED = 0x10000000, COLOR_MODE = 0x3000000, COLOR = 0xffffff;

// Without extended attributes, a cell's style depends only on its two attribute words, so each pair is
// described once.
const styles = new Map();

function style(cell, links) {
  if (cell.bg & HAS_EXTENDED) return describe(cell, links);
  let byBackground = styles.get(cell.fg);
  if (!byBackground) styles.set(cell.fg, byBackground = new Map());
  let described = byBackground.get(cell.bg);
  if (described === undefined) byBackground.set(cell.bg, described = describe(cell, links));
  return described;
}

function describe(cell, links) {
  const parts = [color(cell.getFgColorMode(), cell.getFgColor(), 'fg'), color(cell.getBgColorMode(), cell.getBgColor(), 'bg')];
  if (cell.isBold()) parts.push('bold');
  if (cell.isDim()) parts.push('dim');
  if (cell.isItalic()) parts.push('italic');
  // The style getters report a link as a dashed underline, so read the underline the program chose.
  const extended = cell.bg & HAS_EXTENDED ? cell.extended : undefined;
  const underline = cell.fg & UNDERLINE ? (extended ? extended._ext >> 26 & 7 : 1) : 0;
  if (underline) {
    parts.push(underline > 1 ? `underline=${underline}` : 'underline');
    // Like the color getters, a palette color is only the low byte.
    const underlineColor = extended?.underlineColor ?? 0, mode = underlineColor & COLOR_MODE;
    parts.push(color(mode, underlineColor & (mode === COLOR_MODE ? COLOR : 0xff), 'underlineColor'));
  }
  if (cell.isBlink()) parts.push('blink');
  if (cell.isInverse()) parts.push('inverse');
  if (cell.isInvisible()) parts.push('invisible');
  if (cell.isStrikethrough()) parts.push('strikethrough');
  if (cell.isOverline()) parts.push('overline');
  if (extended?.urlId) parts.push(`link=${links.number(extended.urlId)}`);
  return parts.filter(Boolean).join(' ');
}

/** Numbers links in the order they first appear, with each one's target as `id;uri`. */
class Links {
  targets = [];
  #numbers = new Map();
  constructor(core) { this.core = core; }
  number(urlId) {
    if (!this.#numbers.has(urlId)) {
      const link = this.core._oscLinkService.getLinkData(urlId);
      this.targets.push(`${link?.id ?? ''};${link?.uri ?? ''}`);
      this.#numbers.set(urlId, this.targets.length);
    }
    return this.#numbers.get(urlId);
  }
}

function line(bufferLine, columns, scratch, links) {
  const cells = [];
  for (let column = 0; column < columns; column++) {
    const cell = bufferLine.getCell(column, scratch);
    cells.push([cell.getChars(), cell.getWidth(), style(cell, links)]);
  }
  const blank = ([text, width, style]) => text === '' && width === 1 && style === '';
  while (cells.length && blank(cells.at(-1))) cells.pop();
  return { wrapped: bufferLine.isWrapped, cells };
}

function screen(t, buffer, withHistory, links) {
  const scratch = buffer.getNullCell();
  const lines = (start, count) => Array.from({ length: count }, (_, row) => line(buffer.getLine(start + row), t.cols, scratch, links));
  return { ...(withHistory && { history: lines(0, buffer.baseY) }), visible: lines(buffer.baseY, t.rows) };
}

/** The canonical checkpoint. See state.mjs. */
export function state(t, name, scope, replies) {
  const core = t._core, modes = t.modes, dec = core.coreService.decPrivateModes;
  const buffer = t.buffer.active;
  const alternate = buffer.type === 'alternate';
  const full = scope !== 'visible';
  const links = new Links(core);
  const active = screen(t, buffer, full, links);
  const normal = alternate && full ? screen(t, t.buffer.normal, true, links) : undefined;
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
      mouseTracking: mouseTracking[modes.mouseTrackingMode], mouseEncoding: mouseEncoding[(core.coreMouseService ?? core.mouseStateService).activeEncoding],
    },
    title: core._inputHandler._windowTitle,
    replies,
    active,
    ...(normal && { normal }),
    ...(links.targets.length && { links: links.targets }),
  };
}
