# First bytes

From the package root, run `swift run -c release ThrushBench` to print the operation table and write `.build/benchmarks/first-bytes.json`. To capture a baseline, start on a clean checkout of the source commit and pass `--output Benchmarks/first-bytes.json`. Commit the report after the run. Its commit field identifies the measured source.

Each replay starts with a fresh terminal at the fixture’s grid size. The runner checks the visible row, terminal replies and Up bytes against the reference after each event. It warms up for 100 replays and measures 2,000 more. A failed checkpoint exits before the report is written.

The operation table uses a monotonic clock and nearest-rank percentiles. Receive throughput divides recorded bytes by time spent inside their synchronous receive calls, including clock overhead. The received count advances when a recorded chunk is handed to the core. The applied count advances after the call returns and its reply matches. The reply and key byte counts cover the recorded events in the measured replays. At the first cursor-report checkpoint, a separate sample measures the complete four-byte query in one call and verifies the same answer.

The separate burst measurement makes every recorded chunk available at once. It times ordered receive and key encoding until the input queue drains, with final row and byte checks after the timer stops. The one-second peak counts bytes at the fixture’s recorded timestamps in a sliding one-second window. This small scripted recording establishes a baseline for the first operations. Compare timing across repeated runs on the same machine and power state.

A table entry of `sub-tick` means both clock reads returned the same timestamp. The JSON preserves that measured interval as zero.
