# First bytes

From the package root, run `swift run -c release ThrushBench` to print the operation table and write `.build/benchmarks/first-bytes.json`. To capture a baseline, start on a clean checkout of the source commit and pass `--output Benchmarks/first-bytes.json`. Commit the report after the run. Its commit field identifies the measured source.

Each replay starts with a fresh terminal at the fixture’s grid size. The runner checks the visible row, terminal replies and Up bytes against the reference after each event. It warms up for 100 replays and measures 2,000 more. A failed checkpoint exits before the report is written.

The operation table uses a monotonic clock and nearest-rank percentiles. Receive throughput divides recorded bytes by time spent inside their synchronous receive calls, including clock overhead. The received count advances when a recorded chunk is handed to the core. The applied count advances after the call returns and its reply matches. The reply and key byte counts cover the recorded events in the measured replays. At the first cursor-report checkpoint, a separate sample measures the complete four-byte query in one call and verifies the same answer.

The separate burst measurement makes every recorded chunk available at once. It times ordered receive and key encoding until the input queue drains, with final row and byte checks after the timer stops. The one-second peak counts bytes at the fixture’s recorded timestamps in a sliding one-second window. This small scripted recording establishes a baseline for the first operations. Compare timing across repeated runs on the same machine and power state.

A table entry of `sub-tick` means both clock reads returned the same timestamp. The JSON preserves that measured interval as zero.

Before the replays, each run samples the Mac’s one-, five- and fifteen-minute load averages, active logical core count and thermal state. The runner marks the report `contended` when the one-minute load exceeds the core count. Use contended runs for correctness and collect timing baselines when the machine settles.

## Provisional Mac baseline

The shared Mac was under heavy load during these runs. Its one-minute load average was near 299 shortly afterward, across ten active cores. Use these numbers as provisional timing evidence.

Five consecutive Release runs measured clean revision `174bc3770612` on an Apple M1 Max (MacBookPro18,4), macOS 27.2.1, Swift 6.4.2, on AC power with nominal thermal state. Each run checked 2,000 measured 80 × 24 replays after 100 warmups. The [saved JSON](first-bytes.json) is the run with the median receive throughput.

| Run | Receive (MiB/s) | 8-byte prompt p95 (ns) | 4-byte cursor query p95 (ns) | 75-byte burst drain p95 (ns) |
| --- | ---: | ---: | ---: | ---: |
| 1 | 9.48 | 834 | 542 | 7,500 |
| 2 | 9.67 | 833 | 500 | 7,417 |
| 3 | 9.26 | 875 | 542 | 7,542 |
| 4 | 7.01 | 916 | 584 | 8,167 |
| 5 (saved) | 9.41 | 834 | 542 | 7,500 |

Every run applied all 150,000 input bytes and produced 36,000 query-reply bytes and 18,000 key bytes. The burst counters describe the 75 fixture bytes available to the synchronous runner at once and the zero remaining when it finished. The JSON also records clock percentiles for each chunk, row read and Up encoding.
