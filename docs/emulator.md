# Emulator design

ThrushCore turns shell output into a screen and turns keys into shell input. Measurement settles what each byte should do. The conformance harness feeds the same bytes to a pinned reference emulator and to Thrush, and they must agree. The reference is a test oracle, not a design to copy, so the code describes behavior in its own terms and never names it. The design aims for the fastest core with the simplest code, and follows from where the bytes go. This document records that shape so the emulator stays fast, correct, easy to read and easy to extend.

## Principles

- **Fast.** The core must outrun the fastest emulator cores we can measure, on the same machine and doing the same work. The [comparison benchmark](../Benchmarks/comparison.md) holds that bar, and ThrushBench gates every change against the revision before it.
- **Simple.** The simplest, clearest design is the goal, and speed comes from choosing the right structure rather than clever code. Each file holds one idea and opens by saying what it does and why. Names say what things mean, there is one way to do each thing, and nothing exists for a case we don't have. The few low-level techniques live in small files that explain themselves and the measurement behind them, so everything else reads plainly. Code this plain is also code people can learn from. Someone new to terminals can read ThrushCore from bytes to cells and understand how an emulator works.
- **The harness settles behavior, Swift settles structure.** Thrush matches the reference's results exactly. The exceptions are a reference defect, such as a crash or corrupted history, which the harness lists by case with the reference's result, Thrush's result and why Thrush differs, and the host rule below. How the code gets there is ours, written as idiomatic Swift rather than ported classes, callbacks or handler registries. Comments explain behavior directly instead of pointing at another project.
- **A host change never undoes the program.** Colors a program sets with OSC 4, 10, 11 and 12 last until it restores them with OSC 104, 110, 111 or 112, and the host's theme fills in the rest. The reference discards them when its theme changes. The byte stream never carries that change, so the server that repaints a resumed session can't see it either. Keeping the program's colors means a theme change and the next resume show the same colors.
- **The dispatch reads like the spec.** Every supported control function appears once, by name, in one `switch`. Anything absent there is unsupported, and the harness says so.
- **State, not events.** `Terminal` is a `Sendable` value. Hosts read what they need, such as the title or modes, after applying output. Nothing in the core calls back into the host.
- **Fast by construction, safe by default.** Design starts from the hot path, and every change is measured. Use safe Swift such as `Span`, `MutableSpan` and `InlineArray`. Where a profile shows bounds or uniqueness checks costing real time, use unchecked access in one documented hot-path file that tests cover.

## Layers

```
bytes ─┬─ printable ASCII in ground state ─▶ TextScanner ─▶ Screen.writeASCII
       ├─ single-byte C0 in ground state ─────────────────▶ Terminal.apply
       ├─ other ASCII controls ────────────▶ EscapeParser ─▶ Terminal.apply
       └─ UTF-8 ─▶ TextScanner ─┬─ printable text ────────▶ Screen.writeRun / Screen.write
                                └─ control or payload ────▶ EscapeParser
```

| Layer | Knows | Doesn't know |
| --- | --- | --- |
| `TextScanner` | Where text ends. It finds printable ASCII runs, decodes other text one Unicode scalar at a time, carries a split scalar across chunk boundaries and discards malformed bytes, so an interrupted prefix such as `E2 82` before `Z` leaves only `Z`. | What any control does. |
| `EscapeParser` | Where a VT control starts and ends. It identifies the header and final byte, retains partial parameters across reads and streams string payloads to a handler that enforces the size limit. | What any sequence does. Adding a function never changes it. |
| `Terminal.apply` | Which named function a sequence is, its parameter defaults and which screen operation or mode it drives. | How the grid stores cells. |
| `Screen` | Cursor, margins, cells, wraps, history and both buffers, through intention-revealing operations such as `insertBlanks(_:)` and `deleteCharacters(_:)`. | Escape sequences. |

Input runs the other way through one key table that maps each `Terminal.Input.Key` to its sequence, with a single shared modifier rule.

## Following one chunk

A shell that prints a green prompt sends these 17 bytes.

```
ESC [ 3 2 m ~ / s r c ESC [ 0 m ␠ $ ␠
```

Here is how ThrushCore turns them into cells.

1. **The chunk arrives.** The host calls `Terminal.receive(_:)` with a `Span` over the bytes. The first byte is ESC. The framer can read it directly because every ASCII byte is already a complete code point.
2. **The parser enters a control sequence.** ESC followed by `[` introduces CSI, the control sequence introducer. The parser clears its previous header. A chunk can end immediately after ESC, after `[`, or between digits. In each case, the parser retains what it needs for the next read.
3. **The parser finds the final byte.** It scans past the ASCII digits `3` and `2` to `m`. The whole unprefixed command is present, so the parser returns to ground and identifies the range containing `32` in this chunk. If the read ended between the digits, it would retain the first digit in `ControlParameters` and continue on the next read.
4. **The style reads the operands.** The framer lends the digit range only for the graphic rendition command, SGR. `receive` passes those two bytes straight to `style.applySGR`. For a command split across reads, the framer dispatches `.control(.graphicRendition)` with the operands it retained.
5. **The foreground changes.** In either case the style reads 32 and selects palette color 2, green. The change affects future cells, so the frame generation stays the same.
6. **Text takes the fast path.** Back in `receive`, `~` is printable ASCII, the parser is in the ground state and no scalar is half decoded. `TextScanner.endOfASCII` finds where the run stops, at the next ESC. A long run is checked 16 bytes at a time with SIMD. `Screen.writeASCII` gets those five bytes as one `Span`. It wraps at the right margin if needed, then `Row.writeASCII` stores each byte as a cell with the green style. The cursor advances five columns and the generation goes up by one, so the renderer knows to draw.
7. **The rest repeats the pattern.** `ESC [ 0 m` resets the style through the same steps, and ` $ ` is one more run in the default style.

When a program asks a question, the answer comes back from the same call. If the chunk ended with `ESC [ 6 n`, a cursor position request, `apply` would append `ESC [ 1 ; 9 R` to the replies, which `receive` returns for the host to send to the shell.

Keys flow the other way. Pressing Up calls `Terminal.encode(.key(.up))`. The key table maps Up to cursor final `A`, so it sends `ESC [ A`. If the program enabled application cursor keys with `ESC [ ? 1 h`, it sends `ESC O A` instead.

## The hot path

Most output is text, so text never enters the state machine.

- **Text runs skip the parser.** In the ground state, the scanner searches 16 bytes at a time for the end of printable ASCII. For non-ASCII text it decodes one UTF-8 scalar at a time. With autowrap enabled, insert mode off and the ASCII character set active, printable scalars go straight to the screen as a run. The scanner skips a byte order mark and discards malformed input before the screen opens a row for writing. An encoded C1 control ends the run and goes to the framer. A partial scalar stays in the scanner for the next chunk.
- **Printing fills cells in bulk.** The screen writes an ASCII run one row at a time. For non-ASCII text it appends consecutive scalars that fit at the stored end of the current row, along with continuation cells for double-width characters. The ordinary scalar writer handles overwrites, combining marks and right-margin wraps. Appending advances the screen and terminal generations once per scalar, just as individual writes do.
- **Unicode widths take two lookups.** The high bits of a scalar select a 256-scalar page. The low bits select its two-bit width within that page. The generated Unicode 11 table shares identical pages across the code space. Its 4,352 one-byte page indices and 99 distinct 64-byte pages occupy 10,688 bytes.
- **Single-byte controls have a direct path.** When both the framer and UTF-8 decoder are idle, a C0 function such as carriage return or line feed goes straight to its named handler. Inside a control sequence or after an incomplete scalar, the framer and decoder handle the byte in context.
- **The state machine is data.** Escape framing is a precomputed table indexed by state and byte that yields the next state and action in one load.
- **SGR reads one operand at a time.** For a complete `ESC [ … m` containing only digits, colons and semicolons in one span, the framer lends the parameter bytes to the style handler. The handler converts the digits as it applies the attributes in order. A cancelled header never reaches the style handler.
- **Dispatch carries an identifier.** For other headers the parser keeps the decoded parameters in fixed storage. An early draft that carried parameters in an enum payload ran about 12 times slower on control-heavy output.

## Storage

Nearly every printed byte ends as a store into a row, and every line feed moves rows. Storage is shaped so that printing writes each cell once, scrolling moves no cells and steady output allocates nothing, while a renderer keeps reading the frame it was handed. Rows reserve their width once, cells are 8 bytes with each style stored once per row, line feeds and erases recycle rows, and scroll regions rotate them. The [plan for 0.3.0](../Benchmarks/comparison.md#plan-for-030) records what each of these measured.

- **A row reserves its width once.** A row stores cells up to the last one written, and the columns past it are blank in the default style, so a blank row holds nothing. The first write reserves the full width. Text past the stored cells is appended rather than filled with blanks and then overwritten, so a growing row never reallocates.
- **A cell is 8 bytes of plain data.** It holds the glyph, a scalar in 21 bits with the width flags above it, and the position of its style. A blank cell in the default style is all zero bits, so clearing a row is a memset and printing a run stores one word per cell. A glyph with combining marks keeps its string in the row's cluster table, keyed by column.
- **A row stores each style once.** The row keeps a short list of the styles its cells use, and each cell holds a position in that list. Printing finds the current style once per run. The default style needs no entry, and a run in the style added last reuses that entry. Any other style is appended, even if an older entry matches. The list travels with its row, so a row in history or in a snapshot can be read on its own, and nothing tracks when a style falls out of use. Clearing the row empties its list, and a list that fills twice the row's width is compacted to the styles still in use. A style packs both colors and its flags into 64 bits, so the default style is zero and comparing two styles is one compare. `Style` can grow, with underline styles, underline color and links, without making cells bigger, though every entry grows with it. Output that changes style on every cell pays for the list, since each of those cells appends an entry. That takes about 6% of the SGR workload's time.
- **A line feed recycles a row.** Once history is full, `History.append` hands back the row it evicts, and `advanceLine` clears it in place as the new bottom row. It keeps its reserved width, so scrolling at full speed allocates nothing. Erasing the display clears whole rows in place the same way.
- **A scroll region rotates.** Scrolling inside a region rotates the row slots between its margins, and the row that leaves becomes the new blank row, cleared in place. No row is copied, retained or released. Index, reverse index, inserting and deleting lines and scrolling up and down share the same rotation.
- **The screen and history are rings.** The visible rows rotate through a circular index, so a full-height scroll moves one index. History is a ring of up to 1,000 rows that keeps its oldest row at index zero.

### What a snapshot holds

`Terminal.snapshot()` returns an immutable value with the visible rows, the history, the cursor, modes, the host palette, the program's colors and generation. It copies no cells. Rows and the history ring are copy-on-write values, so a snapshot shares their storage, and the terminal copies one only when it changes something a snapshot still holds. Recycling follows the same rule. Clearing a row that the renderer's snapshot still shares gives the terminal fresh storage and leaves the snapshot's row untouched. A frame never changes under the renderer, and a live snapshot costs at most one copy for each row it holds that changes, about 1,024 rows at 80 × 24.

A renderer reads cells through `row[column]`, which returns a `Cell` with its text, width and resolved `Style`, and caches each row's geometry by `row.generation`. Every write, erase and recycle stamps the row with a new screen revision, as creating a blank row does, so a cleared row never matches geometry cached for its old content. Both stay the same through every storage step, so the view doesn't change.

## Modern Swift we use

- **Swift 6 language mode with strict concurrency.** The core has no isolation of its own. It's a `Sendable` value owned by the session’s internal actor. The public `TerminalSession` is a `@MainActor @Observable` class, like SwiftUI's `WebPage`, and publishes state such as `title` only when it changes.
- **`Span` and `MutableSpan` in hot loops.** `receive(_:)` and the scanner read a `Span<UInt8>`, and printing writes rows through a `MutableSpan`. That keeps zero-copy access with compile-time lifetime safety.
- **`InlineArray` for parameters.** CSI accepts up to 32 semicolon fields and 32 colon fields shared across the whole header. The incremental parser stores both in fixed arrays. SGR enforces the same limits on borrowed input and keeps at most five components of the current colon group, enough for an RGB color with a color-space identifier. An empty colon field stays distinct from zero.
- **Named values instead of raw integers.** Handlers receive enums such as `EraseRange` and `Mode`, never bare `Int` mode numbers. Raw numbers appear only at the boundary where a sequence is decoded.
- **Dictionary-style defaults.** `parameters[0, default: 1]` applies the rule that zero or omitted means the default, mirroring `Dictionary`'s `subscript(_:default:)`.
- **Names that follow the API Design Guidelines.** Functions are named by meaning, such as `.insertCharacters`, with the mnemonic and sequence form in the doc comment (`ICH, CSI Ps @`) so a search for either finds it.
- **`package` access** for everything below the README's public API.
- **Swift Testing for new tests.** Conformance cases run as one parameterized `@Test(arguments:)`, so each case reports on its own. `CustomTestReflectable` shows a readable grid diff on failure. Existing XCTest suites can migrate gradually.

## What we avoid

- Dictionaries of closures, or a protocol with one conforming type per function. A `switch` is the table, compiles to direct calls and keeps every mutation of `self` visible.
- Macros or result builders for the dispatch. Plain Swift is easier to read and debug.
- Interpreting payloads inside the parser, as the original color-query parsing did.
- Callbacks from the core to the host.
- Foundation, existentials and `Any` in ThrushCore.

## Adding a control function

1. Add cases for the function to the conformance corpus, with omitted and zero parameters, its edges and a delivery split inside the sequence. Run `scripts/check-conformance.sh --write` to record the reference’s cells, cursor, modes and replies. The new cases join the known gaps until Thrush matches them. [Conformance harness](../Fixtures/reference/conformance/README.md)
2. Add the named function to the appropriate family in [TerminalControlFunctions.swift](../Sources/ThrushCore/TerminalControlFunctions.swift). For example, `TerminalControlFunction.CSI.cursorForward` has wire value `0x43` and the comment `CUF, CSI Ps C`.
3. Add its case in [Terminal.apply](../Sources/ThrushCore/Terminal.swift). The CUF handler calls `screen.cursorForward(parser.parameters[0, default: 1])`. The same subscript handles both missing and zero counts. Implement the cursor or row operation in [Screen.swift](../Sources/ThrushCore/Screen.swift). For a string command, route its OSC number to a payload handler and commit the result only on successful termination.
4. Run `scripts/check-conformance.sh --write --report gaps.md` so the matching cases leave the known gaps. The report shows anything that still differs. Then run `swift test`, `swift run -c release ThrushBench` and `python3 scripts/check-benchmark-report.py`. The replay runner checks each reference checkpoint before measuring the recording.

## Adding a key

1. Add a case to `Terminal.Input.Key` in [TerminalInput.swift](../Sources/ThrushCore/TerminalInput.swift) and route the native key event to it. Keep committed text on the input method’s existing path.
2. In `encodeKey(_:modifiers:)`, choose the family and final byte or number. For example, Up uses `.cursor(UInt8(ascii: "A"))`. An F1 case would use `.ss3(UInt8(ascii: "P"))`, and F5 would use `.numbered(15)`. The shared encoder applies the active cursor mode and modifier parameter. Numbered keys can specify which modifiers the host handles locally.
3. Record plain and modified presses using the reference keyboard evaluator. Add them to the [key encoding checks](../Tests/ThrushCoreTests/KeySequenceTests.swift) and the recorded input workload for the program that uses them.
