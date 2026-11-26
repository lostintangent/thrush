# Pinned reference

Thrush's fixtures, conformance cases and emulator comparisons come from one reference emulator: the exact `@xterm/headless`, `@xterm/addon-unicode11` and `@xterm/xterm` packages in [package.json](package.json), locked by [bun.lock](bun.lock). [headless.mjs](headless.mjs) starts every reference terminal with the same options, 1,000 history rows, proposed APIs and Unicode 11 cell widths, and loads under Node or Bun. [reference.mjs](reference.mjs) adds what the browser package contributes under Bun: color and focus reports, the keyboard evaluator and the selection service. Each generated fixture records the packages and options it came from.

Install the reference before regenerating anything. Swift builds and tests read the checked-in JSON directly and don't need it.

```sh
bun install --cwd Fixtures/reference --frozen-lockfile
```

## First bytes

`first-bytes.json` records a scripted 80 × 24 shell transcript. Each event supplies PTY output at its microsecond offset from attach. Apply those bytes, collect the immediate replies and read the named zero-based row. An optional `up` asks the client to press Up after handling that event. The trailing space in the prompt is a printed cell. Empty cells to the right are omitted from the row.

The generator writes each chunk to a reference terminal. It samples the visible row from the active buffer and collects replies through `onData`. For Up it runs the browser package's keyboard evaluator against the live cursor-key mode. The benchmark records the SHA-256 of the exact JSON file.

```sh
bun Fixtures/reference/generate.mjs
shasum -a 256 Fixtures/first-bytes.json
```

## Unicode widths and PTY recordings

Run `bun Fixtures/reference/generate-widths.mjs` to regenerate the core's Unicode 11 cell-width data. The generator queries the pinned provider for each code point and groups the observed zero- and double-width intervals. Thrush looks up these observations with its own Swift code.

The numbered compiler log and the interactive Vim session retain their actual PTY bytes and resize events. Their generator replays them through the pinned reference. [Shell and Vim recordings](m2/README.md)

Two further captures open the same Swift source in Vim against the dark and light themes. The PTY records Vim’s choice of background, the resulting syntax colors and the native repaints at three grid sizes. [Styled Swift recordings](m3/README.md)

The three interactive workflow recordings include a soft-wrapped shell copy, an actual server-serialized Vim screen and a streamed Codex response. [Shell, Vim and Codex workflows](m4/README.md)

## Conformance

The conformance harness replays every control function, these recordings, more real programs and seeded random streams through the reference and ThrushCore, compares their complete state and ranks the differences by how often real programs emit each function. [Conformance harness](conformance/README.md)

## Window title

The title oracle samples the reference's window title after each supplied chunk. On the frozen Codex recording it records the first event, every change between PTY reads and the final event. The capture sets `workspace`, updates it while streaming the response, and clears it with an empty OSC 0. The oracle records the SHA-256 of the complete recording so its event indices can be checked against those exact bytes.

The focused cases exercise OSC 0 and 2, BEL, split ST, UTF-8, cancellation, an icon-name update and disabled title-stack operations. RIS preserves the existing title. Two cases use complete 16 × 4 replay frames from a server's scrollback serializer. Its explicit OSC 2 prefix restores a nonempty title and clears stale state for an empty title. The two server inputs and their exact binary frames are in `window-title.capture.json`, which also records the serializer source by SHA-256. The oracle feeds those frames to a reference terminal to obtain the expected titles.

From the repository root, verify the generated JSON byte for byte. Omit `--check` to write it.

```sh
bun Fixtures/reference/window-title.mjs --check
```
