// Seeded random byte streams that mix text and control functions the way no hand-written case does.
//
// Each stream is a few dozen fragments drawn from weighted families, written in chunks split at random
// byte offsets, including inside UTF-8 scalars and escape sequences. A fixed list of seeds keeps the
// corpus identical on every run, so a failing stream always names the same bytes.
import { bytes, CSI, ESC, OSC, DCS, BEL, ST } from './functions.mjs';

/** Mulberry32: tiny, fast and identical in every JavaScript engine. */
function random(seed) {
  let state = seed >>> 0;
  const next = () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  const integer = (low, high) => low + Math.floor(next() * (high - low + 1));
  const pick = values => values[Math.floor(next() * values.length)];
  const weighted = table => {
    let roll = next() * table.reduce((total, [weight]) => total + weight, 0);
    for (const [weight, value] of table) if ((roll -= weight) < 0) return value;
    return table.at(-1)[1];
  };
  return { next, integer, pick, weighted };
}

const words = ['ls', 'git', 'status', 'main', 'thrush$', 'README.md', 'Sources', 'error:', 'warning', '42', '0.2.0',
  '├──', '│', '└─', '→', '✓', '█▉▊', '…', '±', 'naïve', 'café'];
const wide = ['界', '翼', '日本語', '한글', '🙂', '👍🏽', '🇯🇵', '👩‍💻', '＿', '中文字'];
const combining = ['e\u0301', 'a\u0308\u0323', 'n\u0303', '\u0301', 'ก\u0e31', '\u200d', '\ufe0f'];
const malformed = [[0xc3], [0xe2, 0x82], [0xf0, 0x9f, 0x99], [0x80], [0xff], [0xc0, 0xaf], [0xed, 0xa0, 0x80]];
const counts = ['', '0', '1', '2', '3', '5', '9', '30', '200'];
const counted = ['@', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'I', 'L', 'M', 'P', 'S', 'T', 'X', 'Z', '`', 'a', 'b', 'd', 'e',
  ' @', ' A', "'}", "'~"];
const renditions = ['0', '1', '2', '3', '4', '5', '7', '8', '9', '21', '22', '23', '24', '25', '27', '28', '29', '53', '55',
  '31', '39', '42', '49', '93', '104', '38;5;196', '48;5;22', '38;2;10;20;30', '48:2::200:100:0', '4:3', '58;5;9', '59', ''];
const decModes = ['1', '6', '7', '12', '25', '45', '47', '66', '1000', '1002', '1003', '1004', '1006', '1047', '1048',
  '1049', '2004', '2026'];

function fragment(r, [columns, rows]) {
  const row = () => r.integer(0, rows + 1), column = () => r.integer(0, columns + 2);
  return r.weighted([
    [30, () => r.pick(words) + (r.next() < 0.5 ? ' ' : '')],
    [8, () => 'x'.repeat(r.integer(1, columns * 2))],
    [8, () => r.pick(wide)],
    [5, () => r.pick(combining)],
    [3, () => r.pick(malformed)],
    [10, () => r.pick(['\r\n', '\n', '\r', '\b', '\t', '\x07', '\x0b', '\x0c', '\x0e', '\x0f', '\x00', '\x7f'])],
    [12, () => `${CSI}${row()};${column()}H`],
    [16, () => `${CSI}${r.pick(counts)}${r.pick(counted)}`],
    [8, () => `${CSI}${r.pick(['', '?'])}${r.pick(['', '0', '1', '2', '3'])}${r.pick(['J', 'K'])}`],
    [12, () => `${CSI}${Array.from({ length: r.integer(1, 3) }, () => r.pick(renditions)).join(';')}m`],
    [6, () => `${CSI}?${r.pick(decModes)}${r.pick(['h', 'l'])}`],
    [2, () => `${CSI}${r.pick(['4', '20'])}${r.pick(['h', 'l'])}`],
    [4, () => `${CSI}${r.integer(0, rows)};${r.integer(0, rows + 1)}r`],
    [6, () => ESC + r.pick(['7', '8', 'D', 'E', 'M', 'H', '=', '>', '(0', '(B', ')0', '#8', 'c', 'n', 'o'])],
    [2, () => `${CSI}${r.pick(['c', '>c', '5n', '6n', '?6n', '?1$p', '?2026$p', '18t', '>0q'])}`],
    [2, () => `${CSI}${r.pick(['', '0', '2', '5', '6'])} q`],
    [2, () => `${CSI}${r.pick(['s', 'u', '!p', 'g', '3g', '0g'])}`],
    [3, () => `${OSC}${r.pick(['0', '2', '1', '7', '8;;', '52;c', '1337'])};${r.pick(words)}${r.pick([BEL, ST])}`],
    [1, () => `${DCS}${r.pick(['$qm', '$qr', '+q544e', '1;2|17/ab'])}${ST}`],
    [2, () => r.pick([ESC, CSI, `${CSI}1;`, `${CSI}?`, `${CSI}>`, OSC, `${CSI}1\x1b[2J`, `${CSI}3\x18`, `${ESC}#`,
      `${CSI}12;34;56;78;90;12;34;56;78;90;12;34;56;78;90;12;34;56;78;90;12;34;56;78;90;12;34;56;78;90;12;34m`])],
  ])();
}

/** Splits bytes into writes at random offsets, keeping some writes whole. */
function chunks(r, data) {
  const result = [];
  for (let offset = 0; offset < data.length;) {
    const length = r.next() < 0.3 ? data.length - offset : r.integer(1, 24);
    result.push(data.slice(offset, offset + length));
    offset += length;
  }
  return result;
}

export const sizes = [[20, 8], [13, 5], [40, 10]];

/** One stream per seed, with a visible checkpoint midway, an optional resize and a full end checkpoint. */
export function stream(seed) {
  const r = random(seed);
  const size = r.pick(sizes);
  const parts = Array.from({ length: r.integer(20, 60) }, () => fragment(r, size));
  const middle = Math.floor(parts.length / 2);
  const steps = [...chunks(r, bytes(...parts.slice(0, middle))).map(write => ({ write })), { checkpoint: 'middle', scope: 'visible' }];
  if (r.next() < 0.25) steps.push({ resize: [r.integer(8, 48), r.integer(3, 12)] });
  steps.push(...chunks(r, bytes(...parts.slice(middle))).map(write => ({ write })));
  return { name: `stream ${seed}`, subject: 'stream', size, steps };
}

export const streamSeeds = Array.from({ length: 400 }, (_, index) => index + 1);
export const streamCases = streamSeeds.map(stream);
