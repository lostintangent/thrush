# Comparison with other emulator cores

ThrushCore has to outrun the fastest emulator cores we can measure, doing the same work on the same machine. This benchmark feeds identical bytes to ThrushCore, libghostty-vt and @xterm/headless, checks that they finish with the same screen, and reports throughput, allocations and where ThrushCore spends its time. [Recorded report](comparison.json)

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3 scripts/comparison/run.py --toy-box ../toy-box --profile --output Benchmarks/comparison.json
```

The runner needs Node, Bun and a Toy Box checkout with its dependencies installed, which supplies the pinned @xterm/headless. The first run downloads Zig and the libghostty-vt source release, checks both against pinned SHA-256 digests and builds the library into `.build/comparison/tools`. A full run took about 7 minutes on the reference machine. Pass `--workloads ascii,vim --rounds 1` for a quick check.

## Where Thrush stands

- **libghostty-vt is faster on every workload.** Thrush reaches 0.12× to 0.64× of its throughput. The gap is widest for scroll regions (0.12× to 0.16×) and dense ASCII (0.23× to 0.27×), and narrowest when every cell changes style (0.56× to 0.64×).
- **Thrush outruns @xterm/headless in 32 of 36 conditions**, by 1.27× to 6.55×. Wide CJK and emoji text is the exception, where Thrush runs at 0.82× to 0.90× of xterm's speed.
- **Thrush's screens matched the reference in all 36 conditions.** libghostty-vt matched in 32. The other four come from one difference between the two other cores, described under [Screens](#screens).
- **Thrush allocates for almost every row it writes**, 1,204 to 64,650 times per workload at 4 KiB chunks, while libghostty-vt allocates 0 to 1,330 times.

The profile points at row storage first. Growing and filling rows, allocation and reference counting take 31% of ThrushCore's samples on dense ASCII, 34% on scrolling and 70% on scroll regions once moving rows is included. [Plan for 0.3.0](#plan-for-030) orders the changes and sets a target for each.

## Identical work

Every core receives the same bytes at the same grid size with a 1,000-row history limit. Each workload runs at 80 × 24 and 240 × 60, and arrives either in 4 KiB chunks or as one buffer. No core has a host attached, so replies to queries go nowhere. Each measured pass creates a fresh terminal outside the timed region, then feeds the whole workload.

- **libghostty-vt builds the full screen, not just a parse.** `ghostty_terminal_vt_write` drives its complete terminal: cells, styles, cursor, modes, both screens and history. Its final rows, cursor and active screen matched xterm's in 32 of 36 conditions, which only a terminal that applied every sequence could do. The check compares text, not colors. Its rate falls from 1,019 MiB/s on plain text to 146 MiB/s when every cell changes style, which fits resolving and storing each style.
- **History depth doesn't change its work.** libghostty-vt drops history a whole page at a time, so with the same 1,000-row limit it kept 578 to 964 rows where the others kept 1,000. Every line still scrolls into history, and a dropped page is reused for new rows, so its whole scroll pass allocated 2 times. A separate check on the scroll workload at 80 × 24 raised its limit to 2,000 rows. It kept 1,864 rows, more than Thrush, and ran at 391 to 401 MiB/s against 389 to 400 with the 1,000-row limit. Only an unlimited history, which keeps all 64,616 lines in new pages, slowed it, to 174 to 182 MiB/s.
- **The four libghostty-vt differences don't count against Thrush.** Thrush's tally is against the reference, and it matched in all 36 conditions. In those four, libghostty-vt stopped scrolling the main screen early, as [Screens](#screens) explains, so it did slightly less work. Their ratios, 0.51× to 0.60×, stay in the tables, and leaving them out wouldn't change the 0.12× to 0.64× range.

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

Recorded November 25, 2026 at 16:12 UTC at revision `fba540215886` on an Apple M1 Max with 10 cores, macOS 27.2.1 and Apple Swift version 6.4.2. The machine was shared, with a one-minute load average of 254 at the start and 238 at the end. Absolute rates are lower than on a quiet machine. The ratios are the result, since each round ran the cores back to back under the same load.

| Workload | Grid | Chunks | Thrush MiB/s | libghostty-vt MiB/s | xterm MiB/s | Thrush ÷ libghostty-vt | Thrush ÷ xterm |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| shell | 80 × 24 | 4 KiB | 96 | 284 | 46 (Node) | 0.33× (0.32–0.34) | 2.36× (1.82–2.54) |
| shell | 80 × 24 | Whole | 93 | 292 | 46 (Node) | 0.33× (0.30–0.35) | 1.83× (1.80–3.19) |
| shell | 240 × 60 | 4 KiB | 86 | 168 | 44 (Node) | 0.51× (0.40–0.59) | 1.89× (1.56–2.14) |
| shell | 240 × 60 | Whole | 88 | 171 | 44 (Node) | 0.51× (0.41–0.55) | 1.98× (1.60–3.88) |
| vim | 80 × 24 | 4 KiB | 144 | 341 | 48 (Bun) | 0.43× (0.42–0.52) | 3.16× (2.92–4.00) |
| vim | 80 × 24 | Whole | 145 | 340 | 49 (Bun) | 0.44× (0.43–0.47) | 2.98× (2.79–4.73) |
| vim | 240 × 60 | 4 KiB | 135 | 234 | 25 (Bun) | 0.58× (0.55–0.64) | 5.47× (4.58–6.97) |
| vim | 240 × 60 | Whole | 140 | 233 | 25 (Bun) | 0.60× (0.58–0.66) | 5.69× (4.95–6.08) |
| codex | 80 × 24 | 4 KiB | 106 | 261 | 53 (Node) | 0.41× (0.40–0.42) | 1.92× (1.77–2.07) |
| codex | 80 × 24 | Whole | 105 | 259 | 53 (Node) | 0.41× (0.36–0.42) | 1.90× (1.83–2.00) |
| codex | 240 × 60 | 4 KiB | 101 | 222 | 41 (Bun) | 0.44× (0.35–0.52) | 2.34× (1.76–2.76) |
| codex | 240 × 60 | Whole | 100 | 223 | 39 (Node) | 0.45× (0.44–0.45) | 2.57× (2.47–2.77) |
| ascii | 80 × 24 | 4 KiB | 237 | 1019 | 71 (Node) | 0.23× (0.22–0.25) | 3.21× (2.96–3.99) |
| ascii | 80 × 24 | Whole | 238 | 1017 | 74 (Node) | 0.23× (0.22–0.24) | 3.09× (2.99–3.38) |
| ascii | 240 × 60 | 4 KiB | 293 | 1067 | 103 (Bun) | 0.27× (0.26–0.29) | 2.84× (2.62–3.29) |
| ascii | 240 × 60 | Whole | 284 | 1063 | 98 (Bun) | 0.27× (0.16–0.29) | 2.83× (1.82–3.21) |
| sgr | 80 × 24 | 4 KiB | 82 | 146 | 59 (Node) | 0.56× (0.41–0.70) | 1.27× (1.11–1.74) |
| sgr | 80 × 24 | Whole | 84 | 142 | 66 (Node) | 0.60× (0.58–1.19) | 1.28× (1.21–1.38) |
| sgr | 240 × 60 | 4 KiB | 85 | 133 | 57 (Node) | 0.64× (0.49–0.64) | 1.38× (1.24–1.69) |
| sgr | 240 × 60 | Whole | 85 | 133 | 63 (Node) | 0.63× (0.62–0.66) | 1.32× (1.23–1.92) |
| wide | 80 × 24 | 4 KiB | 67 | 334 | 73 (Node) | 0.20× (0.19–0.20) | 0.88× (0.83–1.35) |
| wide | 80 × 24 | Whole | 66 | 331 | 76 (Node) | 0.20× (0.20–0.21) | 0.90× (0.83–1.01) |
| wide | 240 × 60 | 4 KiB | 69 | 330 | 81 (Bun) | 0.21× (0.20–0.21) | 0.84× (0.82–0.91) |
| wide | 240 × 60 | Whole | 66 | 330 | 82 (Bun) | 0.20× (0.19–0.52) | 0.82× (0.71–1.31) |
| cursor | 80 × 24 | 4 KiB | 72 | 162 | 39 (Bun) | 0.45× (0.34–0.46) | 1.73× (1.48–2.02) |
| cursor | 80 × 24 | Whole | 72 | 169 | 37 (Bun) | 0.43× (0.31–0.45) | 1.89× (1.64–2.20) |
| cursor | 240 × 60 | 4 KiB | 60 | 101 | 9 (Bun) | 0.60× (0.59–0.68) | 6.47× (5.87–10.82) |
| cursor | 240 × 60 | Whole | 61 | 101 | 9 (Bun) | 0.60× (0.60–0.63) | 6.55× (5.98–7.78) |
| scroll | 80 × 24 | 4 KiB | 90 | 399 | 55 (Bun) | 0.22× (0.20–0.23) | 1.55× (1.50–1.93) |
| scroll | 80 × 24 | Whole | 90 | 399 | 53 (Node) | 0.22× (0.19–0.23) | 1.54× (1.50–2.13) |
| scroll | 240 × 60 | 4 KiB | 85 | 286 | 46 (Node) | 0.29× (0.27–0.31) | 1.74× (1.69–2.43) |
| scroll | 240 × 60 | Whole | 86 | 285 | 49 (Node) | 0.30× (0.30–0.31) | 1.79× (1.73–1.84) |
| region | 80 × 24 | 4 KiB | 57 | 456 | 33 (Bun) | 0.12× (0.12–0.13) | 1.74× (1.37–2.36) |
| region | 80 × 24 | Whole | 57 | 452 | 29 (Node) | 0.13× (0.12–0.13) | 1.88× (1.79–2.55) |
| region | 240 × 60 | 4 KiB | 55 | 340 | 24 (Node) | 0.16× (0.15–0.17) | 2.21× (1.90–2.64) |
| region | 240 × 60 | Whole | 56 | 341 | 24 (Bun) | 0.16× (0.15–0.17) | 2.50× (1.87–3.41) |

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
| shell | 0% | 15% | 18% | 0% | 11% | 16% | `Row.writeASCII` 13%, `consume` 10%, `ColumnWidth.of` 5% |
| vim | 0% | 9% | 26% | 0% | 33% | 16% | `Row.writeASCII` 23%, `consume` 19%, `receive` 9% |
| codex | 1% | 1% | 5% | 0% | 61% | 22% | `consume` 38%, `receive` 12%, `ControlParameters.append` 7% |
| ascii | 0% | 31% | 43% | 4% | 2% | 6% | `Row.writeASCII` 41%, `swift_release` 6%, `TextScanner.endOfASCII` 6% |
| sgr | 0% | 2% | 8% | 0% | 66% | 19% | `consume` 32%, `ControlParameters.append` 13%, `receive` 12% |
| wide | 13% | 9% | 18% | 1% | 9% | 40% | `ColumnWidth.of` 23%, `Screen.write` 11%, `consume` 9% |
| cursor | 21% | 12% | 10% | 0% | 24% | 16% | `UnsafeMutableBufferPointer.initialize` 19%, `consume` 15%, `receive` 8% |
| scroll | 0% | 34% | 19% | 5% | 8% | 11% | `Row.writeASCII` 17%, `TextScanner.endOfASCII` 8%, `swift_release` 7% |
| region | 0% | 56% | 12% | 15% | 4% | 4% | `swift_release` 17%, `Buffer.advanceLine` 15%, `swift_retain` 12% |

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

Each target is Thrush's throughput as a share of libghostty-vt's at 80 × 24 in 4 KiB chunks, after that step and the ones before it. It comes from removing the samples the step aims at from this profile. The model assumes each step removes most of the time it targets, with the share given in each step, and ignores second-order gains such as fewer cache misses. A step that lands below its target needs a new profile before the next one starts.

| Step | Change | Files | Target (today) |
| --- | --- | --- | --- |
| 1 | Reserve each row's width once | `Cell.swift` | Landed: ascii 0.23× (target 0.23×), cursor 0.45× (0.52×), vim 0.43× (0.45×) |
| 2 | Recycle rows through history | `Screen.swift`, `Cell.swift` | scroll 0.29× (0.22×), region 0.19× (0.12×), ascii 0.29× (0.23×) |
| 3 | Parse controls without decoding them | `Terminal.swift`, `EscapeParser.swift`, `ControlParameters.swift`, `GraphicsRendition.swift` | sgr 0.86× (0.56×), codex 0.59× (0.41×), cursor 0.57× (0.45×) |
| 4 | Rotate scroll-region rows | `Screen.swift` | region 0.37× (0.12×) |
| 5 | Compact cells with styles stored once | `Cell.swift`, a new row styles file | ascii 0.44× (0.23×), vim 0.69× (0.43×), shell 0.45× (0.33×), cursor 0.79× (0.45×) |
| 6 | Print non-ASCII text in runs | `Terminal.swift`, `TextScanner.swift`, `ColumnWidth.swift`, `Unicode11Widths.swift`, `Screen.swift` | wide 0.48× (0.20×), shell 0.57× (0.33×) |

1. **Reserve each row's width once.** Landed in `fba5402`. A blank row holds no cells. The first write used to fill storage up to its last column with blanks one element at a time and then overwrite them, and writes further right reallocated as the array doubled. Now the first write reserves the row's full width, and text past the stored cells is appended. Every workload got faster, 1.03× to 1.40× at 80 × 24 in 4 KiB chunks against the revision before, and the SGR workload's allocations fell from 9,555 to 1,204, one per row. Sizing every row to its full width with a bulk blank fill, the first idea, was slower. A 16-byte blank isn't zero, and filling 80 of them for each short line cost scroll 0.68× and region 0.83×. Dense ASCII met its target. Cursor addressing and Vim fell short, because a cleared screen still fills blanks up to each random write column and Vim's time is in the nine-store cell writes. Steps 2 and 5 take those on.
2. **Recycle rows through history.** Each line scrolled into a full history frees the evicted row while a new blank row is allocated, and a full-screen erase replaces every row. Allocation and reference counting take 34% of samples on scrolling and 12% on cursor addressing. Have `History.append` hand back the row it evicts and `Buffer.advanceLine` clear it in place as the new blank row, and let a full-screen erase clear rows in place. A pass should then allocate at most once per row the screen and history can hold, about 1,024 at 80 × 24, against tens of thousands today. A renderer's snapshot that still shares an evicted row keeps its copy, because clearing a shared row copies it first. Assumes 85% of allocation and 60% of reference counting goes.
3. **Parse controls without decoding them.** Every control byte, including each parameter digit, goes through `TextScanner.decode` as a Unicode scalar before the parser sees it. Parsing and dispatch take 61% of samples on Codex and 66% on SGR output. Feed ASCII control bytes straight to the parser, and parse a CSI's parameters and apply SGR in one tight loop over the bytes. This is the parser's own design, so Core owns it. Assumes half of parsing and dispatch goes.
4. **Rotate scroll-region rows.** `advanceLine` shifts a region by assigning `rows[destination] = rows[source]` for each row, retaining one row's cells and clusters and releasing another's. Reference counting and `advanceLine` take 64% of samples on the region workload. Swap rows instead. Once step 2 lands, the row that leaves the region becomes the new blank row. The change stays in the buffer's row-moving helpers, which every region scroll, index, reverse index and line insertion or deletion goes through. Assumes 90% of reference counting and 80% of scrolling goes.
5. **Compact cells with styles stored once.** `StoredCell` is 13 bytes on a 16-byte stride, a 32-bit glyph and a 9-byte `Style` with single-byte alignment, so `Row.writeASCII` writes each cell with nine separate stores and a bounds check and doesn't vectorize. It takes 41% of samples on dense ASCII. libghostty-vt stores 8-byte cells and keeps styles in a per-page table. An 8-byte cell holding the glyph and the position of its style in the row's style list lets one store write a cell and halves the memory every scroll, erase and snapshot touches. A blank cell becomes all zero bits, so the blank fill that still takes 21% of samples on cursor addressing becomes a memset. The row's style list gets its own file, and [Storage](../docs/emulator.md#storage) describes it. The renderer reads cells through `Row`'s subscript, so the view doesn't change. Assumes 60% of cell writes and 80% of the blank fill goes.
6. **Print non-ASCII text in runs.** Wide text is where xterm still wins. Each non-ASCII scalar is decoded a byte at a time, `ColumnWidth` binary-searches Unicode ranges for its width, and `Screen.write` handles it alone, checking wide edges and clusters. Decoding, measuring and writing scalars one at a time take 59% of samples there, and `ColumnWidth.of` alone takes 23%. Decode a run of printable scalars at once, look widths up in a direct table, and write the run in one call. Assumes 60% of receive and decode and half of cell writes goes.

### Where the tricks live

The low-level techniques stay in three files that explain themselves. `Cell.swift` owns row storage, the cell layout and bulk writes. `TextScanner.swift` owns SIMD scanning and decoding. `EscapeParser.swift` owns the transition table. `Screen.swift` and `Terminal.swift` keep calling intention-revealing operations, and each step's change there should read as plainly as it does now. The row style list is the one new file, and it opens by saying what it stores and why.

### After the six steps

The model puts Thrush at 0.37× to 0.92× of libghostty-vt once all six land, so they close most of the gap but don't finish it. libghostty-vt prints plain text at 1,019 MiB/s, about 0.9 ns per byte, and to lead Thrush has to match that. The print path has to become a scan and a bulk store of cells, and a line feed has to cost a few instructions with nothing allocated or retained. The profile after step 5 will show what stands between that and today, and each step's landing should refresh these targets from a new profile.
