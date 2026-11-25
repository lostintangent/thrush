# Comparison with other emulator cores

ThrushCore has to outrun the fastest emulator cores we can measure, doing the same work on the same machine. This benchmark feeds identical bytes to ThrushCore, libghostty-vt and @xterm/headless, checks that they finish with the same screen, and reports throughput, allocations and where ThrushCore spends its time. [Recorded report](comparison.json)

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3 scripts/comparison/run.py --toy-box ../toy-box --profile --output Benchmarks/comparison.json
```

The runner needs Node, Bun and a Toy Box checkout with its dependencies installed, which supplies the pinned @xterm/headless. The first run downloads Zig and the libghostty-vt source release, checks both against pinned SHA-256 digests and builds the library into `.build/comparison/tools`. A full run took about 7 minutes on the reference machine. Pass `--workloads ascii,vim --rounds 1` for a quick check.

## Where Thrush stands

- **Thrush’s median throughput exceeded libghostty-vt’s in 2 of 36 conditions.** These were SGR at 240 × 60 with 4 KiB chunks (1.020×, round range 0.966–1.123×) and SGR at 240 × 60 with one buffer (1.015×, round range 0.872–1.053×). Each of those ranges included a round in which libghostty-vt was faster. Across the full matrix Thrush reached 0.12–1.02× of libghostty-vt’s throughput.
- **Thrush outran the faster @xterm/headless runtime in 32 of 36 conditions**, by 1.54–7.40×. xterm led on wide CJK and emoji at both grids and both chunk sizes. Thrush reached 0.91–0.93× of xterm’s throughput in those four conditions.
- **Thrush matched the reference in all 36 screen checks.** Four libghostty-vt runs differed from the Node reference. The difference occurred on the shell and Vim recordings at 240 × 60 with either chunk size. [Screens](#screens)
- **Thrush allocates for almost every row it writes**, 1,204 to 64,650 times per workload at 4 KiB chunks, while libghostty-vt allocates 0 to 1,330 times.

The raw-byte parser changed the control-heavy workloads most. At 80 × 24 in 4 KiB chunks, Codex rose from 106 to 161 MiB/s and per-cell SGR rose from 82 to 136 MiB/s. The two clean reports recorded matching allocation counts across all 36 conditions.

## Identical work

Every core receives the same bytes at the same grid size with a 1,000-row history limit. Each workload runs at 80 × 24 and 240 × 60, and arrives either in 4 KiB chunks or as one buffer. No core has a host attached, so replies to queries go nowhere. Each measured pass creates a fresh terminal outside the timed region, then feeds the whole workload.

- **libghostty-vt builds the full screen, not just a parse.** `ghostty_terminal_vt_write` drives its complete terminal: cells, styles, cursor, modes, both screens and history. Its final rows, cursor and active screen matched xterm's in 32 of 36 conditions after a full-buffer replay. The screen check compares visible text, cursor position and the active buffer. Color values are outside this check. Its rate falls from 986 MiB/s on plain text to 152 MiB/s when every cell changes style, which fits resolving and storing each style.
- **History depth doesn't change its work.** libghostty-vt drops history a whole page at a time, so with the same 1,000-row limit it kept 578 to 964 rows where the others kept 1,000. Every line still scrolls into history, and a dropped page is reused for new rows, so its whole scroll pass allocated 2 times. A separate check on the scroll workload at 80 × 24 raised its limit to 2,000 rows. It kept 1,864 rows, more than Thrush, and ran at 391 to 401 MiB/s against 389 to 400 with the 1,000-row limit. Only an unlimited history, which keeps all 64,616 lines in new pages, slowed it, to 174 to 182 MiB/s.
- **libghostty-vt did less scrolling in four conditions.** Its main screen retained Vim’s alternate-screen scroll region in the two 240 × 60 recordings. The table includes these observations, with Thrush between 0.59× and 0.85× of libghostty-vt’s throughput. [Screens](#screens)

## Method

### Cores

- **ThrushCore** at the recorded revision, built with `swift build -c release`. `ThrushBench --workload` feeds it a `Span` of each chunk.
- **libghostty-vt 1.0.2**, built from its source release with Zig 0.17.1 and `-Doptimize=ReleaseFast`, then linked statically into `scripts/comparison/ghostty.c`. The runner feeds bytes with `ghostty_terminal_vt_write` and reads the final screen through `ghostty_terminal_grid_ref`. It lifts the default scrollback byte cap so history is limited by rows alone, like the other cores.
- **@xterm/headless 6.0.0** with @xterm/addon-unicode11 0.9.0 and Unicode 11 widths active, the versions Toy Box pins. `scripts/comparison/xterm.mjs` runs it under Node 22.18.0 and Bun 1.4.6, and each condition counts the faster runtime. It feeds bytes through `writeSync` on the terminal's core. The public `write` queues the same bytes and parses them in 12 ms slices between timers, so the synchronous call measures parsing and screen updates in the calling process.

### Timing

Each of 5 rounds runs every core once per workload and condition, in a freshly shuffled order, so load on a shared machine falls on all of them alike. Each run is a new process with 3 warmup passes and 3 measured passes. Rates come from the median wall time of the 15 measured passes. The ratio columns divide Thrush's throughput by the other core's, so a ratio below 1 means Thrush was slower. Each ratio pairs the cores within a round, which shared that round's load, and reports the median of those paired ratios with their range in parentheses. The JSON also records each round's median wall time and the median CPU time.

### Screen checks

At the end of each run every core reports its visible rows, cursor, active screen and history depth. The runner compares them with xterm under Node, after trimming trailing spaces and clamping a cursor that is waiting to wrap to the last column. libghostty-vt's history depth is recorded but not compared, as [Identical work](#identical-work) explains.

### Allocations

A separate pass for ThrushCore and libghostty-vt runs with `scripts/comparison/allocations.c` inserted. It interposes the malloc family, including the typed and zone variants, and anonymous `mmap`, and counts only the outermost call on each thread. Each count covers one measured pass after one warmup, for every condition. [Allocations](#allocations) shows 4 KiB chunks, and the JSON holds the rest. The JavaScript garbage collector manages xterm's memory, so it isn't counted.

### Profile

With `--profile` the runner samples ThrushCore with `sample` for 3 seconds on each workload at 80 × 24 in 4 KiB chunks, and ranks functions by self time. Inlined code counts toward the function it was inlined into, which is why `Terminal.receive` carries much of the per-scalar work.

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

Recorded November 25, 2026 at 16:23 UTC at revision `490316eac49a` on an Apple M1 Max with 10 cores, macOS 27.2.1 and Apple Swift version 6.4.2. The machine was shared, with a one-minute load average of 195 at the start and 326 at the end. Within each round the cores ran back to back. The ranges show how much their relative rates varied. [Measured source](https://github.com/lostintangent/thrush/commit/490316eac49a7e19cd905f357e4294de9f2d9a3b)

| Workload | Grid | Chunks | Thrush MiB/s | libghostty-vt MiB/s | xterm MiB/s | Thrush ÷ libghostty-vt | Thrush ÷ xterm |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| shell | 80 × 24 | 4 KiB | 106 | 290 | 52 (Node) | 0.37× (0.35–0.38) | 2.03× (1.92–2.77) |
| shell | 80 × 24 | Whole | 105 | 290 | 54 (Node) | 0.35× (0.35–0.39) | 1.95× (1.85–2.09) |
| shell | 240 × 60 | 4 KiB | 101 | 170 | 47 (Node) | 0.60× (0.58–0.61) | 2.17× (2.07–2.55) |
| shell | 240 × 60 | Whole | 102 | 171 | 47 (Node) | 0.59× (0.57–0.61) | 2.16× (2.11–3.05) |
| vim | 80 × 24 | 4 KiB | 214 | 339 | 51 (Bun) | 0.63× (0.61–0.68) | 4.15× (3.54–6.50) |
| vim | 80 × 24 | Whole | 216 | 343 | 51 (Node) | 0.63× (0.61–0.64) | 4.20× (4.03–4.66) |
| vim | 240 × 60 | 4 KiB | 189 | 234 | 28 (Bun) | 0.83× (0.80–0.94) | 6.47× (5.62–14.55) |
| vim | 240 × 60 | Whole | 195 | 233 | 27 (Bun) | 0.85× (0.83–1.03) | 7.29× (6.09–9.41) |
| codex | 80 × 24 | 4 KiB | 161 | 262 | 56 (Node) | 0.61× (0.49–0.78) | 2.90× (2.66–3.45) |
| codex | 80 × 24 | Whole | 163 | 257 | 58 (Node) | 0.64× (0.64–0.78) | 3.00× (2.75–3.87) |
| codex | 240 × 60 | 4 KiB | 150 | 226 | 47 (Bun) | 0.66× (0.60–0.75) | 3.39× (2.49–4.65) |
| codex | 240 × 60 | Whole | 152 | 225 | 41 (Bun) | 0.69× (0.67–0.72) | 3.65× (3.59–4.85) |
| ascii | 80 × 24 | 4 KiB | 239 | 986 | 78 (Node) | 0.23× (0.22–0.28) | 2.95× (2.87–3.25) |
| ascii | 80 × 24 | Whole | 239 | 1012 | 82 (Node) | 0.23× (0.18–0.25) | 2.83× (2.26–3.32) |
| ascii | 240 × 60 | 4 KiB | 299 | 1045 | 118 (Bun) | 0.28× (0.27–0.37) | 2.63× (2.47–2.84) |
| ascii | 240 × 60 | Whole | 301 | 1059 | 116 (Bun) | 0.29× (0.28–0.30) | 2.47× (2.34–11.37) |
| sgr | 80 × 24 | 4 KiB | 136 | 152 | 69 (Node) | 0.92× (0.87–0.95) | 2.04× (1.88–2.04) |
| sgr | 80 × 24 | Whole | 138 | 147 | 67 (Node) | 0.94× (0.90–0.98) | 2.03× (1.92–2.22) |
| sgr | 240 × 60 | 4 KiB | 136 | 134 | 65 (Node) | 1.02× (0.97–1.12) | 2.10× (1.91–2.43) |
| sgr | 240 × 60 | Whole | 137 | 134 | 67 (Node) | 1.01× (0.87–1.05) | 2.02× (1.66–2.21) |
| wide | 80 × 24 | 4 KiB | 72 | 332 | 78 (Node) | 0.22× (0.21–0.26) | 0.93× (0.89–0.99) |
| wide | 80 × 24 | Whole | 71 | 331 | 77 (Node) | 0.21× (0.20–0.24) | 0.93× (0.90–1.01) |
| wide | 240 × 60 | 4 KiB | 74 | 322 | 83 (Bun) | 0.23× (0.22–0.25) | 0.91× (0.85–0.99) |
| wide | 240 × 60 | Whole | 75 | 340 | 83 (Bun) | 0.22× (0.21–0.23) | 0.91× (0.87–0.92) |
| cursor | 80 × 24 | 4 KiB | 89 | 169 | 43 (Bun) | 0.54× (0.50–0.57) | 2.14× (1.92–5.42) |
| cursor | 80 × 24 | Whole | 90 | 166 | 45 (Bun) | 0.55× (0.52–0.61) | 2.06× (1.98–2.13) |
| cursor | 240 × 60 | 4 KiB | 70 | 102 | 10 (Bun) | 0.70× (0.67–0.72) | 7.40× (6.86–7.59) |
| cursor | 240 × 60 | Whole | 71 | 102 | 10 (Bun) | 0.71× (0.69–0.77) | 6.94× (6.12–7.64) |
| scroll | 80 × 24 | 4 KiB | 89 | 399 | 56 (Bun) | 0.23× (0.13–0.24) | 1.56× (0.96–1.77) |
| scroll | 80 × 24 | Whole | 91 | 395 | 58 (Node) | 0.23× (0.23–0.25) | 1.58× (1.56–1.91) |
| scroll | 240 × 60 | 4 KiB | 85 | 282 | 47 (Bun) | 0.30× (0.27–0.32) | 1.81× (1.72–1.91) |
| scroll | 240 × 60 | Whole | 88 | 275 | 49 (Node) | 0.31× (0.28–0.38) | 1.82× (1.69–1.90) |
| region | 80 × 24 | 4 KiB | 58 | 456 | 35 (Bun) | 0.13× (0.13–0.13) | 1.54× (1.31–1.91) |
| region | 80 × 24 | Whole | 57 | 457 | 31 (Bun) | 0.12× (0.11–0.13) | 1.76× (1.63–2.64) |
| region | 240 × 60 | 4 KiB | 56 | 337 | 26 (Node) | 0.16× (0.16–0.18) | 2.12× (1.92–2.25) |
| region | 240 × 60 | Whole | 57 | 338 | 29 (Node) | 0.17× (0.16–0.20) | 1.99× (1.86–2.28) |

## Change from the row-only build

The two clean reports used the same bytes, workload order, host, toolchain and core versions. The rates below compare their independent 15-pass medians at 80 × 24 in 4 KiB chunks. The allocation delta counts Thrush allocations in one separate pass. [Row-only report at fba5402](https://github.com/lostintangent/thrush/blob/175383340dcae31674b043def1835304fe6b825f/Benchmarks/comparison.json)

| Workload | Row-only MiB/s | Raw parser MiB/s | Raw parser ÷ row-only | Thrush allocation delta |
| --- | ---: | ---: | ---: | ---: |
| shell | 96.4 | 105.8 | 1.098× | 0 |
| vim | 143.9 | 213.8 | 1.486× | 0 |
| codex | 106.2 | 161.2 | 1.519× | 0 |
| ascii | 237.0 | 239.2 | 1.010× | 0 |
| sgr | 81.9 | 136.3 | 1.664× | 0 |
| wide | 67.3 | 72.4 | 1.076× | 0 |
| cursor | 72.5 | 89.2 | 1.232× | 0 |
| scroll | 90.2 | 89.3 | 0.990× | 0 |
| region | 56.9 | 57.8 | 1.016× | 0 |

Thrush retained the same allocation counts in all 36 conditions.

## Screens

Thrush matched xterm in all 36 conditions, on rows, cursor, active screen and history. libghostty-vt differed on the shell and Vim workloads at 240 × 60, with either chunking. Both recordings were captured at 80 × 24, and Vim sets the scroll region to rows 1 to 24 (`ESC[1;24r`) on the alternate screen. When Vim leaves the alternate screen (`ESC[?1049l`), xterm and Thrush return to the main screen's own region, so the main screen still scrolls across all 60 rows. libghostty-vt keeps one region for both screens, so a line feed on the bottom row, below that region, doesn't scroll.

The smallest stream that shows it runs at 80 × 10:

```
ESC[?1049h ESC[1;5r ESC[?1049l ESC[10;1H a LF b
```

xterm and Thrush finish with `a` on row 9 and ` b` on row 10. libghostty-vt finishes with `ab` on row 10. At 80 × 24 the region already covers the whole screen, so all three cores agree. The affected runs do slightly less scrolling in libghostty-vt than in the other cores.

## Where Thrush spends its time

Shares of all samples, grouped from the 20 functions with the most self time on each workload. The JSON lists those functions by name.

| Workload | Row growth and fill | Allocation and reference counting | Cell writes | Scrolling | Parsing and dispatch | Receive, decode and scan | Top functions |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| shell | 1% | 18% | 20% | 0% | 8% | 15% | `Row.writeASCII` 13%, `receive` 12%, `Screen.writeASCII` 5% |
| vim | 1% | 12% | 33% | 0% | 23% | 10% | `Row.writeASCII` 29%, `EscapeParser.consumeEscape` 14%, `receive` 6% |
| codex | 2% | 2% | 9% | 0% | 57% | 13% | `EscapeParser.consumeEscape` 34%, `apply` 10%, `receive` 9% |
| ascii | 0% | 26% | 44% | 4% | 1% | 8% | `Row.writeASCII` 41%, `TextScanner.endOfASCII` 6%, `swift_release` 4% |
| sgr | 1% | 6% | 12% | 0% | 65% | 8% | `EscapeParser.consumeEscape` 37%, `Style.applySGR` 14%, `receive` 6% |
| wide | 12% | 13% | 20% | 0% | 1% | 47% | `receive` 44%, `Screen.write` 13%, `UnsafeMutableBufferPointer.initialize` 6% |
| cursor | 25% | 16% | 13% | 0% | 18% | 9% | `UnsafeMutableBufferPointer.initialize` 21%, `EscapeParser.consumeEscape` 14%, `Row.writeASCII` 7% |
| scroll | 0% | 38% | 20% | 5% | 4% | 11% | `Row.writeASCII` 17%, `TextScanner.endOfASCII` 8%, `swift_release` 8% |
| region | 0% | 56% | 13% | 16% | 2% | 5% | `swift_release` 18%, `Buffer.advanceLine` 16%, `swift_retain` 12% |

- **Row growth and fill** is `Row.ensureLength` extending a row's cells with blanks through `Array.append(contentsOf:)`, which compiles to `UnsafeMutableBufferPointer.initialize(from:)` and `_consumeAndCreateNew`.
- **Allocation and reference counting** is malloc, free, retain, release and uniqueness checks, nearly all from creating, copying and dropping rows.
- **Cell writes** are `Row.writeASCII`, `Row.write` and `Screen.write`, which store glyphs and styles.
- **Parsing and dispatch** covers `EscapeParser`, `ControlParameters`, `Terminal.apply` and SGR handling.
- **Receive, decode and scan** covers `Terminal.receive`, the UTF-8 decoder, the ASCII scanner and `ColumnWidth`, plus whatever is inlined into them. Non-ASCII text is printed from `Terminal.consume`, so on wide text part of the parsing share is printing.

## Allocations

Allocations in one pass at 4 KiB chunks.

| Workload | Thrush 80 × 24 | Thrush 240 × 60 | libghostty-vt 80 × 24 | libghostty-vt 240 × 60 |
| --- | ---: | ---: | ---: | ---: |
| shell | 38,749 | 38,683 | 134 | 140 |
| vim | 14,046 | 14,465 | 1,330 | 1,330 |
| codex | 2,678 | 2,678 | 475 | 477 |
| ascii | 18,030 | 9,790 | 2 | 9 |
| sgr | 1,204 | 1,204 | 6 | 15 |
| wide | 14,321 | 10,256 | 2 | 9 |
| cursor | 36,830 | 36,830 | 0 | 0 |
| scroll | 64,650 | 64,650 | 2 | 9 |
| region | 49,217 | 49,217 | 0 | 0 |

A row allocates once, on its first write, so Thrush's counts follow the rows it writes. Dense ASCII writes 18,019 rows at 80 × 24 and allocates 18,030 times. Scrolling writes 64,639 lines and allocates 64,650 times, and the scroll region writes 49,216 lines and allocates 49,217 times. The SGR workload writes 1,193 lines and allocates 1,204 times. Cursor addressing allocates 36,830 times because each full-screen erase replaces every row with a new blank one.

## Plan for 0.3.0

Six changes, ordered by expected gain. Each one lands on its own with the comparison, ThrushBench and the conformance harness run before and after. Steps 3, 4 and 6 don't depend on the storage steps, so they can proceed in parallel with them.

Targets in the table are cumulative ratios to libghostty-vt at 80 × 24 in 4 KiB chunks. The accepted model used the row-only profile at `fba5402` and estimated the fraction of time each change would remove. The parenthesized ratios and the storage and wide-text sample shares below also come from that build. Step 3 now has a measured raw-parser checkpoint. One-pass SGR remains open. [Row-only report at fba5402](https://github.com/lostintangent/thrush/blob/175383340dcae31674b043def1835304fe6b825f/Benchmarks/comparison.json)

| Step | Change | Files | Target (row-only ratio) |
| --- | --- | --- | --- |
| 1 | Reserve each row's width once | `Cell.swift` | Landed: ascii 0.23× (target 0.23×), cursor 0.45× (0.52×), vim 0.43× (0.45×) |
| 2 | Recycle rows through history | `Screen.swift`, `Cell.swift` | scroll 0.29× (0.22×), region 0.19× (0.12×), ascii 0.29× (0.23×) |
| 3 | Parse ASCII controls directly and apply SGR in one pass | `Terminal.swift`, `EscapeParser.swift`, `ControlParameters.swift`, `GraphicsRendition.swift` | sgr 0.86× (0.56×), codex 0.59× (0.41×), cursor 0.57× (0.45×) |
| 4 | Rotate scroll-region rows | `Screen.swift` | region 0.37× (0.12×) |
| 5 | Compact cells with styles stored once | `Cell.swift`, a new row styles file | ascii 0.44× (0.23×), vim 0.69× (0.43×), shell 0.45× (0.33×), cursor 0.79× (0.45×) |
| 6 | Print non-ASCII text in runs | `Terminal.swift`, `TextScanner.swift`, `ColumnWidth.swift`, `Unicode11Widths.swift`, `Screen.swift` | wide 0.48× (0.20×), shell 0.57× (0.33×) |

1. **Reserve each row's width once.** Landed in `fba5402`. A blank row holds no cells. The first write used to fill storage up to its last column with blanks one element at a time and then overwrite them, and writes further right reallocated as the array doubled. Now the first write reserves the row's full width, and text past the stored cells is appended. Every workload got faster, 1.03× to 1.40× at 80 × 24 in 4 KiB chunks against the revision before, and the SGR workload's allocations fell from 9,555 to 1,204, one per row. Sizing every row to its full width with a bulk blank fill, the first idea, was slower. A 16-byte blank isn't zero, and filling 80 of them for each short line cost scroll 0.68× and region 0.83×. Dense ASCII met its target. Cursor addressing and Vim fell short, because a cleared screen still fills blanks up to each random write column and Vim's time is in the nine-store cell writes. Steps 2 and 5 take those on.
2. **Recycle rows through history.** Each line scrolled into a full history frees the evicted row while a new blank row is allocated, and a full-screen erase replaces every row. Allocation and reference counting take 34% of samples on scrolling and 12% on cursor addressing. Have `History.append` hand back the row it evicts and `Buffer.advanceLine` clear it in place as the new blank row, and let a full-screen erase clear rows in place. A pass should then allocate at most once per row the screen and history can hold, about 1,024 at 80 × 24, against tens of thousands today. A renderer's snapshot that still shares an evicted row keeps its copy, because clearing a shared row copies it first. Assumes 85% of allocation and 60% of reference counting goes.
3. **Parse ASCII controls directly and apply SGR in one pass.** The raw-byte half landed in `490316e`. The framer takes a span of ASCII control bytes, collects a run of decimal and separator bytes in fixed parameter storage and dispatches through the existing transition table. Fragmented reads and single-pass input use the same state machine. At 80 × 24 in 4 KiB chunks, the measured ratios to libghostty-vt are 0.92× for SGR, 0.61× for Codex and 0.54× for cursor addressing. SGR and Codex reached their modeled ratios. Cursor addressing reached 0.536× against its 0.57× target. Blank-cell initialization led its profile at 20.6% of samples. Step 5’s zero-bit blank targets that cost. `applySGR` still reads the stored parameters after the CSI final byte. The remaining work is to parse the operands and apply the rendition in one forward pass, with the same colon fields, partial sequences and reference checkpoints.
4. **Rotate scroll-region rows.** `advanceLine` shifts a region by assigning `rows[destination] = rows[source]` for each row, retaining one row's cells and clusters and releasing another's. Reference counting and `advanceLine` take 64% of samples on the region workload. Swap rows instead. Once step 2 lands, the row that leaves the region becomes the new blank row. The change stays in the buffer's row-moving helpers, which every region scroll, index, reverse index and line insertion or deletion goes through. Assumes 90% of reference counting and 80% of scrolling goes.
5. **Compact cells with styles stored once.** `StoredCell` is 13 bytes on a 16-byte stride, a 32-bit glyph and a 9-byte `Style` with single-byte alignment, so `Row.writeASCII` writes each cell with nine separate stores and a bounds check and doesn't vectorize. It took 41% of the row-only samples on dense ASCII. libghostty-vt stores 8-byte cells and keeps styles in a per-page table. An 8-byte cell holding the glyph and the position of its style in the row's style list lets one store write a cell and halves the memory every scroll, erase and snapshot touches. A blank cell becomes all zero bits, so the blank fill that still takes 21% of samples on cursor addressing becomes a memset. The row's style list gets its own file, and [Storage](../docs/emulator.md#storage) describes it. The renderer reads cells through `Row`'s subscript, so the view doesn't change. Assumes 60% of cell writes and 80% of the blank fill goes.
6. **Print non-ASCII text in runs.** Wide text is where xterm still wins. Each non-ASCII scalar is decoded a byte at a time, `ColumnWidth` binary-searches Unicode ranges for its width, and `Screen.write` handles it alone, checking wide edges and clusters. Decoding, measuring and writing scalars one at a time take 59% of samples there, and `ColumnWidth.of` alone takes 23%. Decode a run of printable scalars at once, look widths up in a direct table, and write the run in one call. Assumes 60% of receive and decode and half of cell writes goes.

### Where the tricks live

The low-level techniques stay in three files that explain themselves. `Cell.swift` owns row storage, the cell layout and bulk writes. `TextScanner.swift` owns SIMD scanning and decoding. `EscapeParser.swift` owns the transition table. `Screen.swift` and `Terminal.swift` keep calling intention-revealing operations, and each step's change there should read as plainly as it does now. The row style list is the one new file, and it opens by saying what it stores and why.

### After the six steps

The model based on `fba5402` projected 0.37× to 0.92× of libghostty-vt after all six steps. In that report libghostty-vt printed plain text at 1,019 MiB/s, about 0.9 ns per byte. The remaining storage work targets a scan and bulk store for printing, and line feeds that avoid row allocation and reference counting. The profile after step 5 will show how much time those operations still take.
