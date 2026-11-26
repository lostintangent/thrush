# Comparison with other emulator cores

ThrushCore has to outrun the fastest emulator cores we can measure, doing the same work on the same machine. This benchmark feeds identical bytes to ThrushCore, libghostty-vt and @xterm/headless, checks that they finish with the same screen, and reports throughput and allocations. A separate profile shows where ThrushCore spends its time. [Recorded report](comparison.json) · [Recorded profile](comparison-profile.json)

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3 scripts/comparison/run.py --output Benchmarks/comparison.json
```

The runner needs Node and Bun. It installs the [pinned reference](../Fixtures/reference/README.md), which supplies @xterm/headless. The first run downloads Zig and the libghostty-vt source release, checks both against pinned SHA-256 digests and builds the library into `.build/comparison/tools`. After that, a full run takes about 2 minutes on the reference machine. Pass `--workloads ascii,vim --rounds 1` for a quick check. The profile comes from the [Comparison profile workflow](../.github/workflows/comparison-profile.yml). [Profile](#profile)

## Where Thrush stands

- **Thrush led libghostty-vt in 22 of 36 conditions.** It led in every condition on Vim by 1.22–1.70×, dense ASCII by 1.08–1.26×, SGR by 1.37–1.56× and cursor addressing by 1.01–1.55×. At 240 × 60 it also led on the shell recording by 1.55–1.57×, Codex by 1.01–1.02× and scrolling by 1.25–1.30×. [Screens](#screens)
- **The widest gaps are at 80 × 24.** Thrush ran at 0.69–0.70× of libghostty-vt on the scroll region, 0.77–0.79× on wide text and 0.88–0.89× on Codex. [Where Thrush loses time](#where-thrush-loses-time)
- **Thrush ran faster than both @xterm/headless runtimes in every condition**, by 3.01–15.48×.
- **Screen checks.** Thrush matched the Node reference in 36 of 36 conditions. The Bun runtime matched it in 36 of 36, and libghostty-vt matched it in 32 of 36. [Screens](#screens)
- **Allocations.** At 4 KiB, Thrush recorded 21 to 7,661 allocations per workload and libghostty-vt recorded 0 to 1,330. [Allocations](#allocations)

Since the [previous report](#change-since-the-previous-report), Thrush's ratio to libghostty-vt rose in 24 of 36 conditions. At 80 × 24 in 4 KiB chunks, the shell recording went from 0.71× to 0.92× and the scroll region went from 0.68× to 0.70×.

## Identical work

Every core receives the same bytes at the same grid size with a 1,000-row history limit. Each workload runs at 80 × 24 and 240 × 60, and arrives either in 4 KiB chunks or as one buffer. No core has an app attached, so replies to queries go nowhere. Each measured pass creates a fresh terminal outside the timed region, then feeds the whole workload.

- **libghostty-vt builds the full screen.** `ghostty_terminal_vt_write` drives cells, styles, cursor, modes, both screens and history. Its final visible rows, cursor and active screen matched the Node reference in 32 of 36 conditions. The comparison checks visible text, cursor position and the active buffer. It also checks history depth for Thrush and both JavaScript runtimes. The conformance suite checks cell attributes. At 80 × 24 in 4 KiB chunks its throughput was 1,012 MiB/s on plain text and 147 MiB/s on per-cell SGR.
- **History depth doesn't change its work.** libghostty-vt drops history a whole page at a time, so with the same 1,000-row limit it kept 578 to 964 rows where the others kept 1,000. Every line still scrolls into history, and a dropped page is reused for new rows, so its whole scroll pass allocated 2 times. A separate check on the scroll workload at 80 × 24 raised its limit to 2,000 rows. It kept 1,864 rows, more than Thrush, and ran at 391 to 401 MiB/s against 389 to 400 with the 1,000-row limit. Only an unlimited history, which keeps all 64,616 lines in new pages, slowed it, to 174 to 182 MiB/s.
- **libghostty-vt did less scrolling in four conditions.** Its large-grid shell and Vim runs retained the alternate screen’s scroll region. Thrush reached 1.55–1.70× of its throughput in these conditions. [Screens](#screens)

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

Recorded November 26, 2026 at 01:22 UTC on an Apple M1 Max with 10 cores, macOS 27.2.1 and Apple Swift version 6.4.2. The one-minute load average was 3 at the start and 5 at the end. Within each round the cores ran back to back. The ranges show how their relative rates varied. [Measured source 26cf81b](https://github.com/lostintangent/thrush/commit/26cf81bc064ee54912a961367472e7e8a722eb11)

| Workload | Grid | Chunks | Thrush MiB/s | libghostty-vt MiB/s | xterm MiB/s | Thrush ÷ libghostty-vt | Thrush ÷ xterm |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| shell | 80 × 24 | 4 KiB | 275 | 306 | 56 (Node) | 0.92× (0.68–0.93) | 5.01× (3.61–5.11) |
| shell | 80 × 24 | Whole | 285 | 306 | 56 (Node) | 0.93× (0.90–0.94) | 4.97× (4.95–5.09) |
| shell | 240 × 60 | 4 KiB | 277 | 176 | 53 (Node) | 1.55× (1.53–1.62) | 5.27× (5.14–5.76) |
| shell | 240 × 60 | Whole | 281 | 179 | 53 (Node) | 1.57× (1.37–1.61) | 5.30× (4.53–5.98) |
| vim | 80 × 24 | 4 KiB | 442 | 360 | 55 (Node) | 1.22× (1.19–1.23) | 7.94× (7.66–8.11) |
| vim | 80 × 24 | Whole | 451 | 362 | 57 (Bun) | 1.24× (1.19–1.25) | 7.99× (6.81–8.56) |
| vim | 240 × 60 | 4 KiB | 408 | 242 | 33 (Bun) | 1.67× (1.66–1.69) | 12.14× (11.92–12.56) |
| vim | 240 × 60 | Whole | 413 | 245 | 34 (Bun) | 1.70× (1.68–1.76) | 12.27× (12.09–12.53) |
| codex | 80 × 24 | 4 KiB | 238 | 273 | 64 (Bun) | 0.88× (0.86–0.89) | 3.68× (3.66–3.74) |
| codex | 80 × 24 | Whole | 240 | 264 | 67 (Bun) | 0.89× (0.87–0.93) | 3.55× (3.47–3.74) |
| codex | 240 × 60 | 4 KiB | 236 | 232 | 48 (Bun) | 1.01× (0.97–1.05) | 4.85× (3.90–4.95) |
| codex | 240 × 60 | Whole | 240 | 235 | 48 (Bun) | 1.02× (1.01–1.03) | 4.98× (4.83–5.07) |
| ascii | 80 × 24 | 4 KiB | 1160 | 1069 | 83 (Node) | 1.08× (1.05–1.10) | 13.62× (13.38–13.96) |
| ascii | 80 × 24 | Whole | 1185 | 1079 | 88 (Node) | 1.10× (1.09–1.11) | 13.29× (13.17–13.59) |
| ascii | 240 × 60 | 4 KiB | 1398 | 1150 | 118 (Bun) | 1.22× (1.16–1.26) | 11.78× (11.72–12.10) |
| ascii | 240 × 60 | Whole | 1415 | 1157 | 123 (Bun) | 1.26× (1.18–1.26) | 11.58× (11.13–11.86) |
| sgr | 80 × 24 | 4 KiB | 218 | 160 | 72 (Node) | 1.37× (1.33–1.41) | 3.01× (2.97–3.08) |
| sgr | 80 × 24 | Whole | 220 | 160 | 71 (Node) | 1.37× (1.34–1.39) | 3.02× (2.93–3.18) |
| sgr | 240 × 60 | 4 KiB | 217 | 141 | 70 (Node) | 1.56× (1.52–1.61) | 3.07× (3.05–3.20) |
| sgr | 240 × 60 | Whole | 215 | 139 | 70 (Node) | 1.56× (1.43–1.58) | 3.04× (2.85–3.21) |
| wide | 80 × 24 | 4 KiB | 271 | 351 | 78 (Node) | 0.77× (0.73–0.78) | 3.48× (3.07–3.64) |
| wide | 80 × 24 | Whole | 271 | 340 | 82 (Node) | 0.79× (0.77–0.81) | 3.27× (3.07–3.41) |
| wide | 240 × 60 | 4 KiB | 282 | 355 | 90 (Bun) | 0.80× (0.79–0.82) | 3.12× (3.07–3.16) |
| wide | 240 × 60 | Whole | 285 | 354 | 91 (Bun) | 0.80× (0.76–0.80) | 3.12× (3.02–3.16) |
| cursor | 80 × 24 | 4 KiB | 178 | 177 | 46 (Bun) | 1.01× (0.99–1.01) | 3.83× (3.77–3.90) |
| cursor | 80 × 24 | Whole | 177 | 177 | 47 (Bun) | 1.01× (0.99–1.04) | 3.76× (3.73–3.84) |
| cursor | 240 × 60 | 4 KiB | 164 | 104 | 11 (Bun) | 1.54× (1.52–1.60) | 15.48× (14.72–15.83) |
| cursor | 240 × 60 | Whole | 163 | 105 | 11 (Bun) | 1.55× (1.51–1.57) | 15.29× (14.20–15.66) |
| scroll | 80 × 24 | 4 KiB | 412 | 420 | 64 (Bun) | 0.97× (0.95–0.99) | 6.49× (6.23–6.82) |
| scroll | 80 × 24 | Whole | 414 | 419 | 64 (Bun) | 0.98× (0.94–1.01) | 6.38× (6.28–6.62) |
| scroll | 240 × 60 | 4 KiB | 410 | 325 | 53 (Node) | 1.25× (1.22–1.28) | 7.71× (7.54–7.79) |
| scroll | 240 × 60 | Whole | 413 | 318 | 53 (Node) | 1.30× (1.26–1.35) | 7.84× (7.80–8.05) |
| region | 80 × 24 | 4 KiB | 332 | 475 | 44 (Bun) | 0.70× (0.69–0.70) | 7.51× (7.15–7.61) |
| region | 80 × 24 | Whole | 331 | 480 | 44 (Bun) | 0.69× (0.69–0.70) | 7.55× (7.38–7.64) |
| region | 240 × 60 | 4 KiB | 332 | 358 | 33 (Bun) | 0.93× (0.91–0.96) | 10.16× (9.69–10.29) |
| region | 240 × 60 | Whole | 333 | 358 | 34 (Bun) | 0.93× (0.92–0.97) | 9.69× (9.27–9.78) |

## Change since the previous report

Both reports used the same host, toolchain, workload digests and benchmark settings. The rows compare 15-pass medians at 80 × 24 in 4 KiB chunks. Across all 36 conditions Thrush ran 0.92–1.33× as fast as in the previous report, while libghostty-vt's own rates moved by 0.96–1.04×. Rows now keep their cluster tables when they clear, and adding a mark looks its base up once. The shell recording ran 1.27× as fast and wide text 0.99×. In alternating ThrushBench pairs the shell log ran 1.06× and the shell workflow 1.04× as fast, and pointer input moved between 0.98× and 1.07× across code layouts. Full scrolling ran 0.96× here, but a direct cycle count of 6d664e6 against 26cf81b puts it at 1.01× at 80 × 24 and 1.04× at 240 × 60, so its drop is variation between reports. [Storage](../docs/emulator.md#storage) · [Previous report at 6d664e6](https://github.com/lostintangent/thrush/blob/e479fc622462e50dcbe772c9db3eb16f89ce2467/Benchmarks/comparison.json)

| Workload | 6d664e6 MiB/s | 26cf81b MiB/s | Change | 6d664e6 ÷ libghostty-vt | 26cf81b ÷ libghostty-vt |
| --- | ---: | ---: | ---: | ---: | ---: |
| shell | 217.1 | 275.3 | 1.27× | 0.71× | 0.92× |
| vim | 439.4 | 442.5 | 1.01× | 1.22× | 1.22× |
| codex | 242.9 | 238.1 | 0.98× | 0.88× | 0.88× |
| ascii | 1127.0 | 1160.0 | 1.03× | 1.06× | 1.08× |
| sgr | 219.8 | 217.6 | 0.99× | 1.38× | 1.37× |
| wide | 274.6 | 270.7 | 0.99× | 0.78× | 0.77× |
| cursor | 176.5 | 178.3 | 1.01× | 1.00× | 1.01× |
| scroll | 430.7 | 411.9 | 0.96× | 1.07× | 0.97× |
| region | 327.9 | 332.1 | 1.01× | 0.68× | 0.70× |

## Screens

Thrush matched the Node reference in 36 of 36 conditions. The Bun runtime matched it in 36 of 36, and libghostty-vt matched it in 32 of 36. The four libghostty-vt differences were on shell and Vim at 240 × 60. Both recordings were captured at 80 × 24, and Vim sets the scroll region to rows 1 to 24 (`ESC[1;24r`) on the alternate screen. When Vim leaves the alternate screen (`ESC[?1049l`), xterm and Thrush return to the main screen's own region, so the main screen still scrolls across all 60 rows. libghostty-vt keeps one region for both screens, so a line feed on the bottom row, below that region, doesn't scroll.

The smallest stream that shows it runs at 80 × 10:

```
ESC[?1049h ESC[1;5r ESC[?1049l ESC[10;1H a LF b
```

xterm and Thrush finish with `a` on row 9 and ` b` on row 10. libghostty-vt finishes with `ab` on row 10. At 80 × 24 the region already covers the whole screen, so all three cores agree. The affected runs do slightly less scrolling in libghostty-vt than in the other cores.

## Where Thrush spends its time

Shares of all samples in the [recorded profile](comparison-profile.json), taken at `26cf81b` with 1,497 to 6,225 samples per workload. Each of the 20 functions with the most self time in a workload belongs to at most one category. Unclassified functions and the rest of the samples account for the remainder.

| Workload | Scrolling | Allocation and ownership | Cell writes | Parsing and dispatch | Receive, decode and scan | Top functions |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| shell | 6% | 8% | 29% | 8% | 20% | `Row.writeASCII` 9%, `Screen.writeRun` 8%, `receive` 8% |
| vim | 0% | 11% | 23% | 26% | 16% | `EscapeParser.consumeEscape` 17%, `receive` 11%, `Row.writeASCII` 10% |
| codex | 0% | 3% | 9% | 56% | 13% | `EscapeParser.consumeEscape` 33%, `receive` 11%, `apply` 10% |
| ascii | 18% | 11% | 40% | 0% | 23% | `Row.writeASCII` 28%, `TextScanner.endOfASCII` 15%, `Buffer.advanceLine` 10% |
| sgr | 1% | 7% | 18% | 49% | 12% | `Style.applySGR` 28%, `EscapeParser.consumeEscape` 21%, `receive` 9% |
| wide | 4% | 2% | 26% | 0% | 66% | `closure #1 in writeNonASCII` 59%, `Screen.writeRun` 23%, `receive` 4% |
| cursor | 0% | 3% | 45% | 40% | 11% | `EscapeParser.consumeEscape` 30%, `Row.writeASCII` 13%, `Row.set` 12% |
| scroll | 24% | 7% | 41% | 0% | 25% | `Row.writeASCII` 27%, `receive` 19%, `Buffer.advanceLine` 13% |
| region | 45% | 5% | 26% | 3% | 18% | `_platform_memmove` 23%, `Row.writeASCII` 18%, `receive` 13% |

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

At 80 × 24 in 4 KiB chunks Thrush trails libghostty-vt on five of the nine workloads. The profile and the code trace each gap to one or two costs. The [performance plan](../docs/plan.md#closing-the-libghostty-vt-gap) turns each cost into a change.

| Workload | Thrush ÷ libghostty-vt | Where Thrush loses time |
| --- | ---: | --- |
| shell | 0.92× | Decoding one scalar per call |
| codex | 0.88× | Reading control parameters twice |
| wide | 0.77× | Decoding one scalar per call |
| scroll | 0.97× | Moving rows into history |
| region | 0.70× | Rotating row values |

- **Decoding one scalar per call.** On wide text the closure in `Terminal.writeNonASCII` takes 59% of samples and `Screen.writeRun` 23%. For each scalar the closure decodes it, looks up its width and hands it to the run through a call that isn't inlined. libghostty-vt decodes a whole printable run to UTF-32 and then fills the row. The shell recording's accented text takes the same route, where the two take 14% of samples.
- **Reading control parameters twice.** Parsing and dispatch take 56% of samples on Codex and 40% on cursor addressing, with `EscapeParser.consumeEscape` alone at 33% on Codex. The parser scans a complete header once to find its final byte. SGR borrows those bytes, but every other final, such as cursor position or erase, sends them through `ControlParameters.append` again one byte at a time, switching on its destination for each digit.
- **Moving rows into history.** A line feed at the bottom swaps the screen's top row into history's ring and clears the row it gets back, and `Buffer.advanceLine` and `History.append` take 24% of samples on full-screen scrolling. Each swap moves a 64-byte `Row` value between two arrays and checks that each is uniquely referenced. libghostty-vt keeps history and the screen in one list of pages, so its line feed adds a row without moving one.
- **Rotating row values.** Scrolling a region rotates the 64-byte `Row` values between its margins, and the memory move and `Array.rotate` take 36% of samples on the scroll region. libghostty-vt moves 8-byte row offsets instead.
