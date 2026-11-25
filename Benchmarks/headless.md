# Headless replay measurements

Thrush sustained **445.26 MiB/s** at 80 × 24 and resized a grid with 1,000 history rows in **0.796 ms at p95** in the slowest full-history case. The benchmark exercises the emulator directly, from incoming bytes to updated cells and generated replies. [Complete measurements](headless.json)

## Recorded Mac measurements

Five consecutive Release runs used clean revision `75860e3` on a 10-core Apple M1 Max with macOS 27.2.1 and Swift 6.4.2. The Mac was on AC power with low-power mode off. Thermal state stayed nominal. All five runs reported host contention, with one-minute load averages from 204.53 to 213.23. The timings measure elapsed time in the emulator at the listed grid sizes. [Run environment](headless.json)

Run 2 had the median 80 × 24 ASCII throughput. The two published JSON reports and the workload tables use that complete run. Across the five runs, throughput ranged from 423.38 to 463.69 MiB/s, a spread of 40.31 MiB/s (9.05% of the median).

| Run | 80 × 24 ASCII (MiB/s) | One-minute load |
| --- | ---: | ---: |
| 1 | 463.69 | 213.23 |
| 2 | 445.26 | 208.41 |
| 3 | 445.85 | 208.41 |
| 4 | 423.38 | 204.53 |
| 5 | 436.90 | 204.53 |

The sustained-output test feeds 1,048,640 bytes of printable ASCII and line endings in 4 KiB chunks. After one warmup, the runner measures five passes per grid. Each pass verifies the final rows, wrapping, cursor report and 1,000-row history. All three grids cleared the 100 MiB/s target.

| Grid | Receive (MiB/s) | Chunk p50 (µs) | Chunk p95 (µs) |
| --- | ---: | ---: | ---: |
| 80 × 24 | 445.26 | 8.541 | 10.709 |
| 40 × 32 | 388.25 | 9.917 | 10.417 |
| 80 × 14 | 446.51 | 8.541 | 10.667 |

Resizing the normal screen can reflow its scrollback even while Vim’s alternate screen is visible. The table includes every resize that began with **1,000 rows in the normal screen’s history**. Across all 29 recorded resize operations, every p95 fell within the 8.333 ms budget for one 120 Hz frame. The timer measures the synchronous resize call. [Resize measurements](headless.json)

| Active screen | Grid change | Resize p95 (ms) |
| --- | --- | ---: |
| Normal | 80 × 24 → 40 × 32 | 0.796 |
| Normal | 40 × 32 → 80 × 14 | 0.285 |
| Normal | 80 × 14 → 80 × 24 | 0.033 |
| Alternate | 80 × 24 → 40 × 32 | 0.787 |
| Alternate | 40 × 32 → 80 × 14 | 0.293 |

## Recorded interaction measurements

Each recording first passes an independent reference check for cells, attributes, wraps, cursor, history and modes. The runner then times 25 replays through the same queue, checking reply bytes and encoded input. All **134 reference checkpoints** passed. Every recording sustained more than twice its largest recorded one-second output volume. [Recording fixtures](../Fixtures/replays)

| Recording | Output bytes per replay | Checkpoints | Receive (MiB/s) | Burst drain p95 (µs) |
| --- | ---: | ---: | ---: | ---: |
| Shell workflow (`shell-workflow`) | 426 | 7 | 135.35 | 9.125 |
| Vim detach and resume (`vim-resume`) | 10,578 | 10 | 330.46 | 46.709 |
| Codex session (`codex-session`) | 18,382 | 11 | 218.87 | 99.375 |
| Compiler output (`shell-log`) | 104,167 | 14 | 142.70 | 2,799.042 |
| Vim editing (`vim-edit`) | 8,720 | 8 | 330.57 | 40.917 |
| Shell and control-sequence cases (`shell-edges`) | 17,563 | 63 | 626.62 | 74.042 |
| Prompt with a byte order mark (`prompt-bom`) | 15 | 1 | 66.03 | 0.459 |
| Swift source in Vim (`vim-swift-dark`) | 8,190 | 7 | 254.13 | 44.792 |
| Swift source in Vim (`vim-swift-light`) | 7,788 | 7 | 253.23 | 43.084 |
| Hardware keys (`hardware-keys`) | 10 | 2 | 96.88 | 17.166 |
| Pointer input (`pointer-input`) | 42 | 4 | 133.37 | 3.750 |

Receive throughput divides incoming bytes by time spent in `Terminal.receive`. For the hardware-key and pointer fixtures, those bytes set terminal modes. The report times key and pointer encoding separately. Burst drain timing includes queue handling, parsing, input encoding, resizes and reply checks. The queue holds at most 16 events and 8 KiB of output at once. It drains in order and finishes empty on every replay. The JSON includes each recording’s peak byte rate, queue occupancy and operation timings. [Recording details](headless.json)

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
