# First bytes

From the package root, run `swift run -c release ThrushBench` to print the operation table and write `.build/benchmarks/first-bytes.json`. To capture a baseline, start on a clean checkout of the source commit and pass `--output Benchmarks/first-bytes.json`. Commit the report after the run. Its commit field identifies the measured source.

The same command also writes a [headless replay report](headless.md) for sustained ASCII, recorded shell and Vim output, bounded queues and resize.

Each replay starts with a fresh terminal at the fixture’s grid size. The runner checks the visible row, terminal replies and Up bytes against the reference after each event. It warms up for 100 replays and measures 2,000 more. A failed checkpoint exits before the report is written.

The operation table uses a monotonic clock and nearest-rank percentiles. Receive throughput divides recorded bytes by time spent inside their synchronous receive calls, including clock overhead. The received count advances when a recorded chunk is handed to the core. The applied count advances after the call returns and its reply matches. The reply and key byte counts cover the recorded events in the measured replays. At the first cursor-report checkpoint, a separate sample measures the complete four-byte query in one call and verifies the same answer.

The separate burst measurement makes every recorded chunk available at once. It times ordered receive and key encoding until the input queue drains, with final row and byte checks after the timer stops. The one-second peak counts bytes at the fixture’s recorded timestamps in a sliding one-second window. This small scripted recording establishes a baseline for the first operations. Compare timing across repeated runs on the same machine and power state.

A table entry of `sub-tick` means both clock reads returned the same timestamp. The JSON preserves that measured interval as zero.

Before the replays, each run samples the Mac’s one-, five- and fifteen-minute load averages, active logical core count and thermal state. The runner marks the report `contended` when the one-minute load exceeds the core count. Use contended runs for correctness and collect timing baselines when the machine settles.

To measure run-to-run noise, run `python3 scripts/measure-first-bytes.py CHECKOUT OUTPUT` with a clean Thrush checkout and a fresh output directory. It builds the Release executable once and saves five consecutive samples from a quiet period. The manual [first-bytes workflow](../.github/workflows/first-bytes.yml) runs the same procedure on one hosted Mac. Each JSON identifies its processor, power state, source revision, fixture and load.

## Provisional Mac baseline

Five consecutive Release runs measured clean revision `0cd03d0fd191` on Apple M1 Max (MacBookPro18,4), macOS 27.2.1, Swift 6.4.2, on AC power with nominal thermal state. The one-minute load stayed above the active core count in every sample. Each run checked 2,000 measured 80 × 24 replays after 100 warmups. The [saved JSON](first-bytes.json) is the run with the median receive throughput.

| Run | 1 min load / cores | Receive (MiB/s) | 8-byte prompt p95 (ns) | 4-byte query p95 (ns) | 75-byte drain p95 (ns) |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 253.96 / 10 | 9.74 | 833 | 500 | 7,417 |
| 2 | 251.88 / 10 | 9.87 | 791 | 500 | 7,166 |
| 3 (saved) | 250.93 / 10 | 9.55 | 875 | 542 | 8,125 |
| 4 | 251.81 / 10 | 9.50 | 833 | 541 | 7,459 |
| 5 | 250.23 / 10 | 9.33 | 875 | 583 | 7,625 |

Every run applied all 150,000 input bytes and produced 36,000 query-reply bytes and 18,000 key bytes. The burst counters describe the 75 fixture bytes available to the synchronous runner at once and the zero remaining when it finished. The JSON also records clock percentiles for each chunk, row read and Up encoding.
