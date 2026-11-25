# Comparison with other emulator cores

ThrushCore has to outrun the fastest emulator cores we can measure, doing the same work on the same machine. This benchmark feeds identical bytes to ThrushCore, libghostty-vt and @xterm/headless, checks that they finish with the same screen, and reports throughput and allocations. A separate profile shows where ThrushCore spends its time. [Recorded report](comparison.json) · [Recorded profile](comparison-profile.json)

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3 scripts/comparison/run.py --output Benchmarks/comparison.json
```

The runner needs Node and Bun. It installs the [pinned reference](../Fixtures/reference/README.md), which supplies @xterm/headless. The first run downloads Zig and the libghostty-vt source release, checks both against pinned SHA-256 digests and builds the library into `.build/comparison/tools`. After that, a full run takes about 2 minutes on the reference machine. Pass `--workloads ascii,vim --rounds 1` for a quick check. The profile comes from the [Comparison profile workflow](../.github/workflows/comparison-profile.yml). [Profile](#profile)

## Where Thrush stands

- **Thrush led libghostty-vt in 18 of 36 conditions.** It led in every condition on Vim by 1.21–1.67×, dense ASCII by 1.00–1.20× and SGR by 1.40–1.58×. At 240 × 60 it also led on the shell recording by 1.02–1.07×, cursor addressing by 1.46–1.55× and scrolling by 1.26–1.28×. [Screens](#screens)
- **The widest gaps are at 80 × 24.** Thrush ran at 0.61–0.62× of libghostty-vt on the shell recording, 0.66× on wide text and 0.67–0.69× on the scroll region. [Where Thrush loses time](#where-thrush-loses-time)
- **Thrush ran faster than both @xterm/headless runtimes in every condition**, by 2.64–14.88×.
- **Screen checks.** Thrush matched the Node reference in 36 of 36 conditions. The Bun runtime matched it in 36 of 36, and libghostty-vt matched it in 32 of 36. [Screens](#screens)
- **Allocations.** At 4 KiB, Thrush recorded 21 to 21,508 allocations per workload and libghostty-vt recorded 0 to 1,330. [Allocations](#allocations)

Since the [previous report](#change-since-the-previous-report), Thrush's ratio to libghostty-vt rose in 31 of 36 conditions. At 80 × 24 in 4 KiB chunks, scrolling went from 0.76× to 0.90× and dense ASCII went from 0.85× to 1.00×.

## Identical work

Every core receives the same bytes at the same grid size with a 1,000-row history limit. Each workload runs at 80 × 24 and 240 × 60, and arrives either in 4 KiB chunks or as one buffer. No core has an app attached, so replies to queries go nowhere. Each measured pass creates a fresh terminal outside the timed region, then feeds the whole workload.

- **libghostty-vt builds the full screen.** `ghostty_terminal_vt_write` drives cells, styles, cursor, modes, both screens and history. Its final visible rows, cursor and active screen matched the Node reference in 32 of 36 conditions. The comparison checks visible text, cursor position and the active buffer. It also checks history depth for Thrush and both JavaScript runtimes. The conformance suite checks cell attributes. At 80 × 24 in 4 KiB chunks its throughput was 1,012 MiB/s on plain text and 147 MiB/s on per-cell SGR.
- **History depth doesn't change its work.** libghostty-vt drops history a whole page at a time, so with the same 1,000-row limit it kept 578 to 964 rows where the others kept 1,000. Every line still scrolls into history, and a dropped page is reused for new rows, so its whole scroll pass allocated 2 times. A separate check on the scroll workload at 80 × 24 raised its limit to 2,000 rows. It kept 1,864 rows, more than Thrush, and ran at 391 to 401 MiB/s against 389 to 400 with the 1,000-row limit. Only an unlimited history, which keeps all 64,616 lines in new pages, slowed it, to 174 to 182 MiB/s.
- **libghostty-vt did less scrolling in four conditions.** Its large-grid shell and Vim runs retained the alternate screen’s scroll region. Thrush reached 1.02–1.67× of its throughput in these conditions. [Screens](#screens)

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

Recorded November 25, 2026 at 23:40 UTC on an Apple M1 Max with 10 cores, macOS 27.2.1 and Apple Swift version 6.4.2. The one-minute load average was 33 at the start and 39 at the end. Within each round the cores ran back to back. The ranges show how their relative rates varied. [Measured source 0929ef1](https://github.com/lostintangent/thrush/commit/0929ef1bd2183365745a10ef6dbfede7a3fd8303)

| Workload | Grid | Chunks | Thrush MiB/s | libghostty-vt MiB/s | xterm MiB/s | Thrush ÷ libghostty-vt | Thrush ÷ xterm |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| shell | 80 × 24 | 4 KiB | 179 | 289 | 50 (Node) | 0.62× (0.60–1.08) | 3.41× (3.37–4.23) |
| shell | 80 × 24 | Whole | 181 | 295 | 48 (Node) | 0.61× (0.61–0.65) | 3.75× (3.27–4.21) |
| shell | 240 × 60 | 4 KiB | 176 | 171 | 51 (Node) | 1.02× (1.01–1.08) | 3.55× (3.40–4.49) |
| shell | 240 × 60 | Whole | 178 | 167 | 48 (Node) | 1.07× (1.03–1.10) | 3.66× (3.51–4.09) |
| vim | 80 × 24 | 4 KiB | 415 | 343 | 53 (Node) | 1.21× (1.20–1.24) | 7.88× (7.80–8.49) |
| vim | 80 × 24 | Whole | 423 | 341 | 53 (Node) | 1.24× (1.22–1.27) | 7.94× (7.88–8.30) |
| vim | 240 × 60 | 4 KiB | 386 | 235 | 31 (Bun) | 1.65× (1.62–1.74) | 12.26× (11.73–15.76) |
| vim | 240 × 60 | Whole | 392 | 235 | 32 (Bun) | 1.67× (1.66–1.72) | 12.44× (11.59–15.12) |
| codex | 80 × 24 | 4 KiB | 228 | 262 | 61 (Bun) | 0.86× (0.80–0.87) | 3.67× (3.43–4.06) |
| codex | 80 × 24 | Whole | 230 | 262 | 65 (Bun) | 0.87× (0.87–0.89) | 3.52× (3.44–3.64) |
| codex | 240 × 60 | 4 KiB | 223 | 226 | 43 (Bun) | 0.98× (0.90–1.04) | 5.05× (3.69–5.80) |
| codex | 240 × 60 | Whole | 223 | 227 | 43 (Bun) | 0.98× (0.87–1.02) | 5.21× (4.35–7.03) |
| ascii | 80 × 24 | 4 KiB | 1043 | 1025 | 78 (Node) | 1.00× (0.86–1.02) | 12.48× (11.33–12.90) |
| ascii | 80 × 24 | Whole | 1059 | 1007 | 83 (Node) | 1.06× (1.04–1.17) | 12.83× (12.45–15.98) |
| ascii | 240 × 60 | 4 KiB | 1239 | 1088 | 114 (Bun) | 1.15× (0.61–1.23) | 10.58× (8.28–12.18) |
| ascii | 240 × 60 | Whole | 1264 | 1049 | 113 (Bun) | 1.20× (1.13–1.42) | 11.02× (10.69–12.96) |
| sgr | 80 × 24 | 4 KiB | 210 | 150 | 67 (Node) | 1.41× (1.36–1.45) | 3.11× (3.10–3.42) |
| sgr | 80 × 24 | Whole | 211 | 150 | 66 (Node) | 1.40× (1.38–1.54) | 3.12× (2.93–4.42) |
| sgr | 240 × 60 | 4 KiB | 207 | 133 | 66 (Node) | 1.58× (1.50–1.64) | 3.13× (2.99–3.46) |
| sgr | 240 × 60 | Whole | 209 | 135 | 67 (Node) | 1.55× (1.31–1.57) | 3.03× (2.95–3.16) |
| wide | 80 × 24 | 4 KiB | 225 | 337 | 78 (Node) | 0.66× (0.65–0.78) | 2.89× (2.73–2.97) |
| wide | 80 × 24 | Whole | 223 | 337 | 79 (Node) | 0.66× (0.65–0.71) | 2.88× (2.80–3.10) |
| wide | 240 × 60 | 4 KiB | 226 | 332 | 86 (Bun) | 0.68× (0.62–0.70) | 2.64× (2.22–2.97) |
| wide | 240 × 60 | Whole | 230 | 330 | 86 (Bun) | 0.69× (0.68–0.75) | 2.65× (2.57–2.69) |
| cursor | 80 × 24 | 4 KiB | 164 | 169 | 43 (Bun) | 0.97× (0.96–0.97) | 3.65× (3.51–5.89) |
| cursor | 80 × 24 | Whole | 164 | 167 | 45 (Bun) | 0.97× (0.97–1.53) | 3.69× (3.60–5.85) |
| cursor | 240 × 60 | 4 KiB | 151 | 102 | 10 (Bun) | 1.46× (1.31–1.51) | 14.37× (12.90–20.44) |
| cursor | 240 × 60 | Whole | 151 | 98 | 10 (Bun) | 1.55× (1.45–1.62) | 14.88× (14.36–16.86) |
| scroll | 80 × 24 | 4 KiB | 366 | 404 | 60 (Node) | 0.90× (0.25–0.91) | 6.02× (1.72–6.11) |
| scroll | 80 × 24 | Whole | 370 | 399 | 57 (Bun) | 0.91× (0.89–0.94) | 5.96× (5.68–8.27) |
| scroll | 240 × 60 | 4 KiB | 362 | 288 | 49 (Node) | 1.28× (1.22–1.30) | 7.45× (7.15–8.06) |
| scroll | 240 × 60 | Whole | 366 | 292 | 49 (Node) | 1.26× (1.21–1.27) | 7.39× (7.04–13.84) |
| region | 80 × 24 | 4 KiB | 309 | 460 | 32 (Node) | 0.67× (0.25–0.68) | 9.07× (4.00–10.56) |
| region | 80 × 24 | Whole | 308 | 449 | 37 (Bun) | 0.69× (0.64–1.41) | 7.72× (7.41–17.14) |
| region | 240 × 60 | 4 KiB | 305 | 340 | 24 (Bun) | 0.90× (0.85–0.98) | 12.68× (9.47–12.75) |
| region | 240 × 60 | Whole | 310 | 343 | 27 (Bun) | 0.90× (0.85–0.95) | 11.32× (9.62–12.37) |

## Change since the previous report

Both reports used the same host, toolchain, workload digests and benchmark settings. The rows compare 15-pass medians at 80 × 24 in 4 KiB chunks. Across all 36 conditions Thrush ran 0.99–1.23× as fast as in the previous report, while libghostty-vt's own rates moved by 0.95–1.07×. In between, clearing a row began resetting its length, so a recycled row is overwritten in place, and a non-ASCII run began storing its cells through one span. [Storage](../docs/emulator.md#storage) · [Previous report at c528777](https://github.com/lostintangent/thrush/blob/0abf2fa1977a7658b564ff526ff0d9045a467e13/Benchmarks/comparison.json)

| Workload | c528777 MiB/s | 0929ef1 MiB/s | Change | c528777 ÷ libghostty-vt | 0929ef1 ÷ libghostty-vt |
| --- | ---: | ---: | ---: | ---: | ---: |
| shell | 175.7 | 179.4 | 1.02× | 0.59× | 0.62× |
| vim | 393.1 | 414.8 | 1.06× | 1.14× | 1.21× |
| codex | 231.1 | 228.2 | 0.99× | 0.87× | 0.86× |
| ascii | 857.3 | 1042.9 | 1.22× | 0.85× | 1.00× |
| sgr | 206.4 | 209.8 | 1.02× | 1.41× | 1.41× |
| wide | 196.6 | 224.6 | 1.14× | 0.58× | 0.66× |
| cursor | 160.8 | 164.0 | 1.02× | 0.95× | 0.97× |
| scroll | 302.7 | 365.7 | 1.21× | 0.76× | 0.90× |
| region | 269.3 | 308.6 | 1.15× | 0.59× | 0.67× |

## Screens

Thrush matched the Node reference in 36 of 36 conditions. The Bun runtime matched it in 36 of 36, and libghostty-vt matched it in 32 of 36. The four libghostty-vt differences were on shell and Vim at 240 × 60. Both recordings were captured at 80 × 24, and Vim sets the scroll region to rows 1 to 24 (`ESC[1;24r`) on the alternate screen. When Vim leaves the alternate screen (`ESC[?1049l`), xterm and Thrush return to the main screen's own region, so the main screen still scrolls across all 60 rows. libghostty-vt keeps one region for both screens, so a line feed on the bottom row, below that region, doesn't scroll.

The smallest stream that shows it runs at 80 × 10:

```
ESC[?1049h ESC[1;5r ESC[?1049l ESC[10;1H a LF b
```

xterm and Thrush finish with `a` on row 9 and ` b` on row 10. libghostty-vt finishes with `ab` on row 10. At 80 × 24 the region already covers the whole screen, so all three cores agree. The affected runs do slightly less scrolling in libghostty-vt than in the other cores.

## Where Thrush spends its time

Shares of all samples in the [recorded profile](comparison-profile.json), taken at `0929ef1` with 2,037 to 2,239 samples per workload. Each of the 20 functions with the most self time in a workload belongs to at most one category. Unclassified functions and the rest of the samples account for the remainder.

| Workload | Scrolling | Allocation and ownership | Cell writes | Parsing and dispatch | Receive, decode and scan | Top functions |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| shell | 4% | 20% | 25% | 5% | 19% | `receive` 8%, `Row.writeASCII` 7%, `TextScanner.endOfASCII` 6% |
| vim | 0% | 12% | 19% | 29% | 19% | `EscapeParser.consumeEscape` 17%, `receive` 11%, `TextScanner.endOfASCII` 8% |
| codex | 0% | 3% | 6% | 58% | 15% | `EscapeParser.consumeEscape` 34%, `apply` 11%, `receive` 11% |
| ascii | 18% | 9% | 33% | 0% | 32% | `TextScanner.endOfASCII` 25%, `Row.writeASCII` 23%, `History.append` 10% |
| sgr | 0% | 6% | 19% | 54% | 13% | `Style.applySGR` 29%, `EscapeParser.consumeEscape` 25%, `receive` 9% |
| wide | 2% | 4% | 28% | 0% | 63% | `closure #1 in writeNonASCII` 35%, `Screen.writeRun` 16%, `writeNonASCII` 12% |
| cursor | 0% | 4% | 40% | 38% | 17% | `EscapeParser.consumeEscape` 28%, `Row.set` 13%, `TextScanner.endOfASCII` 11% |
| scroll | 15% | 8% | 28% | 0% | 46% | `TextScanner.endOfASCII` 28%, `receive` 18%, `Row.writeASCII` 14% |
| region | 45% | 4% | 18% | 2% | 27% | `_platform_memmove` 27%, `TextScanner.endOfASCII` 14%, `receive` 13% |

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

At 80 × 24 in 4 KiB chunks Thrush trails libghostty-vt on six of the nine workloads. The profile and the code trace each gap to one or two costs. The [performance plan](../docs/plan.md#closing-the-libghostty-vt-gap) turns each cost into a change.

| Workload | Thrush ÷ libghostty-vt | Where Thrush loses time |
| --- | ---: | --- |
| shell | 0.62× | Cluster tables and switching runs |
| codex | 0.86× | Reading control parameters twice |
| wide | 0.66× | Decoding one scalar per call and switching runs |
| cursor | 0.97× | Reading control parameters twice and finding line endings |
| scroll | 0.90× | Finding line endings |
| region | 0.67× | Rotating row values |

- **Finding line endings.** `TextScanner.endOfASCII` checks 16 bytes at a time, but in the block that holds the line ending it walks one byte at a time. Short lines end inside their first block, so the scan takes 28% of samples on scrolling and 11% on cursor addressing.
- **Cluster tables.** The shell recording puts a combining accent on 18,634 lines. Clearing a row releases its `[Int: String]` cluster table, so the next accent on that row allocates a new table and grows it again, and adding a mark looks its base up twice. Hashing, allocation and freeing take about 20% of shell samples.
- **Switching runs.** The wide workload alternates runs of about five CJK or emoji scalars with ASCII runs of about four bytes, mostly single spaces, and the shell recording's accented paths mix them too. Each switch ends a run and starts the next, so the style and the row's write position are found again.
- **Decoding one scalar per call.** On wide text the per-scalar closure in `Terminal.writeNonASCII` takes 35% of samples and `Screen.writeRun` 16%. For each scalar the closure decodes it and looks up its width, then hands it to the run through a call that isn't inlined. libghostty-vt decodes a whole printable run to UTF-32 and then fills the row.
- **Rotating row values.** Scrolling a region rotates the 64-byte `Row` values between its margins, and the memory move and `Array.rotate` take 39% of samples on the scroll region. libghostty-vt moves 8-byte row offsets instead.
- **Reading control parameters twice.** Parsing and dispatch take 58% of samples on Codex and 38% on cursor addressing, with `EscapeParser.consumeEscape` alone at 34% on Codex. The parser scans a complete header once to find its final byte. SGR borrows those bytes, but every other final, such as cursor position or erase, sends them through `ControlParameters.append` again one byte at a time, switching on its destination for each digit.
