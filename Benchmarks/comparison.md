# Comparison with other emulator cores

ThrushCore has to outrun the fastest emulator cores we can measure, doing the same work on the same machine. This benchmark feeds identical bytes to ThrushCore, libghostty-vt and @xterm/headless, checks that they finish with the same screen, and reports throughput, allocations and where ThrushCore spends its time. [Recorded report](comparison.json)

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3 scripts/comparison/run.py --toy-box ../toy-box --profile --output Benchmarks/comparison.json
```

The runner needs Node, Bun and a Toy Box checkout with its dependencies installed, which supplies the pinned @xterm/headless. The first run downloads Zig and the libghostty-vt source release, checks both against pinned SHA-256 digests and builds the library into `.build/comparison/tools`. A full run took about 7 minutes on the reference machine. Pass `--workloads ascii,vim --rounds 1` for a quick check.

## Where Thrush stands

- **libghostty-vt is faster on every workload.** Thrush reaches 0.12× to 0.59× of its throughput. The gap is widest for scroll regions (0.12× to 0.16×) and dense ASCII (0.17× to 0.20×), and narrowest when every cell changes style (0.52× to 0.58×).
- **Thrush outruns @xterm/headless in 32 of 36 conditions**, by 1.12× to 5.98×. Wide CJK and emoji text is the exception, where Thrush runs at 0.65× to 0.69× of xterm's speed.
- **Thrush's screens matched the reference in all 36 conditions.** libghostty-vt matched in 32. The other four come from one difference between the two other cores, described under [Screens](#screens).
- **Thrush allocates for almost every row it writes**, 4,189 to 76,306 times per workload at 4 KiB chunks, while libghostty-vt allocates 0 to 1,330 times.

The profile points at row storage first. Growing and filling rows, allocation and reference counting take 52% of ThrushCore's samples on dense ASCII, 46% on scrolling and 75% on scroll regions once moving rows is included. [Plan for 0.3.0](#plan-for-030) orders the changes and sets a target for each.

## Identical work

Every core receives the same bytes at the same grid size with a 1,000-row history limit. Each workload runs at 80 × 24 and 240 × 60, and arrives either in 4 KiB chunks or as one buffer. No core has a host attached, so replies to queries go nowhere. Each measured pass creates a fresh terminal outside the timed region, then feeds the whole workload.

- **libghostty-vt builds the full screen, not just a parse.** `ghostty_terminal_vt_write` drives its complete terminal: cells, styles, cursor, modes, both screens and history. Its final rows, cursor and active screen matched xterm's in 32 of 36 conditions, which only a terminal that applied every sequence could do. The check compares text, not colors. Its rate falls from 1,008 MiB/s on plain text to 145 MiB/s when every cell changes style, which fits resolving and storing each style.
- **History depth doesn't change its work.** libghostty-vt drops history a whole page at a time, so with the same 1,000-row limit it kept 578 to 964 rows where the others kept 1,000. Every line still scrolls into history, and a dropped page is reused for new rows, so its whole scroll pass allocated 2 times. A separate check on the scroll workload at 80 × 24 raised its limit to 2,000 rows. It kept 1,864 rows, more than Thrush, and ran at 391 to 401 MiB/s against 389 to 400 with the 1,000-row limit. Only an unlimited history, which keeps all 64,616 lines in new pages, slowed it, to 174 to 182 MiB/s.
- **The four libghostty-vt differences don't count against Thrush.** Thrush's tally is against the reference, and it matched in all 36 conditions. In those four, libghostty-vt stopped scrolling the main screen early, as [Screens](#screens) explains, so it did slightly less work. Their ratios, 0.44× to 0.58×, stay in the tables, and leaving them out wouldn't change the 0.12× to 0.59× range.

## Method

### Cores

- **ThrushCore** at the recorded revision, built with `swift build -c release`. `ThrushBench --workload` feeds it a `Span` of each chunk.
- **libghostty-vt 1.0.2**, built from its source release with Zig 0.17.1 and `-Doptimize=ReleaseFast`, then linked statically into `scripts/comparison/ghostty.c`. The runner feeds bytes with `ghostty_terminal_vt_write` and reads the final screen through `ghostty_terminal_grid_ref`. It lifts the default scrollback byte cap so history is limited by rows alone, like the other cores.
- **@xterm/headless 6.0.0** with @xterm/addon-unicode11 0.9.0 and Unicode 11 widths active, the versions Toy Box pins. `scripts/comparison/xterm.mjs` runs it under Node 22.18.0 and Bun 1.4.6, and each condition counts the faster runtime. It feeds bytes through `writeSync` on the terminal's core. The public `write` queues the same bytes and parses them in 12 ms slices between timers, so `writeSync` measures parsing and nothing else.

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

Recorded November 25, 2026 at 15:30 UTC at revision `ee7acbcbe1b9` on an Apple M1 Max with 10 cores, macOS 27.2.1 and Apple Swift version 6.4.2. The machine was shared, with a one-minute load average of 336 at the start and 261 at the end. Absolute rates are lower than on a quiet machine. The ratios are the result, since each round ran the cores back to back under the same load.

| Workload | Grid | Chunks | Thrush MiB/s | libghostty-vt MiB/s | xterm MiB/s | Thrush ÷ libghostty-vt | Thrush ÷ xterm |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| shell | 80 × 24 | 4 KiB | 77 | 286 | 52 (Node) | 0.27× (0.26–0.28) | 1.51× (1.39–1.55) |
| shell | 80 × 24 | Whole | 77 | 289 | 50 (Node) | 0.27× (0.20–0.28) | 1.50× (1.13–1.59) |
| shell | 240 × 60 | 4 KiB | 74 | 169 | 44 (Node) | 0.44× (0.40–0.45) | 1.67× (1.44–1.71) |
| shell | 240 × 60 | Whole | 74 | 169 | 46 (Node) | 0.44× (0.43–0.45) | 1.62× (1.53–1.66) |
| vim | 80 × 24 | 4 KiB | 130 | 340 | 52 (Bun) | 0.38× (0.38–0.41) | 2.62× (2.44–2.66) |
| vim | 80 × 24 | Whole | 136 | 342 | 53 (Node) | 0.40× (0.34–0.42) | 2.63× (2.29–2.78) |
| vim | 240 × 60 | 4 KiB | 127 | 236 | 31 (Bun) | 0.53× (0.51–0.55) | 3.69× (3.29–4.36) |
| vim | 240 × 60 | Whole | 132 | 230 | 31 (Bun) | 0.58× (0.53–0.58) | 4.28× (4.07–4.37) |
| codex | 80 × 24 | 4 KiB | 101 | 257 | 59 (Node) | 0.40× (0.39–0.43) | 1.72× (1.62–1.84) |
| codex | 80 × 24 | Whole | 100 | 257 | 58 (Bun) | 0.39× (0.37–0.40) | 1.79× (1.43–2.09) |
| codex | 240 × 60 | 4 KiB | 95 | 224 | 43 (Bun) | 0.42× (0.38–0.45) | 2.06× (1.69–2.46) |
| codex | 240 × 60 | Whole | 95 | 226 | 42 (Node) | 0.43× (0.40–0.48) | 2.26× (2.18–2.48) |
| ascii | 80 × 24 | 4 KiB | 171 | 1008 | 84 (Node) | 0.17× (0.16–0.27) | 2.08× (1.85–4.22) |
| ascii | 80 × 24 | Whole | 174 | 1007 | 85 (Node) | 0.17× (0.17–0.19) | 2.03× (1.94–2.12) |
| ascii | 240 × 60 | 4 KiB | 209 | 1043 | 116 (Bun) | 0.20× (0.19–0.23) | 1.79× (1.74–2.21) |
| ascii | 240 × 60 | Whole | 210 | 1081 | 118 (Bun) | 0.20× (0.18–0.20) | 1.82× (1.61–2.04) |
| sgr | 80 × 24 | 4 KiB | 77 | 145 | 68 (Node) | 0.52× (0.48–0.55) | 1.12× (1.05–1.15) |
| sgr | 80 × 24 | Whole | 79 | 148 | 68 (Node) | 0.53× (0.49–0.54) | 1.13× (1.08–1.22) |
| sgr | 240 × 60 | 4 KiB | 79 | 135 | 67 (Node) | 0.58× (0.57–0.62) | 1.17× (1.14–1.21) |
| sgr | 240 × 60 | Whole | 78 | 137 | 66 (Node) | 0.58× (0.50–0.58) | 1.17× (1.00–1.18) |
| wide | 80 × 24 | 4 KiB | 52 | 349 | 75 (Node) | 0.15× (0.15–0.16) | 0.69× (0.64–0.75) |
| wide | 80 × 24 | Whole | 52 | 334 | 78 (Node) | 0.15× (0.15–0.16) | 0.67× (0.66–0.68) |
| wide | 240 × 60 | 4 KiB | 55 | 329 | 85 (Bun) | 0.16× (0.16–0.18) | 0.65× (0.62–0.68) |
| wide | 240 × 60 | Whole | 55 | 330 | 87 (Bun) | 0.17× (0.16–0.17) | 0.65× (0.59–0.66) |
| cursor | 80 × 24 | 4 KiB | 69 | 168 | 43 (Bun) | 0.42× (0.40–0.47) | 1.63× (1.57–1.65) |
| cursor | 80 × 24 | Whole | 69 | 169 | 45 (Bun) | 0.41× (0.39–0.42) | 1.53× (1.52–1.64) |
| cursor | 240 × 60 | 4 KiB | 59 | 103 | 10 (Bun) | 0.59× (0.55–0.63) | 5.85× (5.57–5.99) |
| cursor | 240 × 60 | Whole | 58 | 102 | 10 (Bun) | 0.57× (0.55–0.58) | 5.98× (5.51–6.03) |
| scroll | 80 × 24 | 4 KiB | 80 | 395 | 57 (Node) | 0.20× (0.19–0.21) | 1.35× (1.34–1.51) |
| scroll | 80 × 24 | Whole | 79 | 396 | 58 (Bun) | 0.20× (0.18–0.23) | 1.39× (1.21–1.45) |
| scroll | 240 × 60 | 4 KiB | 78 | 270 | 47 (Node) | 0.29× (0.24–0.30) | 1.58× (1.26–1.67) |
| scroll | 240 × 60 | Whole | 81 | 274 | 49 (Node) | 0.28× (0.28–0.32) | 1.63× (1.61–1.66) |
| region | 80 × 24 | 4 KiB | 54 | 446 | 37 (Bun) | 0.12× (0.11–0.14) | 1.42× (1.24–1.46) |
| region | 80 × 24 | Whole | 53 | 454 | 39 (Bun) | 0.12× (0.12–0.15) | 1.27× (1.21–2.55) |
| region | 240 × 60 | 4 KiB | 53 | 339 | 28 (Node) | 0.16× (0.15–0.16) | 2.01× (1.78–2.57) |
| region | 240 × 60 | Whole | 53 | 337 | 26 (Bun) | 0.16× (0.15–0.17) | 2.01× (1.80–2.14) |

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
| shell | 12% | 16% | 13% | 0% | 9% | 12% | `Row.writeASCII` 9%, `consume` 9%, `UnsafeMutableBufferPointer.initialize` 7% |
| vim | 16% | 8% | 17% | 0% | 27% | 11% | `consume` 17%, `Row.writeASCII` 15%, `UnsafeMutableBufferPointer.initialize` 13% |
| codex | 2% | 1% | 4% | 0% | 65% | 18% | `consume` 41%, `TextScanner.decode` 9%, `ControlParameters.append` 7% |
| ascii | 28% | 24% | 26% | 3% | 1% | 4% | `UnsafeMutableBufferPointer.initialize` 27%, `Row.writeASCII` 24%, `_xzm_free_main` 5% |
| sgr | 3% | 2% | 6% | 0% | 64% | 15% | `consume` 33%, `ControlParameters.append` 11%, `Style.applySGR` 9% |
| wide | 12% | 12% | 16% | 0% | 8% | 33% | `ColumnWidth.of` 17%, `Screen.write` 10%, `TextScanner.decode` 8% |
| cursor | 21% | 14% | 6% | 0% | 26% | 13% | `UnsafeMutableBufferPointer.initialize` 19%, `consume` 18%, `_xzm_free_main` 6% |
| scroll | 16% | 29% | 13% | 4% | 5% | 8% | `UnsafeMutableBufferPointer.initialize` 15%, `Row.writeASCII` 10%, `_xzm_free_main` 7% |
| region | 11% | 52% | 9% | 12% | 2% | 5% | `swift_release` 17%, `Buffer.advanceLine` 12%, `swift_retain` 10% |

- **Row growth and fill** is `Row.ensureLength` extending a row's cells with blanks through `Array.append(contentsOf:)`, which compiles to `UnsafeMutableBufferPointer.initialize(from:)` and `_consumeAndCreateNew`.
- **Allocation and reference counting** is malloc, free, retain, release and uniqueness checks, nearly all from creating, copying and dropping rows.
- **Cell writes** are `Row.writeASCII`, `Row.write` and `Screen.write`, which store glyphs and styles.
- **Parsing and dispatch** covers `EscapeParser`, `ControlParameters`, `Terminal.apply` and SGR handling.
- **Receive, decode and scan** covers `Terminal.receive`, the UTF-8 decoder, the ASCII scanner and `ColumnWidth`, plus whatever is inlined into them. Non-ASCII text is printed from `Terminal.consume`, so on wide text part of the parsing share is printing.

## Allocations

Allocations in one pass at 4 KiB chunks.

| Workload | Thrush 80 × 24 | Thrush 240 × 60 | libghostty-vt 80 × 24 | libghostty-vt 240 × 60 |
| --- | ---: | ---: | ---: | ---: |
| shell | 76,306 | 76,239 | 134 | 140 |
| vim | 22,018 | 22,443 | 1,330 | 1,330 |
| codex | 4,189 | 4,189 | 475 | 477 |
| ascii | 18,262 | 10,017 | 2 | 9 |
| sgr | 9,555 | 9,555 | 6 | 15 |
| wide | 71,364 | 55,157 | 2 | 9 |
| cursor | 49,052 | 49,052 | 0 | 0 |
| scroll | 64,859 | 64,859 | 2 | 9 |
| region | 49,382 | 49,382 | 0 | 0 |

Thrush's counts follow the rows it writes. Dense ASCII writes 18,019 rows at 80 × 24 and allocates 18,262 times. Scrolling writes 64,639 lines and allocates 64,859 times, and the scroll region writes 49,216 lines and allocates 49,382 times. Rows that fill one cell at a time cost more. The SGR workload writes 1,193 lines and allocates 9,555 times, about 8 per row, because a row's cells grow to each write's end and reallocate as they double.

## Plan for 0.3.0

Six changes, ordered by expected gain. Each one lands on its own with the comparison, ThrushBench and the conformance harness run before and after. Steps 3, 4 and 6 don't depend on the storage steps, so they can proceed in parallel with them.

Each target is Thrush's throughput as a share of libghostty-vt's at 80 × 24 in 4 KiB chunks, after that step and the ones before it. It comes from removing the samples the step aims at from this profile. The model assumes each step removes most of the time it targets, with the share given in each step, and ignores second-order gains such as fewer cache misses. A step that lands below its target needs a new profile before the next one starts.

| Step | Change | Files | Target (today) |
| --- | --- | --- | --- |
| 1 | Fixed-width rows | `Cell.swift`, `ScreenResize.swift` | ascii 0.23× (0.17×), cursor 0.52× (0.42×), vim 0.45× (0.38×) |
| 2 | Recycle rows through history | `Screen.swift`, `Cell.swift` | scroll 0.32× (0.20×), region 0.21× (0.12×), ascii 0.30× (0.17×) |
| 3 | Parse controls without decoding them | `Terminal.swift`, `EscapeParser.swift`, `ControlParameters.swift`, `GraphicsRendition.swift` | sgr 0.81× (0.52×), codex 0.61× (0.40×), cursor 0.73× (0.42×) |
| 4 | Rotate scroll-region rows | `Screen.swift` | region 0.39× (0.12×) |
| 5 | Compact cells with styles stored once | `Cell.swift`, a new style table file | ascii 0.41× (0.17×), vim 0.69× (0.38×), shell 0.41× (0.27×) |
| 6 | Print non-ASCII text in runs | `Terminal.swift`, `TextScanner.swift`, `ColumnWidth.swift`, `Unicode11Widths.swift`, `Screen.swift` | wide 0.35× (0.15×), shell 0.50× (0.27×) |

1. **Fixed-width rows.** A blank row holds no cells. The first write allocates storage up to its last column, fills it with blanks one element at a time through `Array.append(contentsOf:)` and then overwrites the same cells, and writes further right reallocate. Growth and fill take 28% of samples on dense ASCII. Size a row's cells to its width once, with a bulk fill, so `ensureLength` and every reallocation disappear. The SGR workload's 9,555 allocations should fall to about one per row. Assumes 90% of growth and fill goes.
2. **Recycle rows through history.** Each line scrolled into a full history frees the evicted row while a new blank row is allocated. Allocation and reference counting take 29% of samples on scrolling. Have `History.append` hand back the row it evicts and `Buffer.advanceLine` clear it in place as the new blank row, and let a full-screen erase clear rows in place. A pass should then allocate at most once per row the screen and history can hold, about 1,024 at 80 × 24, against tens of thousands today. A renderer's snapshot that still shares an evicted row keeps its copy, because clearing a shared row copies it first. Assumes 85% of allocation and 60% of reference counting goes.
3. **Parse controls without decoding them.** Every control byte, including each parameter digit, goes through `TextScanner.decode` as a Unicode scalar before the parser sees it. Parsing and dispatch take 65% of samples on Codex and 64% on SGR output. Feed ASCII control bytes straight to the parser, and parse a CSI's parameters and apply SGR in one tight loop over the bytes. This is the parser's own design, so Core owns it. Assumes half of parsing and dispatch goes.
4. **Rotate scroll-region rows.** `advanceLine` shifts a region by assigning `rows[destination] = rows[source]` for each row, retaining one row's cells and clusters and releasing another's. Reference counting and `advanceLine` take 57% of samples on the region workload. Swap rows instead. Once step 2 lands, the row that leaves the region becomes the new blank row. The change stays inside `advanceLine`. Assumes 90% of reference counting and 80% of scrolling goes.
5. **Compact cells with styles stored once.** `StoredCell` is 13 bytes on a 16-byte stride, a 32-bit glyph and a 9-byte `Style` with single-byte alignment, so `Row.writeASCII` writes each cell with nine separate stores and a bounds check and doesn't vectorize. It takes 24% of samples on dense ASCII. libghostty-vt stores 8-byte cells and keeps styles in a per-page table. An 8-byte cell holding the glyph and a style identifier lets one store write a cell and halves the memory every scroll, erase and snapshot touches. The style table gets its own file. The renderer reads cells through `Row`'s subscript, so the view doesn't change. Assumes 60% of cell writes goes.
6. **Print non-ASCII text in runs.** Wide text is where xterm still wins. Each non-ASCII scalar is decoded a byte at a time, `ColumnWidth` binary-searches Unicode ranges for its width, and `Screen.write` handles it alone, checking wide edges and clusters. Decoding, measuring and writing scalars one at a time take 50% of samples there, and `ColumnWidth.of` alone takes 17%. Decode a run of printable scalars at once, look widths up in a direct table, and write the run in one call. Assumes 60% of receive and decode and half of cell writes goes.

### Where the tricks live

The low-level techniques stay in three files that explain themselves. `Cell.swift` owns row storage, the cell layout and bulk writes. `TextScanner.swift` owns SIMD scanning and decoding. `EscapeParser.swift` owns the transition table. `Screen.swift` and `Terminal.swift` keep calling intention-revealing operations, and each step's change there should read as plainly as it does now. The style table is the one new file, and it opens by saying what it stores and why.

### After the six steps

The model puts Thrush at 0.35× to 0.86× of libghostty-vt once all six land, so they close most of the gap but don't finish it. libghostty-vt prints plain text at 1,008 MiB/s, about 0.9 ns per byte, and to lead Thrush has to match that. The print path has to become a scan and a bulk store of cells, and a line feed has to cost a few instructions with nothing allocated or retained. The profile after step 5 will show what stands between that and today, and each step's landing should refresh these targets from a new profile.
