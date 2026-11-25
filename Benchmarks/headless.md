# Headless replay measurements

`swift run -c release ThrushBench` writes the first-bytes report and a second table and JSON report for headless emulation. The default paths are `.build/benchmarks/first-bytes.json` and `.build/benchmarks/headless.json`. With `--output trial.json` the headless report is `trial-headless.json` in the same directory. Both reports sample their own host load, thermal state, hardware and revision.

The bulk workload feeds 1,048,640 bytes of printable ASCII and CRLFs through 4 KiB array chunks. It uses one warmup and five measured passes per grid. Each pass checks the last two rows, their wrap boundary, the 1,000-row history and the final cursor report. The reference generator independently verifies the expected state of the 80 × 24, 40 × 32 and 80 × 14 grids with the pinned xterm implementation.

For each shell, Vim and parser recording, the runner first checks every recorded checkpoint against xterm, including cells, attributes, wraps, cursor, history and modes. It then times 25 replays through that same feeder. Each measured pass checks replies and semantic input bytes. Receive throughput uses only the time spent in synchronous receive calls, including replies to Vim’s foreground and background queries. The ratio in the JSON compares that rate with the largest amount of recorded output in any one-second window. Input, host palette changes and resize have separate timings.

The feeder offers the recording in one burst and requests up to 16 pending events or 8 KiB at a time. It drains that batch in order before requesting more. An oversized output chunk can span batches. The shell log fills the slot budget, and the split control-string recording fills the byte budget. Drain time covers queue management, parsing, resize, encoding and reply checks. These headless measurements exclude transport and viewport presentation.

Each resize records the requested and effective grids, active buffer, visible buffer’s history count before resizing, and p50/p95. The round trips start with a full shell history and repeat with Vim active. Budgets compare p95 with 8.333 ms (120 Hz). The two phone-sized grids exercise layout on the reference Mac. Physical phone timings require the device run. The CI check independently reconciles fixture hashes, byte counts, peak windows, effective sizes and queue bounds with the raw recordings.

## Milestone 1 profile

The original 80 × 24 parser was profiled at commit `3b2b6ff` on the M1 Max with Swift 6.4.2, separate optimized core and caller modules, one warmup and five passes of the bulk workload above. The concrete overloads use the same receive method body as the generic API. The printable-run prototype handles contiguous ASCII in the parser and decoder’s ground states and updates each row in a single mutable access. Rows and the final cursor reply matched in every variant.

| Receive path in the profile | Median MiB/s |
| --- | ---: |
| Generic sequence with array | 12.11 |
| Generic sequence with array slice | 17.95 |
| Generic sequence with unsafe buffer | 55.66 |
| Concrete array | 71.50 |
| Concrete array slice | 74.69 |
| Concrete unsafe buffer | 79.00 |
| Contiguous printable runs | 260.94 |

These same-session comparisons motivated the contiguous receive path and a 100 MiB/s bulk target. The reference machine was contended. Quiet repeated runs are needed to establish a timing baseline.
