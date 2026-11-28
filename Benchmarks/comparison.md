# Comparison with other emulator cores

ThrushCore has to outrun the fastest emulator cores we can measure, doing the same work on the same machine. This benchmark feeds identical bytes to ThrushCore, libghostty-vt and @xterm/headless, checks that they finish with the same screen, and reports throughput and allocations. A separate [profile](#profile) shows where ThrushCore spends its time. [Recorded report](comparison.json) · [Recorded profile](comparison-profile.json)

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3 Benchmarks/comparison/run.py --output Benchmarks/comparison.json
```

The runner needs Node and Bun. It installs the [pinned reference](../Fixtures/reference/README.md), which supplies @xterm/headless. The first run downloads Zig and the libghostty-vt source release, checks both against pinned SHA-256 digests and builds the library into `.build/comparison/tools`. After that, a full run takes about a minute on the reference machine. Pass `--workloads ascii,vim --rounds 1` for a quick check.

## Where Thrush stands

- **Thrush led libghostty-vt in 15 of 18 conditions.** It led at both grids on the shell recording by 1.09–1.85×, Vim by 1.29–1.79×, Codex by 1.09–1.23×, dense ASCII by 1.17–1.30×, SGR by 1.38–1.54×, cursor addressing by 1.25–1.91× and scrolling by 1.13–1.47×. At 240 × 60 it also led on wide text by 1.05×.
- **Thrush trails on the scroll region.** It ran at 0.73× of libghostty-vt at 80 × 24 and 0.97× at 240 × 60. On wide text at 80 × 24 the two were even at 1.00×. [Where Thrush loses time](#where-thrush-loses-time)
- **Thrush ran faster than both @xterm/headless runtimes in every condition**, by 3.03–19.08×.
- **Screen checks.** Thrush and xterm under Bun matched the Node reference in all 18 conditions, and libghostty-vt in 16. [Screens](#screens)
- **Allocations.** Thrush recorded 21 to 7,854 allocations per workload and libghostty-vt recorded 0 to 1,374. [Allocations](#allocations)

## Identical work

Every core receives the same bytes at the same grid size with a 1,000-row history limit. Each workload runs at 80 × 24 and 240 × 60 and arrives in 4 KiB chunks. No core has an app attached, so replies to queries go nowhere. Each measured pass creates a fresh terminal outside the timed region, then feeds the whole workload.

- **libghostty-vt builds the full screen.** `ghostty_terminal_vt_write` drives cells, styles, cursor, modes, both screens and history.
- **History depth doesn't change its work.** libghostty-vt drops history a whole page at a time, so with the same 1,000-row limit it kept 578 to 964 rows where the others kept 1,000. Every line still scrolls into history, and a dropped page is reused for new rows, so its whole scroll pass allocated 2 times. A separate check on the scroll workload at 80 × 24 raised its limit to 2,000 rows. It kept 1,864 rows, more than Thrush, and ran at 384 to 403 MiB/s against 388 to 407 with the 1,000-row limit. Only an unlimited history, which keeps all 64,616 lines in new pages, slowed it, to 198 to 205 MiB/s.
- **libghostty-vt did less scrolling in two conditions.** Its shell and Vim runs at 240 × 60 retained the alternate screen’s scroll region. Thrush reached 1.79–1.85× of its throughput there. [Screens](#screens)

## Method

### Cores

- **ThrushCore** at the recorded revision, built with `swift build -c release`. `ThrushBench --workload` feeds it a `Span` of each chunk.
- **libghostty-vt 1.0.2**, built from its source release with Zig 0.17.1 and `-Doptimize=ReleaseFast`, then linked statically into `Benchmarks/comparison/ghostty.c`. The runner feeds bytes with `ghostty_terminal_vt_write` and reads the final screen through `ghostty_terminal_grid_ref`. It lifts the default scrollback byte cap so history is limited by rows alone, like the other cores.
- **@xterm/headless 6.0.0** with @xterm/addon-unicode11 0.9.0 and Unicode 11 widths active, the [pinned reference](../Fixtures/reference/README.md). `Benchmarks/comparison/xterm.mjs` runs it under Node 22.18.0 and Bun 1.4.6, and each condition counts the faster runtime. It feeds bytes through `writeSync` on the terminal's core. The public `write` queues the same bytes and parses them in 12 ms slices between timers, so the synchronous call measures parsing and screen updates in the calling process.

### Timing

Each of 5 rounds runs every core once per workload and grid, in a freshly shuffled order, so load on a shared machine falls on all of them alike. Each run is a new process with 3 warmup passes and 3 measured passes. Rates come from the median wall time of the 15 measured passes. The ratio columns divide Thrush's throughput by the other core's, so a ratio below 1 means Thrush was slower. Each ratio pairs the cores within a round, which shared that round's load, and reports the median of those paired ratios with their range in parentheses. The JSON also records each round's median wall time.

### Screen checks

At the end of each run every core reports its visible rows, cursor, active screen and history depth. The runner compares them with xterm under Node, after trimming trailing spaces and clamping a cursor that is waiting to wrap to the last column. libghostty-vt's history depth is recorded but not compared, as [Identical work](#identical-work) explains. The conformance suite checks cell attributes.

### Allocations

A separate pass for ThrushCore and libghostty-vt runs with `Benchmarks/comparison/allocations.c` inserted. It interposes the malloc family, including the typed and zone variants, and anonymous `mmap`, and counts only the outermost call on each thread. Each count covers one measured pass after one warmup. The JavaScript garbage collector manages xterm's memory, so it isn't counted.

### Profile

`Benchmarks/comparison/profile.py` builds ThrushBench, samples ThrushCore with `sample` for 3 seconds on each workload at 80 × 24, and ranks functions by self time. The [Comparison profile workflow](../.github/workflows/comparison-profile.yml) runs it on a hosted Mac and uploads the report. That runner is a 3-core Apple M1 (Virtual), so the profile's shares of time carry over to the reference machine but its rates don't. Inlined code counts toward the function it was inlined into, which is why `Terminal.write` carries much of the per-byte work.

## Workloads

Each workload is about 1 MiB, generated deterministically by `Benchmarks/comparison/workloads.py`. The recorded workloads repeat the program output of committed fixtures in `Fixtures/recordings`, without their resizes, until they reach 1 MiB.

| Workload | What it holds | Bytes | SHA-256 prefix |
| --- | --- | ---: | --- |
| shell | `shell-log`: prompts, a long build log with accented and CJK paths, and a short Vim edit | 1,145,837 | `767d3f9e1f704d06` |
| vim | `vim-edit`, `vim-resume`, `vim-swift-dark` and `vim-swift-light`: full-screen editing and highlighted Swift | 1,070,864 | `915274355d5904a6` |
| codex | `codex-session`: a Codex session's styled, cursor-addressed output | 1,066,156 | `ee53772a6d921fcf` |
| ascii | Words in lines of 8 to 200 characters ending in CRLF, so long lines wrap | 1,048,634 | `27549df120fad47a` |
| sgr | 80-cell lines with an SGR before every cell, mixing basic, 256-color and RGB colors with attributes | 1,049,367 | `15e74931214ff067` |
| wide | Lines of CJK ideographs, emoji and words, wrapping wide glyphs at the margin | 1,048,616 | `3e10e33e7379faf1` |
| cursor | Frames that clear the screen, then write 120 words at random positions with occasional EL and ED | 1,049,493 | `41ac6cba6f3aa9bf` |
| scroll | Short numbered lines, so nearly every byte run ends in a scroll into history | 1,048,587 | `3fc3d209db465438` |
| region | 64 lines scrolled inside rows 2 to 20, then a reverse-video status line on row 24 | 1,049,715 | `80c5a714c8ae5cc8` |

## Results

Recorded November 28, 2026 at 09:32 UTC on an Apple M1 Max with 10 cores, macOS 27.2.1 and Apple Swift version 6.4.2. The one-minute load average was 4 at the start and 3 at the end. Within each round the cores ran back to back. The ranges show how their relative rates varied. [Measured source a33dbed](https://github.com/lostintangent/thrush/commit/a33dbed6e64a7abf1f68df55c817514e88216e57)

| Workload | Grid | Thrush MiB/s | libghostty-vt MiB/s | xterm MiB/s | Thrush ÷ libghostty-vt | Thrush ÷ xterm |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| shell | 80 × 24 | 339 | 315 | 56 (Node) | 1.09× (1.02–1.41) | 6.02× (5.71–6.44) |
| shell | 240 × 60 | 337 | 182 | 52 (Node) | 1.85× (1.72–1.85) | 6.44× (6.01–6.56) |
| vim | 80 × 24 | 462 | 358 | 60 (Bun) | 1.29× (1.28–1.31) | 7.61× (7.37–8.46) |
| vim | 240 × 60 | 432 | 242 | 34 (Bun) | 1.79× (1.71–1.85) | 12.43× (12.13–13.05) |
| codex | 80 × 24 | 291 | 267 | 64 (Bun) | 1.09× (1.05–1.15) | 4.52× (4.35–4.89) |
| codex | 240 × 60 | 288 | 235 | 60 (Bun) | 1.23× (1.23–1.32) | 4.84× (4.72–5.12) |
| ascii | 80 × 24 | 1235 | 1065 | 86 (Node) | 1.17× (1.06–1.20) | 14.29× (13.59–14.78) |
| ascii | 240 × 60 | 1514 | 1163 | 122 (Bun) | 1.30× (1.28–1.33) | 12.47× (12.14–12.63) |
| sgr | 80 × 24 | 223 | 161 | 72 (Node) | 1.38× (1.36–1.43) | 3.03× (2.96–3.13) |
| sgr | 240 × 60 | 221 | 144 | 71 (Node) | 1.54× (1.52–1.55) | 3.07× (3.03–3.14) |
| wide | 80 × 24 | 356 | 354 | 82 (Node) | 1.00× (1.00–1.01) | 4.31× (4.24–4.40) |
| wide | 240 × 60 | 372 | 353 | 90 (Bun) | 1.05× (1.04–1.10) | 4.16× (4.12–4.37) |
| cursor | 80 × 24 | 221 | 176 | 47 (Bun) | 1.25× (1.24–1.26) | 4.70× (4.63–4.70) |
| cursor | 240 × 60 | 204 | 107 | 11 (Bun) | 1.91× (1.83–1.91) | 19.08× (18.83–19.21) |
| scroll | 80 × 24 | 478 | 424 | 64 (Bun) | 1.13× (1.12–1.20) | 7.33× (7.25–7.65) |
| scroll | 240 × 60 | 480 | 323 | 52 (Node) | 1.47× (1.46–1.56) | 8.96× (8.81–9.20) |
| region | 80 × 24 | 345 | 478 | 44 (Bun) | 0.73× (0.72–0.74) | 7.85× (7.77–8.06) |
| region | 240 × 60 | 345 | 355 | 31 (Bun) | 0.97× (0.91–0.98) | 10.15× (10.07–11.08) |

## Screens

libghostty-vt's screens differed on shell and Vim at 240 × 60. Both recordings were captured at 80 × 24, and Vim sets the scroll region to rows 1 to 24 (`ESC[1;24r`) on the alternate screen. When Vim leaves the alternate screen (`ESC[?1049l`), xterm and Thrush return to the main screen's own region, so the main screen still scrolls across all 60 rows. libghostty-vt keeps one region for both screens, so a line feed on the bottom row, below that region, doesn't scroll.

The smallest stream that shows it runs at 80 × 10:

```
ESC[?1049h ESC[1;5r ESC[?1049l ESC[10;1H a LF b
```

xterm and Thrush finish with `a` on row 9 and ` b` on row 10. libghostty-vt finishes with `ab` on row 10. At 80 × 24 the region already covers the whole screen, so all three cores agree. The affected runs do slightly less scrolling in libghostty-vt than in the other cores.

## Where Thrush spends its time

Shares of all samples in the [recorded profile](comparison-profile.json), taken at `a33dbed` with 1,420 to 2,313 samples per workload. Each of the 20 functions with the most self time in a workload belongs to at most one category. Unclassified functions and the rest of the samples account for the remainder.

| Workload | Scrolling | Allocation and ownership | Cell writes | Parsing and dispatch | Write loop, decode and scan | Top functions |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| shell | 3% | 13% | 34% | 7% | 20% | `Screen.print` 18%, `write` 10%, `TextScanner.decodeText<let A>` 8% |
| vim | 0% | 8% | 20% | 23% | 19% | `write` 15%, `Style.applySGR` 9%, `Row.writeASCII` 8% |
| codex | 0% | 3% | 9% | 52% | 21% | `write` 18%, `Style.applySGR` 12%, `Parser.readSequence` 10% |
| ascii | 13% | 10% | 42% | 0% | 27% | `Row.writeASCII` 30%, `TextScanner.endOfASCII` 18%, `Buffer.scroll` 13% |
| sgr | 0% | 7% | 19% | 46% | 20% | `Style.applySGR` 31%, `write` 16%, `Parser.endOfParameters` 15% |
| wide | 3% | 3% | 27% | 0% | 63% | `TextScanner.decodeText<let A>` 55%, `Screen.print` 22%, `write` 7% |
| cursor | 0% | 4% | 51% | 25% | 18% | `Row.writeASCII` 15%, `Row.set` 15%, `write` 13% |
| scroll | 18% | 8% | 42% | 0% | 29% | `Row.writeASCII` 29%, `write` 23%, `Buffer.scroll` 18% |
| region | 49% | 3% | 27% | 2% | 16% | `_platform_memmove` 26%, `Row.writeASCII` 20%, `write` 11% |

- **Scrolling** advances lines, appends history, clears recycled rows and rotates scroll regions. On the scroll region most of it is the memory move that rotating row values compiles to.
- **Allocation and ownership** is malloc, free, retain, release, uniqueness checks and hashing.
- **Cell writes** are the screen's print and erase operations, the row writers they call and their blank fills.
- **Parsing and dispatch** covers the `Parser` outside `write`, `Parameters`, `Terminal.perform` and SGR.
- **Write loop, decode and scan** covers `Terminal.write`, the ASCII scanner, UTF-8 decoding and width lookup, with whatever is inlined into them. `Parser.next`, the whole-sequence reader and `perform`'s family switch inline into `write`, so their time counts here.

## Allocations

Allocation counts for one pass. The terminal starts each pass with empty screens and history.

| Workload | Thrush 80 × 24 | Thrush 240 × 60 | libghostty-vt 80 × 24 | libghostty-vt 240 × 60 |
| --- | ---: | ---: | ---: | ---: |
| shell | 3,673 | 3,935 | 134 | 140 |
| vim | 6,987 | 7,854 | 1,374 | 1,374 |
| codex | 3,318 | 3,318 | 475 | 477 |
| ascii | 1,035 | 1,071 | 2 | 9 |
| sgr | 3,083 | 3,191 | 6 | 15 |
| wide | 1,035 | 1,071 | 2 | 9 |
| cursor | 24 | 24 | 0 | 0 |
| scroll | 1,035 | 1,071 | 2 | 9 |
| region | 21 | 21 | 0 | 0 |

A row allocates its cells once, on its first write. A line feed, an erase or a region scroll clears a row in place, so once the screen and 1,000 rows of history fill, steady output stops allocating. Dense ASCII, wide text and scrolling settle at 1,035 allocations at 80 × 24, one for each row the screen and history hold plus a few for the terminal itself. Cursor addressing and the scroll region stay on the screen and allocate 24 and 21 times. A row's style list allocates when the row's first non-default style arrives and again when it grows to the row's width, so per-cell SGR adds 2,048 allocations while its 1 MiB fills the first 1,024 rows. Vim and Codex add style lists the same way. A row's cluster table allocates on the row's first combining mark and stays when the row clears. The shell recording puts an accent on 18,634 lines and allocates 3,673 times. [Where Thrush loses time](#where-thrush-loses-time)

## Where Thrush loses time

At 80 × 24 Thrush trails libghostty-vt on the scroll region and is even with it on wide text. The profile and the code trace each gap to one cost. The [performance plan](../docs/plan.md#keeping-the-core-fast-and-simple) says which of them are worth closing.

| Workload | Thrush ÷ libghostty-vt | Where Thrush loses time |
| --- | ---: | --- |
| wide | 1.00× | Decoding wide text |
| region | 0.73× | Rotating row values |

- **Decoding wide text.** Thrush decodes a run before printing it, as libghostty-vt does, and retires about 13% more instructions per pass on wide text. `TextScanner.decodeText` takes 55% of samples and the screen's print of a run 22%. The two cores are even here, within the spread between rounds, and Thrush leads on wide text at 240 × 60.
- **Rotating row values.** Scrolling a region rotates the 64-byte `Row` values between its margins, and the memory move, `Array.rotate` and `Buffer.rotate` take 40% of samples on the scroll region. Thrush retires about 46% more instructions per pass there. libghostty-vt moves 8-byte row offsets instead.
