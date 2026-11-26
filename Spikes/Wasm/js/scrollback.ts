import { readFileSync } from "node:fs";

/**
 * ThrushCore, compiled to WebAssembly, in the shape of Toy Box's `ScrollbackBuffer`: it holds a PTY's
 * screen and history for a reconnecting client, and replays them as the bytes that redraw them.
 *
 * Every buffer shares one instance of the module. Each owns a terminal in it, named by a handle.
 */
export class ScrollbackBuffer {
  #handle: number;

  constructor(cols: number, rows: number) {
    this.#handle = thrush.thrush_new(cols, rows);
    terminals.register(this, this.#handle, this);
  }

  /** Parses `data` now, so the callback runs before this returns. */
  write(data: string | Uint8Array, callback?: () => void) {
    const bytes = typeof data === "string" ? textEncoder.encode(data) : data;
    if (bytes.length > 0) {
      const input = thrush.thrush_input(bytes.length);
      new Uint8Array(thrush.memory.buffer, input, bytes.length).set(bytes);
      thrush.thrush_write(this.#handle, bytes.length);
    }
    callback?.();
  }

  resize(cols: number, rows: number) {
    thrush.thrush_resize(this.#handle, cols, rows);
  }

  /** The bytes that redraw this screen, its history and its modes on a client that resets first. */
  replay() {
    const length = thrush.thrush_replay(this.#handle);
    const bytes = new Uint8Array(length + resumedClientPrefix.length);
    bytes.set(resumedClientPrefix);
    bytes.set(new Uint8Array(thrush.memory.buffer, thrush.thrush_output(), length), resumedClientPrefix.length);
    return bytes;
  }

  /** Frees the terminal now. Otherwise it goes when this buffer is collected. */
  dispose() {
    terminals.unregister(this);
    thrush.thrush_free(this.#handle);
  }
}

/**
 * ThrushCore's replay assumes a blank terminal. A resumed browser terminal keeps the colors a program
 * set through a reset, so it restores the defaults first.
 */
const resumedClientPrefix = new TextEncoder().encode("\x1b]104\x07\x1b]110\x07\x1b]111\x07\x1b]112\x07");

type ThrushExports = {
  memory: WebAssembly.Memory;
  _initialize(): void;
  thrush_new(cols: number, rows: number): number;
  thrush_free(handle: number): void;
  thrush_input(count: number): number;
  thrush_write(handle: number, count: number): number;
  thrush_resize(handle: number, cols: number, rows: number): void;
  thrush_replay(handle: number): number;
  thrush_output(): number;
};

const textEncoder = new TextEncoder();
const modulePath = process.env.THRUSH_WASM ?? new URL("../out/thrush.wasm", import.meta.url).pathname;
const thrush = instantiate(new WebAssembly.Module(readFileSync(modulePath)));
const terminals = new FinalizationRegistry<number>((handle) => thrush.thrush_free(handle));

/** Starts the module with the few WASI calls the Swift runtime makes. Any other call fails. */
function instantiate(module: WebAssembly.Module) {
  let exports: ThrushExports;
  const memory = () => new DataView(exports.memory.buffer);
  const calls: Record<string, (...args: number[]) => number> = {
    random_get: (pointer, length) => {
      crypto.getRandomValues(new Uint8Array(exports.memory.buffer, pointer, length));
      return 0;
    },
    args_sizes_get: (count, size) => (memory().setUint32(count, 0, true), memory().setUint32(size, 0, true), 0),
    environ_sizes_get: (count, size) => (memory().setUint32(count, 0, true), memory().setUint32(size, 0, true), 0),
    fd_write: (fd, iovs, count, written) => {
      let total = 0;
      for (let i = 0; i < count; i++) {
        const base = memory().getUint32(iovs + i * 8, true);
        const length = memory().getUint32(iovs + i * 8 + 4, true);
        process.stderr.write(new Uint8Array(exports.memory.buffer, base, length));
        total += length;
      }
      memory().setUint32(written, total, true);
      return 0;
    },
    proc_exit: (code) => {
      throw new Error(`ThrushCore exited with ${code}`);
    },
  };
  const wasi: Record<string, (...args: number[]) => number> = {};
  for (const { module: name, name: call } of WebAssembly.Module.imports(module)) {
    if (name === "wasi_snapshot_preview1") wasi[call] = calls[call] ?? (() => 52); // ENOSYS
  }
  const instance = new WebAssembly.Instance(module, { wasi_snapshot_preview1: wasi });
  exports = instance.exports as unknown as ThrushExports;
  exports._initialize();
  return exports;
}
