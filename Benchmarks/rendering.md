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

The Release bundle at `1f9f8c0` drew an 80 × 24 grid on an M1 Max running macOS 27.2.1. The display link measured 16.667 ms. The system's one-minute load was 495.06 on ten cores and its thermal state was fair. This single contended run records cache behavior and provisional timings. [Saved render samples](render-mac.json)

| Operation | Frames | CPU p95, ms | GPU p95, ms | Glyph uploads | Maximum rows prepared |
| --- | ---: | ---: | ---: | ---: | ---: |
| Cold | 1 | 17.648 | 0.436 | 14 | 24 |
| Cursor | 10 | 0.122 | 0.105 | 0 | 0 |
| One row | 10 | 0.143 | 0.105 | 0 | 1 |
| Scroll | 10 | 0.133 | 0.107 | 0 | 1 |
| Full grid | 10 | 0.314 | 0.108 | 0 | 24 |

All three theme switches reused every visible row and glyph. The foreground-idle observation lasted 1.040 s, the suspended-renderer observation 1.066 s and the hidden-window observation 1.215 s. Each recorded zero additional submissions. The Mac session was locked. Its drawable callbacks reported zero presentation timestamps on all 41 workload frames, so this run supplies no receipt-to-presentation latency. A foreground run on an unlocked display is still required for that measurement.
