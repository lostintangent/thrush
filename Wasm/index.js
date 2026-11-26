import module from "./module.js";

// Each terminal is a handle into ThrushCore's WebAssembly module, which index.d.ts documents. Bytes
// cross through the module's memory: a write copies them into its input buffer, and replies and
// replays come back as copies of its output buffer.

// Every terminal shares the module's 4 GiB of memory. At the largest size, a screen and history
// styled cell by cell hold about 150 MiB, and their replay briefly needs about 550 MiB more.
const largest = 2048;
let instance;
const terminals = new FinalizationRegistry((handle) => instance.thrush_dispose(handle));

export class Terminal {
  #handle;

  constructor(columns, rows) {
    checkSize(columns, rows);
    this.#handle = core().thrush_new(columns, rows);
    terminals.register(this, this.#handle, this);
  }

  write(bytes) {
    const handle = this.#live();
    if (!(bytes instanceof Uint8Array)) throw new TypeError("Write a terminal's output as a Uint8Array.");
    const thrush = core();
    // Making room can grow the memory, which replaces its buffer.
    const input = thrush.thrush_input(bytes.length);
    new Uint8Array(thrush.memory.buffer, input, bytes.length).set(bytes);
    return output(thrush, thrush.thrush_write(handle, bytes.length));
  }

  resize(columns, rows) {
    const handle = this.#live();
    checkSize(columns, rows);
    core().thrush_resize(handle, columns, rows);
  }

  replay() {
    const handle = this.#live();
    const thrush = core();
    return output(thrush, thrush.thrush_replay(handle));
  }

  dispose() {
    if (this.#handle < 0) return;
    terminals.unregister(this);
    core().thrush_dispose(this.#handle);
    this.#handle = -1;
  }

  #live() {
    if (this.#handle < 0) throw new Error("This terminal was disposed.");
    return this.#handle;
  }
}

function checkSize(columns, rows) {
  const fits = (count) => Number.isInteger(count) && count >= 1 && count <= largest;
  if (!fits(columns) || !fits(rows)) {
    throw new RangeError(`A terminal is 1 to ${largest} columns by 1 to ${largest} rows, not ${columns} by ${rows}.`);
  }
}

/** A copy of the bytes a call left in the output buffer. Most writes have no replies. */
function output(thrush, length) {
  if (length === 0) return new Uint8Array();
  return new Uint8Array(thrush.memory.buffer, thrush.thrush_output(), length).slice();
}

/** Starts the module the first time a terminal needs it, synchronously from the bytes it carries. */
function core() {
  if (instance) return instance;
  const text = atob(module);
  const bytes = new Uint8Array(text.length);
  for (let index = 0; index < text.length; index++) bytes[index] = text.charCodeAt(index);
  const wasi = {
    // The one system call ThrushCore makes, to seed hashing.
    random_get(pointer, length) {
      crypto.getRandomValues(new Uint8Array(instance.memory.buffer, pointer, length));
      return 0;
    },
  };
  instance = new WebAssembly.Instance(new WebAssembly.Module(bytes), { wasi_snapshot_preview1: wasi }).exports;
  instance._initialize();
  return instance;
}
