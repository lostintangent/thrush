# Headless recording measurements

Thrush sustained **1,595.59 MiB/s** at 80 × 24 and resized a grid with 1,000 history rows in **0.662 ms at p95** in the slowest full-history case. The benchmark exercises the emulator directly, from incoming bytes to updated cells and generated replies. [Complete measurements](headless.json)

## Recorded Mac measurements

Five consecutive Release runs used clean revision `a849ccd` on a 10-core Apple M1 Max with macOS 27.2.1 and Swift 6.4.2. The Mac was on AC power with low-power mode off. Thermal state stayed nominal. None of the five runs reported contention on the Mac, with one-minute load averages from 4.38 to 4.43. The timings measure elapsed time in the emulator at the listed grid sizes. [Run environment](headless.json)

Run 3 had the median 80 × 24 ASCII throughput. The published JSON report and the workload tables use that complete run. Across the five runs, throughput ranged from 1,580.33 to 1,642.47 MiB/s, a spread of 62.15 MiB/s (3.89% of the median).

| Run | 80 × 24 ASCII (MiB/s) | One-minute load |
| --- | ---: | ---: |
| 1 | 1,630.82 | 4.38 |
| 2 | 1,642.47 | 4.43 |
| 3 | 1,595.59 | 4.43 |
| 4 | 1,580.33 | 4.43 |
| 5 | 1,586.07 | 4.43 |

The sustained-output test feeds 1,048,640 bytes of printable ASCII and line endings in 4 KiB chunks. After one warmup, the runner measures five passes per grid. Each pass verifies the final rows, wrapping, cursor report and 1,000-row history. All three grids cleared the 100 MiB/s target.

| Grid | Receive (MiB/s) | Chunk p50 (µs) | Chunk p95 (µs) |
| --- | ---: | ---: | ---: |
| 80 × 24 | 1,595.59 | 2.208 | 5.083 |
| 40 × 32 | 1,088.90 | 3.375 | 3.667 |
| 80 × 14 | 1,658.59 | 2.125 | 4.875 |

Resizing the normal screen can reflow its history even while Vim’s alternate screen is visible. The table includes every resize that began with **1,000 rows in the normal screen’s history**. Across all 29 recorded resize operations, every p95 fell within the 8.333 ms budget for one 120 Hz frame. The timer measures the synchronous resize call. [Resize measurements](headless.json)

| Active screen | Grid change | Resize p95 (ms) |
| --- | --- | ---: |
| Normal | 80 × 24 → 40 × 32 | 0.660 |
| Normal | 40 × 32 → 80 × 14 | 0.286 |
| Normal | 80 × 14 → 80 × 24 | 0.071 |
| Alternate | 80 × 24 → 40 × 32 | 0.662 |
| Alternate | 40 × 32 → 80 × 14 | 0.285 |

## Recorded interaction measurements

Each recording first passes an independent reference check for cells, attributes, wraps, cursor, history and modes. The runner then drains 25 replays through the same queue, checking reply bytes and encoded input. All **143 reference checkpoints** passed. Every recording sustained more than twice its largest recorded one-second output volume. [Recording fixtures](../Fixtures/recordings)

| Recording | Output bytes per replay | Checkpoints | Receive (MiB/s) | Burst drain p95 (µs) |
| --- | ---: | ---: | ---: | ---: |
| Shell workflow (`shell-workflow`) | 426 | 7 | 198.58 | 6.666 |
| Vim detach and resume (`vim-resume`) | 10,578 | 10 | 569.68 | 32.209 |
| Codex session (`codex-session`) | 18,382 | 11 | 269.87 | 155.750 |
| Compiler output (`shell-log`) | 104,167 | 14 | 203.36 | 2,505.208 |
| Vim editing (`vim-edit`) | 8,720 | 8 | 578.55 | 27.000 |
| Shell and control-sequence cases (`shell-edges`) | 17,563 | 63 | 939.24 | 66.708 |
| Prompt with a byte order mark (`prompt-bom`) | 15 | 1 | 74.88 | 0.458 |
| Swift source in Vim (`vim-swift-dark`) | 7,818 | 7 | 334.47 | 31.542 |
| Swift source in Vim (`vim-swift-light`) | 7,428 | 7 | 327.27 | 29.750 |
| Hardware keys (`hardware-keys`) | 10 | 2 | 122.27 | 19.709 |
| Pointer input (`pointer-input`) | 42 | 4 | 186.55 | 3.667 |
| Clearing the screen in zsh (`zsh-clear`) | 1,095 | 9 | 107.62 | 16.084 |

Receive throughput times `Terminal.write` alone over 25 samples and reports the median. Each sample replays the recording on enough fresh terminals to apply at least 8 KiB, so even a 10-byte recording spans more than a thousand clock ticks. The clock stops while the terminals resize or change palette. For the hardware-key and pointer fixtures, the received bytes set terminal modes. The report times key and pointer encoding separately. Burst drain timing includes queue handling, parsing, input encoding, resizes and reply checks. The queue holds at most 16 events and 8 KiB of output at once. It drains in order and finishes empty on every replay. The JSON includes each recording’s peak byte rate, queue occupancy and operation timings. [Recording details](headless.json)

## Starting a new shell and preparing a replay

The current runner also measures two session actions at 80 × 24. The previous shell prints 1,016 numbered lines, leaving 992 in history and 24 on screen. Starting a new shell archives lines 17 through 1,016 in order. Its first PTY read is the bracketed-paste enable and `thrush$ ` prompt from the recorded `shell-workflow`. After eight rows from this shell have entered history, preparing for replay retains exactly lines 25 through 1,016 from the previous shell. Each action must leave a blank grid and a visible cursor at row zero, column zero. Applying the recorded prompt must place the cursor in column eight and enable bracketed paste.

The table and generated JSON give p50 and p95 over 25 passes after one warmup. The timers cover only the two synchronous session calls. Preparing input, applying the prompt and checking every retained row happen outside the timers.

## Run the benchmark

From the package root, run `swift run -c release ThrushBench`, then `python3 Benchmarks/check-benchmark-report.py` to verify the report against the recordings. The runner writes `.build/benchmarks/headless.json`, or the path given with `--output`.

To record a result, build the Release executable once and collect five consecutive runs.

```sh
swift build -c release --product ThrushBench
bin_dir=$(swift build -c release --show-bin-path)
for run in 1 2 3 4 5; do
  "$bin_dir/ThrushBench" --output ".build/benchmarks/run-$run/headless.json"
done
```

Each report records the load average and sets `environment.contended` when the one-minute load exceeds the active core count. Rerun the series if any run is contended. Sort the five 80 × 24 ASCII receive rates and use the middle run. Verify it with `python3 Benchmarks/check-benchmark-report.py .build/benchmarks/run-N/headless.json`, substituting the selected run number for `N`.
