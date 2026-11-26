# Headless recording measurements

Thrush sustained **1,541.90 MiB/s** at 80 × 24 and resized a grid with 1,000 history rows in **0.888 ms at p95** in the slowest full-history case. The benchmark exercises the emulator directly, from incoming bytes to updated cells and generated replies. [Complete measurements](headless.json)

## Recorded Mac measurements

Five consecutive Release runs used clean revision `b3d9f29` on a 10-core Apple M1 Max with macOS 27.2.1 and Swift 6.4.2. The Mac was on AC power with low-power mode off. Thermal state stayed nominal. None of the five runs reported contention on the Mac, with one-minute load averages from 4.25 to 5.78. The timings measure elapsed time in the emulator at the listed grid sizes. [Run environment](headless.json)

Run 4 had the median 80 × 24 ASCII throughput. The two published JSON reports and the workload tables use that complete run. Across the five runs, throughput ranged from 1,275.49 to 1,644.12 MiB/s, a spread of 368.63 MiB/s (23.91% of the median).

| Run | 80 × 24 ASCII (MiB/s) | One-minute load |
| --- | ---: | ---: |
| 1 | 1,644.12 | 4.25 |
| 2 | 1,275.49 | 4.25 |
| 3 | 1,398.71 | 5.59 |
| 4 | 1,541.90 | 5.59 |
| 5 | 1,566.28 | 5.78 |

The sustained-output test feeds 1,048,640 bytes of printable ASCII and line endings in 4 KiB chunks. After one warmup, the runner measures five passes per grid. Each pass verifies the final rows, wrapping, cursor report and 1,000-row history. All three grids cleared the 100 MiB/s target.

| Grid | Receive (MiB/s) | Chunk p50 (µs) | Chunk p95 (µs) |
| --- | ---: | ---: | ---: |
| 80 × 24 | 1,541.90 | 2.292 | 5.208 |
| 40 × 32 | 1,009.45 | 3.584 | 4.042 |
| 80 × 14 | 1,575.86 | 2.209 | 5.083 |

Resizing the normal screen can reflow its history even while Vim’s alternate screen is visible. The table includes every resize that began with **1,000 rows in the normal screen’s history**. Across all 29 recorded resize operations, every p95 fell within the 8.333 ms budget for one 120 Hz frame. The timer measures the synchronous resize call. [Resize measurements](headless.json)

| Active screen | Grid change | Resize p95 (ms) |
| --- | --- | ---: |
| Normal | 80 × 24 → 40 × 32 | 0.888 |
| Normal | 40 × 32 → 80 × 14 | 0.306 |
| Normal | 80 × 14 → 80 × 24 | 0.080 |
| Alternate | 80 × 24 → 40 × 32 | 0.742 |
| Alternate | 40 × 32 → 80 × 14 | 0.317 |

## Recorded interaction measurements

Each recording first passes an independent reference check for cells, attributes, wraps, cursor, history and modes. The runner then drains 25 replays through the same queue, checking reply bytes and encoded input. All **143 reference checkpoints** passed. Every recording sustained more than twice its largest recorded one-second output volume. [Recording fixtures](../Fixtures/recordings)

| Recording | Output bytes per replay | Checkpoints | Receive (MiB/s) | Burst drain p95 (µs) |
| --- | ---: | ---: | ---: | ---: |
| Shell workflow (`shell-workflow`) | 426 | 7 | 186.79 | 6.875 |
| Vim detach and resume (`vim-resume`) | 10,578 | 10 | 557.84 | 33.542 |
| Codex session (`codex-session`) | 18,382 | 11 | 271.09 | 86.166 |
| Compiler output (`shell-log`) | 104,167 | 14 | 192.17 | 2,933.875 |
| Vim editing (`vim-edit`) | 8,720 | 8 | 568.62 | 29.583 |
| Shell and control-sequence cases (`shell-edges`) | 17,563 | 63 | 907.38 | 66.250 |
| Prompt with a byte order mark (`prompt-bom`) | 15 | 1 | 71.43 | 0.458 |
| Swift source in Vim (`vim-swift-dark`) | 7,818 | 7 | 324.75 | 40.208 |
| Swift source in Vim (`vim-swift-light`) | 7,428 | 7 | 316.61 | 30.625 |
| Hardware keys (`hardware-keys`) | 10 | 2 | 119.24 | 19.833 |
| Pointer input (`pointer-input`) | 42 | 4 | 184.00 | 3.750 |
| Clearing the screen in zsh (`zsh-clear`) | 1,095 | 9 | 106.03 | 16.375 |

Receive throughput times `Terminal.write` alone over 25 samples and reports the median. Each sample replays the recording on enough fresh terminals to apply at least 8 KiB, so even a 10-byte recording spans more than a thousand clock ticks. The clock stops while the terminals resize or change palette. For the hardware-key and pointer fixtures, the received bytes set terminal modes. The report times key and pointer encoding separately. Burst drain timing includes queue handling, parsing, input encoding, resizes and reply checks. The queue holds at most 16 events and 8 KiB of output at once. It drains in order and finishes empty on every replay. The JSON includes each recording’s peak byte rate, queue occupancy and operation timings. [Recording details](headless.json)

## Starting a new shell and preparing a replay

The current runner also measures two session actions at 80 × 24. The previous shell prints 1,016 numbered lines, leaving 992 in history and 24 on screen. Starting a new shell archives lines 17 through 1,016 in order. Its first PTY read is the bracketed-paste enable and `thrush$ ` prompt from the recorded `shell-workflow`. After eight rows from this shell have entered history, preparing for replay retains exactly lines 25 through 1,016 from the previous shell. Each action must leave a blank grid and a visible cursor at row zero, column zero. Applying the recorded prompt must place the cursor in column eight and enable bracketed paste.

The table and generated JSON give p50 and p95 over 25 passes after one warmup. The timers cover only the two synchronous session calls. Preparing input, applying the prompt and checking every retained row happen outside the timers.

## Run the benchmark

From the package root, run `swift run -c release ThrushBench`, then `python3 scripts/check-benchmark-report.py` to verify the report against the recordings. The runner writes `.build/benchmarks/headless.json` and `.build/benchmarks/first-bytes.json`. With `--output trial.json`, the two files are `trial-headless.json` and `trial.json`. [First-bytes measurements](first-bytes.md)

To repeat the five-run selection, build the Release executable once and keep each pair of reports in its own directory.

```sh
swift build -c release --product ThrushBench
bin_dir=$(swift build -c release --show-bin-path)
for run in 1 2 3 4 5; do
  "$bin_dir/ThrushBench" --output ".build/benchmarks/run-$run/first-bytes.json"
done
```

Sort the five 80 × 24 ASCII receive rates and use both reports from the middle run. Verify its headless report with `python3 scripts/check-benchmark-report.py .build/benchmarks/run-N/headless.json`, substituting the selected run number for `N`.
