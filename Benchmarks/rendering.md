# Measuring the packaged renderer

Build the Mac [proofs app](../docs/proofs.md) and run its Release benchmark from a logged-in graphical session. The benchmark opens a real window, measures the drawable presentations, then closes it. It runs without a WebSocket peer.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
scripts/build-app.sh proofs mac
.build/proofs/mac/Thrush.app/Contents/MacOS/ThrushProofs --benchmark .build/benchmarks/render.json
python3 Benchmarks/check-render-report.py .build/benchmarks/render.json
```

The simulator uses the same Release workload. Supply the UDID of a booted iPhone. The script installs the packaged proofs app and briefly opens Settings on that simulator to exercise the app's background transition.

```sh
scripts/build-app.sh proofs simulator
scripts/benchmark-simulator.sh "$udid" .build/proofs/simulator/Thrush.app .build/benchmarks/render-simulator.json
```

The first update draws every row with indexed cyan, default text, single-column digits, a CJK ideograph and a color emoji. The six-cell prefix is `A翼🐦Z`. Ten rounds follow. Each moves the cursor, replaces text on one row, scrolls a line into the bottom of the viewport and repaints the full grid. Every warm round uses the same glyphs and styles. The script verifies the input stream's SHA-256 independently from the emulator and checks the dirty rows, glyph uploads and monotonic screen generations.

Each submission records CPU preparation time, command-buffer GPU duration when available, the monotonic host timestamp immediately before supplying the output bytes and the drawable's actual presentation timestamp. The benchmark advances after a successful GPU completion. On a display delivering presentation events, it waits up to 250 ms for the matching drawable before feeding the next update. If the window server stops delivering those events, the benchmark continues at GPU completion and resumes presentation pacing when a positive timestamp arrives. It keeps collecting late timestamps by submission through the final one-second idle observation. The JSON preserves each confirmed timestamp and counts missing presentations separately. A missing GPU completion or failed command fails the run.

The receipt-to-presentation measure includes local parsing, scheduling and rendering. Socket and key-to-echo latency belong to the native input benchmark. After the first screen submits, a display link samples twelve refresh intervals in the same window. The cold frame also records asynchronous Metal shader compilation and the elapsed time from native view creation to the first content submission. Each cold run starts in a new process with an empty Thrush pipeline cache. Metal may reuse its system compiler cache across launches. The report compares presented latency with the median interval.

After the redraws, a selection spans the two wide glyphs while the view switches between the light theme, the dark theme and a custom palette. The checker requires each switch to keep the generation and grid, with zero glyph uploads and zero row preparations. A separate final measurement counts all Metal submissions during one second at a settled prompt, one second with updates pending on the suspended renderer, and an actual native hide or background interval. The terminal cursor stays steady.

After the settled prompt, four blinking digits replace part of the first row for two 1.2 s blink cycles. The checker requires the submissions to fall between ten per second of fading and the display rate during the fades, plus one frame at each fade boundary, with zero rows prepared and zero glyph uploads. With Reduce Motion, the next 1.2 s must submit nothing after one redraw. The same digits without blink must then submit nothing for another 1.2 s. These bytes are outside the hashed workload.

The JSON includes the commit and worktree state from app packaging, the device model, OS, toolchain, load average, core count, thermal and power state and grid dimensions. A simulator run measures a shared Mac's graphics stack. Use the Mac and physical iPhone for device timing baselines. Use five quiet passes to estimate variance before setting timing gates.

For a capture of the running app, use `scripts/capture-demo.sh mac "$pid" frame.png` or `scripts/capture-demo.sh simulator "$udid" frame.png`. These commands capture the actual window or device framebuffer with its native chrome.

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

## Hosted Mac visibility check

The packaged Release app at `c1c1ecf` submitted zero frames during 1.015 s at a settled prompt, 1.005 s suspended with an update pending, and 1.185 s while AppKit hid the application. All 41 workload frames recorded CPU and GPU samples. The virtual display supplied no presentation timestamps. [Hosted run](https://github.com/lostintangent/thrush/actions/runs/45608393865/attempts/2) · [Saved report](render-mac-hosted.json)

## Finding plain-text links

The view looks for plain `http` and `https` addresses only on lines whose rows changed. Timed over the recordings on the M1 Max at `933e55b`, that costs 5 to 8 µs on a frame whose visible lines haven't changed and about a quarter of CPU preparation on an output frame, under 1% of a 60 Hz refresh.

## First iPhone simulator measurement

The clean Release build at `be859d5` drew a 47 × 42 portrait grid with the keyboard hidden on an iPhone 17 simulator running iOS 27.2 (24B8117). The hosted arm64 Mac ran macOS 27.0.1 and exposed three cores. Its one-minute load was 615.79. The simulator reported nominal thermal state and a 16.667 ms display interval. These timings describe one heavily contended run on the host graphics stack. [Hosted job](https://github.com/lostintangent/thrush/actions/runs/45566748815/job/139043292929) · [Saved simulator samples](render-simulator.json)

The new process compiled the embedded Metal shader in 2991.834 ms and submitted its first content 3377.887 ms after view creation.

| Operation | Frames | CPU p95, ms | GPU p95, ms | Glyph uploads | Maximum rows prepared |
| --- | ---: | ---: | ---: | ---: | ---: |
| Cold | 1 | 137.024 | 2.795 | 14 | 42 |
| Cursor | 10 | 0.615 | 2.562 | 0 | 0 |
| One row | 10 | 1.531 | 6.029 | 0 | 1 |
| Scroll | 10 | 0.845 | 0.126 | 0 | 1 |
| Full grid | 10 | 8.788 | 0.227 | 0 | 42 |

All three theme switches preserved the generation and reused every visible row and glyph. There were zero submissions during 1.009 s of foreground idle, 1.029 s with an update pending on the suspended renderer, and 4.079 s between UIKit background and foreground notifications while Settings was open.

Three partial synchronized generations produced zero submissions. The end marker released one frame. A truncated block released its latest generation once through the watchdog after 1001.981 ms, followed by 1.048 s with zero further submissions.

The simulator SDK exposes command-buffer timing but no drawable presentation timestamp. Each of the 41 workload frames has a CPU and GPU measurement. Receipt-to-presentation latency for those frames and both synchronized releases requires a physical iPhone.

## Native input and echo latency

Build the Release app, then run the same input sequence through its native text responder and a fresh loopback socket.

```sh
scripts/build-app.sh proofs mac
bun scripts/interaction-peer.ts .build/proofs/mac/Thrush.app .build/benchmarks/interactions.json

scripts/build-app.sh proofs simulator
bun scripts/interaction-peer.ts --simulator "$udid" .build/proofs/simulator/Thrush.app .build/benchmarks/interactions-iphone.json
```

The peer expects 22 binary input frames. It checks one committed Japanese glyph after two marked-text updates, one bracketed paste and 20 printable keys. Each echo has a distinct terminal generation. The app also selects and copies a wide glyph across a soft wrap, reads a history row, and activates Latest.

Each key includes monotonic timestamps for the responder action, the WebSocket write and receipt of the corresponding echo. A matching Metal frame adds submission time. A drawable presentation callback adds visible-echo time on supported displays. The report publishes presentation percentiles only for runs in which all 20 keys have presentation timestamps. Compare visible echo against two display intervals using the interval measured on the same run. Environment fields record contention, thermal state, source revision and working-tree status.

The same report includes `anchoredReplay` for a scrolled 80 × 24 viewport with 1,000 history rows. Twenty replacements alternate between two pre-parsed snapshots whose numbered build steps shift by twelve rows. Each replacement must keep **Build step 512** at the top and **Build step 513** selected. The `milliseconds` samples and `p95Milliseconds` cover restoring the viewport and its native interaction state. Parsing, network latency and display timing have their own measurements above.

The [packaged Mac interaction report](interactions-mac.json) records a clean build of `2a3327e` on the contended M1 Max. Across 20 keys, p95 was 0.066 ms to the WebSocket write and 0.440 ms to receipt of the matching echo. All 20 echoes reached Metal submission. The locked display supplied no presentation times. Restoring the history reader and selection across 1,000 retained rows took 6.282 ms p95 over 20 replacements.
