// Names for every control function, shared by the corpus, the program counts and the gap report.
// Parameters that select a different behavior (erase modes, SGR attributes, DEC modes, reports) name a variant.

const execute = {
  0x07: 'BEL', 0x08: 'BS', 0x09: 'HT', 0x0a: 'LF', 0x0b: 'VT', 0x0c: 'FF', 0x0d: 'CR', 0x0e: 'SO', 0x0f: 'SI',
  0x84: 'IND', 0x85: 'NEL', 0x88: 'HTS',
};

const escape = {
  '7': 'DECSC', '8': 'DECRC', 'D': 'IND', 'E': 'NEL', 'H': 'HTS', 'M': 'RI', '=': 'DECKPAM', '>': 'DECKPNM',
  '\\': 'ST', 'c': 'RIS', 'n': 'LS2', 'o': 'LS3', '|': 'LS3R', '}': 'LS2R', '~': 'LS1R', '#8': 'DECALN',
  '%@': 'DOCS', '%G': 'DOCS',
};
const designators = { '(': 'G0', ')': 'G1', '*': 'G2', '+': 'G3', '-': 'G1', '.': 'G2', '/': 'G3' };

const csi = {
  '@': 'ICH', ' @': 'SL', 'A': 'CUU', ' A': 'SR', 'B': 'CUD', 'C': 'CUF', 'D': 'CUB', 'E': 'CNL', 'F': 'CPL',
  'G': 'CHA', 'H': 'CUP', 'I': 'CHT', 'J': 'ED', '?J': 'DECSED', 'K': 'EL', '?K': 'DECSEL', 'L': 'IL', 'M': 'DL',
  'P': 'DCH', 'S': 'SU', 'T': 'SD', 'X': 'ECH', 'Z': 'CBT', '`': 'HPA', 'a': 'HPR', 'b': 'REP', 'c': 'DA1',
  '>c': 'DA2', 'd': 'VPA', 'e': 'VPR', 'f': 'HVP', 'g': 'TBC', 'h': 'SM', '?h': 'DECSET', 'l': 'RM',
  '?l': 'DECRST', 'm': 'SGR', 'n': 'DSR', '?n': 'DECDSR', '!p': 'DECSTR', ' q': 'DECSCUSR', 'r': 'DECSTBM',
  's': 'SCOSC', 't': 'XTWINOPS', 'u': 'SCORC', "'}": 'DECIC', "'~": 'DECDC', '"q': 'DECSCA', '$p': 'DECRQM',
  '?$p': 'DECRQM',
};
// Functions whose first parameter selects the behavior. The rest take counts or positions.
const selectedByFirst = new Set(['ED', 'DECSED', 'EL', 'DECSEL', 'TBC', 'DSR', 'DECDSR', 'DECSCUSR', 'XTWINOPS']);
const modes = new Set(['SM', 'RM', 'DECSET', 'DECRST']);

const first = parameters => {
  const value = parameters[0];
  return typeof value === 'number' && value > 0 ? value : 0;
};

function graphicsRendition(parameters) {
  const names = [];
  for (let index = 0; index < parameters.length; index++) {
    const value = parameters[index] === -1 ? 0 : parameters[index];
    const next = parameters[index + 1];
    if (Array.isArray(next)) {
      // A colon form carries its own subparameters, such as 4:3 or 38:2::r:g:b.
      names.push(`SGR ${value}:${value === 4 ? next[0] : next[0] === 5 || next[0] === 2 ? next[0] : '?'}`);
      index++;
    } else if (value === 38 || value === 48 || value === 58) {
      const kind = parameters[index + 1];
      names.push(`SGR ${value};${kind === 5 || kind === 2 ? kind : '?'}`);
      index += kind === 5 ? 2 : kind === 2 ? 4 : 1;
    } else {
      names.push(`SGR ${value}`);
    }
  }
  return names;
}

function oscName(id, payload = '') {
  if (id === 4) return payload.split(';').some((part, index) => index % 2 === 1 && part === '?') ? 'OSC 4 ?' : 'OSC 4 set';
  if (id >= 10 && id <= 12) return payload.split(';').includes('?') ? `OSC ${id} ?` : `OSC ${id} set`;
  return id < 0 ? 'OSC' : `OSC ${id}`;
}

/** The names of the functions one dispatch performs. Several mode or SGR parameters yield several names. */
export function functionName(kind, identity, parameters = []) {
  switch (kind) {
    case 'execute': {
      const code = identity;
      return [execute[code] ?? `${code < 0x20 ? 'C0' : 'C1'} 0x${code.toString(16).padStart(2, '0')}`];
    }
    case 'esc':
      if (identity.length === 2 && designators[identity[0]]) return [`SCS ${designators[identity[0]]} ${identity[1]}`];
      return [escape[identity] ?? `ESC ${identity}`];
    case 'osc':
      return [oscName(identity, parameters)];
    case 'dcs':
      return [identity === '$q' ? 'DECRQSS' : `DCS ${identity}`];
    case 'csi': {
      const mnemonic = csi[identity];
      if (!mnemonic) return [`CSI ${identity}`];
      if (mnemonic === 'SGR') return graphicsRendition(parameters.length ? parameters : [0]);
      if (modes.has(mnemonic)) return parameters.filter(value => typeof value === 'number').map(value => `${mnemonic} ${value}`);
      if (mnemonic === 'DECRQM') return [`DECRQM ${identity[0] === '?' ? '?' : ''}${first(parameters)}`];
      if (mnemonic === 'DA1' || mnemonic === 'DA2') return [first(parameters) ? `${mnemonic} ${first(parameters)}` : mnemonic];
      return [selectedByFirst.has(mnemonic) ? `${mnemonic} ${first(parameters)}` : mnemonic];
    }
  }
  throw new Error(`Unknown function kind ${kind}`);
}

/** The family a variant belongs to, such as EL for EL 2 or SGR for SGR 4:3. */
export const family = name => name.split(' ')[0];
