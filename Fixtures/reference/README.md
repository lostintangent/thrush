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
