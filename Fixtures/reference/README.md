# Pinned reference

Thrush's fixtures, conformance cases and emulator comparisons come from one reference emulator: the exact `@xterm/headless`, `@xterm/addon-unicode11` and `@xterm/xterm` packages in [package.json](package.json), locked by [bun.lock](bun.lock). [headless.mjs](headless.mjs) starts every reference terminal with the same options, 1,000 history rows, proposed APIs and Unicode 11 cell widths, and loads under Node or Bun. [reference.mjs](reference.mjs) adds what the browser package contributes under Bun: color and focus reports, the keyboard evaluator and the selection service. Each generated recording names the packages and options it came from.

Install the reference before regenerating anything. Swift builds and tests read the checked-in JSON directly and don't need it.

```sh
bun install --cwd Fixtures/reference --frozen-lockfile
```

## Unicode widths and PTY recordings

Run `bun Fixtures/reference/generate-widths.mjs` to regenerate the core's Unicode 11 cell-width data. The generator queries the pinned provider for each code point and groups the observed zero- and double-width intervals. Thrush looks up these observations with its own Swift code.

Every recorder runs its program through one PTY session in [capture.py](capture.py), which records each read, key and window change in order. As the program runs, [replies.mjs](replies.mjs) answers its queries the way the reference does, so the recording follows the replies a terminal sends.

The numbered compiler log and the interactive Vim session retain their actual PTY bytes and resize events. Their generator replays them through the pinned reference. [Shell and Vim recordings](m2/README.md)

Two further captures open the same Swift source in Vim against the dark and light themes. The PTY records Vim’s choice of background, the resulting syntax colors and the native repaints at three grid sizes. [Styled Swift recordings](m3/README.md)

The three interactive workflow recordings include a soft-wrapped shell copy, an actual server-serialized Vim screen and a streamed Codex response. [Shell, Vim and Codex workflows](m4/README.md)

## Conformance

The conformance harness replays every control function, these recordings, more real programs and seeded random streams through the reference and ThrushCore, and compares their complete state. [Conformance harness](conformance/README.md)
