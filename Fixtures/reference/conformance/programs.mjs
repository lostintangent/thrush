// Real programs, as recorded from disposable PTYs: every read in order, with the window changes between them.
//
// Captures come from the replay fixtures (shell, Vim, Codex, Clang) and from `programs/`, which
// `capture-programs.py` records for pagers, editors, multiplexers and system monitors. Only output and
// resizes matter here. Input events are the keys that produced the output and replay through the PTY echo.
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join, relative } from 'node:path';

const fixtures = ['m2/shell-log', 'm2/vim-edit', 'm3/vim-swift-dark', 'm3/vim-swift-light', 'm4/codex-session',
  'm4/shell-workflow', 'm4/phone/codex-session', 'm4/phone/vim-edit'];

/** Every capture, as { path, capture }. */
export function captures(reference) {
  const directory = join(reference, 'conformance/programs');
  const recorded = existsSync(directory)
    ? readdirSync(directory).filter(name => name.endsWith('.capture.json')).sort().map(name => join(directory, name))
    : [];
  return [...fixtures.map(name => join(reference, `${name}.capture.json`)), ...recorded]
    .map(path => ({ path: relative(reference, path), capture: JSON.parse(readFileSync(path, 'utf8')) }));
}

/** A capture as a case. Each recorded checkpoint keeps its name, and checkpoints repeat-named get a suffix. */
export function programCase({ path, capture }) {
  const program = path.replace(/\.capture\.json$/, '').replace(/^conformance\/programs\//, '');
  const steps = [];
  const names = new Map();
  let palette;
  for (const event of capture.events) {
    if (event.palette) {
      if (steps.some(step => step.write)) throw new Error(`${path}: a palette change after output isn't supported`);
      palette = event.palette;
    }
    if (event.lifecycle) throw new Error(`${path}: lifecycle events replay a different terminal`);
    if (event.resize) steps.push({ resize: [event.resize.columns, event.resize.rows] });
    if (event.bytes) steps.push({ write: Uint8Array.from(Buffer.from(event.bytes, 'base64')) });
    if (event.checkpoint) {
      const count = (names.get(event.name) ?? 0) + 1;
      names.set(event.name, count);
      steps.push({ checkpoint: count === 1 ? event.name : `${event.name} ${count}` });
    }
  }
  return {
    name: `${program} program`, subject: `program ${program}`, program,
    size: [capture.columns, capture.rows], ...(palette && { palette }), steps,
  };
}

export const programCases = reference => captures(reference).map(programCase);
