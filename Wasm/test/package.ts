import { Terminal } from "thrush-wasm";

// Checks the installed package as Bun, Node and a Bun-compiled binary run it, and as TypeScript
// reads its declarations.

const text = (value: string) => new TextEncoder().encode(value);
const nothing = new Uint8Array();

function same(actual: Uint8Array, expected: Uint8Array, what: string) {
  if (actual.length === expected.length && actual.every((byte, index) => byte === expected[index])) return;
  throw new Error(`${what}: ${JSON.stringify(new TextDecoder().decode(actual))}`);
}

function fails(action: () => unknown, kind: typeof Error, what: string) {
  try {
    action();
  } catch (error) {
    if (error instanceof Error && error.constructor === kind) return;
    throw error;
  }
  throw new Error(`${what} didn't throw a ${kind.name}`);
}

const terminal = new Terminal(80, 24);
same(terminal.write(text("\x1b[1;31mhello\r\nworld")), nothing, "Text has no replies");
same(terminal.write(text("\x1b[6n")), text("\x1b[2;6R"), "A cursor position request");

// A replay redraws a terminal on a blank one of the same size, which then replays the same bytes.
const redraw = (source: Terminal, columns: number, rows: number) => {
  const client = new Terminal(columns, rows);
  same(client.write(source.replay()), nothing, "A replay has no replies");
  same(client.replay(), source.replay(), `A replay at ${columns} by ${rows}`);
  return client;
};
redraw(terminal, 80, 24);
terminal.resize(3, 24);
redraw(terminal, 3, 24);

// A disposed terminal stays inert, even after another takes its place in the module.
terminal.dispose();
terminal.dispose();
const next = redraw(new Terminal(40, 10), 40, 10);
fails(() => terminal.write(text("x")), Error, "Writing to a disposed terminal");
fails(() => terminal.resize(80, 24), Error, "Resizing a disposed terminal");
fails(() => terminal.replay(), Error, "Replaying a disposed terminal");
redraw(next, 40, 10);

for (const [columns, rows] of [[0, 24], [80, 1.5], [2049, 24], [80, NaN]]) {
  fails(() => new Terminal(columns, rows), RangeError, `A ${columns} by ${rows} terminal`);
  fails(() => next.resize(columns, rows), RangeError, `Resizing to ${columns} by ${rows}`);
}
fails(() => next.write("text" as unknown as Uint8Array), TypeError, "Writing a string");
console.log(`thrush-wasm works in ${navigator.userAgent}`);
