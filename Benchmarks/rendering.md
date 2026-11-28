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
Tests/ThrushProofs/benchmark-simulator.sh "$udid" .build/proofs/simulator/Thrush.app .build/benchmarks/render-simulator.json
```

The first update draws every row with indexed cyan, default text, single-column digits, a CJK ideograph and a color emoji. The six-cell prefix is `A翼🐦Z`. Ten rounds follow. Each moves the cursor, replaces text on one row, scrolls a line into the bottom of the viewport and repaints the full grid. Every warm round uses the same glyphs and styles. The script verifies the input stream's SHA-256 independently from the emulator and checks the dirty rows, glyph uploads and monotonic screen generations.

Each submission records CPU preparation time, command-buffer GPU duration when available, the monotonic host timestamp immediately before supplying the output bytes and the drawable's actual presentation timestamp. The benchmark advances after a successful GPU completion. On a display delivering presentation events, it waits up to 250 ms for the matching drawable before feeding the next update. If the window server stops delivering those events, the benchmark continues at GPU completion and resumes presentation pacing when a positive timestamp arrives. It keeps collecting late timestamps by submission through the final one-second idle observation. The JSON preserves each confirmed timestamp and counts missing presentations separately. A missing GPU completion or failed command fails the run.

The receipt-to-presentation measure includes local parsing, scheduling and rendering. Socket and key-to-echo latency belong to the [native input benchmark](interactions.md). After the first screen submits, a display link samples twelve refresh intervals in the same window. The cold frame also records asynchronous Metal shader compilation and the elapsed time from native view creation to the first content submission. Each cold run starts in a new process with an empty Thrush pipeline cache. Metal may reuse its system compiler cache across launches. The report compares presented latency with the median interval.

After the redraws, a selection spans the two wide glyphs while the view switches between the light theme, the dark theme and a custom palette. The checker requires each switch to keep the generation and grid, with zero glyph uploads and zero row preparations. A separate final measurement counts all Metal submissions during one second at a settled prompt, one second with updates pending on the suspended renderer, and an actual native hide or background interval. The terminal cursor stays steady.

After the settled prompt, four blinking digits replace part of the first row for two 1.2 s blink cycles. The checker requires the submissions to fall between ten per second of fading and the display rate during the fades, plus one frame at each fade boundary, with zero rows prepared and zero glyph uploads. With Reduce Motion, the next 1.2 s must submit nothing after one redraw. The same digits without blink must then submit nothing for another 1.2 s. These bytes are outside the hashed workload.

The JSON includes the commit and worktree state from app packaging, the device model, OS, toolchain, load average, core count, thermal and power state and grid dimensions. A simulator run measures a shared Mac's graphics stack. Use the Mac and physical iPhone for device timing baselines. Use five quiet passes to estimate variance before setting timing gates.

For a capture of the running app, use `Tests/ThrushProofs/capture-demo.sh mac "$pid" frame.png` or `Tests/ThrushProofs/capture-demo.sh simulator "$udid" frame.png`. These commands capture the actual window or device framebuffer with its native chrome.

## Mac measurement

The clean Release bundle at `e627614` drew an 80 × 24 grid on an M1 Max running macOS 27.2.1 (26B131), on AC power with a nominal thermal state. The display link measured 16.667 ms. The one-minute load was 5.0 on ten cores. [Saved report](render-mac.json)

The new process compiled its embedded Metal shader in 7.049 ms. Its first content submission came 125.032 ms after view creation.

| Operation | Frames | CPU p95, ms | GPU p95, ms | Receipt to presentation p95, ms | Glyph uploads | Maximum rows prepared |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Cold | 1 | 7.369 | 1.187 | 34.447 | 14 | 24 |
| Cursor | 10 | 0.127 | 0.167 | 31.003 | 0 | 0 |
| One row | 10 | 0.161 | 1.118 | 31.879 | 0 | 1 |
| Scroll | 10 | 0.174 | 0.108 | 31.949 | 0 | 1 |
| Full grid | 10 | 0.340 | 0.947 | 32.769 | 0 | 24 |

Every workload frame, theme switch and synchronized release has a presentation time. Each warm frame reached the display within two refresh intervals of its bytes arriving, and the cold frame took 34.447 ms.

All three theme switches reused every visible row and glyph. The foreground-idle observation lasted 1.019 s, the suspended-renderer observation 1.042 s and the hidden-window observation 1.238 s. Each recorded zero additional submissions. Blinking text submitted 48 frames in 2.433 s, within the allowed 8 to 56, then none under Reduce Motion and none once it stopped blinking.

Three partial generations inside synchronized output produced 0 submissions. Closing the block submitted one coherent screen. When the end marker was omitted, the watchdog submitted the latest generation 1006.312 ms after the block opened, followed by 1.066 s with zero further submissions.

Cursor frames hold near 0.106 ms of GPU time, while full-grid frames range from 0.095 to 0.947 ms on a presenting display. Five consecutive runs of this build put full-grid CPU p95 between 0.330 and 1.504 ms and GPU p95 between 0.503 and 1.126 ms, so one run shows headroom rather than a timing baseline.

## iPhone simulator measurement

The clean Release build at `e627614` drew a 45 × 34 portrait grid with the keyboard hidden on an iPhone Duo simulator running iOS 27.2 (24B91016s). The hosted arm64 Mac exposed three cores and its one-minute load was 597.25. The simulator reported a nominal thermal state and a 16.667 ms display interval. These timings describe one heavily contended run on the host's graphics stack. [Hosted job](https://github.com/lostintangent/thrush/actions/runs/46128808056/job/140929242322) · [Saved report](render-simulator.json)

The new process compiled the embedded Metal shader in 6527.394 ms and submitted its first content 8125.687 ms after view creation.

| Operation | Frames | CPU p95, ms | GPU p95, ms | Glyph uploads | Maximum rows prepared |
| --- | ---: | ---: | ---: | ---: | ---: |
| Cold | 1 | 164.387 | 3.987 | 14 | 34 |
| Cursor | 10 | 0.743 | 2.883 | 0 | 0 |
| One row | 10 | 0.811 | 1.793 | 0 | 1 |
| Scroll | 10 | 0.972 | 0.107 | 0 | 1 |
| Full grid | 10 | 6.076 | 0.143 | 0 | 34 |

All three theme switches preserved the generation and reused every visible row and glyph. There were zero submissions during 1.062 s of foreground idle, 1.016 s with an update pending on the suspended renderer, and 4.250 s between UIKit background and foreground notifications while Settings was open. Blinking text submitted 46 frames in 2.441 s, within the allowed 8 to 56, then none under Reduce Motion and none once it stopped blinking.

Three partial synchronized generations produced zero submissions. The end marker released one frame. A truncated block released its latest generation once through the watchdog after 1004.568 ms, followed by 1.062 s with zero further submissions.

The simulator SDK exposes command-buffer timing but no drawable presentation timestamp. Each of the 41 workload frames has a CPU and GPU measurement. Receipt-to-presentation latency on iPhone needs a physical device.

## Finding plain-text links

The view looks for plain `http` and `https` addresses only on lines whose rows changed. Timed over the recordings on the M1 Max at `933e55b`, that costs 5 to 8 µs on a frame whose visible lines haven't changed and about a quarter of CPU preparation on an output frame, under 1% of a 60 Hz refresh.
