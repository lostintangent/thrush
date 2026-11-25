// Compare xterm's independent server/client states across a serialized Vim attachment.
import assert from 'node:assert/strict';

function rendition(cell) {
  const flags = ['isBold', 'isDim', 'isItalic', 'isUnderline', 'isBlink', 'isInverse',
    'isInvisible', 'isStrikethrough', 'isOverline', 'isProtected'];
  return {
    foreground:[cell.getFgColorMode(), cell.getFgColor()],
    background:[cell.getBgColorMode(), cell.getBgColor()],
    flags:flags.filter(flag => cell[flag]()),
    underline:cell.isUnderline() ? [cell.getUnderlineStyle(), cell.getUnderlineColorMode(), cell.getUnderlineColor()] : null
  };
}

function state(t) {
  const core = t._core;
  const cursor = core.coreService.decPrivateModes;
  return {
    dimensions:[t.cols, t.rows], active:t.buffer.active.type,
    modes:t.modes, mouseEncoding:core.coreMouseService.activeEncoding,
    scrollRegion:[core.buffer.scrollTop, core.buffer.scrollBottom],
    cursorVisible:!core.coreService.isCursorHidden,
    cursorShape:cursor.cursorStyle ?? t.options.cursorStyle, cursorBlink:cursor.cursorBlink ?? t.options.cursorBlink,
    pen:rendition(core._inputHandler._curAttrData)
  };
}

function bufferGeometry(buffer) {
  return {cursor:[buffer.cursorX, buffer.cursorY], length:buffer.length, base:buffer.baseY, viewport:buffer.viewportY};
}

function cellAt(line, x, scratch) {
  const cell = line.getCell(x, scratch);
  return {text:cell.getChars(), width:cell.getWidth(), ...rendition(cell)};
}

export function assertDefaultShellPrompt(t) {
  const prompt = 'thrush$ ';
  const buffer = t.buffer.active;
  assert.equal(buffer.type, 'normal');
  const line = buffer.getLine(buffer.baseY + buffer.cursorY);
  assert.equal(line.translateToString(true, 0, t.cols), prompt);
  assert.equal(buffer.cursorX, prompt.length);
  const scratch = buffer.getNullCell();
  for (let x = 0; x < prompt.length; x++) {
    assert.deepEqual(cellAt(line, x, scratch), {text:prompt[x], width:1,
      foreground:[0, -1], background:[0, -1], flags:[], underline:null}, 'Shell prompt column ' + x);
  }
}

export function assertSameVimScreen(actual, expected) {
  assert.deepEqual(state(actual), state(expected), 'Terminal modes, margins, cursor presentation or current rendition differ');
  for (const name of ['normal', 'alternate']) {
    const a = actual.buffer[name], b = expected.buffer[name];
    const ac = a.getNullCell(), bc = b.getNullCell();
    assert.deepEqual(bufferGeometry(a), bufferGeometry(b), name + ' buffer geometry or cursor differs');
    for (let y = 0; y < b.length; y++) {
      const left = a.getLine(y), right = b.getLine(y);
      assert.equal(left.isWrapped, right.isWrapped, name + ' row ' + y + ' wrap differs');
      // xterm may retain the previous landscape allocation behind an alternate row.
      // Every addressable column, including blank and wide continuation cells, is compared.
      for (let x = 0; x < expected.cols; x++) {
        assert.deepEqual(cellAt(left, x, ac), cellAt(right, x, bc), name + ' row ' + y + ' col ' + x);
      }
    }
  }
}
