// Finds where a failing case first goes wrong, then shrinks it to the few bytes that still disagree.
//
// Bytes split into tokens: a run of text, one control or one whole escape sequence. Delta debugging
// removes tokens while the reference and Thrush still disagree, so the survivors name the gap.

const isFinal = byte => byte >= 0x40 && byte <= 0x7e;

function escapeEnd(bytes, start) {
  let index = start + 1;
  if (index >= bytes.length) return bytes.length;
  const kind = bytes[index++];
  if (kind === 0x5b) { // CSI
    while (index < bytes.length && !isFinal(bytes[index]) && bytes[index] !== 0x1b) index++;
    return bytes[index] === 0x1b ? index : Math.min(index + 1, bytes.length);
  }
  if ([0x5d, 0x50, 0x5f, 0x5e, 0x58].includes(kind)) { // OSC, DCS, APC, PM and SOS strings
    while (index < bytes.length) {
      const byte = bytes[index];
      if (byte === 0x07 || byte === 0x18 || byte === 0x1a) return index + 1;
      if (byte === 0x1b) return bytes[index + 1] === 0x5c ? index + 2 : index;
      index++;
    }
    return index;
  }
  index--;
  while (index < bytes.length && bytes[index] >= 0x20 && bytes[index] <= 0x2f) index++;
  return Math.min(index + 1, bytes.length);
}

/** Splits bytes into text runs, single controls and whole escape sequences. */
export function tokenize(bytes) {
  const tokens = [];
  for (let start = 0; start < bytes.length;) {
    const byte = bytes[start];
    let end = start + 1;
    if (byte === 0x1b) end = escapeEnd(bytes, start);
    else if (byte >= 0x20 && byte !== 0x7f) while (end < bytes.length && bytes[end] >= 0x20 && bytes[end] !== 0x7f && bytes[end] !== 0x1b) end++;
    tokens.push(bytes.subarray(start, end));
    start = end;
  }
  return tokens;
}

/** Splits a text run into its UTF-8 scalars, keeping malformed bytes on their own. */
function scalars(token) {
  if (token[0] < 0x20 || token[0] === 0x7f || token.length === 1) return [token];
  const result = [];
  for (let start = 0; start < token.length;) {
    let end = start + 1;
    while (end < token.length && (token[end] & 0xc0) === 0x80) end++;
    result.push(token.subarray(start, end));
    start = end;
  }
  return result;
}

/** A case's steps as tokens that remember which write they came from, so chunk boundaries survive. */
function pieces(steps) {
  const result = [];
  steps.forEach((step, index) => {
    if (step.write) for (const token of tokenize(step.write)) result.push({ write: token, chunk: index });
    else if (!step.checkpoint) result.push({ step });
  });
  return result;
}

function concatenate(arrays) {
  const result = new Uint8Array(arrays.reduce((total, array) => total + array.length, 0));
  let offset = 0;
  for (const array of arrays) { result.set(array, offset); offset += array.length; }
  return result;
}

/** Rebuilds steps from tokens, joining neighbors that came from the same write. */
export function assemble(tokens) {
  const steps = [];
  for (const token of tokens) {
    const last = steps.at(-1);
    if (token.write && last?.parts && last.chunk === token.chunk) last.parts.push(token.write);
    else steps.push(token.write ? { parts: [token.write], chunk: token.chunk } : token.step);
  }
  return steps.map(step => step.parts ? { write: concatenate(step.parts) } : step);
}

/** Delta debugging over complements: the smallest list, one removal at a time, that still fails. */
async function minimize(items, fails, budget) {
  let granularity = 2;
  while (items.length >= 2 && budget.tests > 0) {
    const size = Math.ceil(items.length / granularity);
    let reduced = false;
    for (let start = 0; start < items.length && budget.tests > 0; start += size) {
      const complement = [...items.slice(0, start), ...items.slice(start + size)];
      budget.tests--;
      if (await fails(complement)) {
        items = complement;
        granularity = Math.max(granularity - 1, 2);
        reduced = true;
        break;
      }
    }
    if (!reduced) {
      if (granularity >= items.length) break;
      granularity = Math.min(granularity * 2, items.length);
    }
  }
  return items;
}

/** The kind of state a difference is in, such as `cursor position`, `active.visible`, `modes.insert` or `replies`. */
export const kindOf = difference => difference.path.replace(/\[.*$/, '').replace(/^cursor\.(row|column)$/, 'cursor position');

const csiPattern = /^\x1b\[([<=>?]?)([\d;:]*)([ -/]*[@-~])$/;

/** Removes single parameters from CSI sequences while the case still fails, so `1;4;42m` can become `4m`. */
async function dropParameters(tokens, fails, budget) {
  for (let index = 0; index < tokens.length; index++) {
    const match = tokens[index].write && Buffer.from(tokens[index].write).toString('latin1').match(csiPattern);
    if (!match) continue;
    let [, prefix, parameters, final] = match;
    parameters = parameters.split(';');
    for (let parameter = parameters.length - 1; parameter >= 0 && parameters.length > 1 && budget.tests > 0; parameter--) {
      const fewer = parameters.toSpliced(parameter, 1);
      const write = Uint8Array.from(Buffer.from(`\x1b[${prefix}${fewer.join(';')}${final}`, 'latin1'));
      const candidate = tokens.with(index, { ...tokens[index], write });
      budget.tests--;
      if (await fails(candidate)) { tokens = candidate; parameters = fewer; }
    }
  }
  return tokens;
}

export class Shrinker {
  constructor(reference, thrush) {
    this.reference = reference;
    this.thrush = thrush;
  }

  /** Thrush's differences from the reference at a visible checkpoint after the given steps. */
  async differences(testCase, steps) {
    const probe = { ...testCase, steps: [...steps, { checkpoint: 'end', scope: 'visible' }] };
    const result = await this.thrush.run(probe, this.reference.run(probe));
    return result.crashed ? [{ path: 'crash', reference: 'no crash', thrush: result.crashed }] : result.differences;
  }

  /**
   * For each kind of visible state that ever disagrees, the first write or resize after which it does,
   * as { steps, kinds: Map(kind → { step, difference }) }, or { steps, crashed }.
   */
  async divergences(testCase) {
    const steps = testCase.steps.filter(step => !step.checkpoint);
    const probe = {
      ...testCase,
      steps: steps.flatMap((step, index) => [step, { checkpoint: `after step ${index}`, scope: 'visible' }]),
    };
    const result = await this.thrush.run(probe, this.reference.run(probe));
    if (result.crashed) return { steps, crashed: result.crashed, kinds: new Map() };
    const kinds = new Map();
    // The implied final checkpoint is a full one, and history differences there are reported separately.
    for (const difference of result.differences.filter(difference => difference.checkpoint !== 'end')) {
      const step = Number(difference.checkpoint.replace('after step ', ''));
      const kind = kindOf(difference);
      if (!kinds.has(kind) || kinds.get(kind).step > step) kinds.set(kind, { step, difference });
    }
    return { steps, kinds };
  }

  /**
   * The fewest tokens that still disagree in the same way, from a case that disagrees somewhere in `steps`.
   * "The same way" is the kind of state that differs, such as the cursor, cells or replies, which is the
   * first difference's unless `kind` names one, so shrinking can't wander off to an unrelated gap. Returns
   * { steps, differences } for the minimal case, or undefined when the visible state doesn't disagree that way.
   */
  async shrink(testCase, steps, { tests = 3000, scalars: splitText = true, kind } = {}) {
    let tokens = pieces(steps);
    const original = await this.differences(testCase, assemble(tokens));
    kind ??= original[0] && kindOf(original[0]);
    if (!original.some(difference => kindOf(difference) === kind)) return undefined;
    const fails = async candidate => (await this.differences(testCase, assemble(candidate))).some(difference => kindOf(difference) === kind);
    // Find the shortest failing prefix first, since everything after the culprit is noise.
    let low = 1, high = tokens.length;
    while (low < high) {
      const middle = (low + high) >> 1;
      if (await fails(tokens.slice(0, middle))) high = middle; else low = middle + 1;
    }
    tokens = tokens.slice(0, high);
    const budget = { tests };
    tokens = await minimize(tokens, fails, budget);
    tokens = await dropParameters(tokens, fails, budget);
    const split = tokens.flatMap(token => token.write ? scalars(token.write).map(write => ({ ...token, write })) : [token]);
    if (splitText && split.length > tokens.length && split.length <= 4000) tokens = await minimize(split, fails, budget);
    const minimal = assemble(tokens);
    return { steps: minimal, differences: await this.differences(testCase, minimal) };
  }

  /**
   * The functions the reference dispatched for the given steps, without repeats, with `resize` for a
   * window change and `focus` for a focus change.
   */
  functions(testCase, steps) {
    const { functions } = this.reference.run({ ...testCase, steps }, { observe: true });
    const host = [...steps.some(step => step.resize) ? ['resize'] : [], ...steps.some(step => step.focus !== undefined) ? ['focus'] : []];
    return [...new Set([...functions.flat(), ...host])];
  }
}
