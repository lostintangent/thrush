# Emulator design

ThrushCore turns shell output into a screen and turns keys into shell input. Measurement settles what each byte should do. The conformance harness feeds the same bytes to a pinned reference emulator and to Thrush, and they must agree. The reference is a test oracle, not a design to copy, so the code describes behavior in its own terms and never names it. Speed comes first, and the rest of the design follows from where the bytes go. ThrushCore should also be a codebase people read to learn how a terminal emulator works. This document records that shape so the emulator stays fast, easy to read and easy to extend.

## Principles

- **Speed is the first requirement.** The core must outrun the fastest emulator cores we can measure, on the same machine and doing the same work. The [comparison benchmark](../Benchmarks/comparison.md) holds that bar, and ThrushBench gates every change against the revision before it.
- **Code to learn from.** Someone new to terminals should be able to read ThrushCore from bytes to cells and come away understanding how an emulator works. Each file holds one idea and opens by saying what it does and why. Names say what things mean, there is one way to do each thing, and nothing exists for a case we don't have. Speed and clarity aren't a trade. The low-level techniques live in a few small files that explain themselves and the measurement behind them, so everything else reads plainly.
- **The harness settles behavior, Swift settles structure.** Thrush matches the reference's results exactly. The one exception is a reference defect, such as a crash or corrupted history, which the harness lists by case with the reference's result, Thrush's result and why Thrush differs. How the code gets there is ours, written as idiomatic Swift rather than ported classes, callbacks or handler registries. Comments explain behavior directly instead of pointing at another project.
- **The dispatch reads like the spec.** Every supported control function appears once, by name, in one `switch`. Anything absent there is unsupported, and the harness says so.
- **State, not events.** `Terminal` is a `Sendable` value. Hosts read what they need, such as the title or modes, after applying output. Nothing in the core calls back into the host.
- **Fast by construction, safe by default.** Design starts from the hot path, and every change is measured. Use safe Swift such as `Span`, `MutableSpan` and `InlineArray`. Where a profile shows bounds or uniqueness checks costing real time, use unchecked access in one documented hot-path file that tests cover.

## Layers

```
bytes ─▶ TextScanner ── printable ASCII runs ─▶ Screen.writeASCII
           ├─────────── Unicode scalars ─────▶ Screen.write
           └─────────── controls ────────────▶ EscapeParser ─▶ Terminal.apply
```

| Layer | Knows | Doesn't know |
| --- | --- | --- |
| `TextScanner` | Where text ends. It finds printable ASCII runs, decodes other text one Unicode scalar at a time, carries a split scalar across chunk boundaries and discards malformed bytes, so an interrupted prefix such as `E2 82` before `Z` leaves only `Z`. | What any control does. |
| `EscapeParser` | Where a VT control starts and ends. It gathers a prefix, intermediates and parameters, and streams string payloads to a handler that enforces the size limit. | What any sequence does. Adding a function never changes it. |
| `Terminal.apply` | Which named function a sequence is, its parameter defaults and which screen operation or mode it drives. | How the grid stores cells. |
| `Screen` | Cursor, margins, cells, wraps, history and both buffers, through intention-revealing operations such as `insertBlanks(_:)` and `deleteCharacters(_:)`. | Escape sequences. |

Input runs the other way through one key table that maps each `Terminal.Input.Key` to its sequence, with a single shared modifier rule.

## Following one chunk

A shell that prints a green prompt sends these 16 bytes:

```
ESC [ 3 2 m ~ / s r c ESC [ 0 m ␠ $ ␠
```

Here is how ThrushCore turns them into cells.

1. **The chunk arrives.** The host calls `Terminal.receive(_:)` with a `Span` over the bytes. The loop checks the first byte. ESC isn't printable, so it takes the slow path through `consume`.
2. **The scanner decodes a scalar.** `TextScanner.decode` returns U+001B. A multibyte character would take several calls, and a chunk that ends halfway through one carries the partial scalar into the next call.
3. **The parser frames the sequence.** `EscapeParser.consume` looks up its current state and the scalar in the transition table. ESC moves it from the ground state to escape, and `[` moves it to the start of a control sequence and clears the parameters. `3` and `2` accumulate `32` in `ControlParameters`, and `m` is the final byte. That transition returns `.csi` with an identifier packing the final byte and any prefix and intermediates. Nothing has been copied or allocated.
4. **Dispatch names it.** `TerminalControlFunction(action)` maps the identifier to `.control(.graphicRendition)`, the function the specs call SGR.
5. **`apply` runs it.** The `graphicRendition` case calls `style.applySGR(parser.parameters)`. It reads `32` in place and sets the foreground to palette color 2, green. Nothing visible changed, so the frame generation stays the same.
6. **Text takes the fast path.** Back in `receive`, `~` is printable ASCII, the parser is in the ground state and no scalar is half decoded. `TextScanner.endOfASCII` finds where the run stops, at the next ESC. A long run is checked 16 bytes at a time with SIMD. `Screen.writeASCII` gets those five bytes as one `Span`. It wraps at the right margin if needed, then `Row.writeASCII` stores each byte as a cell with the green style. The cursor advances five columns and the generation goes up by one, so the renderer knows to draw.
7. **The rest repeats the pattern.** `ESC [ 0 m` resets the style through the same steps, and ` $ ` is one more run in the default style.

When a program asks a question, the answer comes back from the same call. If the chunk ended with `ESC [ 6 n`, a cursor position request, `apply` would append `ESC [ 1 ; 9 R` to the replies, which `receive` returns for the host to send to the shell.

Keys flow the other way. Pressing Up calls `Terminal.encode(.key(.up))`. The key table maps Up to cursor final `A`, so it sends `ESC [ A`. If the program enabled application cursor keys with `ESC [ ? 1 h`, it sends `ESC O A` instead.

## The hot path

Most output is text, so text never enters the state machine.

- **Text runs skip the parser.** In the ground state, the scanner searches blocks of 16 bytes for the first byte outside printable ASCII. `Screen.writeASCII` receives the run. `Screen.write` receives other printable Unicode scalars individually. Control bytes and complete C1 scalars go to the framer.
- **Printing fills cells in bulk.** `Screen.writeASCII` writes a printable ASCII run row by row with the current style and wraps at the margin. ASCII occupies one column. For other scalars, `ColumnWidth` searches the ordered Unicode 11 ranges for zero-width and double-width characters. Combining marks extend the preceding cell when there is one.
- **The state machine is data.** Escape framing is a precomputed table indexed by state and byte that yields the next state and action in one load.
- **Parameters stay where they're parsed.** The parser collects parameters in fixed storage it owns. Dispatch receives a small command identifier that packs the prefix, intermediates and final byte, then reads parameters in place. Dispatch needs no parameter array allocation or copy. An early draft that carried parameters in an enum payload ran about 12 times slower on control-heavy output.

## Storage

Nearly every printed byte ends as a store into a row, and every line feed moves rows. Storage is shaped so that printing writes each cell once, scrolling moves no cells and steady output allocates nothing, while a renderer keeps reading the frame it was handed. The [plan for 0.3.0](../Benchmarks/comparison.md#plan-for-030) builds this one measured step at a time. Rows already reserve their width once, and the rest describes where the other steps lead.

- **A row reserves its width once.** A row stores cells up to the last one written, and the columns past it are blank in the default style, so a blank row holds nothing. The first write reserves the full width. Text past the stored cells is appended rather than filled with blanks and then overwritten, so a growing row never reallocates.
- **A cell is 8 bytes of plain data.** It holds the glyph, a scalar in 21 bits with the width flags above it, and the position of its style. A blank cell in the default style is all zero bits, so clearing a row is a memset and printing a run stores one word per cell. A glyph with combining marks keeps its string in the row's cluster table, keyed by column.
- **A row stores each style once.** The row keeps a short list of the styles its cells use, and each cell holds a position in that list. Printing finds the current style once per run, starting with the one it used last. The list travels with its row, so a row in history or in a snapshot can be read on its own, and nothing tracks when a style falls out of use. Clearing the row empties its list, and a list that outgrows the row's width is compacted to the styles still in use. `Style` can grow, with underline styles, underline color and links, without making cells bigger.
- **A line feed recycles a row.** Once history is full, `History.append` hands back the row it evicts, and `advanceLine` clears it in place as the new bottom row. It keeps its reserved width, so scrolling at full speed allocates nothing. A full-screen erase clears rows in place the same way.
- **A scroll region rotates.** Scrolling inside a region rotates the row slots between its margins, and the row that leaves becomes the new blank row, cleared in place. No row is copied, retained or released. Index, reverse index, inserting and deleting lines and scrolling up and down share the same rotation.
- **The screen and history are rings.** The visible rows rotate through a circular index, so a full-height scroll moves one index. History is a ring of up to 1,000 rows that keeps its oldest row at index zero.

### What a snapshot holds

`Terminal.snapshot()` returns an immutable value with the visible rows, the history, the cursor, modes, palette and generation. It copies no cells. Rows and the history ring are copy-on-write values, so a snapshot shares their storage, and the terminal copies one only when it changes something a snapshot still holds. Recycling follows the same rule. Clearing a row that the renderer's snapshot still shares gives the terminal fresh storage and leaves the snapshot's row untouched. A frame never changes under the renderer, and a live snapshot costs at most one copy for each row it holds that changes, about 1,024 rows at 80 × 24.

A renderer reads cells through `row[column]`, which returns a `Cell` with its text, width and resolved `Style`, and caches each row's geometry by `row.generation`. Every write, erase and recycle stamps the row with a new screen revision, as creating a blank row does, so a cleared row never matches geometry cached for its old content. Both stay the same through every storage step, so the view doesn't change.

## Modern Swift we use

- **Swift 6 language mode with strict concurrency.** The core has no isolation of its own. It's a `Sendable` value owned by the shell's internal actor. The public `TerminalShell` is a `@MainActor @Observable` class, like SwiftUI's `WebPage`, and publishes state such as `title` only when it changes.
- **`Span` and `MutableSpan` in hot loops.** `receive(_:)` and the scanner read a `Span<UInt8>`, and printing writes rows through a `MutableSpan`. That keeps zero-copy access with compile-time lifetime safety.
- **`InlineArray` for parameters.** The parser keeps CSI parameters in a fixed `InlineArray` capped at 32 entries, with colon sub-parameters tracked alongside. Dispatch reads them in place, so a sequence never copies or allocates them.
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
