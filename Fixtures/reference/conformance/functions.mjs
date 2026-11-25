// One case per xterm control function and the variants that change its result.
//
// Each case paints a small canvas, places the cursor, applies the subject, records a checkpoint,
// then prints a marker so the attributes, charset and position the subject left behind show up too.

export const ESC = '\x1b', CSI = '\x1b[', OSC = '\x1b]', DCS = '\x1bP', BEL = '\x07', ST = '\x1b\\';
const encoder = new TextEncoder();

/** Concatenates strings (as UTF-8) and arrays of raw bytes. */
export function bytes(...parts) {
  const chunks = parts.map(part => typeof part === 'string' ? encoder.encode(part) : Uint8Array.from(part));
  const result = new Uint8Array(chunks.reduce((total, chunk) => total + chunk.length, 0));
  let offset = 0;
  for (const chunk of chunks) { result.set(chunk, offset); offset += chunk.length; }
  return result;
}

export const size = [20, 8];
// Columns on row 3: w0 i1 d2 e3 _4 界5-6 界7-8 _9 c10 d11 _12 翼13-14 e15 f16.
const canvas = [
  'ABCDEFGHIJKLMNOPQRST',
  'abcdefghijklmnopqrst',
  'wide 界界 cd 翼ef',
  `${CSI}1;31mbold red${CSI}m plain ${CSI}44mblue${CSI}m`,
  'klmnopqrstuvwxyz0123',
  'UVWXYZ',
].join('\r\n');

/** Where a subject runs. Setups use only printing, CUP and DECSTBM so they mean the same in both emulators. */
export const positions = {
  'middle': `${CSI}2;6H`,
  'line start': `${CSI}2;1H`,
  'last column': `${CSI}2;20H`,
  'pending wrap': `${CSI}2;20Ht`,
  'wide left half': `${CSI}3;6H`,
  'wide right half': `${CSI}3;7H`,
  'top row': `${CSI}1;6H`,
  'bottom row': `${CSI}8;6H`,
  'inside a scroll region': `${CSI}3;6r${CSI}4;6H`,
  'at a region bottom': `${CSI}3;6r${CSI}6;6H`,
  'at a region top': `${CSI}3;6r${CSI}3;6H`,
  'below a scroll region': `${CSI}2;4r${CSI}7;6H`,
};

const cases = [];
function add(subject, variant, ...steps) { addSized(size, subject, variant, ...steps); }
function addSized(size, subject, variant, ...steps) {
  const flat = steps.flatMap(step => typeof step === 'string' || step instanceof Uint8Array ? [{ write: step }] : [step])
    .map(step => step.write !== undefined && typeof step.write === 'string' ? { write: bytes(step.write) } : step);
  cases.push({ name: variant ? `${subject} · ${variant}` : subject, subject, size, steps: flat });
}
/** The usual shape: canvas, setup, subject, checkpoint, marker. */
function probe(subject, variant, setup, sequence, marker = '*') {
  add(subject, variant, canvas + setup, sequence, { checkpoint: 'subject' }, marker);
}

// Functions that take a count or position. Every parameter form runs mid-line, then a count of 3
// runs from each position that changes the outcome.
const counted = {
  ICH: ['@', ['line start', 'last column', 'pending wrap', 'wide left half', 'wide right half']],
  DCH: ['P', ['line start', 'last column', 'pending wrap', 'wide left half', 'wide right half']],
  ECH: ['X', ['last column', 'pending wrap', 'wide left half', 'wide right half']],
  REP: ['b', ['last column', 'pending wrap', 'bottom row']],
  CUU: ['A', ['top row', 'pending wrap', 'inside a scroll region', 'at a region top', 'below a scroll region']],
  CUD: ['B', ['bottom row', 'pending wrap', 'inside a scroll region', 'at a region bottom', 'below a scroll region']],
  CUF: ['C', ['last column', 'pending wrap', 'wide left half']],
  CUB: ['D', ['line start', 'pending wrap', 'wide right half']],
  CNL: ['E', ['bottom row', 'pending wrap', 'at a region bottom']],
  CPL: ['F', ['top row', 'pending wrap', 'at a region top']],
  CHA: ['G', ['pending wrap', 'wide right half']],
  HPA: ['`', ['pending wrap', 'wide right half']],
  HPR: ['a', ['last column', 'pending wrap']],
  VPA: ['d', ['pending wrap', 'inside a scroll region']],
  VPR: ['e', ['bottom row', 'pending wrap', 'inside a scroll region']],
  IL: ['L', ['top row', 'bottom row', 'pending wrap', 'inside a scroll region', 'below a scroll region']],
  DL: ['M', ['top row', 'bottom row', 'pending wrap', 'inside a scroll region', 'below a scroll region']],
  SU: ['S', ['pending wrap', 'inside a scroll region', 'below a scroll region']],
  SD: ['T', ['pending wrap', 'inside a scroll region', 'below a scroll region']],
  CHT: ['I', ['last column', 'pending wrap', 'wide left half']],
  CBT: ['Z', ['line start', 'pending wrap', 'wide right half']],
  SL: [' @', ['inside a scroll region']],
  SR: [' A', ['inside a scroll region']],
  DECIC: ["'}", ['inside a scroll region', 'wide right half']],
  DECDC: ["'~", ['inside a scroll region', 'wide right half']],
};
for (const [subject, [final, places]] of Object.entries(counted)) {
  for (const parameter of ['', '0', '1', '3', '99']) {
    probe(subject, parameter === '' ? 'no parameter' : `parameter ${parameter}`, positions.middle, `${CSI}${parameter}${final}`);
  }
  for (const place of places) probe(subject, place, positions[place], `${CSI}3${final}`);
}
probe('REP', 'after a wide character', `${CSI}3;10H界`, `${CSI}3b`);
probe('REP', 'after a combining mark', `${CSI}5;1He\u0301`, `${CSI}2b`);
probe('REP', 'after a control', `${CSI}2;6H\r`, `${CSI}3b`);
probe('ICH', 'with a background color', `${positions.middle}${CSI}42m`, `${CSI}3@`);
probe('DCH', 'with a background color', `${positions.middle}${CSI}42m`, `${CSI}3P`);
probe('ECH', 'with a background color', `${positions.middle}${CSI}42m`, `${CSI}3X`);
probe('IL', 'with a background color', `${positions.middle}${CSI}42m`, `${CSI}2L`);
probe('DL', 'with a background color', `${positions.middle}${CSI}42m`, `${CSI}2M`);
probe('SU', 'with a background color', `${positions.middle}${CSI}42m`, `${CSI}2S`);
probe('SD', 'with a background color', `${positions.middle}${CSI}42m`, `${CSI}2T`);

// Absolute positioning.
for (const [subject, final] of [['CUP', 'H'], ['HVP', 'f']]) {
  for (const parameters of ['', '0;0', '3;4', '3', ';4', '99;99', '8;20', '2;99']) {
    probe(subject, parameters === '' ? 'no parameter' : `parameters ${parameters}`, positions.middle, `${CSI}${parameters}${final}`);
  }
}
probe('CUP', 'from a pending wrap', positions['pending wrap'], `${CSI}2;20H`);

// Erasing. The background color variants show which erasures keep the current background.
const erasures = { ED: 'J', EL: 'K', DECSED: '?J', DECSEL: '?K' };
for (const [subject, final] of Object.entries(erasures)) {
  for (const mode of ['', '0', '1', '2', '3', '99']) {
    const name = `${subject} ${mode || '0'}`;
    probe(name, mode === '' ? 'no parameter' : '', positions.middle, `${CSI}${final[0] === '?' ? '?' : ''}${mode}${final.at(-1)}`);
    if (mode === '' || mode === '3' || mode === '99') continue;
    const sequence = `${CSI}${final[0] === '?' ? '?' : ''}${mode}${final.at(-1)}`;
    probe(name, 'with a background color', `${positions.middle}${CSI}1;4;42m`, sequence);
    probe(name, 'from a pending wrap', positions['pending wrap'], sequence);
    probe(name, 'on a wide right half', positions['wide right half'], sequence);
    probe(name, 'on a wide left half', positions['wide left half'], sequence);
  }
}
for (const subject of ['ED', 'DECSED']) {
  const q = subject === 'DECSED' ? '?' : '';
  for (const mode of ['2', '3']) {
    add(`${subject} ${mode}`, 'with history', `${canvas}\r\n1\r\n2\r\n3\r\n4\r\n5`, `${CSI}${q}${mode}J`, { checkpoint: 'subject' }, '*');
  }
}
// Erasing through the cursor at the bottom right of a small screen, where the reference's ED 1 fails.
// Each case is a listed reference defect.
for (const [variant, setup] of [
  ['from a pending wrap on the bottom row', 'ABCDEFGHI'],
  ['at the bottom right corner', `ABCDEFGHI${CSI}3;3H`],
  ['at the right margin below history', `ABCDEFGHIJKLMNOPQRSTU${CSI}1;3H`],
]) {
  addSized([3, 3], 'ED 1', variant, setup, `${CSI}1J`, { checkpoint: 'subject' }, '*');
}
for (const [subject, sequence] of [['DECSED 2', `${CSI}?2J`], ['DECSEL 2', `${CSI}?2K`], ['ED 2', `${CSI}2J`], ['ECH', `${CSI}3X`]]) {
  probe(subject, 'over protected cells', `${CSI}2;3H${CSI}1"qPROT${CSI}0"q${positions.middle}`, sequence);
}
probe('DECSCA 1', '', positions.middle, `${CSI}1"q`, 'p');
probe('DECSCA 0', 'after 1', positions.middle, `${CSI}1"q${CSI}0"q`, 'p');

// Graphic rendition. The marker prints in whatever rendition the subject leaves.
const renditions = [
  '', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '21', '22', '23', '24', '25', '27', '28', '29',
  '30', '31', '32', '33', '34', '35', '36', '37', '39', '40', '41', '42', '43', '44', '45', '46', '47', '49', '53', '55', '59',
  '90', '91', '92', '93', '94', '95', '96', '97', '100', '101', '102', '103', '104', '105', '106', '107', '10', '11', '12', '20',
  '26', '50', '51', '52', '54', '60', '65', '73', '74', '75', '99', '1;2', '1;22', '2;22', '3;23', '4;24', '5;25',
  '7;27', '8;28', '9;29', '53;55', '1;4;31;42', '31;0;4', ';1', '1;;4', '0;;',
  '4:0', '4:1', '4:2', '4:3', '4:4', '4:5', '4:6', '4:3;24', '4:3;4', '21;24',
  '38;5;1', '38;5;9', '38;5;196', '38;5;255', '38;5;256', '38;5', '38;2;1;2;3', '38;2;255;0;300', '38;2;1;2',
  '38;3;1;2;3', '38;4;1;2;3;4', '38;9', '48;5;2', '48;2;10;20;30', '38;5;1;1', '38;2;1;2;3;4',
  '38:5:1', '38:2::1:2:3', '38:2:0:1:2:3', '38:2:1:2:3', '48:5:200', '48:2::40:50:60', '38:5:1;1',
  '58;5;3', '58;2;7;8;9', '58:5:3', '58:2::7:8:9', '4;58;5;3', '4;58;2;7;8;9;59', '4:3;58:2::7:8:9',
  '4;58;5;3;24;4', '1:2',
];
for (const parameters of renditions) {
  probe(`SGR ${parameters || '(empty)'}`.replace(/^SGR (\d+)$/, 'SGR $1'), '', `${positions.middle}${CSI}31;44m`, `${CSI}${parameters}m`, '*x');
}
probe('SGR 7', 'with default colors', positions.middle, `${CSI}7m`, '*');
probe('SGR 1', 'with an indexed color', positions.middle, `${CSI}1;34m`, '*');
probe('SGR 38;5', 'bright index with bold', positions.middle, `${CSI}1;38;5;4m`, '*');
probe('SGR 4', 'carried into an erase', positions.middle, `${CSI}4;43m`, `${CSI}K*`);
probe('SGR 9', 'carried into wide text', positions.middle, `${CSI}9;53m`, '界');

// Modes. Each set and reset is followed by the action the mode changes.
const decModes = {
  1: '', 2: '', 3: '', 4: '', 5: '', 6: `${CSI}3;6r${CSI}1;1H`, 7: `${CSI}2;19Habc`, 8: '', 9: '', 12: '',
  25: '', 40: '', 41: '', 44: '', 45: `${CSI}3;1H\b\b`, 47: 'alt', 66: '', 67: '', 69: '', 80: '', 95: '',
  1000: '', 1001: '', 1002: '', 1003: '', 1004: '', 1005: '', 1006: '', 1007: '', 1010: '', 1011: '', 1015: '',
  1016: '', 1034: '', 1035: '', 1036: '', 1039: '', 1042: '', 1043: '', 1046: '', 1047: 'alt', 1048: '',
  1049: 'alt', 1050: '', 2004: '', 2026: '', 2027: '', 2031: '', 2048: '', 9001: '',
};
for (const [mode, action] of Object.entries(decModes)) {
  for (const [subject, letter] of [['DECSET', 'h'], ['DECRST', 'l']]) {
    const before = subject === 'DECRST' ? `${CSI}?${mode}h` : '';
    probe(`${subject} ${mode}`, '', positions.middle + before, `${CSI}?${mode}${letter}`, action === 'alt' ? 'alt*' : action + '*');
  }
}
for (const mode of [47, 1047, 1049]) {
  add(`DECSET ${mode}`, 'and back with a changed cursor and rendition', canvas + positions.middle,
    `${CSI}?${mode}h${CSI}1;32mALT${CSI}5;5H`, { checkpoint: 'alternate' }, `${CSI}?${mode}l`, { checkpoint: 'subject' }, '*');
  add(`DECSET ${mode}`, 'twice', canvas + positions.middle, `${CSI}?${mode}hALT${CSI}?${mode}h`, { checkpoint: 'subject' }, '*');
  add(`DECRST ${mode}`, 'without the alternate screen', canvas + positions.middle, `${CSI}?${mode}l`, { checkpoint: 'subject' }, '*');
}
probe('DECSET 1048', 'then restore after moving', positions.middle, `${CSI}?1048h${CSI}31m${CSI}7;3H${CSI}?1048l`);
probe('DECSET 6', 'then CUP past the region', `${CSI}3;6r`, `${CSI}?6h${CSI}9;9H`);
probe('DECSET 6', 'then DECSC and DECRC', `${CSI}3;6r`, `${CSI}?6h${CSI}2;2H${ESC}7${CSI}?6l${ESC}8`);
probe('DECSET 6', 'then DSR 6', `${CSI}3;6r`, `${CSI}?6h${CSI}2;2H${CSI}6n`);
probe('DECRST 7', 'then a wide character at the edge', positions.middle, `${CSI}?7l${CSI}2;20H界`);
probe('DECRST 7', 'then a combining mark after a dropped wide character', positions.middle, `${CSI}?7l${CSI}2;19Ha界\u0301`);
probe('DECSET 45', 'then BS across a wrap', '', `${CSI}2;1H${CSI}?7h${CSI}?45h${CSI}1;20Hxy\b\b\b`);
for (const [mode, action] of Object.entries({ 2: '', 4: 'ab', 12: '', 20: '\nx', 34: '' })) {
  probe(`SM ${mode}`, '', positions.middle, `${CSI}${mode}h`, action + '*');
  probe(`RM ${mode}`, '', positions.middle + `${CSI}${mode}h`, `${CSI}${mode}l`, action + '*');
}
probe('SM 4', 'pushing a wide character off the edge', `${CSI}3;6H`, `${CSI}4h`, 'abcdefghijklm');
probe('SM 4', 'inserting a wide character', positions.middle, `${CSI}4h`, '界');
probe('SM 4', 'at a pending wrap', positions['pending wrap'], `${CSI}4h`, 'x');
probe('SM 20', 'with VT and FF', positions.middle, `${CSI}20h`, 'a\x0bb\x0cc');

// Reports. Every query a program can send, answered or not.
const reports = {
  'DA1': `${CSI}c`, 'DA1 0': `${CSI}0c`, 'DA1 1': `${CSI}1c`, 'DA2': `${CSI}>c`, 'DA2 0': `${CSI}>0c`, 'DA3': `${CSI}=c`,
  'DSR 5': `${CSI}5n`, 'DSR 6': `${CSI}6n`, 'DSR 99': `${CSI}99n`, 'DECDSR 6': `${CSI}?6n`, 'DECDSR 15': `${CSI}?15n`,
  'DECDSR 25': `${CSI}?25n`, 'DECDSR 26': `${CSI}?26n`, 'DECDSR 53': `${CSI}?53n`, 'DECDSR 996': `${CSI}?996n`,
  'XTVERSION': `${CSI}>q`, 'XTVERSION 0': `${CSI}>0q`, 'kitty keyboard query': `${CSI}?u`,
  'XTMODKEYS set': `${CSI}>4;2m`, 'XTMODKEYS reset': `${CSI}>4m`, 'XTQMODKEYS': `${CSI}?4m`,
  'XTWINOPS 11': `${CSI}11t`, 'XTWINOPS 13': `${CSI}13t`, 'XTWINOPS 14': `${CSI}14t`, 'XTWINOPS 16': `${CSI}16t`,
  'XTWINOPS 18': `${CSI}18t`, 'XTWINOPS 19': `${CSI}19t`, 'XTWINOPS 21': `${CSI}21t`, 'XTWINOPS 22;0': `${CSI}22;0t`,
  'XTWINOPS 23;0': `${CSI}23;0t`, 'XTWINOPS 8': `${CSI}8;10;40t`,
  'OSC 4 ?': `${OSC}4;1;?${BEL}`, 'OSC 4 ? 200': `${OSC}4;200;?${ST}`, 'OSC 4 ? several': `${OSC}4;0;?;15;?${BEL}`,
  'OSC 10 ?': `${OSC}10;?${BEL}`, 'OSC 11 ?': `${OSC}11;?${ST}`, 'OSC 12 ?': `${OSC}12;?${BEL}`,
  'OSC 10 ? and 11 ?': `${OSC}10;?;?${BEL}`,
  'DECRQSS m': `${DCS}$qm${ST}`, 'DECRQSS r': `${DCS}$qr${ST}`, 'DECRQSS SP q': `${DCS}$q q${ST}`,
  'DECRQSS " q': `${DCS}$q"q${ST}`, 'DECRQSS " p': `${DCS}$q"p${ST}`, 'DECRQSS unknown': `${DCS}$qz${ST}`,
  'XTGETTCAP': `${DCS}+q544e${ST}`,
};
for (const [subject, sequence] of Object.entries(reports)) probe(subject, '', positions.middle, sequence);
probe('DSR 6', 'at a pending wrap', positions['pending wrap'], `${CSI}6n`);
probe('DECDSR 6', 'at a pending wrap', positions['pending wrap'], `${CSI}?6n`);
probe('DECRQSS m', 'after a rendition', `${positions.middle}${CSI}1;4;38;5;100;48;2;1;2;3m`, `${DCS}$qm${ST}`);
probe('DECRQSS r', 'with a region', `${CSI}2;5r`, `${DCS}$qr${ST}`);
probe('DECRQSS SP q', 'after DECSCUSR 6', positions.middle, `${CSI}6 q${DCS}$q q${ST}`);
probe('OSC 4 ?', 'after OSC 4 set', positions.middle, `${OSC}4;1;rgb:12/34/56${BEL}${OSC}4;1;?${BEL}`);
probe('OSC 11 ?', 'after OSC 11 set', positions.middle, `${OSC}11;#102030${BEL}${OSC}11;?${BEL}`);
probe('OSC 104', 'after OSC 4 set', positions.middle, `${OSC}4;1;#abcdef${BEL}${OSC}104;1${BEL}${OSC}4;1;?${BEL}`);
probe('OSC 104', 'without parameters', positions.middle, `${OSC}4;1;#abcdef${BEL}${OSC}104${BEL}${OSC}4;1;?${BEL}`);
probe('OSC 110', 'after OSC 10 set', positions.middle, `${OSC}10;#abcdef${BEL}${OSC}110${BEL}${OSC}10;?${BEL}`);
probe('OSC 111', 'after OSC 11 set', positions.middle, `${OSC}11;#abcdef${BEL}${OSC}111${BEL}${OSC}11;?${BEL}`);
probe('OSC 112', 'after OSC 12 set', positions.middle, `${OSC}12;#abcdef${BEL}${OSC}112${BEL}${OSC}12;?${BEL}`);
// Program colors, observed through queries: each rule for fields, specifications, resets and lifetime.
const queryColors = (...indices) => `${OSC}4;${indices.map(index => `${index};?`).join(';')}${BEL}${OSC}10;?;?;?${BEL}`;
const colorSpecifications = ['rgb:f/0/8', 'rgb:ff/00/80', 'rgb:fff/000/888', 'rgb:ffff/0000/8888', 'RGB:AB/cD/eF', 'rgb:7/80/abc',
  '#abc', '#aabbcc', '#aaabbbccc', '#aaaabbbbcccc', '#ABCDEF', '#123456789'];
const invalidSpecifications = ['rgb:1/22/333', '#1234', 'rgb:1/2', 'rgb:1/2/3/4', 'rgb:g/0/0', 'red', '#', 'rgb:', 'rgb:+1/2/3',
  '#+12', 'rgb:12345/0/0', ' #123', '#123 ', 'rgb:1/2/3 ', '#１２３'];
probe('OSC 4 set', 'specifications', positions.middle,
  `${OSC}4;${colorSpecifications.map((spec, i) => `${i + 1};${spec}`).join(';')}${BEL}` + queryColors(...colorSpecifications.map((_, i) => i + 1)));
probe('OSC 4 set', 'invalid specifications', positions.middle,
  `${OSC}4;${invalidSpecifications.map((spec, i) => `${i + 1};${spec}`).join(';')}${BEL}` + queryColors(...invalidSpecifications.map((_, i) => i + 1)));
probe('OSC 4 set', 'indices', positions.middle, `${OSC}4;256;#111;x;#222;01;#333;-2;#444;;#555;0255;#666;7${BEL}` + queryColors(1, 2, 5, 7, 255));
probe('OSC 4 set', 'then a query in one command', positions.middle, `${OSC}4;1;#555;1;?;1;#777${BEL}${OSC}4;1;?${BEL}`);
probe('OSC 4 set', 'cancelled', positions.middle, `${OSC}4;1;#555\x18${OSC}4;2;#555\x1a` + queryColors(1, 2));
probe('OSC 4 set', 'ended by another escape sequence', positions.middle, `${OSC}4;3;#555${ESC}[C` + queryColors(3));
probe('OSC 4 ?', 'index 256', positions.middle, `${OSC}4;256;?;1${BEL}`);
probe('OSC 10 set', 'through the cursor', positions.middle, `${OSC}10;#111;#222;#333;#444${BEL}` + queryColors());
probe('OSC 10 set', 'skipping an invalid field', positions.middle, `${OSC}10;bad;#222;;#444${BEL}` + queryColors());
probe('OSC 11 set', 'through the cursor', positions.middle, `${OSC}11;#222;#333;#444${BEL}` + queryColors());
probe('OSC 12 set', 'then a query', positions.middle, `${OSC}12;rgb:12/34/56${ST}${OSC}12;?${ST}`);
probe('OSC 10 ?', 'between sets', positions.middle, `${OSC}10;?;#222;?${BEL}${OSC}10;#111;?;?${BEL}`);
probe('OSC 104', 'with a list', positions.middle, `${OSC}4;1;#111;2;#222;3;#333;4;#444${BEL}${OSC}104;1;x;003;300;-4${BEL}` + queryColors(1, 2, 3, 4));
probe('OSC 104', 'with empty fields', positions.middle, `${OSC}4;1;#111${BEL}${OSC}104;;${BEL}` + queryColors(1));
probe('OSC 104', 'keeps default colors', positions.middle, `${OSC}4;1;#111;200;#222${BEL}${OSC}10;#333;#444;#555${BEL}${OSC}104;${BEL}` + queryColors(1, 200));
probe('OSC 110', 'with a payload', positions.middle, `${OSC}10;#111;#222;#333${BEL}${OSC}110;1;2${BEL}` + queryColors());
probe('OSC 112', 'without its set', positions.middle, `${OSC}10;#111;#222;#333${BEL}${OSC}112${BEL}${OSC}111${BEL}` + queryColors());
probe('RIS', 'keeps program colors', `${positions.middle}${OSC}4;1;#111${BEL}${OSC}10;#222;#333;#444${BEL}`, `${ESC}c` + queryColors(1));
probe('DECSTR', 'keeps program colors', `${positions.middle}${OSC}4;1;#111${BEL}${OSC}10;#222;#333;#444${BEL}`, `${CSI}!p` + queryColors(1));
add('OSC 4 set', 'split across writes', canvas + positions.middle, `${OSC}4;1;rgb:1`, `2/34/5`, `6${ESC}`, `\\${OSC}4;1;?${BEL}`, { checkpoint: 'subject' }, '*');
for (const mode of [1, 3, 6, 7, 12, 25, 45, 47, 66, 1000, 1002, 1003, 1004, 1006, 1047, 1048, 1049, 2004, 2026, 9999]) {
  probe(`DECRQM ?${mode}`, '', positions.middle, `${CSI}?${mode}$p`);
  probe(`DECRQM ?${mode}`, 'after DECSET', positions.middle + `${CSI}?${mode}h`, `${CSI}?${mode}$p`);
}
for (const mode of [2, 4, 12, 20, 99]) probe(`DECRQM ${mode}`, '', positions.middle, `${CSI}${mode}$p`);

// Cursor style, saving and resetting.
for (const shape of ['', '0', '1', '2', '3', '4', '5', '6', '7']) {
  probe(`DECSCUSR ${shape || '0'}`, shape === '' ? 'no parameter' : '', positions.middle, `${CSI}${shape} q`);
}
probe('DECSCUSR 0', 'after DECSCUSR 6', positions.middle, `${CSI}6 q${CSI}0 q`);
probe('DECSCUSR 0', 'with DECSET 12', positions.middle, `${CSI}?12h${CSI}2 q${CSI}0 q`);
probe('DECSC', 'and DECRC after moving and styling', positions.middle, `${ESC}7${CSI}1;31m${CSI}7;3H${ESC}8`);
probe('DECRC', 'without DECSC', positions.middle, `${CSI}1;31m${ESC}8`);
probe('DECSC', 'at a pending wrap', positions['pending wrap'], `${ESC}7${CSI}1;1H${ESC}8`);
probe('DECSC', 'with a charset', positions.middle, `${ESC}(0${ESC}7${ESC}(B${ESC}8`, 'lqk');
probe('SCOSC', 'and SCORC', positions.middle, `${CSI}s${CSI}1;31m${CSI}7;3H${CSI}u`);
probe('SCOSC', 'with parameters', positions.middle, `${CSI}1;5s${CSI}7;3H${CSI}u`);
probe('DECSTR', '', `${positions.middle}${CSI}1;31m${CSI}?25l${CSI}4h${CSI}?6h${CSI}3;6r${CSI}?7l${ESC}(0${CSI}?1h${ESC}=`, `${CSI}!p`, 'q*');
probe('RIS', '', `${positions.middle}${CSI}1;31m${CSI}?25l${CSI}3;6r${OSC}2;title${BEL}${CSI}?1049h`, `${ESC}c`, '*');
probe('DECALN', '', positions.middle, `${ESC}#8`);
probe('DECALN', 'inside a scroll region', `${CSI}3;6r`, `${ESC}#8`);

// Scrolling regions.
for (const parameters of ['', '2;5', '5;2', '3;3', '0;0', '2', ';5', '1;99', '2;8']) {
  probe(`DECSTBM`, parameters === '' ? 'no parameter' : `parameters ${parameters}`, positions.middle, `${CSI}${parameters}r`, `${CSI}8;1H\n\n*`);
}
probe('DECSTBM', 'from a pending wrap', positions['pending wrap'], `${CSI}2;5r`);

// Escape sequences.
const escapes = {
  IND: `${ESC}D`, NEL: `${ESC}E`, RI: `${ESC}M`, HTS: `${ESC}H`, DECKPAM: `${ESC}=`, DECKPNM: `${ESC}>`,
  LS2: `${ESC}n`, LS3: `${ESC}o`, LS1R: `${ESC}~`, LS2R: `${ESC}}`, LS3R: `${ESC}|`, 'DOCS %G': `${ESC}%G`, 'DOCS %@': `${ESC}%@`,
  'ESC unknown': `${ESC}Q`, 'ESC 6 (DECBI)': `${ESC}6`, 'ESC 9 (DECFI)': `${ESC}9`, 'ESC F': `${ESC}F`, 'ESC l': `${ESC}l`,
  'ESC #3': `${ESC}#3`, 'ESC #6': `${ESC}#6`, 'ESC SP F': `${ESC} F`, 'ST alone': ST,
};
for (const [subject, sequence] of Object.entries(escapes)) {
  probe(subject, '', positions.middle, sequence);
  if (['IND', 'NEL', 'RI'].includes(subject)) {
    for (const place of ['top row', 'bottom row', 'pending wrap', 'at a region top', 'at a region bottom', 'below a scroll region']) {
      probe(subject, place, positions[place], sequence);
    }
    probe(subject, 'with a background color', `${positions['bottom row']}${CSI}43m`, sequence);
  }
}
for (const [designate, set] of [['(', 'G0'], [')', 'G1'], ['*', 'G2'], ['+', 'G3'], ['-', 'G1'], ['.', 'G2'], ['/', 'G3']]) {
  const invoke = { G0: '', G1: '\x0e', G2: `${ESC}n`, G3: `${ESC}o` }[set];
  for (const charset of ['0', 'A', 'B', '4', 'C', '5', 'R', 'Q', 'K', 'Y', 'E', '6', 'Z', 'H', '7', '=', '<', '%5', '"?']) {
    probe(`SCS ${set} ${charset}`, designate === '(' || designate === ')' ? '' : `with ${designate}`, positions.middle,
      `${ESC}${designate}${charset}${invoke}`, "jklmnqtuvwx`afg~{}|#@[\\]^_'");
  }
}
probe('SO', 'without a G1 designation', positions.middle, '\x0e', 'lqk');
probe('SI', 'after SO', positions.middle, `${ESC})0\x0e\x0f`, 'lqk');
probe('SCS G0 0', 'with wide text and combining marks', positions.middle, `${ESC}(0`, 'q界e\u0301x');
probe('SCS G0 0', 'across a reset', positions.middle, `${ESC}(0${ESC}c`, 'lqk');
probe('SS2', '', positions.middle, `${ESC}*0${ESC}N`, 'qq');
probe('SS3', '', positions.middle, `${ESC}+0${ESC}O`, 'qq');

// C0 and C1 controls.
const controls = {
  NUL: [0x00], SOH: [0x01], ENQ: [0x05], BEL: [0x07], BS: [0x08], HT: [0x09], LF: [0x0a], VT: [0x0b], FF: [0x0c],
  CR: [0x0d], DLE: [0x10], DC1: [0x11], CAN: [0x18], SUB: [0x1a], FS: [0x1c], US: [0x1f], DEL: [0x7f],
};
for (const [subject, code] of Object.entries(controls)) {
  probe(subject, '', positions.middle, bytes(code));
  for (const place of ['line start', 'pending wrap', 'wide right half', 'bottom row', 'at a region bottom']) {
    if (['BS', 'HT', 'LF', 'VT', 'FF', 'CR'].includes(subject)) probe(subject, place, positions[place], bytes(code));
  }
}
probe('HT', 'from the last tab stop', `${CSI}2;17H`, '\t');
probe('HT', 'three times', positions['line start'], '\t\t\t');
probe('HT', 'over styled text', `${positions['line start']}${CSI}41m`, '\t');
probe('HT', 'after a resize', '', { resize: [30, 8] }, `${CSI}2;1H\t\t\t`);
probe('HT', 'between printed words', positions['line start'], 'name\tvalue');
probe('HTS', 'then HT', `${CSI}2;1H`, `${CSI}4G${ESC}H${CSI}1G\t`);
probe('HTS', 'by C1 control', `${CSI}2;1H`, `${CSI}4G\u0088${CSI}1G\t`);
for (const mode of ['', '0', '3', '5']) probe(`TBC ${mode || '0'}`, mode === '' ? 'no parameter' : '', `${CSI}2;9H`, `${CSI}${mode}g${CSI}1G\t`);
probe('TBC 3', 'then CHT', `${CSI}2;1H`, `${CSI}3g${CSI}I`);
probe('BS', 'twice over a wide character', `${CSI}3;9H`, '\b\b');
probe('CAN', 'inside a CSI', positions.middle, `${CSI}1\x18m`);
probe('SUB', 'inside a CSI', positions.middle, `${CSI}1\x1am`);
probe('ESC', 'inside a CSI', positions.middle, `${CSI}1${ESC}[4m`);
probe('C0', 'inside a CSI', positions.middle, `${CSI}1\r;4m`);
probe('C0', 'inside an OSC', positions.middle, `${OSC}2;ti\rtle${BEL}`);
probe('CSI', 'with too many parameters', positions.middle, `${CSI}${Array(40).fill(1).join(';')};4m`);
probe('CSI', 'with a huge parameter', positions.middle, `${CSI}99999999999C`);
probe('CSI', 'with intermediate and parameter disorder', positions.middle, `${CSI}1$2m`);
probe('CSI', 'with a private marker after parameters', positions.middle, `${CSI}1?m`);
probe('CSI', 'unknown final', positions.middle, `${CSI}1y`);
probe('CSI', 'with a space intermediate and unknown final', positions.middle, `${CSI}1 z`);
// Requests real programs send that the reference doesn't answer: vim's modifyOtherKeys query and
// terminal check, the kitty keyboard protocol from Codex, and an agent state report.
probe('CSI %m', 'from vim', positions.middle, `${CSI}0%m`);
probe('DCS z', 'from vim', positions.middle, `${DCS}zz${ST}`);
probe('CSI >u', 'push keyboard flags', positions.middle, `${CSI}>7u`);
probe('CSI <u', 'pop keyboard flags', positions.middle, `${CSI}<1u${CSI}<u`);
probe('OSC 7501', 'agent state', positions.middle, `${OSC}7501;state=working:app=codex${BEL}`);
for (const [subject, code] of [['IND', 0x84], ['NEL', 0x85], ['HTS', 0x88], ['RI', 0x8d], ['CSI', 0x9b], ['OSC', 0x9d], ['ST', 0x9c]]) {
  probe(`C1 ${subject}`, 'as UTF-8', positions.middle, String.fromCodePoint(code) + (subject === 'CSI' ? '4m' : subject === 'OSC' ? '2;t\x07' : ''));
  probe(`C1 ${subject}`, 'as a raw byte', positions.middle, bytes([code]));
}

// Text: widths, combining marks, wrapping and malformed UTF-8.
const texts = {
  'wide at the last column': [`${CSI}2;20H`, '界'],
  'wide at the second last column': [`${CSI}2;19H`, '界'],
  'wide over a wide right half': [positions['wide right half'], '翼'],
  'narrow over a wide left half': [positions['wide left half'], 'x'],
  'narrow over a wide right half': [positions['wide right half'], 'x'],
  'combining mark': [positions.middle, 'e\u0301\u0302'],
  'combining mark at line start': [positions['line start'], '\u0301'],
  'combining mark after a wrap': [`${CSI}2;20H`, 'xy\u0301'],
  'combining mark on a wide character': [positions.middle, '界\u0301'],
  'combining mark after a cursor move': [positions.middle, `e${CSI}C\u0301`],
  'combining mark at a pending wrap': [`${CSI}2;20H`, 'e\u0301'],
  'emoji': [positions.middle, '😀x'],
  'emoji with VS16': [positions.middle, '☺\ufe0fx'],
  'emoji with VS15': [positions.middle, '☺\ufe0ex'],
  'ZWJ family': [positions.middle, '👨\u200d👩\u200d👧x'],
  'regional indicators': [positions.middle, '🇺🇸x'],
  'skin tone modifier': [positions.middle, '👍🏽x'],
  'keycap': [positions.middle, '1\ufe0f\u20e3x'],
  'Hangul jamo': [positions.middle, '\u1100\u1161\u11a8x'],
  'zero width space': [positions.middle, 'a\u200bb'],
  'zero width joiner alone': [positions.middle, 'a\u200db'],
  'byte order mark': [positions.middle, 'a\ufeffb'],
  'soft hyphen': [positions.middle, 'a\u00adb'],
  'fullwidth forms': [positions.middle, 'ＡＢ'],
  'ambiguous width': [positions.middle, '±§¶'],
  'unassigned private use': [positions.middle, '\ue000x'],
  'Devanagari cluster': [positions.middle, 'क्षx'],
  'Thai with marks': [positions.middle, 'กิ่x'],
  'long line wrapping twice': [positions['line start'], 'x'.repeat(45)],
  'text filling the screen': [`${CSI}8;1H`, 'y'.repeat(41)],
  'wide text wrapping': [positions['line start'], '界'.repeat(12)],
};
for (const [variant, [setup, text]] of Object.entries(texts)) probe('print', variant, setup, text);
const malformed = {
  'lone continuation byte': [0x80], 'truncated two-byte': [0xc3], 'truncated three-byte': [0xe7, 0x95],
  'truncated four-byte': [0xf0, 0x9f, 0x98], 'overlong slash': [0xc0, 0xaf], 'surrogate': [0xed, 0xa0, 0x80],
  'beyond U+10FFFF': [0xf4, 0x90, 0x80, 0x80], 'invalid lead byte': [0xff], 'truncated then escape': [0xe7, 0x1b, 0x5b, 0x31, 0x6d],
  'truncated then newline': [0xe7, 0x95, 0x0a],
};
for (const [variant, code] of Object.entries(malformed)) probe('UTF-8', variant, positions.middle, bytes('a', code, 'b'));
add('UTF-8', 'split across writes', canvas + positions.middle, bytes([0xe7, 0x95]), bytes([0x8c, 0x78]), { checkpoint: 'subject' }, '*');
add('CSI', 'split across writes', canvas + positions.middle, `${CSI}3`, ';4', 'H', { checkpoint: 'subject' }, '*');
add('OSC 2', 'split across writes', canvas + positions.middle, `${OSC}2;ti`, `tle${ESC}`, '\\', { checkpoint: 'subject' }, '*');

// Operating system commands and other strings.
const strings = {
  'OSC 0': `${OSC}0;window and icon${BEL}`, 'OSC 1': `${OSC}1;icon${BEL}`, 'OSC 2': `${OSC}2;window${BEL}`,
  'OSC 2 with ST': `${OSC}2;window${ST}`, 'OSC 2 empty': `${OSC}2;${BEL}`, 'OSC 2 UTF-8': `${OSC}2;界 ✓${BEL}`,
  'OSC 2 with semicolons': `${OSC}2;a;b;c${BEL}`, 'OSC 2 without a payload separator': `${OSC}2${BEL}`,
  'OSC 2 then OSC 1': `${OSC}2;window${BEL}${OSC}1;icon${BEL}`, 'OSC 2 long': `${OSC}2;${'t'.repeat(2000)}${BEL}`,
  'OSC 2 with C1 ST': `${OSC}2;window\u009c`, 'OSC 2 unterminated then text': `${OSC}2;window`,
  'OSC 4 set': `${OSC}4;1;rgb:ff/00/00${BEL}`, 'OSC 7': `${OSC}7;file://host/Users/me${BEL}`,
  'OSC 8': `${OSC}8;;https://example.com${BEL}link${OSC}8;;${BEL}`, 'OSC 8 with id': `${OSC}8;id=1;https://example.com${ST}link${OSC}8;;${ST}`,
  'OSC 9': `${OSC}9;notification${BEL}`, 'OSC 10 set': `${OSC}10;#123456${BEL}`, 'OSC 11 set': `${OSC}11;rgb:1/2/3${BEL}`,
  'OSC 12 set': `${OSC}12;red${BEL}`, 'OSC 52': `${OSC}52;c;aGVsbG8=${BEL}`, 'OSC 52 ?': `${OSC}52;c;?${BEL}`,
  'OSC 104': `${OSC}104${BEL}`, 'OSC 133': `${OSC}133;A${BEL}`, 'OSC 633': `${OSC}633;A${BEL}`, 'OSC 777': `${OSC}777;notify;a;b${BEL}`,
  'OSC 1337': `${OSC}1337;SetUserVar=a=Yg==${BEL}`, 'OSC invalid number': `${OSC}x;payload${BEL}`,
  'DCS tmux passthrough': `${DCS}tmux;${ESC}${ESC}[1m${ST}`, 'DCS sixel': `${DCS}q#0;2;0;0;0#0~~${ST}`,
  'APC': `${ESC}_Gf=24;AAAA${ST}`, 'PM': `${ESC}^private${ST}`, 'SOS': `${ESC}Xstring${ST}`,
};
for (const [subject, sequence] of Object.entries(strings)) {
  const [name, ...rest] = subject.split(' ');
  const family = name === 'OSC' && /^\d+$/.test(rest[0]) ? `OSC ${rest.shift()}` : name;
  probe(family, rest.join(' ') || '', positions.middle, sequence, 'after');
}

// Resizing. Each resize records a checkpoint so reflow is compared step by step, and a string
// between sizes is written there.
const resizes = {
  'narrower with a soft wrap': [`${CSI}2;1H${'x'.repeat(30)}`, [[12, 8], [20, 8], [7, 8]]],
  'narrower with wide text': [`${CSI}2;1H${'界'.repeat(14)}`, [[11, 8], [20, 8], [5, 8]]],
  'shorter with the cursor at the bottom': [`${CSI}8;3H`, [[20, 4], [20, 8], [20, 2]]],
  'shorter with the cursor at the top': [`${CSI}1;3H`, [[20, 4], [20, 8]]],
  'taller with history': [`\r\n1\r\n2\r\n3\r\n4\r\n5\r\n6`, [[20, 12], [20, 4], [20, 10]]],
  'wider and narrower at a pending wrap': [positions['pending wrap'], [[25, 8], [20, 8], [10, 8]]],
  'narrower after cutting a wide glyph': [`${CSI}7;1H${'x'.repeat(18)}${CSI}41m界${CSI}m`, [[19, 8], '\r\n', [10, 8]]],
  'narrower after cutting a wide glyph from a wrapped row': [`${CSI}7;1H${'x'.repeat(18)}界y\r${CSI}X`, [[19, 8], '\r\n', [10, 8]]],
  'narrower with combining marks': [`${CSI}6;1H${'x'.repeat(20)}abn\u0303de\u0301${CSI}8;1H`, [[18, 8]]],
  'on the alternate screen': [`${CSI}?1049h${CSI}2;1Halternate text that wraps around`, [[10, 4], [20, 8], [30, 10]]],
  'with a scroll region': [`${CSI}3;6r${CSI}4;1H`, [[20, 5], [20, 9]]],
};
for (const [variant, [setup, steps]] of Object.entries(resizes)) {
  let count = 0;
  add('resize', variant, canvas + setup, ...steps.flatMap(step =>
    typeof step === 'string' ? [step] : [{ resize: step }, { checkpoint: `resize ${++count}` }]), '*');
}
// Narrowing with the cursor above rows that make room for the added ones.
addSized([5, 3], 'resize', 'narrower above text', `\r\nabc\r\n12345${CSI}H`, { resize: [2, 3] }, { checkpoint: 'resize 1' }, '*');

export const functionCases = cases;
