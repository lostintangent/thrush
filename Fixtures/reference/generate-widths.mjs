// Sample the server provider through xterm's Unicode addon registration interface.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import { writeFile } from 'node:fs/promises';

const checkout = resolve(process.argv[2] ?? '../toy-box');
const require = createRequire(resolve(checkout, 'package.json'));
assert.equal(execFileSync('git', ['-C', checkout, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(),
  'b9d0eca3c5f4e9036e58327ba633eff52474bb92');
assert.equal(require('@xterm/addon-unicode11/package.json').version, '0.9.0');
const { Unicode11Addon } = require('@xterm/addon-unicode11');
let provider;
new Unicode11Addon().activate({ unicode: { register(value) { provider = value; } } });
assert.equal(provider.version, '11');

function rangesFor(width) {
  const ranges = [];
  let start;
  for (let value = 0; value <= 0x110000; value++) {
    const matches = value < 0x110000 && provider.wcwidth(value) === width;
    if (matches && start === undefined) start = value;
    if (!matches && start !== undefined) {
      ranges.push('0x' + start.toString(16) + '...0x' + (value - 1).toString(16));
      start = undefined;
    }
  }
  const lines = [];
  for (let index = 0; index < ranges.length; index += 4) {
    lines.push('        ' + ranges.slice(index, index + 4).join(', ') + ',');
  }
  return lines.join('\n');
}

const source = [
  '// Cell-width observations from the pinned Toy Box Unicode 11 provider.',
  '// Regenerate with bun Fixtures/reference/generate-widths.mjs ../toy-box.',
  'extension ColumnWidth {',
  '    static let zero: [ClosedRange<UInt32>] = [', rangesFor(0), '    ]',
  '    static let double: [ClosedRange<UInt32>] = [', rangesFor(2), '    ]',
  '}', ''
].join('\n');
await writeFile(new URL('../../Sources/Thrush/Unicode11Widths.swift', import.meta.url), source);
