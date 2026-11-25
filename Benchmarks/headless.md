# Headless replay measurements

`swift run -c release ThrushBench` writes the first-bytes report and a second table and JSON report for headless emulation. The default paths are `.build/benchmarks/first-bytes.json` and `.build/benchmarks/headless.json`. With `--output trial.json` the headless report is `trial-headless.json` in the same directory. Both reports sample their own host load, thermal state, hardware and revision.

The bulk workload feeds 1,048,640 bytes of printable ASCII and CRLFs through 4 KiB array chunks. It uses one warmup and five measured passes per grid. Each pass checks the last two rows, their wrap boundary, the 1,000-row history and the final cursor report. The reference generator independently verifies the expected state of the 80 × 24, 40 × 32 and 80 × 14 grids with the pinned xterm implementation.

For each shell, Vim and parser recording, the runner first checks every recorded checkpoint against xterm, including cells, attributes, wraps, cursor, history and modes. It then times 25 replays through that same feeder. Each measured pass checks replies and semantic input bytes. Receive throughput uses only the time spent in synchronous receive calls, including replies to Vim’s foreground and background queries. The ratio in the JSON compares that rate with the largest amount of recorded output in any one-second window. Input, host palette changes and resize have separate timings.

The feeder offers the recording in one burst and requests up to 16 pending events or 8 KiB at a time. It drains that batch in order before requesting more. An oversized output chunk can span batches. The shell log fills the slot budget, and the split control-string recording fills the byte budget. Drain time covers queue management, parsing, resize, encoding and reply checks. These headless measurements exclude transport and viewport presentation.

The runner also plays two recordings of Vim painting the same Swift file under Slate Dark and Slate Light. Each includes a desktop, portrait and landscape repaint, with indented source and Vim’s reverse-video status line. They joined the workload after the four-recording measurement below. The current runner also measures the shell, resumable Vim and Codex workflows, plus hardware keys under both cursor modes. Each workflow’s JSON row includes its exact byte and reply counts, receive rate and peak, timed semantic inputs and maximum queue occupancy. [Workflow recordings](../Fixtures/reference/m4/README.md)

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

## Recorded Mac measurements

Five Release runs measured clean revision `04c69f871d6b` on Apple M1 Max (MacBookPro18,4, 10 active cores), macOS 27.2.1 (Build 26B131), Swift 6.4.2, AC Power. Thermal state was nominal. All five runs exceeded the one-minute load threshold. Timing remains provisional until quiet-machine measurements are available.

| Run | Load (1 / 5 / 15 min) | 80×24 ASCII MiB/s | 40×32 ASCII MiB/s | 80×14 ASCII MiB/s | Compiler MiB/s | Worst full-history p95 (ms) |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 1 (selected) | 311.75 / 337.01 / 328.23 | 193.02 | 151.36 | 204.63 | 76.00 | 0.582 |
| 2 | 310.33 / 336.30 / 328.03 | 185.45 | 146.57 | 197.43 | 69.86 | 0.684 |
| 3 | 309.05 / 335.17 / 327.72 | 204.51 | 151.69 | 200.20 | 71.31 | 0.758 |
| 4 | 313.85 / 335.73 / 327.96 | 182.40 | 139.40 | 202.61 | 75.18 | 0.628 |
| 5 | 316.19 / 335.85 / 328.05 | 195.44 | 151.50 | 190.97 | 74.10 | 0.625 |
| Range ÷ median | | 11.5% | 8.1% | 6.8% | 8.3% | 28.0% |

Run 1 had the median 80×24 bulk throughput and supplies the detailed timing and queue tables. The last column takes the largest resize p95 among operations that started with 1,000 normal-history rows, including resizes while Vim was active. The range row describes the observed five-run spread. [Complete measured JSON](headless.json)

| Recording | Receive MiB/s | Recorded peak B/s | Rate / peak | Max queued bytes | Max queued slots | Drain p95 (ms) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| shell-log | 76.00 | 58,076 | 1,372.2× | 8,192 | 16 | 3.091 |
| vim-edit | 158.21 | 5,611 | 29,566.4× | 4,465 | 16 | 0.069 |
| shell-edges | 120.24 | 17,110 | 7,368.9× | 8,192 | 16 | 0.170 |
| prompt-bom | 43.79 | 15 | 3,061,474.4× | 15 | 1 | 0.001 |

| Recording | Active screen | Resize | Active history before | Normal history before | p50 (ms) | p95 (ms) |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| shell-log | Normal | 80×24 → 40×32 | 1,000 | 1,000 | 0.577 | 0.582 |
| shell-log | Normal | 40×32 → 80×14 | 1,000 | 1,000 | 0.256 | 0.262 |
| shell-log | Normal | 80×14 → 80×24 | 1,000 | 1,000 | 0.029 | 0.030 |
| shell-log | Alternate | 80×24 → 40×32 | 0 | 1,000 | 0.577 | 0.581 |
| shell-log | Alternate | 40×32 → 80×14 | 0 | 1,000 | 0.256 | 0.258 |
| shell-log | Alternate | 80×14 → 80×24 | 0 | 497 | 0.015 | 0.016 |
| vim-edit | Alternate | 80×24 → 40×32 | 0 | 0 | 0.005 | 0.006 |
| vim-edit | Alternate | 40×32 → 80×14 | 0 | 0 | 0.004 | 0.004 |
| vim-edit | Alternate | 80×14 → 80×24 | 0 | 0 | 0.001 | 0.001 |

All five runs cleared the 100 MiB/s bulk target on all three grids and the 2× recorded-peak target on every fixture. Every resize p95 was within 8.333 ms. All four fixture queues drained to zero in every measured pass.

The phone-sized grids were measured on the Mac. Physical iPhone timing remains outstanding.

## Recorded interaction measurements

One Release run on the same M1 Max measured 25 repetitions of each interaction at clean revision `95f7edfe0505`. The one-minute load was 645.60 on 10 cores. Each workload applied all its recorded bytes, checked the replies and semantic input, and drained its queue. The drain time covers a headless burst. The interactive peer separately preserves the PTY’s timed output between user actions.

| Workflow | Output bytes per replay | Receive MiB/s | Peak queued bytes | Drain p95 (ms) |
| --- | ---: | ---: | ---: | ---: |
| shell-workflow | 426 | 72.38 | 283 | 0.012 |
| vim-resume | 10,568 | 146.32 | 6,255 | 0.086 |
| codex-session | 18,382 | 69.69 | 2,862 | 0.270 |
