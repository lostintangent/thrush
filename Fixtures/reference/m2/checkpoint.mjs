// Intern rows and cells so the complete scrollback stays small across resize checkpoints.
export class Pool {
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
export function checkpoint(t, cells, lines) {
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
