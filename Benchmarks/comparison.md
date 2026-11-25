# Comparison with other emulator cores

ThrushCore has to outrun the fastest emulator cores we can measure, doing the same work on the same machine. This benchmark feeds identical bytes to ThrushCore, libghostty-vt and @xterm/headless, checks that they finish with the same screen, and reports throughput, allocations and where ThrushCore spends its time. [Recorded report](comparison.json)

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3 scripts/comparison/run.py --toy-box ../toy-box --profile --output Benchmarks/comparison.json
```

The runner needs Node, Bun and a Toy Box checkout with its dependencies installed, which supplies the pinned @xterm/headless. The first run downloads Zig and the libghostty-vt source release, checks both against pinned SHA-256 digests and builds the library into `.build/comparison/tools`. A full run took about 7 minutes on the reference machine. Pass `--workloads ascii,vim --rounds 1` for a quick check.

## Where Thrush stands

- **Three Thrush medians exceeded libghostty-vt’s.** All three were at 240 × 60, on per-cell SGR with both delivery sizes and cursor addressing with 4 KiB chunks. Each of those five-round ranges crossed parity. Across all 36 conditions Thrush reached 0.12–1.05× libghostty-vt’s throughput.
- **Thrush ran faster than both @xterm/headless runtimes in every condition.** The full range was 1.68–9.82×. On wide CJK and emoji the range was 2.11–2.28×.
- **Screen checks.** Thrush matched the Node reference in 36 of 36 conditions. The Bun runtime matched it in 36 of 36, and libghostty-vt matched it in 32 of 36. [Screens](#screens)
- **Allocations.** At 4 KiB, Thrush recorded 24 to 49,217 allocations per workload and libghostty-vt recorded 0 to 1,330.

At 80 × 24 in 4 KiB chunks, Unicode batching lifted wide text from 74.4 to 170.7 MiB/s. The shell recording, which mixes ASCII and Unicode, rose from 116.3 to 124.8 MiB/s. [Change from the parent build](#change-from-the-parent-build)

## Identical work

Every core receives the same bytes at the same grid size with a 1,000-row history limit. Each workload runs at 80 × 24 and 240 × 60, and arrives either in 4 KiB chunks or as one buffer. No core has a host attached, so replies to queries go nowhere. Each measured pass creates a fresh terminal outside the timed region, then feeds the whole workload.

- **libghostty-vt builds the full screen.** `ghostty_terminal_vt_write` drives cells, styles, cursor, modes, both screens and history. Its final visible rows, cursor and active screen matched the Node reference in 32 of 36 conditions. The comparison covers visible text, cursor position and the active buffer. The conformance suite checks cell attributes. At 80 × 24 in 4 KiB chunks its throughput was 1016 MiB/s on plain text and 147 MiB/s on per-cell SGR.
- **History depth doesn't change its work.** libghostty-vt drops history a whole page at a time, so with the same 1,000-row limit it kept 578 to 964 rows where the others kept 1,000. Every line still scrolls into history, and a dropped page is reused for new rows, so its whole scroll pass allocated 2 times. A separate check on the scroll workload at 80 × 24 raised its limit to 2,000 rows. It kept 1,864 rows, more than Thrush, and ran at 391 to 401 MiB/s against 389 to 400 with the 1,000-row limit. Only an unlimited history, which keeps all 64,616 lines in new pages, slowed it, to 174 to 182 MiB/s.
- **libghostty-vt did less scrolling in four conditions.** Its large-grid shell and Vim runs retained the alternate screen’s scroll region. Thrush reached 0.76–0.97× of its throughput in these conditions. [Screens](#screens)

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

Recorded November 25, 2026 at 17:01 UTC on an Apple M1 Max with 10 cores, macOS 27.2.1 and Apple Swift version 6.4.2. The one-minute load average was 199 at the start and 152 at the end. Within each round the cores ran back to back. The ranges show how their relative rates varied. [Measured source a1612a7](https://github.com/lostintangent/thrush/commit/a1612a7ee6100dc916642a910ed9e43877de948f)

| Workload | Grid | Chunks | Thrush MiB/s | libghostty-vt MiB/s | xterm MiB/s | Thrush ÷ libghostty-vt | Thrush ÷ xterm |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| shell | 80 × 24 | 4 KiB | 125 | 290 | 51 (Node) | 0.45× (0.44–0.48) | 2.59× (2.35–2.95) |
| shell | 80 × 24 | Whole | 131 | 290 | 46 (Node) | 0.45× (0.42–0.52) | 2.53× (2.32–3.42) |
| shell | 240 × 60 | 4 KiB | 122 | 169 | 45 (Node) | 0.76× (0.65–0.80) | 2.71× (2.46–3.14) |
| shell | 240 × 60 | Whole | 125 | 171 | 48 (Node) | 0.77× (0.66–0.78) | 2.76× (2.55–3.50) |
| vim | 80 × 24 | 4 KiB | 240 | 344 | 49 (Node) | 0.70× (0.68–0.71) | 4.90× (4.57–7.39) |
| vim | 80 × 24 | Whole | 240 | 335 | 52 (Node) | 0.69× (0.60–0.74) | 4.58× (3.93–4.81) |
| vim | 240 × 60 | 4 KiB | 220 | 228 | 26 (Node) | 0.97× (0.89–0.98) | 8.25× (7.67–8.67) |
| vim | 240 × 60 | Whole | 223 | 231 | 29 (Bun) | 0.97× (0.94–1.07) | 7.73× (7.13–8.91) |
| codex | 80 × 24 | 4 KiB | 163 | 259 | 59 (Node) | 0.63× (0.61–0.71) | 2.77× (2.64–3.90) |
| codex | 80 × 24 | Whole | 164 | 260 | 63 (Bun) | 0.63× (0.61–0.74) | 2.62× (2.53–2.78) |
| codex | 240 × 60 | 4 KiB | 152 | 226 | 45 (Bun) | 0.69× (0.66–0.77) | 3.43× (2.57–4.27) |
| codex | 240 × 60 | Whole | 159 | 224 | 41 (Bun) | 0.70× (0.67–0.82) | 3.75× (3.57–5.51) |
| ascii | 80 × 24 | 4 KiB | 357 | 1016 | 82 (Node) | 0.35× (0.34–0.36) | 4.45× (4.05–4.83) |
| ascii | 80 × 24 | Whole | 360 | 1016 | 82 (Node) | 0.35× (0.34–0.36) | 4.41× (4.21–4.60) |
| ascii | 240 × 60 | 4 KiB | 392 | 1079 | 111 (Bun) | 0.37× (0.36–0.37) | 3.47× (3.37–3.96) |
| ascii | 240 × 60 | Whole | 389 | 1058 | 111 (Bun) | 0.37× (0.36–0.38) | 3.31× (3.21–4.31) |
| sgr | 80 × 24 | 4 KiB | 135 | 147 | 66 (Node) | 0.91× (0.65–1.13) | 2.00× (1.58–2.07) |
| sgr | 80 × 24 | Whole | 135 | 146 | 64 (Node) | 0.92× (0.87–1.00) | 2.12× (1.94–2.38) |
| sgr | 240 × 60 | 4 KiB | 132 | 133 | 65 (Node) | 1.01× (0.83–1.06) | 2.02× (1.71–3.38) |
| sgr | 240 × 60 | Whole | 135 | 134 | 67 (Node) | 1.05× (0.99–1.08) | 2.07× (1.98–2.11) |
| wide | 80 × 24 | 4 KiB | 171 | 335 | 75 (Node) | 0.50× (0.49–0.52) | 2.28× (2.07–2.36) |
| wide | 80 × 24 | Whole | 171 | 333 | 79 (Node) | 0.51× (0.49–0.52) | 2.16× (2.10–2.31) |
| wide | 240 × 60 | 4 KiB | 174 | 331 | 84 (Bun) | 0.53× (0.52–0.54) | 2.11× (1.90–2.73) |
| wide | 240 × 60 | Whole | 175 | 330 | 85 (Bun) | 0.52× (0.51–0.55) | 2.12× (2.03–2.33) |
| cursor | 80 × 24 | 4 KiB | 114 | 169 | 42 (Bun) | 0.67× (0.66–0.68) | 2.66× (2.58–2.75) |
| cursor | 80 × 24 | Whole | 118 | 168 | 45 (Bun) | 0.72× (0.68–0.75) | 2.62× (2.56–2.83) |
| cursor | 240 × 60 | 4 KiB | 100 | 100 | 10 (Bun) | 1.02× (0.97–1.02) | 9.81× (9.11–10.25) |
| cursor | 240 × 60 | Whole | 100 | 102 | 10 (Bun) | 0.99× (0.95–1.01) | 9.82× (9.33–10.34) |
| scroll | 80 × 24 | 4 KiB | 166 | 396 | 59 (Node) | 0.42× (0.41–0.65) | 2.85× (2.78–2.93) |
| scroll | 80 × 24 | Whole | 162 | 401 | 57 (Node) | 0.41× (0.35–0.41) | 2.85× (2.56–2.91) |
| scroll | 240 × 60 | 4 KiB | 162 | 280 | 49 (Node) | 0.58× (0.56–0.65) | 3.31× (3.21–3.38) |
| scroll | 240 × 60 | Whole | 163 | 280 | 49 (Node) | 0.58× (0.55–0.68) | 3.29× (3.21–3.53) |
| region | 80 × 24 | 4 KiB | 54 | 459 | 32 (Node) | 0.12× (0.12–0.13) | 1.68× (1.64–1.82) |
| region | 80 × 24 | Whole | 54 | 444 | 31 (Node) | 0.12× (0.11–0.16) | 1.71× (1.58–2.20) |
| region | 240 × 60 | 4 KiB | 53 | 340 | 28 (Bun) | 0.16× (0.15–0.18) | 1.80× (1.73–2.52) |
| region | 240 × 60 | Whole | 54 | 341 | 25 (Node) | 0.16× (0.16–0.16) | 2.11× (1.87–2.42) |

## Change from the parent build

Each report used the same host, toolchain, workload digests and benchmark settings. The rows compare independent 15-pass medians at 80 × 24 in 4 KiB chunks. Allocation changes come from separately instrumented passes. Parent [4e332dc](https://github.com/lostintangent/thrush/commit/4e332dccf4191751c1d380c9fd205e6f00006782). Candidate [a1612a7](https://github.com/lostintangent/thrush/commit/a1612a7ee6100dc916642a910ed9e43877de948f).

| Workload | Parent 4e332dc MiB/s | Candidate a1612a7 MiB/s | Candidate ÷ parent | Thrush allocation delta |
| --- | ---: | ---: | ---: | ---: |
| shell | 116.3 | 124.8 | 1.073× | 0 |
| vim | 236.8 | 239.9 | 1.013× | 0 |
| codex | 161.5 | 162.8 | 1.008× | 0 |
| ascii | 362.0 | 357.4 | 0.987× | 0 |
| sgr | 131.3 | 134.9 | 1.027× | 0 |
| wide | 74.4 | 170.7 | 2.296× | 0 |
| cursor | 114.7 | 113.8 | 0.992× | 0 |
| scroll | 165.5 | 165.9 | 1.002× | 0 |
| region | 54.7 | 54.0 | 0.988× | 0 |

Allocation counts were identical in all 36 conditions. Eleven alternating pairs at each grid and delivery size put the wide-text wall-time reduction at 55–57%. In separate standalone runs, throughput dipped 2.1% on the 80 × 14 ASCII grid and 2.9% on the 15-byte prompt with a byte-order mark. Repeating those two inputs in isolation produced timing intervals that included parity. The ASCII run retired 1.5% more instructions.

## Screens

Thrush matched the Node reference in 36 of 36 conditions. The Bun runtime matched it in 36 of 36, and libghostty-vt matched it in 32 of 36. The four libghostty-vt differences were on shell and Vim at 240 × 60. Both recordings were captured at 80 × 24, and Vim sets the scroll region to rows 1 to 24 (`ESC[1;24r`) on the alternate screen. When Vim leaves the alternate screen (`ESC[?1049l`), xterm and Thrush return to the main screen's own region, so the main screen still scrolls across all 60 rows. libghostty-vt keeps one region for both screens, so a line feed on the bottom row, below that region, doesn't scroll.

The smallest stream that shows it runs at 80 × 10:

```
ESC[?1049h ESC[1;5r ESC[?1049l ESC[10;1H a LF b
```

xterm and Thrush finish with `a` on row 9 and ` b` on row 10. libghostty-vt finishes with `ab` on row 10. At 80 × 24 the region already covers the whole screen, so all three cores agree. The affected runs do slightly less scrolling in libghostty-vt than in the other cores.

## Where Thrush spends its time

Shares of all samples, grouped by the sampled symbol among the top 20 self-time entries per workload. Each entry belongs to at most one category. Unclassified symbols and samples outside the top 20 account for the remainder. Inlined work is charged to the symbol in which it was sampled.

| Workload | Row growth and fill | Allocation and reference counting | Cell writes | Scrolling | Parsing and dispatch | Receive, decode and scan | Top functions |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| shell | 0% | 9% | 29% | 2% | 8% | 15% | `Row.writeASCII` 16%, `Screen.writeRun` 7%, `receive` 5% |
| vim | 1% | 7% | 38% | 0% | 26% | 12% | `Row.writeASCII` 31%, `EscapeParser.consumeEscape` 14%, `receive` 6% |
| codex | 2% | 3% | 10% | 0% | 60% | 10% | `EscapeParser.consumeEscape` 35%, `apply` 10%, `Style.applySGR` 8% |
| ascii | 0% | 4% | 66% | 5% | 5% | 12% | `Row.writeASCII` 63%, `TextScanner.endOfASCII` 10%, `Buffer.advanceLine` 3% |
| sgr | 1% | 6% | 13% | 0% | 67% | 8% | `EscapeParser.consumeEscape` 39%, `Style.applySGR` 17%, `receive` 6% |
| wide | 0% | 8% | 33% | 2% | 3% | 50% | `closure #1 in writeNonASCII` 37%, `Screen.writeRun` 20%, `Row.writeASCII` 7% |
| cursor | 29% | 6% | 25% | 0% | 27% | 12% | `UnsafeMutableBufferPointer.initialize` 26%, `EscapeParser.consumeEscape` 20%, `Row.writeASCII` 9% |
| scroll | 1% | 8% | 36% | 8% | 17% | 21% | `Row.writeASCII` 28%, `TextScanner.endOfASCII` 17%, `Screen.writeASCII` 6% |
| region | 0% | 55% | 10% | 15% | 4% | 4% | `swift_release` 15%, `Buffer.deleteRows` 15%, `swift_retain` 14% |

Row growth includes blank initialization and capacity growth. Allocation and reference counting include allocator and Swift ownership functions. Cell writes include `Screen.writeRun`, `Row.appendRun`, and the scalar and ASCII writers. Scrolling includes advancing or moving rows and appending history. Parsing includes VT framing, dispatch and SGR operand handling. Receive and decode include `Terminal.writeNonASCII`, the scanner and column-width lookup.

## Allocations

Allocation counts for one pass at 4 KiB chunks. The terminal starts each pass with empty screens and history.

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
| 6 | Print non-ASCII text in runs | `Terminal.swift`, `TextScanner.swift`, `ColumnWidth.swift`, `Unicode11Widths.swift`, `Screen.swift` | Landed: wide 0.50× (target 0.48×, row-only 0.20×), shell 0.45× (target 0.57×, row-only 0.33×) |

1. **Reserve each row's width once.** Landed in `fba5402`. A blank row holds no cells. The first write used to fill storage up to its last column with blanks one element at a time and then overwrite them, and writes further right reallocated as the array doubled. Now the first write reserves the row's full width, and text past the stored cells is appended. Every workload got faster, 1.03× to 1.40× at 80 × 24 in 4 KiB chunks against the revision before, and the SGR workload's allocations fell from 9,555 to 1,204, one per row. Sizing every row to its full width with a bulk blank fill, the first idea, was slower. A 16-byte blank isn't zero, and filling 80 of them for each short line cost scroll 0.68× and region 0.83×. Dense ASCII met its target. Cursor addressing and Vim fell short, because a cleared screen still fills blanks up to each random write column and Vim's time is in the nine-store cell writes. Steps 2 and 5 take those on.
2. **Recycle rows through history.** Landed in `ee966eb`. Once history is full, `History.append` swaps the row leaving the screen into its oldest slot and hands back the row it evicts, and `advanceLine` clears that row in place as the new bottom row, keeping its reserved width. Erasing the display clears rows in place the same way. Against its parent `3412608` at 80 × 24 in 4 KiB chunks, scrolling ran 1.80× faster, dense ASCII 1.53×, cursor addressing 1.27×, the shell recording 1.19× and Vim 1.16×, and no workload got slower. Allocations fell to about one per row the screen and history hold: 1,035 on scrolling, dense ASCII, SGR and wide text, and 24 on cursor addressing. Scrolling and dense ASCII beat their targets. The scroll region didn't move, because its region starts below the top row and its lines never reach history, so its target moves to step 4. A renderer's snapshot that still shares a recycled row keeps its cells, because clearing a shared row gives the terminal new storage.
3. **Parse ASCII controls directly and apply SGR in one pass.** The raw-byte half landed in `490316e`. The framer takes a span of ASCII control bytes, collects a run of decimal and separator bytes in fixed parameter storage and dispatches through the existing transition table. Fragmented reads and single-pass input use the same state machine. At 80 × 24 in 4 KiB chunks, the measured ratios to libghostty-vt are 0.92× for SGR, 0.61× for Codex and 0.54× for cursor addressing. SGR and Codex reached their modeled ratios. Cursor addressing reached 0.536× against its 0.57× target. Blank-cell initialization led its profile at 20.6% of samples. Step 5’s zero-bit blank targets that cost. `applySGR` still reads the stored parameters after the CSI final byte. The remaining work is to parse the operands and apply the rendition in one forward pass, with the same colon fields, partial sequences and reference checkpoints.
4. **Rotate scroll-region rows.** `Buffer.deleteRows` and `insertRows` shift a region by assigning `rows[destination] = rows[source]` for each row, retaining one row's cells and clusters and releasing another's, then fill the freed rows with a new blank row. Reference counting and `deleteRows` take 63% of samples on the region workload. Swap rows instead, and clear the rows that leave the region in place as its new blank rows, as step 2 does for line feeds. Every region scroll, index, reverse index and line insertion or deletion goes through these two helpers. Assumes 90% of reference counting and 80% of scrolling goes.
5. **Compact cells with styles stored once.** `StoredCell` is 13 bytes on a 16-byte stride, a 32-bit glyph and a 9-byte `Style` with single-byte alignment, so `Row.writeASCII` writes each cell with nine separate stores and a bounds check and doesn't vectorize. It took 41% of the row-only samples on dense ASCII. libghostty-vt stores 8-byte cells and keeps styles in a per-page table. An 8-byte cell holding the glyph and the position of its style in the row's style list lets one store write a cell and halves the memory every scroll, erase and snapshot touches. A blank cell becomes all zero bits, so the blank fill that takes 29% of samples on cursor addressing at `ee966eb` becomes a memset. The row's style list gets its own file, and [Storage](../docs/emulator.md#storage) describes it. The renderer reads cells through `Row`'s subscript, so the view doesn't change. Assumes 60% of cell writes and 80% of the blank fill goes.
6. **Print non-ASCII text in runs.** Landed in `a1612a7`. On the row-only build, decoding, measuring and writing one Unicode scalar at a time accounted for 59% of wide-text samples. Width lookup alone accounted for 23%. The new path groups printable non-ASCII scalars when autowrap is on, insert mode is off and the active character set is ASCII. It reads Unicode 11 widths from a packed page table and appends adjacent glyphs that fit on the row. Combining marks, overwrites and right-margin wraps use the scalar writer. At 80 × 24 in 4 KiB chunks, wide text rose from 74.4 to 170.7 MiB/s. That was 2.282× the faster JavaScript runtime and 0.503× libghostty-vt, above the modeled 0.48× target. Shell reached 0.453× libghostty-vt, below its cumulative 0.57× target. The model also includes compact cells from step 5. [Parent 4e332dc](https://github.com/lostintangent/thrush/commit/4e332dccf4191751c1d380c9fd205e6f00006782), [measured source a1612a7](https://github.com/lostintangent/thrush/commit/a1612a7ee6100dc916642a910ed9e43877de948f).

### Where the tricks live

The low-level techniques stay in three files that explain themselves. `Cell.swift` owns row storage, the cell layout and bulk writes. `TextScanner.swift` owns SIMD scanning and decoding. `EscapeParser.swift` owns the transition table. `Screen.swift` and `Terminal.swift` keep calling intention-revealing operations, and each step's change there should read as plainly as it does now. The row style list is the one new file, and it opens by saying what it stores and why.

### After the six steps

The model based on `fba5402` projected 0.37× to 0.92× of libghostty-vt after all six steps. In that report libghostty-vt printed plain text at 1,019 MiB/s, about 0.9 ns per byte. The remaining storage work targets a scan and bulk store for printing, and line feeds that avoid row allocation and reference counting. The profile after step 5 will show how much time those operations still take.
