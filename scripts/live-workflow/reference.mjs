// Observe the bytes delivered to the native pane with the server's independent emulator.
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import { Pool, checkpoint } from '../../Fixtures/reference/m2/checkpoint.mjs';

export function openReference(grid) {
    assert(process.env.THRUSH_XTERM_MODULES, 'Set THRUSH_XTERM_MODULES to the pinned Toy Box node_modules');
    const load = createRequire(resolve(process.env.THRUSH_XTERM_MODULES, '..', 'package.json'));
    for (const [name, version] of [['headless', '6.0.0'], ['addon-unicode11', '0.9.0']]) {
        assert.equal(load('@xterm/' + name + '/package.json').version, version);
    }
    const { Terminal } = load('@xterm/headless');
    const { Unicode11Addon } = load('@xterm/addon-unicode11');
    const terminal = new Terminal({ cols: grid.columns, rows: grid.rows, scrollback: 1000, allowProposedApi: true });
    terminal.loadAddon(new Unicode11Addon());
    terminal.unicode.activeVersion = '11';
    return terminal;
}

export function logicalLines(terminal, viewportOnly = false) {
    const buf = terminal.buffer.active;
    const result = [];
    for (let row = viewportOnly ? buf.baseY : 0; row < buf.length;) {
        const first = row;
        let text = '';
        while (buf.getLine(row + 1)?.isWrapped) text += buf.getLine(row++).translateToString(false, 0, terminal.cols);
        const last = buf.getLine(row);
        text += last.translateToString(true, 0, terminal.cols);
        result.push({ first, last: row++, text });
    }
    return result;
}

export function referenceDocument(terminal, fixture, event) {
    const cells = new Pool(), lines = new Pool();
    cells.get({ text: '', width: 1, flags: 0, foreground: -1, background: -1 });
    const expected = checkpoint(terminal, cells, lines);
    expected.synchronizedOutput = terminal.modes.synchronizedOutputMode;
    const entry = { name: event.name, offsetMicroseconds: 0, checkpoint: expected, lifecycle: event.lifecycle };
    let copy;
    if (event.copy) {
        const text = event.copy.text;
        const match = logicalLines(terminal).find(line => line.text === text);
        assert(match && match.first < match.last, 'The native grid must soft-wrap the selected compiler path');
        const end = terminal.buffer.active.getLine(match.last);
        let column = terminal.cols;
        while (column > 0 && end.getCell(column - 1).getChars() === '') column--;
        copy = { start: { row: match.first, column: 0 }, end: { row: match.last, column }, text };
    }
    return { version: 1, name: fixture.name, columns: terminal.cols, rows: terminal.rows,
        cells: cells.values, lines: lines.values, events: [{ ...entry, copy }] };
}

// Observe parsed SGR from the real binary byte stream, including a sequence split across frames.
// Returning false leaves the control for xterm's normal rendition handler.
export function observeBackgrounds(terminal, colors) {
    terminal.parser.registerCsiHandler({final: 'm'}, params => {
        for (let i = 0; i < params.length; i++) {
            const p = params[i];
            let mode, values;
            if (Array.isArray(p) && p[0] === 48) {
                mode = p[1];
                values = mode === 2 ? p.slice(-3) : p.slice(2, 3);
            } else if (p === 48) {
                mode = params[++i];
                values = params.slice(i + 1, i + (mode === 2 ? 4 : 2));
                i += values.length;
            } else if (!Array.isArray(p) && (p === 38 || p === 58)) {
                const kind = params[++i];
                i += kind === 2 ? 3 : kind === 5 ? 1 : 0;
            } else continue;
            if (mode === 2 && values.length === 3 && values.every(v => Number.isInteger(v) && v >= 0 && v <= 255)) {
                const rgb = '#' + values.map(v => v.toString(16).padStart(2, '0')).join('');
                colors.set(rgb, (colors.get(rgb) ?? 0) + 1);
            }
        }
        return false;
    });
}

function cellColor(cell, foreground) {
    if (foreground ? cell.isFgDefault() : cell.isBgDefault()) return {mode:'default'};
    const value = foreground ? cell.getFgColor() : cell.getBgColor();
    return (foreground ? cell.isFgRGB() : cell.isBgRGB())
        ? {mode:'rgb', rgb:'#' + value.toString(16).padStart(6, '0')}
        : {mode:'indexed', index:value};
}

export function userPromptRows(terminal) {
    const buffer = terminal.buffer.active;
    const rows = [];
    for (let row = 0; row < buffer.length; row++) {
        const line = buffer.getLine(row);
        const text = line.translateToString(true, 0, terminal.cols);
        if (!text.includes('Name 12 songbirds')) continue;
        const runs = [];
        for (let column = 0; column < terminal.cols; column++) {
            const cell = line.getCell(column);
            const foreground = cellColor(cell, true), background = cellColor(cell, false);
            const key = JSON.stringify([foreground, background]);
            if (runs.at(-1)?.key === key) runs.at(-1).endColumn = column + 1;
            else runs.push({ key, column, endColumn:column+1, foreground, background });
        }
        rows.push({row, visible:row >= buffer.baseY, text, styles:runs.map(({key, ...style}) => style)});
    }
    return rows;
}
