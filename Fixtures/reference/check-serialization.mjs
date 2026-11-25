// Compare the new server's repaint, and the following PTY output, with every recorded checkpoint.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { Pool, checkpoint } from './m2/checkpoint.mjs';
import { headless } from './headless.mjs';

const binary = process.argv[2];
assert(binary, 'Usage: bun Fixtures/reference/check-serialization.mjs PATH_TO_THRUSHBENCH');
const root = resolve(import.meta.dir, '../..');
const paths = (await readdir(join(root, 'Fixtures/replays'))).filter(name => name.endsWith('.json'))
    .map(name => join(root, 'Fixtures/replays', name));
for (const name of ['vim-resume', 'codex-session']) paths.push(join(root, 'Fixtures/reference/m4/phone', name + '.json'));

// A reflow can leave the first half of a wide glyph in the last column. At this size
// a VT painter can only leave that cell empty. Preserve every other expected cell.
function representable(id, cols, cells, lines, losses) {
    const line = lines.values[id];
    const columns = [];
    for (let i = 0; i < line.runs.length; i += 2) {
        for (let n = 0; n < line.runs[i]; n++) columns.push(line.runs[i + 1]);
    }
    let changed = false;
    let text = '';
    for (let col = 0; col < columns.length; col++) {
        const cell = cells.values[columns[col]];
        if (cell.width === 2 && col === cols - 1) {
            columns[col] = 0;
            losses.clippedWide++;
            changed = true;
        } else {
            text += cell.text || (cell.width ? ' ' : '');
            if (cell.width === 2 && col + 1 < columns.length && cells.values[columns[col + 1]].width !== 0) {
                columns[col + 1] = cells.get({ ...cell, text: '', width: 0 });
                losses.overlapped++;
                changed = true;
            }
        }
    }
    if (!changed) return id;
    while (columns.at(-1) === 0) columns.pop();
    const runs = [];
    for (const cell of columns) {
        if (runs.at(-1) === cell) runs[runs.length - 2]++;
        else runs.push(1, cell);
    }
    return lines.get({ wrapped: line.wrapped, text, runs });
}
function compare(terminal, event, cells, lines, losses) {
    const actual = checkpoint(terminal, cells, lines);
    const expected = { ...event.checkpoint };
    for (const group of ['history', 'visible']) {
        expected[group] = expected[group].map(id => representable(id, expected.columns, cells, lines, losses));
    }
    if (expected.synchronizedOutput !== undefined) actual.synchronizedOutput = terminal.modes.synchronizedOutputMode;
    for (const key of Object.keys(expected)) {
        const bad = Array.isArray(actual[key]) && actual[key].findIndex((id, i) => id !== expected[key][i]);
        if (typeof bad === 'number' && bad >= 0) {
            throw Error(event.name + ' · ' + key + ' row ' + bad + ': ' + JSON.stringify(lines.values[actual[key][bad]]) +
                ' expected ' + JSON.stringify(lines.values[expected[key][bad]]));
        }
        assert.deepEqual(actual[key], expected[key], event.name + ' · ' + key);
    }
}
const write = (terminal, bytes) => new Promise(done => terminal.write(bytes, done));
const temp = await mkdtemp(join(tmpdir(), 'thrush-checkpoints-'));
try {
    for (const path of paths) {
        const recording = JSON.parse(await readFile(path));
        const out = join(temp, 'replays.json');
        execFileSync(binary, ['--serialize-replay', path, out], { stdio: 'inherit' });
        const samples = JSON.parse(await readFile(out));
        const losses = { clippedWide: 0, overlapped: 0, hiddenAlternate: 0 };
        const cells = new Pool(), lines = new Pool();
        for (const cell of recording.cells) cells.get(cell);
        for (const line of recording.lines) lines.get(line);
        for (const sample of samples) {
            const event = recording.events[sample.event];
            const terminal = headless(event.checkpoint.columns, event.checkpoint.rows);
            try {
                await write(terminal, Buffer.from(sample.bytes, 'base64'));
                compare(terminal, event, cells, lines, losses);
                if (recording.name === 'shell-edges' && sample.event === 12) {
                    assert.equal(terminal.buffer.active.getLine(0).translateToString(true), 'left +');
                    terminal.resize(12, 4);
                    const widened = terminal.buffer.active.getLine(0);
                    const uninterrupted = recording.lines[recording.events[13].checkpoint.visible[0]].text;
                    assert.equal(uninterrupted, 'left + right');
                    assert.equal(widened.translateToString(true), 'left +');
                    for (let col = 6; col < 12; col++) assert.equal(widened.getCell(col).getChars(), '');
                    losses.hiddenAlternate += 6;
                    continue;
                }
                // Feed every intervening write at this geometry. A following resize can expose
                // hidden alternate columns, which VT cannot address on the current grid.
                for (const next of recording.events.slice(sample.event + 1)) {
                    if (next.resize || next.lifecycle?.type === 'ready') break;
                    if (next.bytes) await write(terminal, Buffer.from(next.bytes, 'base64'));
                    if (next.checkpoint) { compare(terminal, next, cells, lines, { clippedWide: 0, overlapped: 0 }); break; }
                }
            } finally { terminal.dispose(); }
        }
        assert.equal(losses.clippedWide, recording.name === 'shell-edges' ? 4 : 0);
        assert.equal(losses.overlapped, recording.name === 'shell-edges' ? 44 : 0);
        assert.equal(losses.hiddenAlternate, recording.name === 'shell-edges' ? 6 : 0);
        const milliseconds = samples.map(s => s.nanoseconds / 1e6).sort((a, b) => a - b);
        const bytes = samples.reduce((n, s) => n + Buffer.from(s.bytes, 'base64').length, 0);
        console.log(recording.name, recording.columns + '×' + recording.rows, samples.length + ' checkpoints,',
            bytes + ' bytes, median ' + milliseconds[Math.floor(samples.length / 2)].toFixed(3) + ' ms');
    }
} finally { await rm(temp, { recursive: true }); }
