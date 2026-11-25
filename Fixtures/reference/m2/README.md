# Shell and Vim replay references

The two `*.capture.json` files contain real reads, writes and window changes from disposable PTYs. Each read retains its byte boundary and its monotonic microsecond offset from session startup. The recorded shell is `/bin/bash --noprofile --norc -i` with `TERM=xterm-256color`, a temporary home, no history file, a fixed `thrush$ ` prompt and the `en_US.UTF-8` locale. The editor is the system Vim 9.1, patches 1–1752. Its complete configuration and initial scratch-file contents are in `capture.py`. Vim uses its ordinary xterm-256color probe sequences. A live, pinned headless xterm processes each PTY read and writes its automatic replies back to Vim. Each capture records the Vim and Clang compiler versions.

- **shell-log** runs Clang on a scratch translation unit with 1,030 separate headers. The build logger numbers and colors each actual include trace. Header paths contain CJK, combining text and occasional longer components. The logger checks that the compiler visited the expected headers in order and produced a nonempty object. The shell starts with headers 0001–1030 on the 80 × 24 grid. It resizes to 40 × 32, then 80 × 14. At 80 × 14 it compiles another 640 headers (1031–1670) before resizing back to 80 × 24. It compiles a final 24 headers (1671–1694) before opening Vim and repeating the same resizes on the alternate screen.
- **vim-edit** opens a two-line scratch file, enters Insert mode, pastes text containing a wide character and a combining mark, exits Insert mode, resizes, saves and returns to the shell. The recorder checks the saved file contents and the return of the original prompt before retaining the trace.
- **shell-edges** is a scripted byte transcript for small-screen and split-input cases. It covers the two-column minimum, pending-wrap cursor reports, reflow next to wide cells, foreground and background colors, alternate-screen clipping, an interrupted UTF-8 scalar, a 16 KiB unknown OSC split at its terminator, mode-dependent arrows and bracketed paste.
- **prompt-bom** starts a fresh 80 × 24 terminal with `EF BB BF`, the eight printable bytes of `thrush$ `, and a cursor query. The reference reports row 1, column 9.

The reference generator checks that all three normal-screen resizes start with 1,000 history rows and that the shell again has 1,000 before Vim starts. The active normal history after each resize is 1,000, 496 and 990 rows respectively. On the alternate screen, active history remains empty. The saved normal buffer has 1,000, 1,000 and 497 rows before those alternate resizes. After returning to the shell it has 487 rows.

At startup, each recorded Vim issues two cursor reports and a secondary device-attributes query. The live reference sends `ESC [ 2 ; 2 R`, `ESC [ 3 ; 1 R` and `ESC [ > 0 ; 276 ; 0 c` in sequence. Vim then requests the cursor-blink setting with `CSI ? 12 $ p` and receives `CSI ? 12 ; 2 $ y`. The OSC 10/11 palette queries and DCS termcap queries produced zero reply bytes in this headless reference. Vim saved the scratch file and returned to the prompt with these exchanges.

## Reproduce the reference files

Use the Toy Box checkout at `b9d0eca3c5f4e9036e58327ba633eff52474bb92` with its locked dependencies installed. From Thrush, run the generator against the checked-in PTY recordings.

```sh
NODE_PATH="$PWD/../toy-box/node_modules/@xterm/xterm/src" bun Fixtures/reference/m2/generate.mjs ../toy-box
shasum -a 256 Fixtures/replays/*.json
```

The generator reads the pinned server's emulator configuration, xterm-headless 6.0.0 and Unicode 11 addon 0.9.0. It feeds the output bytes into xterm in recorded order. It obtains replies via `onData`, encodes special keys with xterm's browser keyboard evaluator, and uses xterm's paste conversion and bracket helpers. In each real recording, the resulting input and automatic reply bytes must match their separate capture fields, including reads that produced no reply. It also verifies the benchmark's 1,048,640-byte ASCII stream at all three grid sizes in 4 KiB writes. [Server emulator](https://github.com/lostintangent/toy-box/blob/b9d0eca3c5f4e9036e58327ba633eff52474bb92/src/features/terminal/model/emulator.ts) · [Pinned packages](https://github.com/lostintangent/toy-box/blob/b9d0eca3c5f4e9036e58327ba633eff52474bb92/bun.lock)

To record a new local shell and Vim session, run `python3 Fixtures/reference/m2/capture.py ../toy-box` and then regenerate the references. New recordings reflect the machine's PTY read boundaries, timing and Vim version. Regenerating from the checked-in captures produces identical bytes and hashes. Both steps use local temporary files and processes. The Swift test suite reads the bundled JSON directly.

## Replay format

Each version-1 JSON file contains its initial grid, ordered events, and two tables of reference cells and rows. An event can supply a grid size, base64 PTY output, semantic input with its expected wire bytes, replies, or a checkpoint. Apply a resize, consume the PTY output and compare any reply before inspecting the checkpoint. Key and paste events go to the encoder. The captured PTY supplies the echo. A nonempty `observedReply` in a capture is the exact automatic reply the live reference wrote to the PTY, with its own `replyOffsetMicroseconds`. The regenerated `reply` is checked against that observation. Each generated real replay records the SHA-256 of its capture file.

`normalHistoryRowsBefore` and `historyRowsBefore` record the normal-buffer and active-buffer counts immediately before each resize.

Every checkpoint stores the renderer's effective `cursorShape` and `cursorBlink`. The separate `modes.cursorBlink` field records the option that mode query 12 reports. The `shell-edges` cursor sequence exercises all six DECSCUSR styles, the blink option while a style is active, and explicit-zero and omitted-parameter resets. The pinned xterm also retains the preceding shape for parameters 7 and 8 and applies their odd/even blink setting.

A checkpoint stores the effective grid, raw cursor row and column, active screen and modes, then indexes every history and viewport row in display order. Each row stores its visible text, soft-wrap flag, and repeated count/cell-index pairs. Its omitted tail contains empty single-column default cells. A cell includes exact UTF-8 text, display width, foreground, background and flags. Colors use −1 for the default, 0–255 for indexed colors, and 256 plus packed RGB for true color. Flags encode bold, dim, italic, underline, blink, inverse, invisible and strikethrough from the least significant bit. Empty cells, printed spaces and wide continuation cells therefore remain distinguishable. Visible text and cells stop at the active grid width, including on the alternate screen.
