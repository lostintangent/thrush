// The canonical terminal state both emulators report, and how it is stored.
//
// A checkpoint is { name, size, cursor, buffer, modes, title, replies, active, normal? }.
// A screen is { history?, visible } and a line is { wrapped, cells } where each cell is
// [text, width, style]. Trailing blank cells are omitted. Replies are bytes in a latin1 string.
// Sources/ThrushConformance/Checkpoint.swift decodes the same shape and owns comparison.

export const emptyLine = { isBlank: cell => cell[0] === '' && cell[1] === 1 && cell[2] === '' };

/** Interns cells and lines so long histories and repeated rows stay small in Git. */
export class Pool {
  values = [];
  #ids = new Map();
  constructor(values = []) { values.forEach(value => this.id(value)); }
  id(value) {
    const key = JSON.stringify(value);
    let id = this.#ids.get(key);
    if (id === undefined) {
      id = this.values.length;
      this.values.push(value);
      this.#ids.set(key, id);
    }
    return id;
  }
}

export function pack(checkpoint, pools) {
  const packScreen = screen => screen && Object.fromEntries(Object.entries(screen).map(([key, lines]) => [key,
    lines.map(line => pools.lines.id([line.wrapped ? 1 : 0, ...line.cells.map(cell => pools.cells.id(cell))]))]));
  return { ...checkpoint, active: packScreen(checkpoint.active), ...(checkpoint.normal && { normal: packScreen(checkpoint.normal) }) };
}
