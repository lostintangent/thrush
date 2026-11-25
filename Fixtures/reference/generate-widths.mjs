// Samples the pinned reference's Unicode provider through the addon's registration interface, and writes
// Sources/ThrushCore/Unicode11Widths.swift.
import assert from 'node:assert/strict';
import { writeFile } from 'node:fs/promises';
import { Unicode11Addon, reference } from './headless.mjs';

let provider;
new Unicode11Addon().activate({ unicode: { register(value) { provider = value; } } });
assert.equal(provider.version, reference.unicode);

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
  '// Cell widths observed from the pinned reference\'s Unicode 11 provider.',
  '// Regenerate with bun Fixtures/reference/generate-widths.mjs.',
  'extension ColumnWidth {',
  '    static let pageIndices: [UInt8] = [', lines(pageIndices, 32), '    ]',
  '    static let widthWords: [UInt64] = [', lines(words, 4), '    ]',
  '}', ''
].join('\n');
await writeFile(new URL('../../Sources/ThrushCore/Unicode11Widths.swift', import.meta.url), source);
