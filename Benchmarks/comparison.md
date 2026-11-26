# Comparison with other emulator cores

ThrushCore has to outrun the fastest emulator cores we can measure, doing the same work on the same machine. This benchmark feeds identical bytes to ThrushCore, libghostty-vt and @xterm/headless, checks that they finish with the same screen, and reports throughput and allocations. A separate profile shows where ThrushCore spends its time. [Recorded report](comparison.json) · [Recorded profile](comparison-profile.json)

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3 scripts/comparison/run.py --output Benchmarks/comparison.json
```

The runner needs Node and Bun. It installs the [pinned reference](../Fixtures/reference/README.md), which supplies @xterm/headless. The first run downloads Zig and the libghostty-vt source release, checks both against pinned SHA-256 digests and builds the library into `.build/comparison/tools`. After that, a full run takes about 2 minutes on the reference machine. Pass `--workloads ascii,vim --rounds 1` for a quick check. The profile comes from the [Comparison profile workflow](../.github/workflows/comparison-profile.yml). [Profile](#profile)

## Where Thrush stands

- **Thrush led libghostty-vt in 22 of 36 conditions.** It led in every condition on Vim by 1.22–1.68×, dense ASCII by 1.06–1.29× and SGR by 1.38–1.54×. At 240 × 60 it also led on the shell recording by 1.19–1.21×, Codex by 1.01×, cursor addressing by 1.52–1.53× and scrolling by 1.33–1.45×. [Screens](#screens)
- **The widest gaps are at 80 × 24.** Thrush ran at 0.68× of libghostty-vt on the scroll region, 0.70–0.71× on the shell recording and 0.78× on wide text. [Where Thrush loses time](#where-thrush-loses-time)
- **Thrush ran faster than both @xterm/headless runtimes in every condition**, by 3.02–15.21×.
- **Screen checks.** Thrush matched the Node reference in 36 of 36 conditions. The Bun runtime matched it in 36 of 36, and libghostty-vt matched it in 32 of 36. [Screens](#screens)
- **Allocations.** At 4 KiB, Thrush recorded 21 to 21,508 allocations per workload and libghostty-vt recorded 0 to 1,330. [Allocations](#allocations)

Since the [previous report](#change-since-the-previous-report), Thrush's ratio to libghostty-vt rose in 30 of 36 conditions. At 80 × 24 in 4 KiB chunks, scrolling went from 0.90× to 1.07× and wide text went from 0.66× to 0.78×.

## Identical work

Every core receives the same bytes at the same grid size with a 1,000-row history limit. Each workload runs at 80 × 24 and 240 × 60, and arrives either in 4 KiB chunks or as one buffer. No core has an app attached, so replies to queries go nowhere. Each measured pass creates a fresh terminal outside the timed region, then feeds the whole workload.

- **libghostty-vt builds the full screen.** `ghostty_terminal_vt_write` drives cells, styles, cursor, modes, both screens and history. Its final visible rows, cursor and active screen matched the Node reference in 32 of 36 conditions. The comparison checks visible text, cursor position and the active buffer. It also checks history depth for Thrush and both JavaScript runtimes. The conformance suite checks cell attributes. At 80 × 24 in 4 KiB chunks its throughput was 1,012 MiB/s on plain text and 147 MiB/s on per-cell SGR.
- **History depth doesn't change its work.** libghostty-vt drops history a whole page at a time, so with the same 1,000-row limit it kept 578 to 964 rows where the others kept 1,000. Every line still scrolls into history, and a dropped page is reused for new rows, so its whole scroll pass allocated 2 times. A separate check on the scroll workload at 80 × 24 raised its limit to 2,000 rows. It kept 1,864 rows, more than Thrush, and ran at 391 to 401 MiB/s against 389 to 400 with the 1,000-row limit. Only an unlimited history, which keeps all 64,616 lines in new pages, slowed it, to 174 to 182 MiB/s.
- **libghostty-vt did less scrolling in four conditions.** Its large-grid shell and Vim runs retained the alternate screen’s scroll region. Thrush reached 1.19–1.68× of its throughput in these conditions. [Screens](#screens)

## Method

### Cores

- **ThrushCore** at the recorded revision, built with `swift build -c release`. `ThrushBench --workload` feeds it a `Span` of each chunk.
- **libghostty-vt 1.0.2**, built from its source release with Zig 0.17.1 and `-Doptimize=ReleaseFast`, then linked statically into `scripts/comparison/ghostty.c`. The runner feeds bytes with `ghostty_terminal_vt_write` and reads the final screen through `ghostty_terminal_grid_ref`. It lifts the default scrollback byte cap so history is limited by rows alone, like the other cores.
- **@xterm/headless 6.0.0** with @xterm/addon-unicode11 0.9.0 and Unicode 11 widths active, the [pinned reference](../Fixtures/reference/README.md). `scripts/comparison/xterm.mjs` runs it under Node 22.18.0 and Bun 1.4.6, and each condition counts the faster runtime. It feeds bytes through `writeSync` on the terminal's core. The public `write` queues the same bytes and parses them in 12 ms slices between timers, so the synchronous call measures parsing and screen updates in the calling process.

### Timing

Each of 5 rounds runs every core once per workload and condition, in a freshly shuffled order, so load on a shared machine falls on all of them alike. Each run is a new process with 3 warmup passes and 3 measured passes. Rates come from the median wall time of the 15 measured passes. The ratio columns divide Thrush's throughput by the other core's, so a ratio below 1 means Thrush was slower. Each ratio pairs the cores within a round, which shared that round's load, and reports the median of those paired ratios with their range in parentheses. The JSON also records each round's median wall time and the median CPU time.

### Screen checks

At the end of each run every core reports its visible rows, cursor, active screen and history depth. The runner compares them with xterm under Node, after trimming trailing spaces and clamping a cursor that is waiting to wrap to the last column. libghostty-vt's history depth is recorded but not compared, as [Identical work](#identical-work) explains.

### Allocations

A separate pass for ThrushCore and libghostty-vt runs with `scripts/comparison/allocations.c` inserted. It interposes the malloc family, including the typed and zone variants, and anonymous `mmap`, and counts only the outermost call on each thread. Each count covers one measured pass after one warmup, for every condition. [Allocations](#allocations) shows 4 KiB chunks, and the JSON holds the rest. The JavaScript garbage collector manages xterm's memory, so it isn't counted.

### Profile

`scripts/comparison/profile.py` builds ThrushBench, samples ThrushCore with `sample` for 3 seconds on each workload at 80 × 24 in 4 KiB chunks, and ranks functions by self time. The [Comparison profile workflow](../.github/workflows/comparison-profile.yml) runs it on a hosted Mac and uploads the report. That runner is a 3-core Apple M1 (Virtual), so the profile's shares of time carry over to the reference machine but its rates don't. Inlined code counts toward the function it was inlined into, which is why `Terminal.receive` carries much of the per-byte work.

## Workloads

Each workload is about 1 MiB, generated deterministically by `scripts/comparison/workloads.py`. The recorded workloads repeat the program output of committed fixtures in `Fixtures/replays`, without their resizes, until they reach 1 MiB.

| Workload | What it holds | Bytes | SHA-256 prefix |
| --- | --- | ---: | --- |
| shell | `shell-log`: prompts, a long build log with accented and CJK paths, and a short Vim edit | 1,145,837 | `767d3f9e1f704d06` |
| vim | `vim-edit`, `vim-resume`, `vim-swift-dark` and `vim-swift-light`: full-screen editing and highlighted Swift | 1,058,280 | `92b5b28883faecfe` |
| codex | `codex-session`: a Codex session's styled, cursor-addressed output | 1,066,156 | `ee53772a6d921fcf` |
| ascii | Words in lines of 8 to 200 characters ending in CRLF, so long lines wrap | 1,048,634 | `27549df120fad47a` |
| sgr | 80-cell lines with an SGR before every cell, mixing basic, 256-color and RGB colors with attributes | 1,049,367 | `15e74931214ff067` |
| wide | Lines of CJK ideographs, emoji and words, wrapping wide glyphs at the margin | 1,048,616 | `3e10e33e7379faf1` |
| cursor | Frames that clear the screen, then write 120 words at random positions with occasional EL and ED | 1,049,493 | `41ac6cba6f3aa9bf` |
| scroll | Short numbered lines, so nearly every byte run ends in a scroll into history | 1,048,587 | `3fc3d209db465438` |
| region | 64 lines scrolled inside rows 2 to 20, then a reverse-video status line on row 24 | 1,049,715 | `80c5a714c8ae5cc8` |

## Results

Recorded November 26, 2026 at 00:07 UTC on an Apple M1 Max with 10 cores, macOS 27.2.1 and Apple Swift version 6.4.2. The one-minute load average was 5 at the start and 12 at the end. Within each round the cores ran back to back. The ranges show how their relative rates varied. [Measured source 6d664e6](https://github.com/lostintangent/thrush/commit/6d664e6a962362e53437be45453923436664be34)

| Workload | Grid | Chunks | Thrush MiB/s | libghostty-vt MiB/s | xterm MiB/s | Thrush ÷ libghostty-vt | Thrush ÷ xterm |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| shell | 80 × 24 | 4 KiB | 217 | 302 | 56 (Node) | 0.71× (0.70–0.85) | 3.83× (3.02–3.96) |
| shell | 80 × 24 | Whole | 214 | 310 | 56 (Node) | 0.70× (0.69–0.72) | 3.81× (3.72–3.87) |
| shell | 240 × 60 | 4 KiB | 216 | 178 | 52 (Node) | 1.21× (1.21–1.27) | 4.18× (4.04–4.40) |
| shell | 240 × 60 | Whole | 216 | 181 | 50 (Node) | 1.19× (1.19–1.20) | 4.29× (4.03–4.61) |
| vim | 80 × 24 | 4 KiB | 439 | 362 | 55 (Bun) | 1.22× (1.20–1.22) | 7.72× (7.55–8.33) |
| vim | 80 × 24 | Whole | 448 | 358 | 59 (Bun) | 1.24× (1.24–1.25) | 7.59× (7.24–8.46) |
| vim | 240 × 60 | 4 KiB | 404 | 241 | 32 (Bun) | 1.67× (1.64–1.69) | 12.18× (11.72–12.60) |
| vim | 240 × 60 | Whole | 414 | 246 | 34 (Bun) | 1.68× (1.65–1.69) | 12.15× (12.08–12.31) |
| codex | 80 × 24 | 4 KiB | 243 | 276 | 63 (Node) | 0.88× (0.86–0.88) | 3.85× (3.81–3.85) |
| codex | 80 × 24 | Whole | 245 | 276 | 68 (Bun) | 0.89× (0.86–0.91) | 3.62× (2.80–3.74) |
| codex | 240 × 60 | 4 KiB | 229 | 228 | 59 (Bun) | 1.01× (1.00–1.02) | 3.87× (3.81–4.00) |
| codex | 240 × 60 | Whole | 241 | 239 | 48 (Bun) | 1.01× (0.99–1.01) | 5.02× (4.85–5.04) |
| ascii | 80 × 24 | 4 KiB | 1127 | 1073 | 87 (Node) | 1.06× (0.90–1.15) | 13.06× (11.17–13.68) |
| ascii | 80 × 24 | Whole | 1162 | 1052 | 88 (Node) | 1.09× (1.08–1.13) | 12.90× (12.59–13.94) |
| ascii | 240 × 60 | 4 KiB | 1413 | 1126 | 118 (Bun) | 1.25× (1.23–1.30) | 11.80× (11.51–11.96) |
| ascii | 240 × 60 | Whole | 1450 | 1123 | 123 (Bun) | 1.29× (1.27–1.43) | 11.73× (11.50–12.05) |
| sgr | 80 × 24 | 4 KiB | 220 | 160 | 72 (Node) | 1.38× (1.36–1.49) | 3.08× (2.98–3.08) |
| sgr | 80 × 24 | Whole | 220 | 158 | 72 (Node) | 1.38× (1.32–1.40) | 3.02× (2.93–3.06) |
| sgr | 240 × 60 | 4 KiB | 211 | 142 | 70 (Node) | 1.50× (1.43–1.55) | 3.02× (2.85–3.09) |
| sgr | 240 × 60 | Whole | 221 | 144 | 72 (Node) | 1.54× (1.53–1.55) | 3.08× (3.05–3.15) |
| wide | 80 × 24 | 4 KiB | 275 | 350 | 82 (Node) | 0.78× (0.77–0.81) | 3.31× (3.27–3.38) |
| wide | 80 × 24 | Whole | 275 | 353 | 83 (Node) | 0.78× (0.77–0.79) | 3.28× (3.15–3.31) |
| wide | 240 × 60 | 4 KiB | 287 | 351 | 90 (Bun) | 0.81× (0.81–0.88) | 3.19× (3.17–3.28) |
| wide | 240 × 60 | Whole | 285 | 347 | 89 (Bun) | 0.82× (0.81–0.86) | 3.11× (3.08–3.20) |
| cursor | 80 × 24 | 4 KiB | 176 | 176 | 46 (Bun) | 1.00× (0.98–1.01) | 3.72× (3.70–3.83) |
| cursor | 80 × 24 | Whole | 179 | 177 | 46 (Bun) | 1.00× (0.99–1.01) | 3.77× (3.71–3.89) |
| cursor | 240 × 60 | 4 KiB | 162 | 106 | 11 (Bun) | 1.52× (1.48–1.55) | 14.99× (14.71–15.25) |
| cursor | 240 × 60 | Whole | 163 | 106 | 11 (Bun) | 1.53× (1.52–1.57) | 15.21× (14.94–15.57) |
| scroll | 80 × 24 | 4 KiB | 431 | 414 | 62 (Bun) | 1.07× (1.02–1.18) | 7.19× (6.42–7.97) |
| scroll | 80 × 24 | Whole | 408 | 416 | 63 (Bun) | 0.96× (0.94–1.23) | 6.44× (6.01–6.61) |
| scroll | 240 × 60 | 4 KiB | 444 | 311 | 52 (Node) | 1.45× (1.39–1.48) | 8.39× (8.34–8.74) |
| scroll | 240 × 60 | Whole | 417 | 316 | 51 (Node) | 1.33× (1.28–1.35) | 7.94× (7.83–8.25) |
| region | 80 × 24 | 4 KiB | 328 | 482 | 44 (Bun) | 0.68× (0.68–1.04) | 7.40× (7.13–7.67) |
| region | 80 × 24 | Whole | 324 | 461 | 42 (Bun) | 0.68× (0.68–0.72) | 7.51× (7.35–8.19) |
| region | 240 × 60 | 4 KiB | 326 | 344 | 31 (Bun) | 0.92× (0.90–0.96) | 9.99× (9.06–11.50) |
| region | 240 × 60 | Whole | 321 | 353 | 31 (Bun) | 0.92× (0.90–0.92) | 9.60× (9.27–11.69) |

## Change since the previous report

Both reports used the same host, toolchain, workload digests and benchmark settings. The rows compare 15-pass medians at 80 × 24 in 4 KiB chunks. Across all 36 conditions Thrush ran 1.02–1.27× as fast as in the previous report, while libghostty-vt's own rates moved by 1.01–1.09×. In between, the ASCII scanner began reading where printable ASCII ends from the vector block that holds the end, and printable ASCII began continuing a non-ASCII run that appends cells. In 24 alternating ThrushBench pairs on the second change, the shell log ran 1.14× and the shell workflow 1.10× as fast. The hardware-keys and pointer-input replays ran 0.988× (0.980–0.998) and 0.982× (0.972–0.992). They carry 10 and 42 bytes of mode changes and no text, so they never reach the changed code, and the dip is code layout rather than work. [The hot path](../docs/emulator.md#the-hot-path) · [Previous report at 0929ef1](https://github.com/lostintangent/thrush/blob/c12f36758edbdc77ba7bde7cf228811816a3def0/Benchmarks/comparison.json)

| Workload | 0929ef1 MiB/s | 6d664e6 MiB/s | Change | 0929ef1 ÷ libghostty-vt | 6d664e6 ÷ libghostty-vt |
| --- | ---: | ---: | ---: | ---: | ---: |
| shell | 179.4 | 217.1 | 1.21× | 0.62× | 0.71× |
| vim | 414.8 | 439.4 | 1.06× | 1.21× | 1.22× |
| codex | 228.2 | 242.9 | 1.06× | 0.86× | 0.88× |
| ascii | 1042.9 | 1127.0 | 1.08× | 1.00× | 1.06× |
| sgr | 209.8 | 219.8 | 1.05× | 1.41× | 1.38× |
| wide | 224.6 | 274.6 | 1.22× | 0.66× | 0.78× |
| cursor | 164.0 | 176.5 | 1.08× | 0.97× | 1.00× |
| scroll | 365.7 | 430.7 | 1.18× | 0.90× | 1.07× |
| region | 308.6 | 327.9 | 1.06× | 0.67× | 0.68× |

## Screens

Thrush matched the Node reference in 36 of 36 conditions. The Bun runtime matched it in 36 of 36, and libghostty-vt matched it in 32 of 36. The four libghostty-vt differences were on shell and Vim at 240 × 60. Both recordings were captured at 80 × 24, and Vim sets the scroll region to rows 1 to 24 (`ESC[1;24r`) on the alternate screen. When Vim leaves the alternate screen (`ESC[?1049l`), xterm and Thrush return to the main screen's own region, so the main screen still scrolls across all 60 rows. libghostty-vt keeps one region for both screens, so a line feed on the bottom row, below that region, doesn't scroll.

The smallest stream that shows it runs at 80 × 10:

```
ESC[?1049h ESC[1;5r ESC[?1049l ESC[10;1H a LF b
```

xterm and Thrush finish with `a` on row 9 and ` b` on row 10. libghostty-vt finishes with `ab` on row 10. At 80 × 24 the region already covers the whole screen, so all three cores agree. The affected runs do slightly less scrolling in libghostty-vt than in the other cores.

## Where Thrush spends its time

Shares of all samples in the [recorded profile](comparison-profile.json), taken at `6d664e6` with 1,596 to 2,040 samples per workload. Each of the 20 functions with the most self time in a workload belongs to at most one category. Unclassified functions and the rest of the samples account for the remainder.

| Workload | Scrolling | Allocation and ownership | Cell writes | Parsing and dispatch | Receive, decode and scan | Top functions |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| shell | 6% | 18% | 18% | 7% | 15% | `Row.writeASCII` 7%, `Hasher._hash` 7%, `receive` 6% |
| vim | 1% | 7% | 23% | 28% | 17% | `EscapeParser.consumeEscape` 17%, `receive` 12%, `Row.writeASCII` 10% |
| codex | 0% | 2% | 9% | 57% | 12% | `EscapeParser.consumeEscape` 35%, `receive` 10%, `apply` 9% |
| ascii | 18% | 10% | 37% | 0% | 26% | `Row.writeASCII` 27%, `TextScanner.endOfASCII` 17%, `Buffer.advanceLine` 10% |
| sgr | 0% | 5% | 18% | 54% | 12% | `Style.applySGR` 31%, `EscapeParser.consumeEscape` 24%, `receive` 9% |
| wide | 3% | 2% | 24% | 0% | 68% | `closure #1 in writeNonASCII` 61%, `Screen.writeRun` 22%, `receive` 4% |
| cursor | 0% | 5% | 47% | 38% | 9% | `EscapeParser.consumeEscape` 29%, `Row.writeASCII` 14%, `Row.set` 14% |
| scroll | 23% | 9% | 38% | 0% | 25% | `Row.writeASCII` 27%, `receive` 19%, `History.append` 12% |
| region | 46% | 4% | 30% | 2% | 15% | `_platform_memmove` 26%, `Row.writeASCII` 20%, `receive` 12% |

- **Scrolling** advances lines, appends history, clears recycled rows and rotates scroll regions. On the scroll region most of it is the memory move that rotating row values compiles to.
- **Allocation and ownership** is malloc, free, retain, release, uniqueness checks and hashing. On the shell recording most of it comes from rows' cluster tables.
- **Cell writes** are the ASCII, scalar and run writers, erases and their blank fills.
- **Parsing and dispatch** covers `EscapeParser`, `ControlParameters`, `Terminal.apply` and SGR.
- **Receive, decode and scan** covers `Terminal.receive`, the ASCII scanner, UTF-8 decoding, width lookup and the non-ASCII writer, with whatever is inlined into them.

## Allocations

Allocation counts for one pass at 4 KiB chunks. The terminal starts each pass with empty screens and history.

| Workload | Thrush 80 × 24 | Thrush 240 × 60 | libghostty-vt 80 × 24 | libghostty-vt 240 × 60 |
| --- | ---: | ---: | ---: | ---: |
| shell | 21,282 | 21,508 | 134 | 140 |
| vim | 7,002 | 7,841 | 1,330 | 1,330 |
| codex | 3,838 | 3,838 | 475 | 477 |
| ascii | 1,035 | 1,071 | 2 | 9 |
| sgr | 3,083 | 3,191 | 6 | 15 |
| wide | 1,035 | 1,071 | 2 | 9 |
| cursor | 24 | 24 | 0 | 0 |
| scroll | 1,035 | 1,071 | 2 | 9 |
| region | 21 | 21 | 0 | 0 |

A row allocates its cells once, on its first write. A line feed, an erase or a region scroll clears a row in place, so once the screen and 1,000 rows of history fill, steady output stops allocating. Dense ASCII, wide text and scrolling settle at 1,035 allocations at 80 × 24, one for each row the screen and history hold plus a few for the terminal itself. Cursor addressing and the scroll region stay on the screen and allocate 24 and 21 times. A row's style list allocates when the row's first non-default style arrives and again when it grows to the row's width, so per-cell SGR adds 2,048 allocations while its 1 MiB fills the first 1,024 rows. Vim and Codex add style lists the same way. The shell recording allocates 21,282 times, close to one for each of the 18,634 lines that carry a combining accent, because clearing a row releases its cluster table. [Where Thrush loses time](#where-thrush-loses-time)

## Where Thrush loses time

At 80 × 24 in 4 KiB chunks Thrush trails libghostty-vt on five of the nine workloads. The profile and the code trace each gap to one or two costs. The [performance plan](../docs/plan.md#closing-the-libghostty-vt-gap) turns each cost into a change.

| Workload | Thrush ÷ libghostty-vt | Where Thrush loses time |
| --- | ---: | --- |
| shell | 0.71× | Cluster tables and decoding one scalar per call |
| codex | 0.88× | Reading control parameters twice |
| wide | 0.78× | Decoding one scalar per call |
| cursor | 0.999× | Reading control parameters twice |
| region | 0.68× | Rotating row values |

- **Rotating row values.** Scrolling a region rotates the 64-byte `Row` values between its margins, and the memory move and `Array.rotate` take 38% of samples on the scroll region. libghostty-vt moves 8-byte row offsets instead.
- **Cluster tables.** The shell recording puts a combining accent on 18,634 lines. Clearing a row releases its `[Int: String]` cluster table, so the next accent on that row allocates a new table and grows it again, and adding a mark looks its base up twice. Hashing, allocation and freeing take about 18% of shell samples.
- **Decoding one scalar per call.** On wide text the closure in `Terminal.writeNonASCII` takes 61% of samples and `Screen.writeRun` 22%. For each scalar the closure decodes it, looks up its width and hands it to the run through a call that isn't inlined. libghostty-vt decodes a whole printable run to UTF-32 and then fills the row. The shell recording's accented paths take the same route.
- **Reading control parameters twice.** Parsing and dispatch take 57% of samples on Codex and 38% on cursor addressing, with `EscapeParser.consumeEscape` alone at 35% on Codex. The parser scans a complete header once to find its final byte. SGR borrows those bytes, but every other final, such as cursor position or erase, sends them through `ControlParameters.append` again one byte at a time, switching on its destination for each digit.
