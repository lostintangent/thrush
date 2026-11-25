// Project the recorded PTY onto the running pane's real grid with Toy Box's pinned xterm.
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import { Pool, checkpoint } from '../Fixtures/reference/m2/checkpoint.mjs';

function openTerminal(grid) {
    const modules = process.env.THRUSH_XTERM_MODULES;
    assert(modules, 'Set THRUSH_XTERM_MODULES to the pinned xterm installation');
    const load = createRequire(resolve(modules, '..', 'package.json'));
    assert.equal(load('@xterm/headless/package.json').version, '6.0.0');
    assert.equal(load('@xterm/addon-unicode11/package.json').version, '0.9.0');
    const { Terminal } = load('@xterm/headless');
    const { Unicode11Addon } = load('@xterm/addon-unicode11');
    const t = new Terminal({ cols: grid.columns, rows: grid.rows, scrollback: 1000, allowProposedApi: true });
    t.loadAddon(new Unicode11Addon());
    t.unicode.activeVersion = '11';
    return t;
}

function selection(t, expectedText) {
    const buffer = t.buffer.active;
    for (let row = 0; row < buffer.length; row++) {
        const first = buffer.getLine(row);
        if (first.isWrapped) continue;
        let last = row;
        let text = '';
        while (buffer.getLine(last + 1)?.isWrapped) {
            // Preserve printed spaces at a soft-wrap boundary.
            text += buffer.getLine(last++).translateToString(false);
        }
        text += buffer.getLine(last).translateToString(true);
        if (text !== expectedText) continue;
        assert(last > row, 'The native grid must soft-wrap the recorded compiler path');
        const end = buffer.getLine(last);
        let column = t.cols;
        while (column > 0 && end.getCell(column - 1).getChars() === '') column--;
        return { start: { row, column: 0 }, end: { row: last, column }, text };
    }
    throw Error('The xterm viewport did not contain the recorded compiler path');
}

export async function nativeCheckpoint(recording, grids, eventIndex, transitions) {
    const start = grids.get(-1);
    const source = recording.events[eventIndex];
    assert(start && source?.checkpoint, 'A native checkpoint needs an attached grid and recorded expectation');
    const same = (a, b) => a.columns === b.columns && a.rows === b.rows;
    const original = same(start, recording) && [...grids].every(([index, grid]) =>
        index < 0 || index > eventIndex || same(grid, recording.events[index].resize));
    const header = { version: 1, name: recording.name, columns: start.columns, rows: start.rows };
    const exactTransitions = transitions === undefined || transitions.filter(t => t.eventIndex <= eventIndex)
        .every(t => recording.events[t.eventIndex].resize && same(t, recording.events[t.eventIndex].resize));
    if (original && exactTransitions) return { ...header, cells: recording.cells, lines: recording.lines, events: [source] };

    let t = openTerminal(start);
    try {
        for (let i = 0; i <= eventIndex; i++) {
            const event = recording.events[i];
            const layout = transitions?.filter(change => change.eventIndex === i) ?? [];
            for (const change of layout) if (change.position === 'before') t.resize(change.columns, change.rows);
            if (event.lifecycle?.type === 'ready') {
                const grid = { columns: t.cols, rows: t.rows };
                t.dispose();
                t = openTerminal(grid);
            }
            if (event.resize && transitions === undefined) {
                const actual = grids.get(i);
                assert(actual, 'Missing native resize at ' + i);
                t.resize(actual.columns, actual.rows);
            }
            if (event.bytes) await new Promise(done => t.write(Buffer.from(event.bytes, 'base64'), done));
            for (const change of layout) if (change.position === 'after') t.resize(change.columns, change.rows);
        }
        const cells = new Pool(), lines = new Pool();
        cells.get({ text: '', width: 1, flags: 0, foreground: -1, background: -1 });
        const projected = checkpoint(t, cells, lines);
        if (source.checkpoint.synchronizedOutput !== undefined) projected.synchronizedOutput = t.modes.synchronizedOutputMode;
        const event = { ...source, checkpoint: projected };
        if (event.copy) event.copy = selection(t, event.copy.text);
        return { ...header, cells: cells.values, lines: lines.values, events: [event] };
    } finally {
        t.dispose();
    }
}
