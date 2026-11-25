# Measuring the packaged renderer

Build the native Mac demo and run its Release benchmark from a logged-in graphical session. The benchmark opens a real window, measures the drawable presentations, then closes it. It runs without a WebSocket peer.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
scripts/build-demo.sh mac
swift run -c release ThrushBench --render .build/demo/mac/Thrush.app
python3 scripts/check-render-report.py .build/benchmarks/render.json
```

The simulator uses the same Release workload. Supply the UDID of a booted iPhone. The script installs the packaged demo and briefly opens Settings on that simulator to exercise the app's background transition.

```sh
scripts/build-demo.sh simulator
scripts/benchmark-simulator.sh "$udid" .build/demo/simulator/Thrush.app .build/benchmarks/render-simulator.json
```

The first update draws every row with indexed cyan, default text, single-column digits, a CJK ideograph and a color emoji. The six-cell prefix is `A翼🐦Z`. Ten rounds follow. Each moves the cursor, replaces text on one row, scrolls a line into the bottom of the viewport and repaints the full grid. Every warm round uses the same glyphs and styles. The script verifies the input stream's SHA-256 independently from the emulator and checks the dirty rows, glyph uploads and monotonic screen generations.

Each submission records CPU preparation time, command-buffer GPU duration when available, the monotonic host timestamp immediately before supplying the output bytes and the drawable's actual presentation timestamp. The JSON preserves individual timestamps and reports missing presentations separately. The receipt-to-presentation measure includes local parsing, scheduling and rendering. Socket and key-to-echo latency belong to the interaction replay. After the first screen submits, a display link samples twelve refresh intervals in the same window. Schema version 2 records asynchronous Metal shader compilation and the elapsed time from native view creation to the first content submission. Each cold run starts in a new process with an empty Thrush pipeline cache. Metal may reuse its system compiler cache across launches. The report compares presented latency with the median interval.

After the redraws, a selection spans the two wide glyphs while the view switches between Slate Light, Slate Dark and a custom palette. The checker requires each switch to keep the generation and grid, with zero glyph uploads and zero row preparations. A separate final measurement counts all Metal submissions during one second at a settled prompt, one second with updates pending on the suspended renderer, and an actual native hide or background interval. The terminal cursor stays steady.

The JSON includes the commit and worktree state from app packaging, the device model, OS, toolchain, load average, core count, thermal and power state and grid dimensions. A simulator run measures a shared Mac's graphics stack. Use the Mac and physical iPhone for device timing baselines. Use five quiet passes to estimate variance before setting timing gates.

For a capture of a running demo, use `scripts/capture-demo.sh mac "$pid" frame.png` or `scripts/capture-demo.sh simulator "$udid" frame.png`. These commands capture the actual window or device framebuffer with its native chrome.

## First Mac measurement

The resource-free Release bundle at `aac046b` drew an 80 × 24 grid on an M1 Max running macOS 27.2.1. The display link measured 16.667 ms. The system's one-minute load was 396.32 on ten cores and its thermal state was fair. This single contended run records cache behavior and provisional timings. [Saved render samples](render-mac.json)

The new process compiled its embedded Metal shader in 279.336 ms. Its first content submission occurred 812.020 ms after view creation.

| Operation | Frames | CPU p95, ms | GPU p95, ms | Glyph uploads | Maximum rows prepared |
| --- | ---: | ---: | ---: | ---: | ---: |
| Cold | 1 | 10.783 | 1.380 | 14 | 24 |
| Cursor | 10 | 0.126 | 0.105 | 0 | 0 |
| One row | 10 | 0.134 | 0.102 | 0 | 1 |
| Scroll | 10 | 0.135 | 0.105 | 0 | 1 |
| Full grid | 10 | 0.274 | 0.102 | 0 | 24 |

All three theme switches reused every visible row and glyph. The foreground-idle observation lasted 1.009 s, the suspended-renderer observation 1.057 s and the hidden-window observation 1.227 s. Each recorded zero additional submissions.

Three partial generations inside synchronized output produced 0 submissions. Closing the block submitted one coherent screen. When the end marker was omitted, the watchdog submitted the latest generation 1000.665 ms after the block opened, followed by 1.027 s with zero further submissions.

The Mac session was locked. Its drawable callbacks returned zero presentation timestamps on all 41 drawing workload frames and both synchronized-output releases. CPU preparation, GPU duration and submission timestamps are available. A foreground run on an unlocked display is still required for receipt-to-presentation latency.

## Native input and echo latency

Build the Release app, then run the same input sequence through its native text responder and a fresh loopback socket.

```sh
scripts/build-demo.sh mac
swift run -c release ThrushBench --interactions .build/demo/mac/Thrush.app

scripts/build-demo.sh simulator
bun scripts/interaction-peer.ts --simulator "$udid" .build/demo/simulator/Thrush.app .build/benchmarks/interactions-iphone.json
```

The peer expects 22 binary input frames. It checks one committed Japanese glyph after two marked-text updates, one bracketed paste and 20 printable keys. Each echo has a distinct terminal generation. The app also selects and copies a wide glyph across a soft wrap, reads a history row, and activates Latest.

The Mac report is written to `.build/benchmarks/interactions.json`. Each key includes monotonic timestamps for the responder action, the WebSocket write and receipt of the corresponding echo. A matching Metal frame adds submission time. A drawable presentation callback adds visible-echo time on supported displays. The report publishes presentation percentiles only for runs in which all 20 keys have presentation timestamps. Compare visible echo against two display intervals using the interval measured on the same run. Environment fields record contention, thermal state, source revision and working-tree status.

The same report includes `anchoredReplay` for a scrolled 80 × 24 viewport with 1,000 history rows. Twenty replacements alternate between two pre-parsed snapshots whose numbered build steps shift by twelve rows. Each replacement must keep **Build step 512** at the top and **Build step 513** selected. The `milliseconds` samples and `p95Milliseconds` cover restoring the viewport and its native interaction state. Parsing, network latency and display timing have their own measurements above.

The [packaged Mac interaction report](interactions-mac.json) records a clean build of `2a3327e` on the contended M1 Max. Across 20 keys, p95 was 0.066 ms to the WebSocket write and 0.440 ms to receipt of the matching echo. All 20 echoes reached Metal submission. The locked display supplied no presentation times. Restoring the history reader and selection across 1,000 retained rows took 6.282 ms p95 over 20 replacements.
