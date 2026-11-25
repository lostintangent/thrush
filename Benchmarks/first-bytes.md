# First bytes

Thrush applied the eight-byte shell prompt in **167 ns at p95** and answered a complete four-byte cursor-position query in **167 ns at p95**. The benchmark uses a fresh 80 × 24 terminal for each replay and checks the visible row, terminal reply and encoded Up key against the fixture. [Complete measurements](first-bytes.json) · [Fixture](../Fixtures/first-bytes.json)

## Recorded Mac measurements

The Release run used clean revision `75860e3` on a 10-core Apple M1 Max with macOS 27.2.1 and Swift 6.4.2. The Mac was on AC power with low-power mode off. Thermal state was nominal and the one-minute load average was 208.41. This was run 2 of five, selected by median 80 × 24 ASCII throughput. Short operations can occupy only a few timer ticks on this machine. [Run environment and timings](first-bytes.json) · [Five-run results](headless.md#recorded-mac-measurements)

| Operation | p50 (ns) | p95 (ns) |
| --- | ---: | ---: |
| Apply the eight-byte shell prompt | 125 | 167 |
| Encode Up in normal cursor-key mode | 42 | 84 |
| Encode Up in application cursor-key mode | 42 | 84 |
| Read a visible row | 125 | 166 |
| Answer the complete four-byte cursor-position query | 166 | 167 |
| Drain the 75-byte burst | 1,584 | 1,708 |

The runner warms up for 100 replays, then measures 2,000. It applied all **150,000 received bytes**, emitted **36,000 reply bytes** and encoded **18,000 key bytes**. Receive throughput was **44.10 MiB/s**, calculated from time spent inside synchronous receive calls. The fixture splits a cursor query across two chunks. At the first cursor-report checkpoint, the runner also times the complete query in one call and verifies the same reply.

For the burst measurement, the runner offers all 75 fixture bytes at once and times the ordered receive and key-encoding calls. It checks the final row and outgoing bytes after the timer stops. The queue drained to zero. These measurements cover the headless emulator. [Sustained output, workflows and resize](headless.md)

## Run the benchmark

Run `swift run -c release ThrushBench` from the package root. It prints the operation timings and writes `.build/benchmarks/first-bytes.json` together with the headless replay report. To measure variation, run `python3 scripts/measure-first-bytes.py CHECKOUT OUTPUT` with a clean checkout and a fresh output directory. The script builds once and collects five consecutive runs that meet the quiet-host checks. [Five-run measurement script](../scripts/measure-first-bytes.py)
