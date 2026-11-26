/**
 * A terminal without a display, for a server that keeps a program's screen while no client shows it.
 * Write the program's output to it, and it keeps the screen, history and modes as a terminal would.
 * Its replay redraws them on a client that attaches later.
 *
 * Every terminal lives in one instance of ThrushCore's WebAssembly module, which starts with the first.
 */
export declare class Terminal {
  #private;

  /** A blank terminal of `columns` by `rows`, each from 1 to 2,048. */
  constructor(columns: number, rows: number);

  /**
   * Writes a program's output to this terminal, and returns the replies a terminal sends back, such
   * as its answer to a cursor position request. Send nonempty replies to the program in order.
   * Characters and escape sequences can span writes.
   */
  write(bytes: Uint8Array): Uint8Array;

  /** Resizes the grid, reflowing history at soft wraps. Give the program's PTY the same size. */
  resize(columns: number, rows: number): void;

  /** The bytes that redraw this terminal's screen, history and modes on a blank one of the same size. */
  replay(): Uint8Array;

  /** Frees this terminal now, rather than when it's collected. Its other methods throw afterward. */
  dispose(): void;
}
