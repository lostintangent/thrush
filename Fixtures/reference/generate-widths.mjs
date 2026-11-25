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

// A 256-scalar page is identical across many Unicode blocks. Emit each distinct page once.
const pageIndices = [];
const pages = [];
const indicesByWidth = new Map();
for (let start = 0; start < 0x110000; start += 256) {
  const widths = Array.from({ length: 256 }, (_, offset) => provider.wcwidth(start + offset));
  const key = widths.join('');
  if (!indicesByWidth.has(key)) {
    indicesByWidth.set(key, pages.length);
    pages.push(widths);
  }
  pageIndices.push(indicesByWidth.get(key));
}
assert.ok(pages.length <= 256);

function lines(values, perLine) {
  const result = [];
  for (let i = 0; i < values.length; i += perLine) {
    result.push('        ' + values.slice(i, i + perLine).join(', ') + ',');
  }
  return result.join('\n');
}
// Pack 32 two-bit widths per word. The lowest bits are the first scalar in that word.
const words = [];
for (const page of pages) {
  for (let i = 0; i < page.length; i += 32) {
    let word = 0n;
    for (let j = 0; j < 32; j++) word |= BigInt(page[i + j]) << BigInt(2 * j);
    words.push('0x' + word.toString(16).padStart(16, '0'));
  }
}

const source = [
  '// Cell-width observations from the pinned Toy Box Unicode 11 provider.',
  '// Regenerate with bun Fixtures/reference/generate-widths.mjs ../toy-box.',
  'extension ColumnWidth {',
  '    static let pageIndices: [UInt8] = [', lines(pageIndices, 32), '    ]',
  '    static let widthWords: [UInt64] = [', lines(words, 4), '    ]',
  '}', ''
].join('\n');
await writeFile(new URL('../../Sources/ThrushCore/Unicode11Widths.swift', import.meta.url), source);
