# Shell and Vim recording references

The `*.capture.json` files contain real reads, writes and window changes from disposable PTYs. Each read retains its byte boundary and its monotonic microsecond offset from session startup. The shell-log and Vim recordings use `/bin/bash --noprofile --norc -i` with `TERM=xterm-256color`, a temporary home, no history file, a fixed `thrush$ ` prompt and the `en_US.UTF-8` locale. The editor is the system Vim 9.1, patches 1–1752. Its complete configuration and initial scratch-file contents are in `capture.py`. Vim uses its ordinary xterm-256color probe sequences. The pinned server emulator processes each PTY read. Its parsed color requests use the pinned browser terminal’s color handler and ThemeService, and the recorder writes all automatic replies back to Vim in order. The shell-log and Vim captures record the Vim and Clang compiler versions.

- **shell-log** runs Clang on a scratch translation unit with 1,030 separate headers. The build logger numbers and colors each actual include trace. Header paths contain CJK, combining text and occasional longer components. The logger checks that the compiler visited the expected headers in order and produced a nonempty object. The shell starts with headers 0001–1030 on the 80 × 24 grid. It resizes to 40 × 32, then 80 × 14. At 80 × 14 it compiles another 640 headers (1031–1670) before resizing back to 80 × 24. It compiles a final 24 headers (1671–1694) before opening Vim and repeating the same resizes on the alternate screen.
- **vim-edit** opens a two-line scratch file, enters Insert mode, pastes text containing a wide character and a combining mark, exits Insert mode, resizes, saves and returns to the shell. The recorder checks the saved file contents and the return of the original prompt before retaining the trace.
- **shell-edges** combines a scripted transcript with an interactive Bash display recording. It covers the two-column minimum, pending-wrap cursor reports, reflow next to wide cells, foreground and background colors, alternate-screen clipping, an interrupted UTF-8 scalar, a 16 KiB unknown OSC split at its terminator, mode-dependent arrows and bracketed paste.
- **prompt-bom** starts a fresh 80 × 24 terminal with `EF BB BF`, the eight printable bytes of `thrush$ `, and a cursor query. The reference reports row 1, column 9.

The reference generator checks that all three normal-screen resizes start with 1,000 history rows and that the shell again has 1,000 before Vim starts. The active normal history after each resize is 1,000, 496 and 990 rows respectively. On the alternate screen, active history remains empty. The saved normal buffer has 1,000, 1,000 and 497 rows before those alternate resizes. After returning to the shell it has 487 rows.

At startup, each recorded Vim issues two cursor reports and a secondary device-attributes query. The live reference sends `ESC [ 2 ; 2 R`, `ESC [ 3 ; 1 R` and `ESC [ > 0 ; 276 ; 0 c` in sequence. Vim then requests the cursor-blink setting with `CSI ? 12 $ p` and receives `CSI ? 12 ; 2 $ y`. On the same startup read, OSC 11 and OSC 10 receive the default black background and white foreground, respectively. The pinned browser handler formats these as `rgb:0000/0000/0000` and `rgb:ffff/ffff/ffff`, terminated with ST. The server-only headless package omits color replies. The DCS termcap probes produced zero reply bytes. Vim saved the scratch file and returned to the prompt with these exchanges.

The small shell recording also checks erasing from the beginning of a line or display through the cursor. It records each visible cell, including the erase background and the text after the cursor.

## Bash line edits and formatted output

The last part of `shell-edges` replays `bash-display.capture.json`. It was recorded on a 16 × 25 PTY with GNU Bash 5.3.9, `TERM=xterm-256color`, a fresh home and Readline’s Emacs bindings. On two fresh prompts the recorder types `abcdef` and presses Ctrl-B three times. Each Ctrl-B produces one backspace on the PTY. Bash then emits a delete-character sequence for Ctrl-D and an insert-character sequence followed by `X` for the typed insertion. Ctrl-C cancels each edited command.

| Checkpoint | PTY output bytes | xterm visible row | Cursor (row, column), zero-based |
| --- | --- | --- | --- |
| Deleted middle character | `1B 5B 31 50` | `thrush$ abcef` | (0, 11) |
| Inserted middle character | `1B 5B 31 40 58` | `thrush$ abcXdef` | (1, 12) |
| Literal tab stop | `name`, `09`, `value` | `name    value` | (6, 13) |
| Erased progress line | `progress...`, `0D 1B 5B 32 4B`, `Done` | `Done` | (12, 4) |

Bash runs `printf 'name\tvalue'` and `printf 'progress...\r\033[2KDone'`. After each command, a silent `read -rsn1` waits for one input byte so xterm can record the line and cursor before Bash prints the next prompt. The recording’s `captureSHA256` identifies this raw Bash recording. Regenerate the four checkpoints offline from the committed bytes with the command below. Run the Python command first only to collect a new live recording.

```sh
python3 Fixtures/reference/m2/capture-display.py --bash /opt/homebrew/bin/bash
bun Fixtures/reference/m2/generate.mjs shell-edges
```

## Reproduce the reference files

With the [pinned reference](../README.md) installed, run the generator against the checked-in PTY recordings from the repository root.

```sh
bun Fixtures/reference/m2/generate.mjs
shasum -a 256 Fixtures/recordings/*.json
```

The generator feeds the output bytes into a reference terminal in recorded order. It obtains replies via `onData`, encodes special keys with the browser package's keyboard evaluator, and uses its paste conversion and bracket helpers. In each real recording, the resulting input and automatic reply bytes must match their separate capture fields, including reads that produced no reply. The recorded programs never heard a focus report, so that check leaves focus reports out. It also verifies the benchmark's 1,048,640-byte ASCII stream at all three grid sizes in 4 KiB writes.

To record a new local shell and Vim session, run `python3 Fixtures/reference/m2/capture.py` and then regenerate the references. New recordings reflect the machine's PTY read boundaries, timing and Vim version. Regenerating from the checked-in captures produces identical bytes and hashes. Both steps use local temporary files and processes. The Swift test suite reads the bundled JSON directly.

## Recording format

Each version-1 JSON file contains its initial grid, ordered events, and two tables of reference cells and rows. An event can supply a grid size, base64 PTY output, semantic input with its expected wire bytes, replies, or a checkpoint. Apply a resize, consume the PTY output and compare any reply before inspecting the checkpoint. Key and paste events go to the encoder. The captured PTY supplies the echo. A nonempty `observedReply` in a capture is the exact automatic reply the live reference wrote to the PTY, with its own `replyOffsetMicroseconds`. The regenerated `reply` is checked against that observation. Each generated real recording records the SHA-256 of its capture file.

The reference doesn't know the kitty keyboard protocol, so the generator follows each screen's keyboard flags itself. Where a program pushes them, as Codex does, a recording carries Thrush's answer to the flags query and the key reports Thrush sends, such as `CSI 116 ; 5 u` for Control-T. Captures that predate this sent the reference's bytes and never received an answer, so the checks against them leave both out.

`normalHistoryRowsBefore` and `historyRowsBefore` record the normal-buffer and active-buffer counts immediately before each resize.

Every checkpoint stores the renderer's effective `cursorShape` and `cursorBlink`. The separate `modes.cursorBlink` field records the option that mode query 12 reports. The `shell-edges` cursor sequence exercises all six DECSCUSR styles, the blink option while a style is active, and explicit-zero and omitted-parameter resets. The pinned xterm also retains the preceding shape for parameters 7 and 8 and applies their odd/even blink setting.

A host `palette` event supplies foreground and background as `#rrggbb` plus an `ansi` array in index order (0–15). Apply the palette before the bytes in that event. Shell edge cases start with browser xterm defaults, apply a custom host palette during a partial foreground query, then swap foreground/background and reverse the 16 ANSI entries. Every query comes from the pinned browser handler. The edge cases cover OSC 4 pairs, extended indexes 16–255, a chained OSC 10/11 query, BEL and split ST terminators, cancellation by CAN/SUB, and unsupported indexes. Stored indexed cells retain their indexes through host palette changes.

A checkpoint stores the effective grid, raw cursor row and column, active screen and modes, then indexes every history and viewport row in display order. Each row stores its visible text, soft-wrap flag, and repeated count/cell-index pairs. Its omitted tail contains empty single-column default cells. A cell includes exact UTF-8 text, display width, foreground, background and flags. Colors use −1 for the default, 0–255 for indexed colors, and 256 plus packed RGB for true color. Flags encode bold, dim, italic, underline, blink, inverse, invisible and strikethrough from the least significant bit. Empty cells, printed spaces and wide continuation cells therefore remain distinguishable. Visible text and cells stop at the active grid width, including on the alternate screen.
