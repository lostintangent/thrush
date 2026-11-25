# First bytes reference

`first-bytes.json` records a scripted 80 × 24 shell transcript. Each event supplies PTY output at its microsecond offset from attach. Apply those bytes, collect the immediate replies and read the named zero-based row. An optional `up` asks the client to press Up after handling that event. The trailing space in the prompt is a printed cell. Empty cells to the right are omitted from the row.

The generator writes each chunk to the same headless xterm and Unicode 11 addon as the pinned Toy Box server. It samples the visible row from xterm’s active buffer and collects replies through `onData`. For Up it runs xterm’s keyboard evaluator from the browser package against the live cursor-key mode. The fixture lists the Toy Box revision and all three package versions. The benchmark records the SHA-256 of the exact JSON file. [Server configuration](https://github.com/lostintangent/toy-box/blob/b9d0eca3c5f4e9036e58327ba633eff52474bb92/src/features/terminal/model/emulator.ts) · [Pinned dependencies](https://github.com/lostintangent/toy-box/blob/b9d0eca3c5f4e9036e58327ba633eff52474bb92/bun.lock)

To regenerate, use a Toy Box checkout at `b9d0eca3c5f4e9036e58327ba633eff52474bb92` with its dependencies installed via `bun install --frozen-lockfile`. Run these commands from the Thrush repository with the checkout at `../toy-box`.

```sh
NODE_PATH="$PWD/../toy-box/node_modules/@xterm/xterm/src" bun Fixtures/reference/generate.mjs ../toy-box
shasum -a 256 Fixtures/first-bytes.json
```

`NODE_PATH` resolves the browser keyboard evaluator’s internal TypeScript imports. Swift builds and tests read the checked-in JSON directly.

## Unicode widths and PTY recordings

Run `bun Fixtures/reference/generate-widths.mjs ../toy-box` to regenerate the core's Unicode 11 cell-width data. The generator queries the pinned provider for each code point and groups the observed zero- and double-width intervals. Thrush looks up these observations with its own Swift code.

The numbered compiler log and the interactive Vim session retain their actual PTY bytes and resize events. Their reference generator replays them through the same pinned server emulator. [Shell and Vim recordings](m2/README.md)

Two further captures open the same Swift source in Vim against Slate Dark and Slate Light. The PTY records Vim’s choice of background, the resulting syntax colors and the native repaints at three grid sizes. [Styled Swift recordings](m3/README.md)

The three interactive workflow recordings include a soft-wrapped shell copy, an actual server-serialized Vim screen and a streamed Codex response. [Shell, Vim and Codex workflows](m4/README.md)

## Conformance

The conformance harness replays every control function, these recordings, more real programs and seeded random streams through the reference and ThrushCore, compares their complete state and ranks the differences by how often real programs emit each function. [Conformance harness](conformance/README.md)

## Window title

The title oracle samples the pinned headless xterm's window title after each supplied chunk. On the frozen Codex replay it records the first event, every change between PTY reads and the final event. The capture sets `workspace`, updates it while streaming the response, and clears it with an empty OSC 0. The oracle records the SHA-256 of the complete replay so its event indices can be checked against those exact bytes.

The focused cases exercise OSC 0 and 2, BEL, split ST, UTF-8, cancellation, an icon-name update and disabled title-stack operations. RIS preserves the existing title. Two cases use complete 16 × 4 replay frames produced by Toy Box’s `ScrollbackBuffer`. Its explicit OSC 2 prefix restores a nonempty title and clears stale state for an empty title. The oracle records the serializer source digest separately from the pinned xterm revision.

The two server inputs and their exact binary replay frames are in `window-title.capture.json`. The title oracle feeds those frames to the pinned terminal to obtain the expected titles. The capture identifies the reviewed local `src/features/terminal/server/scrollback.ts` by SHA-256 `f4857aa8af1f38ff6d9f99df3e572fcdc10681ac6a827162d97218ad73a80e1d`. The published reference revision predates the title prefix.

From the repository root, verify the generated JSON byte for byte using the published Toy Box checkout at `b9d0eca3c5f4e9036e58327ba633eff52474bb92` and its locked dependencies. Omit `--check` to write the generated JSON.

```sh
NODE_PATH="$PWD/../toy-box/node_modules/@xterm/xterm/src" bun Fixtures/reference/window-title.mjs ../toy-box --check
```

To also verify the source digest and reproduce the captured server frames, supply a checkout containing the matching serializer and its dependencies as a second path.

```sh
NODE_PATH="$PWD/../toy-box/node_modules/@xterm/xterm/src" bun Fixtures/reference/window-title.mjs ../toy-box ../toy-box-title --check
```
