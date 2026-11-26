# Comparison with other emulator cores

ThrushCore has to outrun the fastest emulator cores we can measure, doing the same work on the same machine. This benchmark feeds identical bytes to ThrushCore, libghostty-vt and @xterm/headless, checks that they finish with the same screen, and reports throughput and allocations. A separate profile shows where ThrushCore spends its time. [Recorded report](comparison.json) · [Recorded profile](comparison-profile.json)

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3 scripts/comparison/run.py --output Benchmarks/comparison.json
```

The runner needs Node and Bun. It installs the [pinned reference](../Fixtures/reference/README.md), which supplies @xterm/headless. The first run downloads Zig and the libghostty-vt source release, checks both against pinned SHA-256 digests and builds the library into `.build/comparison/tools`. After that, a full run takes about 2 minutes on the reference machine. Pass `--workloads ascii,vim --rounds 1` for a quick check. The profile comes from the [Comparison profile workflow](../.github/workflows/comparison-profile.yml). [Profile](#profile)

## Where Thrush stands

- **Thrush led libghostty-vt in 30 of 36 conditions.** It led in every condition on the shell recording by 1.06–1.79×, Vim by 1.23–1.70×, Codex by 1.05–1.21×, dense ASCII by 1.11–1.28×, SGR by 1.38–1.54×, cursor addressing by 1.24–1.84× and scrolling by 1.09–1.44×. At 240 × 60 it also led on wide text by 1.05×. [Screens](#screens)
- **The widest gaps are at 80 × 24.** Thrush ran at 0.70–0.72× of libghostty-vt on the scroll region and 0.983–0.996× on wide text. [Where Thrush loses time](#where-thrush-loses-time)
- **Thrush ran faster than both @xterm/headless runtimes in every condition**, by 3.04–18.56×.
- **Screen checks.** Thrush matched the Node reference in 36 of 36 conditions. The Bun runtime matched it in 36 of 36, and libghostty-vt matched it in 32 of 36. [Screens](#screens)
- **Allocations.** At 4 KiB, Thrush recorded 21 to 8,802 allocations per workload and libghostty-vt recorded 0 to 1,330. [Allocations](#allocations)

Since the [previous report](#change-since-the-previous-report), Thrush's ratio to libghostty-vt rose in 27 of 36 conditions. At 80 × 24 in 4 KiB chunks, cursor addressing went from 1.00× to 1.25× and Codex went from 0.89× to 1.05×.

## Identical work

Every core receives the same bytes at the same grid size with a 1,000-row history limit. Each workload runs at 80 × 24 and 240 × 60, and arrives either in 4 KiB chunks or as one buffer. No core has an app attached, so replies to queries go nowhere. Each measured pass creates a fresh terminal outside the timed region, then feeds the whole workload.

- **libghostty-vt builds the full screen.** `ghostty_terminal_vt_write` drives cells, styles, cursor, modes, both screens and history. Its final visible rows, cursor and active screen matched the Node reference in 32 of 36 conditions. The comparison checks visible text, cursor position and the active buffer. It also checks history depth for Thrush and both JavaScript runtimes. The conformance suite checks cell attributes. At 80 × 24 in 4 KiB chunks its throughput was 1,101 MiB/s on plain text and 161 MiB/s on per-cell SGR.
- **History depth doesn't change its work.** libghostty-vt drops history a whole page at a time, so with the same 1,000-row limit it kept 578 to 964 rows where the others kept 1,000. Every line still scrolls into history, and a dropped page is reused for new rows, so its whole scroll pass allocated 2 times. A separate check on the scroll workload at 80 × 24 raised its limit to 2,000 rows. It kept 1,864 rows, more than Thrush, and ran at 391 to 401 MiB/s against 389 to 400 with the 1,000-row limit. Only an unlimited history, which keeps all 64,616 lines in new pages, slowed it, to 174 to 182 MiB/s.
- **libghostty-vt did less scrolling in four conditions.** Its large-grid shell and Vim runs retained the alternate screen’s scroll region. Thrush reached 1.69–1.79× of its throughput in these conditions. [Screens](#screens)

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

Each workload is about 1 MiB, generated deterministically by `scripts/comparison/workloads.py`. The recorded workloads repeat the program output of committed fixtures in `Fixtures/recordings`, without their resizes, until they reach 1 MiB.

| Workload | What it holds | Bytes | SHA-256 prefix |
| --- | --- | ---: | --- |
| shell | `shell-log`: prompts, a long build log with accented and CJK paths, and a short Vim edit | 1,145,837 | `767d3f9e1f704d06` |
| vim | `vim-edit`, `vim-resume`, `vim-swift-dark` and `vim-swift-light`: full-screen editing and highlighted Swift | 1,055,040 | `ba7161493d4ee857` |
| codex | `codex-session`: a Codex session's styled, cursor-addressed output | 1,066,156 | `ee53772a6d921fcf` |
| ascii | Words in lines of 8 to 200 characters ending in CRLF, so long lines wrap | 1,048,634 | `27549df120fad47a` |
| sgr | 80-cell lines with an SGR before every cell, mixing basic, 256-color and RGB colors with attributes | 1,049,367 | `15e74931214ff067` |
| wide | Lines of CJK ideographs, emoji and words, wrapping wide glyphs at the margin | 1,048,616 | `3e10e33e7379faf1` |
| cursor | Frames that clear the screen, then write 120 words at random positions with occasional EL and ED | 1,049,493 | `41ac6cba6f3aa9bf` |
| scroll | Short numbered lines, so nearly every byte run ends in a scroll into history | 1,048,587 | `3fc3d209db465438` |
| region | 64 lines scrolled inside rows 2 to 20, then a reverse-video status line on row 24 | 1,049,715 | `80c5a714c8ae5cc8` |

## Results

Recorded November 26, 2026 at 11:48 UTC on an Apple M1 Max with 10 cores, macOS 27.2.1 and Apple Swift version 6.4.2. The one-minute load average was 4 at the start and 4 at the end. Within each round the cores ran back to back. The ranges show how their relative rates varied. [Measured source f79a268](https://github.com/lostintangent/thrush/commit/f79a268db3a82b7f7923fa2da8441eeb9cd788f8)

| Workload | Grid | Chunks | Thrush MiB/s | libghostty-vt MiB/s | xterm MiB/s | Thrush ÷ libghostty-vt | Thrush ÷ xterm |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| shell | 80 × 24 | 4 KiB | 328 | 311 | 57 (Node) | 1.06× (1.05–1.06) | 5.71× (5.60–5.87) |
| shell | 80 × 24 | Whole | 327 | 307 | 58 (Node) | 1.06× (1.06–1.07) | 5.67× (5.44–6.17) |
| shell | 240 × 60 | 4 KiB | 321 | 179 | 53 (Node) | 1.79× (1.76–1.80) | 6.15× (5.73–6.17) |
| shell | 240 × 60 | Whole | 324 | 181 | 53 (Node) | 1.79× (1.78–1.80) | 6.12× (5.93–6.22) |
| vim | 80 × 24 | 4 KiB | 442 | 361 | 57 (Bun) | 1.23× (1.12–1.24) | 7.82× (7.22–7.89) |
| vim | 80 × 24 | Whole | 447 | 356 | 56 (Node) | 1.25× (1.10–1.26) | 7.96× (6.72–8.01) |
| vim | 240 × 60 | 4 KiB | 411 | 243 | 33 (Bun) | 1.69× (1.67–1.73) | 12.39× (11.78–12.43) |
| vim | 240 × 60 | Whole | 414 | 246 | 33 (Bun) | 1.70× (1.65–1.73) | 12.31× (12.27–12.72) |
| codex | 80 × 24 | 4 KiB | 288 | 274 | 64 (Bun) | 1.05× (1.03–1.07) | 4.44× (4.38–4.53) |
| codex | 80 × 24 | Whole | 291 | 272 | 68 (Bun) | 1.06× (1.04–1.08) | 4.26× (4.19–4.40) |
| codex | 240 × 60 | 4 KiB | 284 | 239 | 50 (Bun) | 1.19× (1.14–1.22) | 5.72× (5.58–5.93) |
| codex | 240 × 60 | Whole | 291 | 239 | 49 (Bun) | 1.21× (1.20–1.22) | 5.98× (5.67–6.02) |
| ascii | 80 × 24 | 4 KiB | 1214 | 1101 | 86 (Node) | 1.11× (0.93–1.13) | 14.16× (11.89–14.44) |
| ascii | 80 × 24 | Whole | 1253 | 1086 | 90 (Node) | 1.15× (1.14–1.16) | 13.87× (13.66–14.27) |
| ascii | 240 × 60 | 4 KiB | 1494 | 1172 | 120 (Bun) | 1.27× (1.26–1.29) | 12.39× (12.10–12.76) |
| ascii | 240 × 60 | Whole | 1530 | 1166 | 124 (Bun) | 1.28× (1.20–1.34) | 12.21× (11.09–12.56) |
| sgr | 80 × 24 | 4 KiB | 219 | 161 | 71 (Node) | 1.38× (1.36–1.43) | 3.07× (2.99–3.10) |
| sgr | 80 × 24 | Whole | 220 | 160 | 72 (Node) | 1.38× (1.35–1.42) | 3.05× (3.00–3.08) |
| sgr | 240 × 60 | 4 KiB | 221 | 143 | 73 (Node) | 1.54× (1.50–1.55) | 3.05× (2.91–3.10) |
| sgr | 240 × 60 | Whole | 220 | 144 | 72 (Node) | 1.52× (1.50–1.54) | 3.04× (2.93–3.08) |
| wide | 80 × 24 | 4 KiB | 360 | 356 | 83 (Node) | 1.00× (0.99–1.01) | 4.27× (4.19–4.37) |
| wide | 80 × 24 | Whole | 358 | 360 | 82 (Node) | 0.98× (0.97–1.00) | 4.27× (4.20–4.31) |
| wide | 240 × 60 | 4 KiB | 376 | 361 | 92 (Bun) | 1.05× (1.00–1.08) | 4.13× (3.83–4.15) |
| wide | 240 × 60 | Whole | 374 | 358 | 91 (Bun) | 1.05× (1.03–1.08) | 4.10× (4.06–4.13) |
| cursor | 80 × 24 | 4 KiB | 221 | 178 | 47 (Bun) | 1.25× (1.21–1.28) | 4.74× (4.56–4.79) |
| cursor | 80 × 24 | Whole | 222 | 176 | 47 (Bun) | 1.24× (1.22–1.49) | 4.76× (4.42–4.84) |
| cursor | 240 × 60 | 4 KiB | 198 | 110 | 11 (Bun) | 1.83× (1.74–1.84) | 18.39× (17.81–18.58) |
| cursor | 240 × 60 | Whole | 200 | 109 | 11 (Bun) | 1.84× (1.81–1.91) | 18.56× (18.18–18.83) |
| scroll | 80 × 24 | 4 KiB | 463 | 424 | 63 (Bun) | 1.09× (1.08–1.12) | 7.40× (6.98–7.53) |
| scroll | 80 × 24 | Whole | 468 | 425 | 66 (Bun) | 1.10× (1.02–1.13) | 6.94× (6.88–7.35) |
| scroll | 240 × 60 | 4 KiB | 463 | 329 | 53 (Node) | 1.41× (1.40–1.44) | 8.73× (8.67–8.85) |
| scroll | 240 × 60 | Whole | 470 | 326 | 52 (Node) | 1.44× (1.42–1.62) | 8.91× (8.79–9.58) |
| region | 80 × 24 | 4 KiB | 344 | 479 | 45 (Bun) | 0.72× (0.70–0.72) | 7.76× (7.33–7.77) |
| region | 80 × 24 | Whole | 336 | 482 | 44 (Bun) | 0.70× (0.67–0.72) | 7.64× (7.32–9.49) |
| region | 240 × 60 | 4 KiB | 343 | 359 | 33 (Bun) | 0.96× (0.94–0.96) | 10.58× (9.90–10.81) |
| region | 240 × 60 | Whole | 346 | 363 | 36 (Bun) | 0.95× (0.95–0.96) | 9.68× (9.60–10.12) |

## Change since the previous report

Both reports used the same host, toolchain and benchmark settings, and every workload but Vim's had the same digest. The Vim workload now holds the styled Vim recordings at the 47 × 24 iPhone portrait pane, and is 3,240 bytes shorter. The rows compare 15-pass medians at 80 × 24 in 4 KiB chunks. Across all 36 conditions Thrush ran 1.01–1.27× as fast as in the previous report, while libghostty-vt's own rates moved by 1.00–1.10×. Since then the parser reads text, a lone control or a whole control sequence in `receive`, keeps parameters as the bytes that arrived and reads a whole header once. It holds its transition table instead of reading a lazy static, and the hot-path tricks worth 2% or less were removed. Cursor addressing ran 1.25× and Codex 1.23× as fast, so both now lead in every condition. The other workloads ran 1.03–1.10× as fast, about as much as libghostty-vt's own rates rose on the same machine, so their ratios moved by 5% or less. Scroll and region rates also move by about 6% with code placement alone. [Where the speed lives](../docs/emulator.md#where-the-speed-lives) · [Previous report at 59093ee](https://github.com/lostintangent/thrush/blob/b56a70b/Benchmarks/comparison.json)

| Workload | 59093ee MiB/s | f79a268 MiB/s | Change | 59093ee ÷ libghostty-vt | f79a268 ÷ libghostty-vt |
| --- | ---: | ---: | ---: | ---: | ---: |
| shell | 317.4 | 328.2 | 1.03× | 1.07× | 1.06× |
| vim | 428.1 | 442.1 | 1.03× | 1.24× | 1.23× |
| codex | 234.8 | 287.7 | 1.23× | 0.89× | 1.05× |
| ascii | 1146.7 | 1214.0 | 1.06× | 1.10× | 1.11× |
| sgr | 210.4 | 219.2 | 1.04× | 1.38× | 1.38× |
| wide | 329.7 | 359.5 | 1.09× | 0.97× | 1.00× |
| cursor | 176.5 | 221.3 | 1.25× | 1.00× | 1.25× |
| scroll | 423.2 | 463.3 | 1.09× | 1.05× | 1.09× |
| region | 317.9 | 343.8 | 1.08× | 0.68× | 0.72× |

## Screens

Thrush matched the Node reference in 36 of 36 conditions. The Bun runtime matched it in 36 of 36, and libghostty-vt matched it in 32 of 36. The four libghostty-vt differences were on shell and Vim at 240 × 60. Both recordings were captured at 80 × 24, and Vim sets the scroll region to rows 1 to 24 (`ESC[1;24r`) on the alternate screen. When Vim leaves the alternate screen (`ESC[?1049l`), xterm and Thrush return to the main screen's own region, so the main screen still scrolls across all 60 rows. libghostty-vt keeps one region for both screens, so a line feed on the bottom row, below that region, doesn't scroll.

The smallest stream that shows it runs at 80 × 10:

```
ESC[?1049h ESC[1;5r ESC[?1049l ESC[10;1H a LF b
```

xterm and Thrush finish with `a` on row 9 and ` b` on row 10. libghostty-vt finishes with `ab` on row 10. At 80 × 24 the region already covers the whole screen, so all three cores agree. The affected runs do slightly less scrolling in libghostty-vt than in the other cores.

## Where Thrush spends its time

Shares of all samples in the [recorded profile](comparison-profile.json), taken at `f79a268` with 1,416 to 3,283 samples per workload. Each of the 20 functions with the most self time in a workload belongs to at most one category. Unclassified functions and the rest of the samples account for the remainder.

| Workload | Scrolling | Allocation and ownership | Cell writes | Parsing and dispatch | Receive, decode and scan | Top functions |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| shell | 5% | 12% | 31% | 6% | 23% | `Screen.writeRun` 16%, `receive` 11%, `TextScanner.decodeText<let A>` 9% |
| vim | 0% | 12% | 21% | 19% | 18% | `receive` 14%, `Row.writeASCII` 9%, `Style.applySGR` 8% |
| codex | 1% | 3% | 9% | 49% | 20% | `receive` 17%, `Style.applySGR` 12%, `Parser.readSequence` 10% |
| ascii | 15% | 9% | 39% | 0% | 26% | `Row.writeASCII` 28%, `TextScanner.endOfASCII` 17%, `Screen.writeASCII` 10% |
| sgr | 0% | 6% | 20% | 47% | 18% | `Style.applySGR` 32%, `Parser.endOfParameters` 15%, `receive` 14% |
| wide | 4% | 3% | 29% | 0% | 62% | `TextScanner.decodeText<let A>` 55%, `Screen.writeRun` 25%, `receive` 5% |
| cursor | 0% | 5% | 49% | 27% | 18% | `Row.set` 15%, `receive` 14%, `Row.writeASCII` 14% |
| scroll | 18% | 9% | 42% | 0% | 27% | `Row.writeASCII` 28%, `receive` 19%, `Screen.writeASCII` 12% |
| region | 47% | 4% | 25% | 1% | 18% | `_platform_memmove` 25%, `Row.writeASCII` 17%, `receive` 13% |

- **Scrolling** advances lines, appends history, clears recycled rows and rotates scroll regions. On the scroll region most of it is the memory move that rotating row values compiles to.
- **Allocation and ownership** is malloc, free, retain, release, uniqueness checks and hashing.
- **Cell writes** are the ASCII, scalar and run writers, erases and their blank fills.
- **Parsing and dispatch** covers the `Parser` outside `receive`, `Parameters`, `Terminal.perform` and SGR.
- **Receive, decode and scan** covers `Terminal.receive`, the ASCII scanner, UTF-8 decoding and width lookup, with whatever is inlined into them. `Parser.next`, the whole-sequence reader and `perform`'s family switch inline into `receive`, so their time counts here.

## Allocations

Allocation counts for one pass at 4 KiB chunks. The terminal starts each pass with empty screens and history.

| Workload | Thrush 80 × 24 | Thrush 240 × 60 | libghostty-vt 80 × 24 | libghostty-vt 240 × 60 |
| --- | ---: | ---: | ---: | ---: |
| shell | 3,783 | 4,045 | 134 | 140 |
| vim | 7,963 | 8,802 | 1,330 | 1,330 |
| codex | 3,318 | 3,318 | 475 | 477 |
| ascii | 1,035 | 1,071 | 2 | 9 |
| sgr | 3,083 | 3,191 | 6 | 15 |
| wide | 1,035 | 1,071 | 2 | 9 |
| cursor | 24 | 24 | 0 | 0 |
| scroll | 1,035 | 1,071 | 2 | 9 |
| region | 21 | 21 | 0 | 0 |

A row allocates its cells once, on its first write. A line feed, an erase or a region scroll clears a row in place, so once the screen and 1,000 rows of history fill, steady output stops allocating. Dense ASCII, wide text and scrolling settle at 1,035 allocations at 80 × 24, one for each row the screen and history hold plus a few for the terminal itself. Cursor addressing and the scroll region stay on the screen and allocate 24 and 21 times. A row's style list allocates when the row's first non-default style arrives and again when it grows to the row's width, so per-cell SGR adds 2,048 allocations while its 1 MiB fills the first 1,024 rows. Vim and Codex add style lists the same way. A row's cluster table allocates on the row's first combining mark and stays when the row clears. The shell recording puts an accent on 18,634 lines and allocates 3,783 times. Vim and the shell recording also ask for capabilities with XTGETTCAP 1,200 and 110 times, and listing each query's names allocates once. [Where Thrush loses time](#where-thrush-loses-time)

## Where Thrush loses time

At 80 × 24 in 4 KiB chunks Thrush trails libghostty-vt on two of the nine workloads. The profile and the code trace each gap to one cost. The [performance plan](../docs/plan.md#keeping-the-core-fast-and-simple) says which of them are worth closing.

| Workload | Thrush ÷ libghostty-vt | Where Thrush loses time |
| --- | ---: | --- |
| wide | 0.996× | Decoding and storing wide text |
| region | 0.72× | Rotating row values |

- **Decoding and storing wide text.** Thrush decodes a run before storing it, as libghostty-vt does, and retires about 13% more instructions per pass on wide text. `TextScanner.decodeText` takes 55% of samples and `Screen.writeRun` 25%. The gap is within the spread between rounds, and Thrush leads on wide text at 240 × 60.
- **Rotating row values.** Scrolling a region rotates the 64-byte `Row` values between its margins, and the memory move, `Array.rotate` and `Buffer.rotate` take 39% of samples on the scroll region. Thrush retires about 43% more instructions per pass there. libghostty-vt moves 8-byte row offsets instead.
