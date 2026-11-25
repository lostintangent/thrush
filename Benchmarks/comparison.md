# Comparison with other emulator cores

ThrushCore has to outrun the fastest emulator cores we can measure, doing the same work on the same machine. This benchmark feeds identical bytes to ThrushCore, libghostty-vt and @xterm/headless, checks that they finish with the same screen, and reports throughput, allocations and where ThrushCore spends its time. [Recorded report](comparison.json)

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3 scripts/comparison/run.py --toy-box ../toy-box --profile --output Benchmarks/comparison.json
```

The runner needs Node, Bun and a Toy Box checkout with its dependencies installed, which supplies the pinned @xterm/headless. The first run downloads Zig and the libghostty-vt source release, checks both against pinned SHA-256 digests and builds the library into `.build/comparison/tools`. A full run took about 7 minutes on the reference machine. Pass `--workloads ascii,vim --rounds 1` for a quick check.

## Where Thrush stands

- **Thrush’s median throughput exceeded libghostty-vt’s in 3 of 36 conditions.** These were SGR at 240 × 60 with 4 KiB chunks (1.020×, round range 0.990–1.187×), SGR at 240 × 60 with one buffer (1.043×, round range 1.004–1.525×) and cursor addressing at 240 × 60 with one buffer (1.011×, round range 0.962–1.013×). SGR with one buffer led in every round. The other two each included a round in which libghostty-vt was faster. Across the full matrix Thrush reached 0.12–1.04× of libghostty-vt’s throughput.
- **Thrush outran the faster @xterm/headless runtime in 32 of 36 conditions**, by 1.43–11.09×. xterm led on wide CJK and emoji at both grids and both chunk sizes. Thrush reached 0.95–0.98× of xterm’s throughput in those four conditions.
- **Thrush matched the reference in all 36 screen checks.** Four libghostty-vt runs differed from the Node reference. The difference occurred on the shell and Vim recordings at 240 × 60 with either chunk size. [Screens](#screens)
- **Thrush no longer allocates for every line on most workloads.** Plain text, SGR, wide text and scrolling allocate 1,035 times per pass at 80 × 24, about once per row the screen and history hold, and cursor addressing allocates 24. The scroll region still allocates 49,217 times, once per line, and the shell recording 20,027. libghostty-vt allocates 0 to 1,330 times.

Row recycling changed scrolling and plain text most. At 80 × 24 in 4 KiB chunks, scrolling rose from 89 to 159 MiB/s and dense ASCII from 239 to 361 MiB/s. [Change from the raw-parser build](#change-from-the-raw-parser-build)

## Identical work

Every core receives the same bytes at the same grid size with a 1,000-row history limit. Each workload runs at 80 × 24 and 240 × 60, and arrives either in 4 KiB chunks or as one buffer. No core has a host attached, so replies to queries go nowhere. Each measured pass creates a fresh terminal outside the timed region, then feeds the whole workload.

- **libghostty-vt builds the full screen, not just a parse.** `ghostty_terminal_vt_write` drives its complete terminal: cells, styles, cursor, modes, both screens and history. Its final rows, cursor and active screen matched xterm's in 32 of 36 conditions after a full-buffer replay. The screen check compares visible text, cursor position and the active buffer. Color values are outside this check. Its rate falls from 1,012 MiB/s on plain text to 148 MiB/s when every cell changes style, which fits resolving and storing each style.
- **History depth doesn't change its work.** libghostty-vt drops history a whole page at a time, so with the same 1,000-row limit it kept 578 to 964 rows where the others kept 1,000. Every line still scrolls into history, and a dropped page is reused for new rows, so its whole scroll pass allocated 2 times. A separate check on the scroll workload at 80 × 24 raised its limit to 2,000 rows. It kept 1,864 rows, more than Thrush, and ran at 391 to 401 MiB/s against 389 to 400 with the 1,000-row limit. Only an unlimited history, which keeps all 64,616 lines in new pages, slowed it, to 174 to 182 MiB/s.
- **libghostty-vt did less scrolling in four conditions.** Its main screen retained Vim’s alternate-screen scroll region in the two 240 × 60 recordings. The table includes these observations, with Thrush between 0.67× and 0.95× of libghostty-vt’s throughput. [Screens](#screens)

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

Recorded November 25, 2026 at 16:51 UTC at revision `ee966eb1e461` on an Apple M1 Max with 10 cores, macOS 27.2.1 and Apple Swift version 6.4.2. The machine was shared, with a one-minute load average of 249 at the start and 330 at the end. Within each round the cores ran back to back. The ranges show how much their relative rates varied. [Measured source](https://github.com/lostintangent/thrush/commit/ee966eb1e4619085709b05cd0ad69857c9be079b)

| Workload | Grid | Chunks | Thrush MiB/s | libghostty-vt MiB/s | xterm MiB/s | Thrush ÷ libghostty-vt | Thrush ÷ xterm |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| shell | 80 × 24 | 4 KiB | 121 | 290 | 52 (Node) | 0.43× (0.40–0.46) | 2.41× (2.15–2.48) |
| shell | 80 × 24 | Whole | 118 | 292 | 53 (Node) | 0.40× (0.39–0.53) | 2.22× (2.18–2.42) |
| shell | 240 × 60 | 4 KiB | 119 | 170 | 49 (Node) | 0.67× (0.65–0.71) | 2.43× (2.27–2.98) |
| shell | 240 × 60 | Whole | 117 | 169 | 44 (Node) | 0.69× (0.66–0.73) | 2.54× (2.46–2.71) |
| vim | 80 × 24 | 4 KiB | 236 | 331 | 51 (Node) | 0.71× (0.69–0.77) | 4.85× (4.38–5.02) |
| vim | 80 × 24 | Whole | 239 | 343 | 53 (Node) | 0.69× (0.68–0.71) | 4.53× (4.36–4.84) |
| vim | 240 × 60 | 4 KiB | 216 | 233 | 29 (Bun) | 0.93× (0.88–0.93) | 7.20× (6.96–8.06) |
| vim | 240 × 60 | Whole | 222 | 234 | 28 (Bun) | 0.95× (0.94–0.98) | 8.17× (6.96–10.16) |
| codex | 80 × 24 | 4 KiB | 159 | 259 | 58 (Node) | 0.61× (0.60–0.62) | 2.75× (2.66–2.90) |
| codex | 80 × 24 | Whole | 159 | 260 | 59 (Node) | 0.62× (0.61–0.66) | 2.97× (2.58–3.20) |
| codex | 240 × 60 | 4 KiB | 149 | 225 | 44 (Bun) | 0.69× (0.65–1.02) | 3.29× (2.68–4.13) |
| codex | 240 × 60 | Whole | 148 | 225 | 40 (Node) | 0.65× (0.59–0.77) | 3.66× (2.98–4.34) |
| ascii | 80 × 24 | 4 KiB | 361 | 1012 | 82 (Node) | 0.36× (0.35–0.40) | 4.40× (4.33–4.90) |
| ascii | 80 × 24 | Whole | 362 | 1019 | 80 (Node) | 0.36× (0.35–0.36) | 4.70× (4.31–6.03) |
| ascii | 240 × 60 | 4 KiB | 387 | 1063 | 110 (Bun) | 0.35× (0.34–0.37) | 3.58× (3.26–3.83) |
| ascii | 240 × 60 | Whole | 389 | 1057 | 110 (Bun) | 0.37× (0.36–0.37) | 3.68× (3.13–3.72) |
| sgr | 80 × 24 | 4 KiB | 131 | 148 | 64 (Node) | 0.92× (0.79–0.93) | 2.00× (1.94–2.47) |
| sgr | 80 × 24 | Whole | 133 | 144 | 63 (Node) | 0.92× (0.91–0.98) | 2.07× (2.03–2.45) |
| sgr | 240 × 60 | 4 KiB | 133 | 133 | 63 (Node) | 1.02× (0.99–1.19) | 2.08× (1.90–2.31) |
| sgr | 240 × 60 | Whole | 131 | 131 | 62 (Node) | 1.04× (1.00–1.53) | 2.09× (2.01–2.41) |
| wide | 80 × 24 | 4 KiB | 75 | 336 | 75 (Node) | 0.22× (0.18–0.23) | 0.96× (0.84–1.03) |
| wide | 80 × 24 | Whole | 75 | 332 | 77 (Node) | 0.22× (0.22–0.23) | 0.98× (0.95–5.11) |
| wide | 240 × 60 | 4 KiB | 75 | 326 | 74 (Node) | 0.23× (0.21–0.24) | 0.95× (0.92–2.08) |
| wide | 240 × 60 | Whole | 75 | 328 | 78 (Bun) | 0.23× (0.20–0.24) | 0.96× (0.88–1.45) |
| cursor | 80 × 24 | 4 KiB | 120 | 168 | 42 (Bun) | 0.73× (0.55–0.79) | 2.73× (2.17–3.39) |
| cursor | 80 × 24 | Whole | 117 | 169 | 42 (Bun) | 0.69× (0.68–0.72) | 2.83× (2.64–2.98) |
| cursor | 240 × 60 | 4 KiB | 96 | 102 | 10 (Bun) | 0.95× (0.88–1.00) | 9.33× (8.94–10.05) |
| cursor | 240 × 60 | Whole | 100 | 103 | 10 (Bun) | 1.01× (0.96–1.01) | 11.09× (9.54–11.36) |
| scroll | 80 × 24 | 4 KiB | 159 | 399 | 56 (Bun) | 0.40× (0.38–0.51) | 2.94× (2.65–3.20) |
| scroll | 80 × 24 | Whole | 165 | 397 | 58 (Bun) | 0.42× (0.39–0.49) | 2.79× (2.60–3.14) |
| scroll | 240 × 60 | 4 KiB | 158 | 285 | 48 (Node) | 0.56× (0.54–0.56) | 3.27× (3.09–4.18) |
| scroll | 240 × 60 | Whole | 157 | 288 | 50 (Node) | 0.55× (0.53–0.57) | 3.18× (3.01–3.34) |
| region | 80 × 24 | 4 KiB | 54 | 456 | 38 (Bun) | 0.12× (0.12–0.12) | 1.43× (1.27–2.08) |
| region | 80 × 24 | Whole | 55 | 460 | 35 (Bun) | 0.12× (0.11–0.12) | 1.46× (1.28–1.67) |
| region | 240 × 60 | 4 KiB | 53 | 339 | 26 (Node) | 0.16× (0.15–0.18) | 2.05× (1.83–2.23) |
| region | 240 × 60 | Whole | 54 | 340 | 24 (Bun) | 0.16× (0.15–0.19) | 2.21× (1.64–2.80) |

## Change from the raw-parser build

The two clean reports used the same bytes, workload order, host, toolchain and core versions. The rates below compare their independent 15-pass medians at 80 × 24 in 4 KiB chunks. Allocations count one separate pass. Between the two revisions, `3412608` also moved line feeds, index, reverse index and line insertion and deletion onto shared row-moving helpers. [Raw-parser report at 490316e](https://github.com/lostintangent/thrush/blob/307a1a1c4c0dfee285362547c077591c6007cd28/Benchmarks/comparison.json)

| Workload | Raw parser MiB/s | Recycled rows MiB/s | Recycled ÷ raw parser | Thrush allocations |
| --- | ---: | ---: | ---: | ---: |
| shell | 105.8 | 121.5 | 1.148× | 38,749 → 20,027 |
| vim | 213.8 | 236.3 | 1.105× | 14,046 → 4,296 |
| codex | 161.2 | 158.7 | 0.984× | 2,678 → 2,736 |
| ascii | 239.2 | 361.1 | 1.509× | 18,030 → 1,035 |
| sgr | 136.3 | 131.5 | 0.965× | 1,204 → 1,035 |
| wide | 72.4 | 74.6 | 1.030× | 14,321 → 1,035 |
| cursor | 89.2 | 119.6 | 1.340× | 36,830 → 24 |
| scroll | 89.3 | 158.8 | 1.778× | 64,650 → 1,035 |
| region | 57.8 | 54.4 | 0.942× | 49,217 → 49,217 |

Codex, SGR and wide text changed within run-to-run variation. The scroll region doesn't recycle, because its region starts below the top row, so its lines never reach history. Its 4–6% drop comes from `3412608`: it retires 2,519 million instructions per ten 4 KiB passes against 2,365 million at `490316e`, and 2,515 million with recycling. Interleaved runs of `ee966eb` against its parent `3412608` put every workload's median between 0.98× and 1.89×, with the scroll region between 0.98× and 1.01×.

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
| shell | 2% | 9% | 27% | 1% | 8% | 18% | `Row.writeASCII` 16%, `receive` 13%, `Screen.writeASCII` 5% |
| vim | 0% | 9% | 40% | 0% | 25% | 11% | `Row.writeASCII` 33%, `EscapeParser.consumeEscape` 13%, `receive` 6% |
| codex | 2% | 2% | 9% | 0% | 56% | 13% | `EscapeParser.consumeEscape` 34%, `apply` 10%, `receive` 9% |
| ascii | 0% | 8% | 65% | 7% | 3% | 9% | `Row.writeASCII` 61%, `TextScanner.endOfASCII` 7%, `Screen.writeASCII` 4% |
| sgr | 1% | 4% | 14% | 0% | 63% | 8% | `EscapeParser.consumeEscape` 35%, `Style.applySGR` 15%, `Row.writeASCII` 7% |
| wide | 14% | 9% | 22% | 2% | 1% | 50% | `receive` 47%, `Screen.write` 15%, `UnsafeMutableBufferPointer.initialize` 6% |
| cursor | 29% | 5% | 22% | 0% | 25% | 12% | `UnsafeMutableBufferPointer.initialize` 27%, `EscapeParser.consumeEscape` 19%, `Row.writeASCII` 11% |
| scroll | 1% | 9% | 39% | 6% | 10% | 23% | `Row.writeASCII` 29%, `TextScanner.endOfASCII` 14%, `receive` 9% |
| region | 0% | 56% | 10% | 15% | 2% | 5% | `Buffer.deleteRows` 15%, `swift_release` 15%, `swift_retain` 14% |

- **Row growth and fill** is `Row.ensureLength` extending a row's cells with blanks through `Array.append(contentsOf:)`, which compiles to `UnsafeMutableBufferPointer.initialize(from:)` and `_consumeAndCreateNew`.
- **Allocation and reference counting** is malloc, free, retain, release and uniqueness checks, nearly all from creating, copying and dropping rows and their cluster tables.
- **Scrolling** is `advanceLine`, `History.append` and the row-moving helpers `deleteRows` and `insertRows`.
- **Cell writes** are `Row.writeASCII`, `Row.write` and `Screen.write`, which store glyphs and styles.
- **Parsing and dispatch** covers `EscapeParser`, `ControlParameters`, `Terminal.apply` and SGR handling.
- **Receive, decode and scan** covers `Terminal.receive`, the UTF-8 decoder, the ASCII scanner and `ColumnWidth`, plus whatever is inlined into them. Non-ASCII text is printed from `Terminal.consume`, so on wide text part of the parsing share is printing.

## Allocations

Allocations in one pass at 4 KiB chunks.

| Workload | Thrush 80 × 24 | Thrush 240 × 60 | libghostty-vt 80 × 24 | libghostty-vt 240 × 60 |
| --- | ---: | ---: | ---: | ---: |
| shell | 20,027 | 20,140 | 134 | 140 |
| vim | 4,296 | 4,715 | 1,330 | 1,330 |
| codex | 2,736 | 2,736 | 475 | 477 |
| ascii | 1,035 | 1,071 | 2 | 9 |
| sgr | 1,035 | 1,071 | 6 | 15 |
| wide | 1,035 | 1,071 | 2 | 9 |
| cursor | 24 | 24 | 0 | 0 |
| scroll | 1,035 | 1,071 | 2 | 9 |
| region | 49,217 | 49,217 | 0 | 0 |

A row allocates its cells once, on its first write, and a line feed or display erase now clears a row in place instead of replacing it. So once the screen and 1,000 rows of history fill, steady output stops allocating. Dense ASCII, SGR, wide text and scrolling settle at 1,035 allocations at 80 × 24, one for each row the screen and history hold plus a few for the terminal itself. Cursor addressing writes only within the screen and allocates 24 times, down from 36,830 when each full-screen erase replaced every row. The scroll region writes 49,216 lines and allocates 49,217 times, because a region that starts below the top row moves rows by copying them. The shell recording allocates 20,027 times, close to one for each of the 18,634 lines that carry a combining accent and so need a cluster table.

## Plan for 0.3.0

Six changes, ordered by expected gain. Each one lands on its own with the comparison, ThrushBench and the conformance harness run before and after. Steps 3, 4 and 6 don't depend on the storage steps, so they can proceed in parallel with them.

Targets in the table are cumulative ratios to libghostty-vt at 80 × 24 in 4 KiB chunks. The accepted model used the row-only profile at `fba5402` and estimated the fraction of time each change would remove. The parenthesized ratios and the storage and wide-text sample shares below also come from that build. Step 3 now has a measured raw-parser checkpoint. One-pass SGR remains open. [Row-only report at fba5402](https://github.com/lostintangent/thrush/blob/175383340dcae31674b043def1835304fe6b825f/Benchmarks/comparison.json)

| Step | Change | Files | Target (row-only ratio) |
| --- | --- | --- | --- |
| 1 | Reserve each row's width once | `Cell.swift` | Landed: ascii 0.23× (target 0.23×), cursor 0.45× (0.52×), vim 0.43× (0.45×) |
| 2 | Recycle rows through history | `Screen.swift`, `Cell.swift` | Landed: scroll 0.40× (target 0.29×), ascii 0.36× (0.29×). Region stays 0.12× (0.19×) until step 4 |
| 3 | Parse ASCII controls directly and apply SGR in one pass | `Terminal.swift`, `EscapeParser.swift`, `ControlParameters.swift`, `GraphicsRendition.swift` | sgr 0.86× (0.56×), codex 0.59× (0.41×), cursor 0.57× (0.45×) |
| 4 | Rotate scroll-region rows | `Screen.swift` | region 0.37× (0.12×) |
| 5 | Compact cells with styles stored once | `Cell.swift`, a new row styles file | ascii 0.44× (0.23×), vim 0.69× (0.43×), shell 0.45× (0.33×), cursor 0.79× (0.45×) |
| 6 | Print non-ASCII text in runs | `Terminal.swift`, `TextScanner.swift`, `ColumnWidth.swift`, `Unicode11Widths.swift`, `Screen.swift` | wide 0.48× (0.20×), shell 0.57× (0.33×) |

1. **Reserve each row's width once.** Landed in `fba5402`. A blank row holds no cells. The first write used to fill storage up to its last column with blanks one element at a time and then overwrite them, and writes further right reallocated as the array doubled. Now the first write reserves the row's full width, and text past the stored cells is appended. Every workload got faster, 1.03× to 1.40× at 80 × 24 in 4 KiB chunks against the revision before, and the SGR workload's allocations fell from 9,555 to 1,204, one per row. Sizing every row to its full width with a bulk blank fill, the first idea, was slower. A 16-byte blank isn't zero, and filling 80 of them for each short line cost scroll 0.68× and region 0.83×. Dense ASCII met its target. Cursor addressing and Vim fell short, because a cleared screen still fills blanks up to each random write column and Vim's time is in the nine-store cell writes. Steps 2 and 5 take those on.
2. **Recycle rows through history.** Landed in `ee966eb`. Once history is full, `History.append` swaps the row leaving the screen into its oldest slot and hands back the row it evicts, and `advanceLine` clears that row in place as the new bottom row, keeping its reserved width. Erasing the display clears rows in place the same way. Against its parent `3412608` at 80 × 24 in 4 KiB chunks, scrolling ran 1.80× faster, dense ASCII 1.53×, cursor addressing 1.27×, the shell recording 1.19× and Vim 1.16×, and no workload got slower. Allocations fell to about one per row the screen and history hold: 1,035 on scrolling, dense ASCII, SGR and wide text, and 24 on cursor addressing. Scrolling and dense ASCII beat their targets. The scroll region didn't move, because its region starts below the top row and its lines never reach history, so its target moves to step 4. A renderer's snapshot that still shares a recycled row keeps its cells, because clearing a shared row gives the terminal new storage.
3. **Parse ASCII controls directly and apply SGR in one pass.** The raw-byte half landed in `490316e`. The framer takes a span of ASCII control bytes, collects a run of decimal and separator bytes in fixed parameter storage and dispatches through the existing transition table. Fragmented reads and single-pass input use the same state machine. At 80 × 24 in 4 KiB chunks, the measured ratios to libghostty-vt are 0.92× for SGR, 0.61× for Codex and 0.54× for cursor addressing. SGR and Codex reached their modeled ratios. Cursor addressing reached 0.536× against its 0.57× target. Blank-cell initialization led its profile at 20.6% of samples. Step 5’s zero-bit blank targets that cost. `applySGR` still reads the stored parameters after the CSI final byte. The remaining work is to parse the operands and apply the rendition in one forward pass, with the same colon fields, partial sequences and reference checkpoints.
4. **Rotate scroll-region rows.** `Buffer.deleteRows` and `insertRows` shift a region by assigning `rows[destination] = rows[source]` for each row, retaining one row's cells and clusters and releasing another's, then fill the freed rows with a new blank row. Reference counting and `deleteRows` take 63% of samples on the region workload. Swap rows instead, and clear the rows that leave the region in place as its new blank rows, as step 2 does for line feeds. Every region scroll, index, reverse index and line insertion or deletion goes through these two helpers. Assumes 90% of reference counting and 80% of scrolling goes.
5. **Compact cells with styles stored once.** `StoredCell` is 13 bytes on a 16-byte stride, a 32-bit glyph and a 9-byte `Style` with single-byte alignment, so `Row.writeASCII` writes each cell with nine separate stores and a bounds check and doesn't vectorize. It took 41% of the row-only samples on dense ASCII. libghostty-vt stores 8-byte cells and keeps styles in a per-page table. An 8-byte cell holding the glyph and the position of its style in the row's style list lets one store write a cell and halves the memory every scroll, erase and snapshot touches. A blank cell becomes all zero bits, so the blank fill that takes 29% of samples on cursor addressing at `ee966eb` becomes a memset. The row's style list gets its own file, and [Storage](../docs/emulator.md#storage) describes it. The renderer reads cells through `Row`'s subscript, so the view doesn't change. Assumes 60% of cell writes and 80% of the blank fill goes.
6. **Print non-ASCII text in runs.** Wide text is where xterm still wins. Each non-ASCII scalar is decoded a byte at a time, `ColumnWidth` binary-searches Unicode ranges for its width, and `Screen.write` handles it alone, checking wide edges and clusters. Decoding, measuring and writing scalars one at a time take 59% of samples there, and `ColumnWidth.of` alone takes 23%. Decode a run of printable scalars at once, look widths up in a direct table, and write the run in one call. Assumes 60% of receive and decode and half of cell writes goes.

### Where the tricks live

The low-level techniques stay in three files that explain themselves. `Cell.swift` owns row storage, the cell layout and bulk writes. `TextScanner.swift` owns SIMD scanning and decoding. `EscapeParser.swift` owns the transition table. `Screen.swift` and `Terminal.swift` keep calling intention-revealing operations, and each step's change there should read as plainly as it does now. The row style list is the one new file, and it opens by saying what it stores and why.

### After the six steps

The model based on `fba5402` projected 0.37× to 0.92× of libghostty-vt after all six steps. In that report libghostty-vt printed plain text at 1,019 MiB/s, about 0.9 ns per byte. The remaining storage work targets a scan and bulk store for printing, and line feeds that avoid row allocation and reference counting. The profile after step 5 will show how much time those operations still take.
