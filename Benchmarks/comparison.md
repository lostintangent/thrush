# Comparison with other emulator cores

ThrushCore has to outrun the fastest emulator cores we can measure, doing the same work on the same machine. This benchmark feeds identical bytes to ThrushCore, libghostty-vt and @xterm/headless, checks that they finish with the same screen, and reports throughput and allocations. A separate profile shows where ThrushCore spends its time. [Recorded report](comparison.json) · [Recorded profile](comparison-profile.json)

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3 scripts/comparison/run.py --output Benchmarks/comparison.json
```

The runner needs Node and Bun. It installs the [pinned reference](../Fixtures/reference/README.md), which supplies @xterm/headless. The first run downloads Zig and the libghostty-vt source release, checks both against pinned SHA-256 digests and builds the library into `.build/comparison/tools`. After that, a full run takes about 2 minutes on the reference machine. Pass `--workloads ascii,vim --rounds 1` for a quick check. The profile comes from the [Comparison profile workflow](../.github/workflows/comparison-profile.yml). [Profile](#profile)

## Where Thrush stands

- **Thrush led libghostty-vt in 14 of 36 conditions.** It led in every SGR condition by 1.41–1.54× and every Vim condition by 1.14–1.53×. At 240 × 60 it also led on dense ASCII by 1.11–1.13×, cursor addressing by 1.20–1.24× and scrolling by 1.08–1.09×. [Screens](#screens)
- **The widest gaps are at 80 × 24.** Thrush ran at 0.58–0.59× of libghostty-vt on wide text, 0.58–0.59× on the scroll region and 0.59× on the shell recording. On dense ASCII libghostty-vt ran at 1,012 MiB/s on both grids, while Thrush ran at 857 MiB/s at 80 × 24 and 1,174 MiB/s at 240 × 60, where the same text wraps into fewer lines. Each line still costs Thrush more than it costs libghostty-vt. [Where Thrush loses time](#where-thrush-loses-time)
- **Thrush ran faster than both @xterm/headless runtimes in every condition**, by 2.37–12.43×.
- **Screen checks.** Thrush matched the Node reference in 36 of 36 conditions. The Bun runtime matched it in 36 of 36, and libghostty-vt matched it in 32 of 36. [Screens](#screens)
- **Allocations.** At 4 KiB, Thrush recorded 21 to 21,497 allocations per workload and libghostty-vt recorded 0 to 1,330. [Allocations](#allocations)

Since the [previous report](#change-since-the-previous-report), every ratio to libghostty-vt rose. At 80 × 24 in 4 KiB chunks, the scroll region went from 0.12× to 0.59× and dense ASCII from 0.36× to 0.85×.

## Identical work

Every core receives the same bytes at the same grid size with a 1,000-row history limit. Each workload runs at 80 × 24 and 240 × 60, and arrives either in 4 KiB chunks or as one buffer. No core has a host attached, so replies to queries go nowhere. Each measured pass creates a fresh terminal outside the timed region, then feeds the whole workload.

- **libghostty-vt builds the full screen.** `ghostty_terminal_vt_write` drives cells, styles, cursor, modes, both screens and history. Its final visible rows, cursor and active screen matched the Node reference in 32 of 36 conditions. The comparison checks visible text, cursor position and the active buffer. It also checks history depth for Thrush and both JavaScript runtimes. The conformance suite checks cell attributes. At 80 × 24 in 4 KiB chunks its throughput was 1,012 MiB/s on plain text and 147 MiB/s on per-cell SGR.
- **History depth doesn't change its work.** libghostty-vt drops history a whole page at a time, so with the same 1,000-row limit it kept 578 to 964 rows where the others kept 1,000. Every line still scrolls into history, and a dropped page is reused for new rows, so its whole scroll pass allocated 2 times. A separate check on the scroll workload at 80 × 24 raised its limit to 2,000 rows. It kept 1,864 rows, more than Thrush, and ran at 391 to 401 MiB/s against 389 to 400 with the 1,000-row limit. Only an unlimited history, which keeps all 64,616 lines in new pages, slowed it, to 174 to 182 MiB/s.
- **libghostty-vt did less scrolling in four conditions.** Its large-grid shell and Vim runs retained the alternate screen’s scroll region. Thrush reached 0.97–1.53× of its throughput in these conditions. [Screens](#screens)

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

Recorded November 25, 2026 at 21:31 UTC on an Apple M1 Max with 10 cores, macOS 27.2.1 and Apple Swift version 6.4.2. The one-minute load average was 15 at the start and 21 at the end. Within each round the cores ran back to back. The ranges show how their relative rates varied. [Measured source c528777](https://github.com/lostintangent/thrush/commit/c528777f5f666abeb100d2227c0f294179b4747f)

| Workload | Grid | Chunks | Thrush MiB/s | libghostty-vt MiB/s | xterm MiB/s | Thrush ÷ libghostty-vt | Thrush ÷ xterm |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| shell | 80 × 24 | 4 KiB | 176 | 296 | 53 (Node) | 0.59× (0.58–0.60) | 3.15× (3.10–3.34) |
| shell | 80 × 24 | Whole | 178 | 296 | 53 (Node) | 0.59× (0.58–0.61) | 3.35× (3.16–3.35) |
| shell | 240 × 60 | 4 KiB | 174 | 175 | 49 (Node) | 0.99× (0.99–1.00) | 3.50× (3.27–5.08) |
| shell | 240 × 60 | Whole | 168 | 170 | 50 (Node) | 0.97× (0.95–0.98) | 3.38× (3.25–3.56) |
| vim | 80 × 24 | 4 KiB | 393 | 345 | 54 (Bun) | 1.14× (1.12–1.15) | 7.45× (6.49–8.05) |
| vim | 80 × 24 | Whole | 400 | 347 | 54 (Bun) | 1.16× (0.78–1.19) | 7.42× (5.47–7.78) |
| vim | 240 × 60 | 4 KiB | 345 | 233 | 31 (Bun) | 1.50× (1.44–1.62) | 11.11× (10.54–13.87) |
| vim | 240 × 60 | Whole | 355 | 233 | 29 (Bun) | 1.53× (1.51–1.56) | 12.43× (10.93–14.25) |
| codex | 80 × 24 | 4 KiB | 231 | 263 | 60 (Node) | 0.87× (0.84–0.98) | 3.93× (3.82–5.02) |
| codex | 80 × 24 | Whole | 230 | 260 | 64 (Bun) | 0.89× (0.88–1.49) | 3.59× (3.53–3.68) |
| codex | 240 × 60 | 4 KiB | 223 | 227 | 50 (Bun) | 0.97× (0.93–0.99) | 4.01× (3.76–5.32) |
| codex | 240 × 60 | Whole | 222 | 223 | 44 (Bun) | 1.00× (0.96–1.04) | 4.92× (4.57–6.27) |
| ascii | 80 × 24 | 4 KiB | 857 | 1012 | 76 (Node) | 0.85× (0.83–0.86) | 11.34× (10.21–13.34) |
| ascii | 80 × 24 | Whole | 871 | 1016 | 81 (Node) | 0.85× (0.45–0.88) | 10.53× (6.99–12.25) |
| ascii | 240 × 60 | 4 KiB | 1174 | 1013 | 111 (Bun) | 1.13× (1.11–1.68) | 10.51× (10.29–14.30) |
| ascii | 240 × 60 | Whole | 1187 | 1078 | 113 (Bun) | 1.11× (1.09–1.57) | 10.58× (9.59–11.48) |
| sgr | 80 × 24 | 4 KiB | 206 | 147 | 66 (Node) | 1.41× (1.37–1.50) | 3.01× (2.94–3.21) |
| sgr | 80 × 24 | Whole | 207 | 143 | 63 (Node) | 1.45× (1.37–1.57) | 3.03× (2.97–5.50) |
| sgr | 240 × 60 | 4 KiB | 205 | 134 | 66 (Node) | 1.54× (1.51–1.57) | 3.10× (2.94–3.36) |
| sgr | 240 × 60 | Whole | 206 | 136 | 62 (Node) | 1.53× (1.51–1.57) | 3.44× (3.08–4.05) |
| wide | 80 × 24 | 4 KiB | 197 | 335 | 77 (Node) | 0.58× (0.41–0.59) | 2.47× (2.44–2.55) |
| wide | 80 × 24 | Whole | 199 | 337 | 77 (Node) | 0.59× (0.58–0.60) | 2.53× (2.52–3.52) |
| wide | 240 × 60 | 4 KiB | 207 | 333 | 82 (Bun) | 0.62× (0.61–0.73) | 2.53× (2.34–2.72) |
| wide | 240 × 60 | Whole | 208 | 335 | 88 (Bun) | 0.61× (0.55–0.63) | 2.37× (2.24–2.51) |
| cursor | 80 × 24 | 4 KiB | 161 | 169 | 43 (Bun) | 0.95× (0.92–1.14) | 3.75× (3.48–3.92) |
| cursor | 80 × 24 | Whole | 156 | 169 | 42 (Bun) | 0.93× (0.90–1.00) | 3.52× (3.33–5.11) |
| cursor | 240 × 60 | 4 KiB | 127 | 102 | 10 (Bun) | 1.24× (1.21–1.33) | 12.16× (12.08–12.28) |
| cursor | 240 × 60 | Whole | 126 | 103 | 10 (Bun) | 1.20× (1.13–1.26) | 12.00× (11.08–13.58) |
| scroll | 80 × 24 | 4 KiB | 303 | 399 | 58 (Node) | 0.76× (0.73–0.78) | 5.20× (5.08–6.27) |
| scroll | 80 × 24 | Whole | 300 | 395 | 59 (Node) | 0.76× (0.74–0.90) | 5.04× (4.88–5.36) |
| scroll | 240 × 60 | 4 KiB | 309 | 289 | 50 (Node) | 1.08× (0.98–1.22) | 6.02× (5.99–6.37) |
| scroll | 240 × 60 | Whole | 307 | 285 | 49 (Node) | 1.09× (0.89–1.10) | 6.22× (5.15–7.57) |
| region | 80 × 24 | 4 KiB | 269 | 458 | 38 (Bun) | 0.59× (0.58–0.65) | 6.97× (6.14–12.61) |
| region | 80 × 24 | Whole | 266 | 462 | 39 (Bun) | 0.58× (0.57–0.61) | 6.78× (6.18–9.48) |
| region | 240 × 60 | 4 KiB | 266 | 340 | 28 (Bun) | 0.78× (0.19–0.82) | 7.99× (2.37–10.16) |
| region | 240 × 60 | Whole | 276 | 343 | 29 (Node) | 0.79× (0.78–0.81) | 9.19× (9.10–11.23) |

## Change since the previous report

Both reports used the same host, toolchain, workload digests and benchmark settings. The rows compare 15-pass medians at 80 × 24 in 4 KiB chunks. Across all 36 conditions Thrush ran 1.11–5.14× as fast as in the previous report, while libghostty-vt's own rates moved by 0.96–1.06×. In between, scroll regions began rotating rows, cells shrank to 8 bytes with each style stored once per row, and single-byte controls took a direct path. [Storage](../docs/emulator.md#storage) · [Previous report at f4ddc15](https://github.com/lostintangent/thrush/blob/a8ffabb58c0b5bebd2c233614e8888b30f76b190/Benchmarks/comparison.json)

| Workload | f4ddc15 MiB/s | c528777 MiB/s | Change | f4ddc15 ÷ libghostty-vt | c528777 ÷ libghostty-vt |
| --- | ---: | ---: | ---: | ---: | ---: |
| shell | 136.3 | 175.7 | 1.29× | 0.47× | 0.59× |
| vim | 269.4 | 393.1 | 1.46× | 0.78× | 1.14× |
| codex | 195.4 | 231.1 | 1.18× | 0.74× | 0.87× |
| ascii | 366.0 | 857.3 | 2.34× | 0.36× | 0.85× |
| sgr | 186.1 | 206.4 | 1.11× | 1.25× | 1.41× |
| wide | 174.8 | 196.6 | 1.12× | 0.52× | 0.58× |
| cursor | 116.5 | 160.8 | 1.38× | 0.68× | 0.95× |
| scroll | 165.7 | 302.7 | 1.83× | 0.42× | 0.76× |
| region | 54.7 | 269.3 | 4.92× | 0.12× | 0.59× |

## Screens

Thrush matched the Node reference in 36 of 36 conditions. The Bun runtime matched it in 36 of 36, and libghostty-vt matched it in 32 of 36. The four libghostty-vt differences were on shell and Vim at 240 × 60. Both recordings were captured at 80 × 24, and Vim sets the scroll region to rows 1 to 24 (`ESC[1;24r`) on the alternate screen. When Vim leaves the alternate screen (`ESC[?1049l`), xterm and Thrush return to the main screen's own region, so the main screen still scrolls across all 60 rows. libghostty-vt keeps one region for both screens, so a line feed on the bottom row, below that region, doesn't scroll.

The smallest stream that shows it runs at 80 × 10:

```
ESC[?1049h ESC[1;5r ESC[?1049l ESC[10;1H a LF b
```

xterm and Thrush finish with `a` on row 9 and ` b` on row 10. libghostty-vt finishes with `ab` on row 10. At 80 × 24 the region already covers the whole screen, so all three cores agree. The affected runs do slightly less scrolling in libghostty-vt than in the other cores.

## Where Thrush spends its time

Shares of all samples in the [recorded profile](comparison-profile.json), taken at `c528777` with 1,408 to 1,995 samples per workload. Each of the 20 functions with the most self time in a workload belongs to at most one category. Unclassified functions and the rest of the samples account for the remainder.

| Workload | Scrolling | Allocation and ownership | Cell writes | Parsing and dispatch | Receive, decode and scan | Top functions |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| shell | 3% | 19% | 25% | 5% | 19% | `Row.writeASCII` 9%, `receive` 8%, `Screen.writeASCII` 7% |
| vim | 3% | 11% | 26% | 25% | 16% | `EscapeParser.consumeEscape` 16%, `Row.writeASCII` 13%, `receive` 9% |
| codex | 1% | 2% | 12% | 55% | 14% | `EscapeParser.consumeEscape` 33%, `apply` 10%, `receive` 9% |
| ascii | 19% | 11% | 37% | 0% | 27% | `Row.writeASCII` 28%, `TextScanner.endOfASCII` 19%, `receive` 8% |
| sgr | 1% | 4% | 25% | 52% | 13% | `Style.applySGR` 29%, `EscapeParser.consumeEscape` 23%, `Row.writeASCII` 10% |
| wide | 4% | 6% | 35% | 0% | 52% | `closure #1 in writeNonASCII` 27%, `Screen.writeRun` 21%, `writeNonASCII` 11% |
| cursor | 1% | 6% | 37% | 34% | 17% | `EscapeParser.consumeEscape` 25%, `Row.writeASCII` 11%, `TextScanner.endOfASCII` 10% |
| scroll | 23% | 10% | 27% | 0% | 37% | `TextScanner.endOfASCII` 22%, `Row.writeASCII` 16%, `receive` 15% |
| region | 44% | 5% | 21% | 2% | 25% | `_platform_memmove` 22%, `receive` 13%, `Row.writeASCII` 13% |

- **Scrolling** advances lines, appends history, clears recycled rows and rotates scroll regions. On the scroll region most of it is the memory move that rotating row values compiles to.
- **Allocation and ownership** is malloc, free, retain, release, uniqueness checks and hashing. On the shell recording most of it comes from rows' cluster tables.
- **Cell writes** are the ASCII, scalar and run writers, erases and their blank fills.
- **Parsing and dispatch** covers `EscapeParser`, `ControlParameters`, `Terminal.apply` and SGR.
- **Receive, decode and scan** covers `Terminal.receive`, the ASCII scanner, UTF-8 decoding, width lookup and the non-ASCII writer, with whatever is inlined into them.

## Allocations

Allocation counts for one pass at 4 KiB chunks. The terminal starts each pass with empty screens and history.

| Workload | Thrush 80 × 24 | Thrush 240 × 60 | libghostty-vt 80 × 24 | libghostty-vt 240 × 60 |
| --- | ---: | ---: | ---: | ---: |
| shell | 21,271 | 21,497 | 134 | 140 |
| vim | 6,846 | 7,685 | 1,330 | 1,330 |
| codex | 3,722 | 3,722 | 475 | 477 |
| ascii | 1,035 | 1,071 | 2 | 9 |
| sgr | 3,083 | 3,191 | 6 | 15 |
| wide | 1,035 | 1,071 | 2 | 9 |
| cursor | 24 | 24 | 0 | 0 |
| scroll | 1,035 | 1,071 | 2 | 9 |
| region | 21 | 21 | 0 | 0 |

A row allocates its cells once, on its first write. A line feed, an erase or a region scroll clears a row in place, so once the screen and 1,000 rows of history fill, steady output stops allocating. Dense ASCII, wide text and scrolling settle at 1,035 allocations at 80 × 24, one for each row the screen and history hold plus a few for the terminal itself. Cursor addressing and the scroll region stay on the screen and allocate 24 and 21 times. A row's style list allocates when the row's first non-default style arrives and again when it grows to the row's width, so per-cell SGR adds 2,048 allocations while its 1 MiB fills the first 1,024 rows. Vim and Codex add style lists the same way. The shell recording allocates 21,271 times, close to one for each of the 18,634 lines that carry a combining accent, because clearing a row releases its cluster table. [Where Thrush loses time](#where-thrush-loses-time)

## Where Thrush loses time

At 80 × 24 in 4 KiB chunks Thrush trails libghostty-vt on seven of the nine workloads. The profile and the code trace each gap to one or two costs. The [performance plan](../docs/plan.md#closing-the-libghostty-vt-gap) turns each cost into a change.

| Workload | Thrush ÷ libghostty-vt | Where Thrush loses time |
| --- | ---: | --- |
| shell | 0.59× | Cluster tables and switching runs |
| codex | 0.87× | Reading control parameters twice |
| ascii | 0.85× | Clearing recycled rows and finding line endings |
| wide | 0.58× | Decoding one scalar per call and switching runs |
| cursor | 0.95× | Reading control parameters twice, finding line endings and clearing rows |
| scroll | 0.76× | Finding line endings and clearing recycled rows |
| region | 0.59× | Rotating row values |

- **Clearing recycled rows.** A line feed recycles the row leaving the screen or history and clears it with `Array.removeAll(keepingCapacity:)`, which runs the general `replaceSubrange` path. That takes 7% of samples on scrolling, and the next write appends every cell again.
- **Finding line endings.** `TextScanner.endOfASCII` checks 16 bytes at a time, but in the block that holds the line ending it walks one byte at a time. Short lines end inside their first block, so the scan takes 22% of samples on scrolling and 19% on dense ASCII.
- **Cluster tables.** The shell recording puts a combining accent on 18,634 lines. Clearing a row releases its `[Int: String]` cluster table, so the next accent on that row allocates a new table and grows it again, and adding a mark looks its base up twice. Hashing, allocation and freeing take about 19% of shell samples.
- **Switching runs.** The wide workload alternates runs of about five CJK or emoji scalars with ASCII runs of about four bytes, mostly single spaces, and the shell recording's accented paths mix them too. Each switch ends a run and starts the next, so the style and the row's write position are found again.
- **Decoding one scalar per call.** On wide text the per-scalar closure in `Terminal.writeNonASCII` takes 27% of samples and `Screen.writeRun` 21%. For each scalar the closure decodes it and looks up its width, then hands it to the run through a call that isn't inlined, and the run appends its cell behind its own uniqueness check. libghostty-vt decodes a whole printable run to UTF-32 and then fills the row.
- **Rotating row values.** Scrolling a region rotates the 56-byte `Row` values between its margins, and the memory move and `Array.rotate` take 35% of samples on the scroll region. libghostty-vt moves 8-byte row offsets instead.
- **Reading control parameters twice.** Parsing and dispatch take 55% of samples on Codex and 34% on cursor addressing, with `EscapeParser.consumeEscape` alone at 33% on Codex. The parser scans a complete header once to find its final byte. SGR borrows those bytes, but every other final, such as cursor position or erase, sends them through `ControlParameters.append` again one byte at a time, switching on its destination for each digit.
