# Comparison with other emulator cores

ThrushCore has to outrun the fastest emulator cores we can measure, doing the same work on the same machine. This benchmark feeds identical bytes to ThrushCore, libghostty-vt and @xterm/headless, checks that they finish with the same screen, and reports throughput and allocations. A separate profile shows where ThrushCore spends its time. [Recorded report](comparison.json) · [Recorded profile](comparison-profile.json)

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3 scripts/comparison/run.py --output Benchmarks/comparison.json
```

The runner needs Node and Bun. It installs the [pinned reference](../Fixtures/reference/README.md), which supplies @xterm/headless. The first run downloads Zig and the libghostty-vt source release, checks both against pinned SHA-256 digests and builds the library into `.build/comparison/tools`. After that, a full run takes about 2 minutes on the reference machine. Pass `--workloads ascii,vim --rounds 1` for a quick check. The profile comes from the [Comparison profile workflow](../.github/workflows/comparison-profile.yml). [Profile](#profile)

## Where Thrush stands

- **Thrush led libghostty-vt in 28 of 36 conditions.** It led in every condition on the shell recording by 1.07–1.82×, Vim by 1.23–1.71×, dense ASCII by 1.10–1.30×, SGR by 1.38–1.53×, cursor addressing by 1.00–1.56× and scrolling by 1.05–1.37×. At 240 × 60 it also led on Codex by 1.01–1.02× and wide text by 1.03–1.05×. [Screens](#screens)
- **The widest gaps are at 80 × 24.** Thrush ran at 0.68–0.69× of libghostty-vt on the scroll region, 0.89–0.90× on Codex and 0.97–0.98× on wide text. [Where Thrush loses time](#where-thrush-loses-time)
- **Thrush ran faster than both @xterm/headless runtimes in every condition**, by 3.01–15.67×.
- **Screen checks.** Thrush matched the Node reference in 36 of 36 conditions. The Bun runtime matched it in 36 of 36, and libghostty-vt matched it in 32 of 36. [Screens](#screens)
- **Allocations.** At 4 KiB, Thrush recorded 21 to 7,661 allocations per workload and libghostty-vt recorded 0 to 1,330. [Allocations](#allocations)

Since the [previous report](#change-since-the-previous-report), Thrush's ratio to libghostty-vt rose in 26 of 36 conditions. At 80 × 24 in 4 KiB chunks, wide text went from 0.77× to 0.97× and the shell recording went from 0.92× to 1.07×.

## Identical work

Every core receives the same bytes at the same grid size with a 1,000-row history limit. Each workload runs at 80 × 24 and 240 × 60, and arrives either in 4 KiB chunks or as one buffer. No core has an app attached, so replies to queries go nowhere. Each measured pass creates a fresh terminal outside the timed region, then feeds the whole workload.

- **libghostty-vt builds the full screen.** `ghostty_terminal_vt_write` drives cells, styles, cursor, modes, both screens and history. Its final visible rows, cursor and active screen matched the Node reference in 32 of 36 conditions. The comparison checks visible text, cursor position and the active buffer. It also checks history depth for Thrush and both JavaScript runtimes. The conformance suite checks cell attributes. At 80 × 24 in 4 KiB chunks its throughput was 1,012 MiB/s on plain text and 147 MiB/s on per-cell SGR.
- **History depth doesn't change its work.** libghostty-vt drops history a whole page at a time, so with the same 1,000-row limit it kept 578 to 964 rows where the others kept 1,000. Every line still scrolls into history, and a dropped page is reused for new rows, so its whole scroll pass allocated 2 times. A separate check on the scroll workload at 80 × 24 raised its limit to 2,000 rows. It kept 1,864 rows, more than Thrush, and ran at 391 to 401 MiB/s against 389 to 400 with the 1,000-row limit. Only an unlimited history, which keeps all 64,616 lines in new pages, slowed it, to 174 to 182 MiB/s.
- **libghostty-vt did less scrolling in four conditions.** Its large-grid shell and Vim runs retained the alternate screen’s scroll region. Thrush reached 1.68–1.82× of its throughput in these conditions. [Screens](#screens)

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

Recorded November 26, 2026 at 03:30 UTC on an Apple M1 Max with 10 cores, macOS 27.2.1 and Apple Swift version 6.4.2. The one-minute load average was 6 at the start and 17 at the end. Within each round the cores ran back to back. The ranges show how their relative rates varied. [Measured source 59093ee](https://github.com/lostintangent/thrush/commit/59093ee7522ded60f69c8548177ee99a9d8d5fcd)

| Workload | Grid | Chunks | Thrush MiB/s | libghostty-vt MiB/s | xterm MiB/s | Thrush ÷ libghostty-vt | Thrush ÷ xterm |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| shell | 80 × 24 | 4 KiB | 317 | 297 | 55 (Node) | 1.07× (1.06–1.10) | 5.84× (5.74–5.93) |
| shell | 80 × 24 | Whole | 318 | 297 | 55 (Node) | 1.07× (1.06–1.11) | 5.73× (5.69–5.82) |
| shell | 240 × 60 | 4 KiB | 313 | 174 | 50 (Node) | 1.81× (1.80–1.81) | 6.33× (6.25–7.85) |
| shell | 240 × 60 | Whole | 314 | 174 | 51 (Node) | 1.82× (1.81–1.82) | 6.22× (6.15–6.26) |
| vim | 80 × 24 | 4 KiB | 428 | 347 | 55 (Bun) | 1.24× (1.23–1.29) | 7.72× (6.78–8.03) |
| vim | 80 × 24 | Whole | 437 | 355 | 55 (Bun) | 1.23× (1.04–1.26) | 8.12× (5.97–8.29) |
| vim | 240 × 60 | 4 KiB | 396 | 236 | 32 (Bun) | 1.68× (1.67–1.75) | 12.21× (11.49–27.51) |
| vim | 240 × 60 | Whole | 403 | 235 | 32 (Bun) | 1.71× (1.68–1.76) | 12.46× (11.29–12.76) |
| codex | 80 × 24 | 4 KiB | 235 | 265 | 63 (Bun) | 0.89× (0.81–0.89) | 3.70× (3.41–3.77) |
| codex | 80 × 24 | Whole | 237 | 264 | 66 (Bun) | 0.90× (0.87–0.92) | 3.54× (2.76–3.66) |
| codex | 240 × 60 | 4 KiB | 231 | 229 | 49 (Bun) | 1.01× (0.97–1.01) | 3.97× (3.87–4.90) |
| codex | 240 × 60 | Whole | 233 | 230 | 47 (Bun) | 1.02× (1.00–1.04) | 4.99× (4.78–5.27) |
| ascii | 80 × 24 | 4 KiB | 1147 | 1024 | 85 (Node) | 1.10× (1.10–1.15) | 13.51× (13.16–13.79) |
| ascii | 80 × 24 | Whole | 1161 | 1041 | 87 (Node) | 1.10× (1.06–1.14) | 13.47× (12.73–13.48) |
| ascii | 240 × 60 | 4 KiB | 1383 | 1109 | 117 (Bun) | 1.25× (1.17–3.16) | 11.78× (10.94–12.36) |
| ascii | 240 × 60 | Whole | 1406 | 1105 | 123 (Bun) | 1.30× (1.24–1.32) | 11.60× (11.46–12.02) |
| sgr | 80 × 24 | 4 KiB | 210 | 152 | 70 (Node) | 1.38× (1.37–1.43) | 3.02× (2.98–3.06) |
| sgr | 80 × 24 | Whole | 217 | 154 | 71 (Node) | 1.38× (1.37–1.42) | 3.02× (3.02–3.04) |
| sgr | 240 × 60 | 4 KiB | 211 | 138 | 70 (Node) | 1.52× (1.49–1.53) | 3.01× (2.92–3.10) |
| sgr | 240 × 60 | Whole | 215 | 139 | 70 (Node) | 1.53× (1.48–1.58) | 3.08× (3.01–3.12) |
| wide | 80 × 24 | 4 KiB | 330 | 341 | 80 (Node) | 0.97× (0.94–1.01) | 4.16× (4.13–4.22) |
| wide | 80 × 24 | Whole | 331 | 346 | 80 (Node) | 0.98× (0.94–0.99) | 4.12× (4.04–4.26) |
| wide | 240 × 60 | 4 KiB | 354 | 333 | 84 (Bun) | 1.05× (1.03–2.10) | 4.20× (4.03–4.92) |
| wide | 240 × 60 | Whole | 349 | 347 | 91 (Bun) | 1.03× (1.00–1.09) | 3.84× (3.44–7.58) |
| cursor | 80 × 24 | 4 KiB | 176 | 176 | 46 (Bun) | 1.00× (0.93–1.03) | 3.83× (3.49–4.48) |
| cursor | 80 × 24 | Whole | 175 | 171 | 44 (Bun) | 1.02× (0.51–1.11) | 3.92× (2.20–3.96) |
| cursor | 240 × 60 | 4 KiB | 163 | 105 | 10 (Bun) | 1.55× (1.51–1.60) | 15.67× (15.10–17.45) |
| cursor | 240 × 60 | Whole | 161 | 103 | 11 (Bun) | 1.56× (1.54–1.60) | 15.43× (15.00–16.07) |
| scroll | 80 × 24 | 4 KiB | 423 | 405 | 62 (Bun) | 1.05× (0.99–1.08) | 6.83× (6.48–7.33) |
| scroll | 80 × 24 | Whole | 429 | 408 | 62 (Bun) | 1.06× (0.66–1.09) | 6.95× (4.24–7.43) |
| scroll | 240 × 60 | 4 KiB | 419 | 299 | 51 (Node) | 1.37× (0.94–1.42) | 8.17× (4.90–8.35) |
| scroll | 240 × 60 | Whole | 432 | 314 | 51 (Node) | 1.36× (1.35–1.41) | 8.35× (8.24–8.41) |
| region | 80 × 24 | 4 KiB | 318 | 463 | 43 (Bun) | 0.68× (0.67–0.76) | 7.51× (7.16–8.46) |
| region | 80 × 24 | Whole | 328 | 476 | 42 (Bun) | 0.69× (0.69–0.70) | 7.51× (7.42–19.16) |
| region | 240 × 60 | 4 KiB | 326 | 345 | 31 (Bun) | 0.92× (0.91–0.96) | 10.39× (9.60–13.14) |
| region | 240 × 60 | Whole | 327 | 345 | 33 (Bun) | 0.93× (0.91–0.95) | 9.62× (9.32–9.82) |

## Change since the previous report

Both reports used the same host, toolchain, workload digests and benchmark settings. The rows compare 15-pass medians at 80 × 24 in 4 KiB chunks. Across all 36 conditions Thrush ran 0.96–1.26× as fast as in the previous report, while libghostty-vt's own rates moved by 0.92–1.02×. Non-ASCII runs now decode into a buffer before the row stores them. Wide text ran 1.22× and the shell recording 1.15× as fast, and the shell recording now leads in every condition. In alternating ThrushBench pairs the shell log ran 1.02–1.03× as fast, and hardware-keys and pointer-input 0.99×, since their fresh terminals each pay for the buffer's 256 bytes. Full scrolling ran 1.03× as fast and now leads, but this change doesn't explain it. Builds that retire the same instructions on it run at one of two speeds about 6% apart as their code moves, and 59093ee's build runs at the faster one. [The hot path](../docs/emulator.md#the-hot-path) · [Previous report at 26cf81b](https://github.com/lostintangent/thrush/blob/65e5be0/Benchmarks/comparison.json)

| Workload | 26cf81b MiB/s | 59093ee MiB/s | Change | 26cf81b ÷ libghostty-vt | 59093ee ÷ libghostty-vt |
| --- | ---: | ---: | ---: | ---: | ---: |
| shell | 275.3 | 317.4 | 1.15× | 0.92× | 1.07× |
| vim | 442.5 | 428.1 | 0.97× | 1.22× | 1.24× |
| codex | 238.1 | 234.8 | 0.99× | 0.88× | 0.89× |
| ascii | 1160.0 | 1146.7 | 0.99× | 1.08× | 1.10× |
| sgr | 217.6 | 210.4 | 0.97× | 1.37× | 1.38× |
| wide | 270.7 | 329.7 | 1.22× | 0.77× | 0.97× |
| cursor | 178.3 | 176.5 | 0.99× | 1.01× | 1.00× |
| scroll | 411.9 | 423.2 | 1.03× | 0.97× | 1.05× |
| region | 332.1 | 317.9 | 0.96× | 0.70× | 0.68× |

## Screens

Thrush matched the Node reference in 36 of 36 conditions. The Bun runtime matched it in 36 of 36, and libghostty-vt matched it in 32 of 36. The four libghostty-vt differences were on shell and Vim at 240 × 60. Both recordings were captured at 80 × 24, and Vim sets the scroll region to rows 1 to 24 (`ESC[1;24r`) on the alternate screen. When Vim leaves the alternate screen (`ESC[?1049l`), xterm and Thrush return to the main screen's own region, so the main screen still scrolls across all 60 rows. libghostty-vt keeps one region for both screens, so a line feed on the bottom row, below that region, doesn't scroll.

The smallest stream that shows it runs at 80 × 10:

```
ESC[?1049h ESC[1;5r ESC[?1049l ESC[10;1H a LF b
```

xterm and Thrush finish with `a` on row 9 and ` b` on row 10. libghostty-vt finishes with `ab` on row 10. At 80 × 24 the region already covers the whole screen, so all three cores agree. The affected runs do slightly less scrolling in libghostty-vt than in the other cores.

## Where Thrush spends its time

Shares of all samples in the [recorded profile](comparison-profile.json), taken at `59093ee` with 1,829 to 2,367 samples per workload. Each of the 20 functions with the most self time in a workload belongs to at most one category. Unclassified functions and the rest of the samples account for the remainder.

| Workload | Scrolling | Allocation and ownership | Cell writes | Parsing and dispatch | Receive, decode and scan | Top functions |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| shell | 3% | 11% | 30% | 9% | 22% | `Screen.writeRun` 14%, `TextScanner.decodeText<let A>` 10%, `receive` 8% |
| vim | 1% | 12% | 21% | 31% | 15% | `EscapeParser.consumeEscape` 20%, `receive` 10%, `Row.writeASCII` 9% |
| codex | 0% | 2% | 11% | 58% | 12% | `EscapeParser.consumeEscape` 35%, `Style.applySGR` 10%, `receive` 9% |
| ascii | 16% | 11% | 38% | 0% | 27% | `Row.writeASCII` 26%, `TextScanner.endOfASCII` 19%, `Buffer.advanceLine` 9% |
| sgr | 0% | 7% | 18% | 55% | 13% | `Style.applySGR` 29%, `EscapeParser.consumeEscape` 25%, `receive` 9% |
| wide | 4% | 3% | 26% | 0% | 63% | `TextScanner.decodeText<let A>` 55%, `Screen.writeRun` 21%, `receive` 6% |
| cursor | 0% | 3% | 46% | 39% | 11% | `EscapeParser.consumeEscape` 28%, `Row.set` 14%, `Row.writeASCII` 13% |
| scroll | 20% | 9% | 41% | 0% | 26% | `Row.writeASCII` 28%, `receive` 20%, `Buffer.advanceLine` 12% |
| region | 46% | 4% | 28% | 2% | 15% | `_platform_memmove` 26%, `Row.writeASCII` 19%, `receive` 12% |

- **Scrolling** advances lines, appends history, clears recycled rows and rotates scroll regions. On the scroll region most of it is the memory move that rotating row values compiles to.
- **Allocation and ownership** is malloc, free, retain, release, uniqueness checks and hashing.
- **Cell writes** are the ASCII, scalar and run writers, erases and their blank fills.
- **Parsing and dispatch** covers `EscapeParser`, `ControlParameters`, `Terminal.apply` and SGR.
- **Receive, decode and scan** covers `Terminal.receive`, the ASCII scanner, UTF-8 decoding, width lookup and the non-ASCII writer, with whatever is inlined into them.

## Allocations

Allocation counts for one pass at 4 KiB chunks. The terminal starts each pass with empty screens and history.

| Workload | Thrush 80 × 24 | Thrush 240 × 60 | libghostty-vt 80 × 24 | libghostty-vt 240 × 60 |
| --- | ---: | ---: | ---: | ---: |
| shell | 3,672 | 3,934 | 134 | 140 |
| vim | 6,822 | 7,661 | 1,330 | 1,330 |
| codex | 3,838 | 3,838 | 475 | 477 |
| ascii | 1,035 | 1,071 | 2 | 9 |
| sgr | 3,083 | 3,191 | 6 | 15 |
| wide | 1,035 | 1,071 | 2 | 9 |
| cursor | 24 | 24 | 0 | 0 |
| scroll | 1,035 | 1,071 | 2 | 9 |
| region | 21 | 21 | 0 | 0 |

A row allocates its cells once, on its first write. A line feed, an erase or a region scroll clears a row in place, so once the screen and 1,000 rows of history fill, steady output stops allocating. Dense ASCII, wide text and scrolling settle at 1,035 allocations at 80 × 24, one for each row the screen and history hold plus a few for the terminal itself. Cursor addressing and the scroll region stay on the screen and allocate 24 and 21 times. A row's style list allocates when the row's first non-default style arrives and again when it grows to the row's width, so per-cell SGR adds 2,048 allocations while its 1 MiB fills the first 1,024 rows. Vim and Codex add style lists the same way. A row's cluster table allocates on the row's first combining mark and stays when the row clears. The shell recording puts an accent on 18,634 lines and allocates 3,672 times. [Where Thrush loses time](#where-thrush-loses-time)

## Where Thrush loses time

At 80 × 24 in 4 KiB chunks Thrush trails libghostty-vt on three of the nine workloads. The profile and the code trace each gap to one or two costs. The [performance plan](../docs/plan.md#keeping-the-core-fast-and-simple) says which of them are worth closing.

| Workload | Thrush ÷ libghostty-vt | Where Thrush loses time |
| --- | ---: | --- |
| codex | 0.89× | Reading the transition table, and reading control parameters twice |
| wide | 0.97× | Decoding and storing wide text |
| region | 0.68× | Rotating row values |

- **Reading the transition table.** The parser reads its transition table through a lazily initialized static. For tens of milliseconds after its first use, each read calls out to `swift_once` instead of passing an inline check, and Codex makes about 160,000 lookups per pass. Its early passes run about 15% slower than later ones, and each comparison run of three warmups and three passes falls inside that window. A program's first output in a session pays the same.
- **Reading control parameters twice.** Parsing and dispatch take 58% of samples on Codex and 39% on cursor addressing, with `EscapeParser.consumeEscape` alone at 35% on Codex. The parser scans a complete header once to find its final byte. SGR borrows those bytes, but every other final, such as cursor position or erase, sends them through `ControlParameters.append` again one byte at a time, switching on its destination for each digit.
- **Decoding and storing wide text.** Thrush decodes a run before storing it, as libghostty-vt does, but retires about a fifth more instructions on wide text. `TextScanner.decodeText` takes 55% of samples and `Screen.writeRun` 21%, and the decoder's time spreads across its loop head, the branch on the lead byte and the width lookup.
- **Rotating row values.** Scrolling a region rotates the 64-byte `Row` values between its margins, and the memory move and `Array.rotate` take 38% of samples on the scroll region. libghostty-vt moves 8-byte row offsets instead.
