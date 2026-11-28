# Comparison with other emulator cores

ThrushCore has to outrun the fastest emulator cores we can measure, doing the same work on the same machine. This benchmark feeds identical bytes to ThrushCore, libghostty-vt and @xterm/headless, checks that they finish with the same screen, and reports throughput and allocations. A separate [profile](#profile) shows where ThrushCore spends its time. [Recorded report](comparison.json) · [Recorded profile](comparison-profile.json)

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3 scripts/comparison/run.py --output Benchmarks/comparison.json
```

The runner needs Node and Bun. It installs the [pinned reference](../Fixtures/reference/README.md), which supplies @xterm/headless. The first run downloads Zig and the libghostty-vt source release, checks both against pinned SHA-256 digests and builds the library into `.build/comparison/tools`. After that, a full run takes about 2 minutes on the reference machine. Pass `--workloads ascii,vim --rounds 1` for a quick check.

## Where Thrush stands

- **Thrush led libghostty-vt in 15 of 18 conditions.** It led at both grids on the shell recording by 1.10–1.85×, Vim by 1.30–1.76×, Codex by 1.09–1.23×, dense ASCII by 1.17–1.33×, SGR by 1.40–1.54×, cursor addressing by 1.24–1.90× and scrolling by 1.13–1.54×. At 240 × 60 it also led on wide text by 1.07×.
- **Thrush trails on the scroll region.** It ran at 0.72× of libghostty-vt at 80 × 24 and 0.97× at 240 × 60. On wide text at 80 × 24 it ran at 0.998×, within the spread between rounds. [Where Thrush loses time](#where-thrush-loses-time)
- **Thrush ran faster than both @xterm/headless runtimes in every condition**, by 3.00–18.74×.
- **Screen checks.** Thrush and xterm under Bun matched the Node reference in all 18 conditions, and libghostty-vt in 16. [Screens](#screens)
- **Allocations.** Thrush recorded 21 to 7,854 allocations per workload and libghostty-vt recorded 0 to 1,374. [Allocations](#allocations)

## Identical work

Every core receives the same bytes at the same grid size with a 1,000-row history limit. Each workload runs at 80 × 24 and 240 × 60 and arrives in 4 KiB chunks. No core has an app attached, so replies to queries go nowhere. Each measured pass creates a fresh terminal outside the timed region, then feeds the whole workload.

- **libghostty-vt builds the full screen.** `ghostty_terminal_vt_write` drives cells, styles, cursor, modes, both screens and history.
- **History depth doesn't change its work.** libghostty-vt drops history a whole page at a time, so with the same 1,000-row limit it kept 578 to 964 rows where the others kept 1,000. Every line still scrolls into history, and a dropped page is reused for new rows, so its whole scroll pass allocated 2 times. A separate check on the scroll workload at 80 × 24 raised its limit to 2,000 rows. It kept 1,864 rows, more than Thrush, and ran at 391 to 401 MiB/s against 389 to 400 with the 1,000-row limit. Only an unlimited history, which keeps all 64,616 lines in new pages, slowed it, to 174 to 182 MiB/s.
- **libghostty-vt did less scrolling in two conditions.** Its shell and Vim runs at 240 × 60 retained the alternate screen’s scroll region. Thrush reached 1.76–1.85× of its throughput there. [Screens](#screens)

## Method

### Cores

- **ThrushCore** at the recorded revision, built with `swift build -c release`. `ThrushBench --workload` feeds it a `Span` of each chunk.
- **libghostty-vt 1.0.2**, built from its source release with Zig 0.17.1 and `-Doptimize=ReleaseFast`, then linked statically into `scripts/comparison/ghostty.c`. The runner feeds bytes with `ghostty_terminal_vt_write` and reads the final screen through `ghostty_terminal_grid_ref`. It lifts the default scrollback byte cap so history is limited by rows alone, like the other cores.
- **@xterm/headless 6.0.0** with @xterm/addon-unicode11 0.9.0 and Unicode 11 widths active, the [pinned reference](../Fixtures/reference/README.md). `scripts/comparison/xterm.mjs` runs it under Node 22.18.0 and Bun 1.4.6, and each condition counts the faster runtime. It feeds bytes through `writeSync` on the terminal's core. The public `write` queues the same bytes and parses them in 12 ms slices between timers, so the synchronous call measures parsing and screen updates in the calling process.

### Timing

Each of 5 rounds runs every core once per workload and grid, in a freshly shuffled order, so load on a shared machine falls on all of them alike. Each run is a new process with 3 warmup passes and 3 measured passes. Rates come from the median wall time of the 15 measured passes. The ratio columns divide Thrush's throughput by the other core's, so a ratio below 1 means Thrush was slower. Each ratio pairs the cores within a round, which shared that round's load, and reports the median of those paired ratios with their range in parentheses. The JSON also records each round's median wall time.

### Screen checks

At the end of each run every core reports its visible rows, cursor, active screen and history depth. The runner compares them with xterm under Node, after trimming trailing spaces and clamping a cursor that is waiting to wrap to the last column. libghostty-vt's history depth is recorded but not compared, as [Identical work](#identical-work) explains. The conformance suite checks cell attributes.

### Allocations

A separate pass for ThrushCore and libghostty-vt runs with `scripts/comparison/allocations.c` inserted. It interposes the malloc family, including the typed and zone variants, and anonymous `mmap`, and counts only the outermost call on each thread. Each count covers one measured pass after one warmup. The JavaScript garbage collector manages xterm's memory, so it isn't counted.

### Profile

`scripts/comparison/profile.py` builds ThrushBench, samples ThrushCore with `sample` for 3 seconds on each workload at 80 × 24, and ranks functions by self time. The [Comparison profile workflow](../.github/workflows/comparison-profile.yml) runs it on a hosted Mac and uploads the report. That runner is a 3-core Apple M1 (Virtual), so the profile's shares of time carry over to the reference machine but its rates don't. Inlined code counts toward the function it was inlined into, which is why `Terminal.write` carries much of the per-byte work.

## Workloads

Each workload is about 1 MiB, generated deterministically by `scripts/comparison/workloads.py`. The recorded workloads repeat the program output of committed fixtures in `Fixtures/recordings`, without their resizes, until they reach 1 MiB.

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

Recorded November 26, 2026 at 21:30 UTC on an Apple M1 Max with 10 cores, macOS 27.2.1 and Apple Swift version 6.4.2. The one-minute load average was 6 at the start and 9 at the end. Within each round the cores ran back to back. The ranges show how their relative rates varied. [Measured source b3d9f29](https://github.com/lostintangent/thrush/commit/b3d9f2945c4f89f0ce294e6691a41c2f1d7d372e)

| Workload | Grid | Thrush MiB/s | libghostty-vt MiB/s | xterm MiB/s | Thrush ÷ libghostty-vt | Thrush ÷ xterm |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| shell | 80 × 24 | 329 | 300 | 54 (Node) | 1.10× (1.07–1.12) | 6.19× (5.99–6.25) |
| shell | 240 × 60 | 325 | 174 | 51 (Node) | 1.85× (1.75–1.91) | 6.51× (6.03–6.66) |
| vim | 80 × 24 | 457 | 343 | 55 (Node) | 1.30× (1.30–1.35) | 8.20× (8.15–8.49) |
| vim | 240 × 60 | 417 | 235 | 32 (Bun) | 1.76× (1.76–1.83) | 13.01× (11.91–13.13) |
| codex | 80 × 24 | 282 | 260 | 62 (Bun) | 1.09× (1.03–1.14) | 4.49× (4.33–4.56) |
| codex | 240 × 60 | 277 | 234 | 49 (Bun) | 1.23× (1.18–1.28) | 5.60× (4.78–6.88) |
| ascii | 80 × 24 | 1230 | 1056 | 85 (Node) | 1.17× (1.15–1.19) | 14.36× (13.75–15.30) |
| ascii | 240 × 60 | 1447 | 1109 | 117 (Bun) | 1.33× (1.29–1.35) | 12.62× (11.77–15.66) |
| sgr | 80 × 24 | 213 | 151 | 69 (Node) | 1.40× (1.38–1.48) | 3.09× (3.03–3.16) |
| sgr | 240 × 60 | 214 | 141 | 72 (Node) | 1.54× (1.51–1.60) | 3.00× (2.97–3.07) |
| wide | 80 × 24 | 345 | 346 | 80 (Node) | 1.00× (0.97–1.03) | 4.30× (4.20–4.41) |
| wide | 240 × 60 | 372 | 346 | 88 (Bun) | 1.07× (1.06–1.10) | 4.26× (4.07–4.47) |
| cursor | 80 × 24 | 212 | 171 | 45 (Bun) | 1.24× (1.20–1.32) | 4.68× (4.57–4.98) |
| cursor | 240 × 60 | 203 | 106 | 11 (Bun) | 1.90× (1.80–1.98) | 18.74× (18.44–19.22) |
| scroll | 80 × 24 | 472 | 417 | 64 (Bun) | 1.13× (1.11–1.16) | 7.43× (7.22–7.91) |
| scroll | 240 × 60 | 472 | 297 | 52 (Node) | 1.54× (1.11–1.60) | 8.97× (5.55–9.41) |
| region | 80 × 24 | 333 | 464 | 43 (Bun) | 0.72× (0.70–0.79) | 7.92× (7.59–12.50) |
| region | 240 × 60 | 339 | 350 | 33 (Bun) | 0.97× (0.96–1.10) | 10.39× (10.04–10.66) |

## Screens

libghostty-vt's screens differed on shell and Vim at 240 × 60. Both recordings were captured at 80 × 24, and Vim sets the scroll region to rows 1 to 24 (`ESC[1;24r`) on the alternate screen. When Vim leaves the alternate screen (`ESC[?1049l`), xterm and Thrush return to the main screen's own region, so the main screen still scrolls across all 60 rows. libghostty-vt keeps one region for both screens, so a line feed on the bottom row, below that region, doesn't scroll.

The smallest stream that shows it runs at 80 × 10:

```
ESC[?1049h ESC[1;5r ESC[?1049l ESC[10;1H a LF b
```

xterm and Thrush finish with `a` on row 9 and ` b` on row 10. libghostty-vt finishes with `ab` on row 10. At 80 × 24 the region already covers the whole screen, so all three cores agree. The affected runs do slightly less scrolling in libghostty-vt than in the other cores.

## Where Thrush spends its time

Shares of all samples in the [recorded profile](comparison-profile.json), taken at `b3d9f29` with 1,758 to 2,113 samples per workload. Each of the 20 functions with the most self time in a workload belongs to at most one category. Unclassified functions and the rest of the samples account for the remainder.

| Workload | Scrolling | Allocation and ownership | Cell writes | Parsing and dispatch | Write loop, decode and scan | Top functions |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| shell | 4% | 11% | 33% | 6% | 22% | `Screen.print` 17%, `write` 11%, `TextScanner.decodeText<let A>` 9% |
| vim | 1% | 9% | 22% | 20% | 20% | `write` 15%, `Row.writeASCII` 8%, `Style.applySGR` 7% |
| codex | 0% | 2% | 12% | 49% | 20% | `write` 17%, `Style.applySGR` 10%, `Parser.readSequence` 9% |
| ascii | 14% | 10% | 39% | 0% | 28% | `Row.writeASCII` 29%, `TextScanner.endOfASCII` 19%, `Buffer.scroll` 13% |
| sgr | 0% | 7% | 23% | 45% | 18% | `Style.applySGR` 29%, `Parser.endOfParameters` 16%, `write` 15% |
| wide | 3% | 2% | 26% | 0% | 64% | `TextScanner.decodeText<let A>` 57%, `Screen.print` 22%, `write` 6% |
| cursor | 0% | 3% | 50% | 26% | 18% | `Row.set` 14%, `Row.writeASCII` 14%, `write` 14% |
| scroll | 16% | 10% | 42% | 0% | 28% | `Row.writeASCII` 29%, `write` 22%, `Buffer.scroll` 16% |
| region | 46% | 5% | 27% | 2% | 17% | `_platform_memmove` 25%, `Row.writeASCII` 19%, `write` 13% |

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

At 80 × 24 Thrush trails libghostty-vt on two of the nine workloads. The profile and the code trace each gap to one cost. The [performance plan](../docs/plan.md#keeping-the-core-fast-and-simple) says which of them are worth closing.

| Workload | Thrush ÷ libghostty-vt | Where Thrush loses time |
| --- | ---: | --- |
| wide | 0.998× | Decoding wide text |
| region | 0.72× | Rotating row values |

- **Decoding wide text.** Thrush decodes a run before printing it, as libghostty-vt does, and retires about 13% more instructions per pass on wide text. `TextScanner.decodeText` takes 57% of samples and the screen's print of a run 22%. The two cores are even here, within the spread between rounds, and Thrush leads on wide text at 240 × 60.
- **Rotating row values.** Scrolling a region rotates the 64-byte `Row` values between its margins, and the memory move, `Array.rotate` and `Buffer.rotate` take 39% of samples on the scroll region. Thrush retires about 47% more instructions per pass there. libghostty-vt moves 8-byte row offsets instead.
