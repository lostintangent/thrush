# Emulator design

A shell writes bytes. Every byte is either text or part of a control function. Text prints at the cursor. A control function is performed by name.

```
bytes ─▶ parser ─┬─ text ─────────────▶ print
                 └─ control function ─▶ perform
```

That is the whole read path. `Terminal.write` is a loop that asks the parser for the next piece and either prints it or performs it. The parser knows the grammar of bytes and nothing about what any function means. `perform` switches on a function's family, and each family's `switch` has a case for every function Thrush supports, written as operations on the screen or as a change to the terminal's state. Anything absent from those switches is unsupported.

SGR is the one function `write` names itself. It never touches the screen. It only changes the pen the next text prints with, so `write` reads as three cases: text prints with the pen, SGR changes the pen, and everything else is performed.

The parser holds the arguments of the token it just returned, and `print` and `perform` read them only through its `parameters`, `payload` and `glyphs`. Text keeps running until a function is performed, and `REP` and combining marks depend on that.

Some functions are questions, such as where the cursor is. `perform` adds the answer to the replies that `write` returns. Input runs the other way through `encode`, which turns a key, a paste or a click into the bytes the program expects, reading the modes its output set. Nothing in the core calls back.

ThrushCore is fast because a few techniques hide behind these names. Text is found 16 bytes at a time inside the parser, the parser's state machine is a table, printing stores a run of cells at a time, and rows are recycled through rings instead of allocated. None of them appears in `write` or `perform`, so the code that says what a terminal does reads the same as this paragraph. [Where the speed lives](#where-the-speed-lives) names each technique and what it saves.

The conformance harness settles what each byte should do. It feeds the same bytes to a pinned reference emulator and to Thrush, and they must agree. The reference is a test oracle, not a design to copy, so the code describes behavior in its own terms and never names it. The rest of this document records the shape that keeps the core fast, correct, easy to read and easy to extend.

## Principles

- **Fast.** The core must outrun the fastest emulator cores we can measure, on the same machine and doing the same work. The [comparison benchmark](../Benchmarks/comparison.md) holds that bar, and ThrushBench gates every change against the revision before it.
- **Simple.** The simplest, clearest design is the goal, and speed comes from choosing the right structure rather than clever code. Each file holds one idea and opens by saying what it does and why. Names say what things mean, there is one way to do each thing, and nothing exists for a case we don't have. The few low-level techniques live in small files that explain themselves and the measurement behind them, so everything else reads plainly. Code this plain is also code people can learn from. Someone new to terminals can read ThrushCore from bytes to cells and understand how an emulator works.
- **The harness settles behavior, Swift settles structure.** Thrush matches the reference's results exactly. The exceptions are a reference defect, such as a crash or corrupted history, which the harness lists by case with the reference's result, Thrush's result and why Thrush differs, and the rules below for the app's theme, pasteboard and keyboard. How the code gets there is ours, written as idiomatic Swift rather than ported classes, callbacks or handler registries. Comments explain behavior directly instead of pointing at another project.
- **An app's theme change never undoes the program.** Colors a program sets with OSC 4, 10, 11 and 12 last until it restores them with OSC 104, 110, 111 or 112, and the app's theme fills in the rest. The reference discards them when its theme changes. The program's output never carries that change, so the server that repaints a resumed session can't see it either. Keeping the program's colors means a theme change and the next resume show the same colors.
- **A program can follow the app between dark and light.** Mode 2031 and DECDSR 996 come from Contour's [color palette update notifications](https://github.com/contour-terminal/contour/blob/master/docs/vt-extensions/color-palette-update-notifications.md), which the reference doesn't implement. A program that sets mode 2031 hears `CSI ? 997 ; 1 n` when the app's theme turns dark and `CSI ? 997 ; 2 n` when it turns light. DECDSR 996 asks for the current appearance with the same reply. The theme's background decides, and it's dark when white text contrasts with it more than black does. Colors the program set never count, so a program hears only what the app changed. Where the spec is silent, Thrush does what [Ghostty](https://github.com/ghostty-org/ghostty/blob/69023b81/src/terminal/Terminal.zig) does. Setting the mode sends nothing, DECRQM reports it, DECSTR keeps it and RIS clears it. Until the app supplies a theme, DECDSR 996 goes unanswered, so a headless terminal stays silent.
- **A program can copy to the device's pasteboard.** OSC 52 copies text, so a yank in Neovim, Helix or tmux reaches the device in a person's hands, even when the shell runs on another machine. Apple platforms have one pasteboard, so every selection a program names copies to it. A read with `?` goes unanswered, so a program can't see what a person copied elsewhere, and an empty or malformed copy changes nothing. The control-string limit caps a copy near 7.5 MB of text. Of the capabilities XTGETTCAP asks about, Thrush reports only Ms, the one that says how to copy, so a program that asks first, as Neovim does, learns it may. Every other name goes unanswered, as Ghostty does, so a reply never carries a program's text back to the shell. The reference implements neither, so the harness lists Thrush's replies as reference defects.
- **A program can tell Shift-Enter from Enter.** Legacy key encoding sends Enter and Shift-Enter as the same carriage return, so a program like Claude Code or Codex can't start a new line without sending the prompt. Both ask for the [kitty keyboard protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/), which the reference doesn't implement. Thrush supports its flags 1 and 4. Flag 1 reports Escape and every chord legacy encoding can't tell apart as `CSI code ; modifiers u`, so Shift-Enter sends `CSI 13 ; 2 u`. Flag 4 adds the shifted key to a chord, so Control-Shift-A sends `CSI 97 : 65 ; 6 u`. Text keeps its usual bytes, and so do keys legacy encoding already tells apart, except that the cursor keys ignore application mode. Each screen keeps its own stack of up to eight pushes, each with the flags the program asked for, so a replay hands all of them to a client that supports more. `CSI ? u` reports the top entry's flags that Thrush supports, so a program asking for more learns what it got. DECSTR and RIS empty both stacks, as kitty does, so a program that resets the terminal as it exits leaves keys reported the usual way. The harness lists Thrush's replies as reference defects.
- **The dispatch reads like the spec.** Every supported control function appears once, by name, in its family's `switch` under `perform`, or as SGR's one case in `write`. Anything absent there is unsupported, and the harness says so.
- **State, not events.** `Terminal` is a `Sendable` value. The session and view read what they need, such as the title, modes or text to copy, after applying output. Nothing in the core calls back into them.
- **Fast by construction, safe by default.** Design starts from the hot path, and every change is measured. Use safe Swift such as `Span`, `MutableSpan` and `InlineArray`. The one technique that uses unsafe Swift, a rotation in blocks, is measured under [Where the speed lives](#where-the-speed-lives).

## Layers

| Layer | Knows | Doesn't know |
| --- | --- | --- |
| `TextScanner` | Where text ends. It finds printable ASCII runs, decodes other text into scalars that carry their widths, carries a split scalar across chunk boundaries and discards malformed bytes, so an interrupted prefix such as `E2 82` before `Z` leaves only `Z`. | What any control does. |
| `Parser` | Where text ends and where a control function starts and ends, across reads that split either anywhere. It reads text through `TextScanner`, names each complete function, keeps the parameter bytes as they arrive and keeps the payload of a string Thrush performs, up to its size limit. | What any function does. Adding a function names it in [ControlFunctions.swift](../Sources/ThrushCore/ControlFunctions.swift) and never changes the parser. |
| `Terminal` | `write` prints text, gives SGR to the pen and hands every other function to `perform`, which knows each function's parameter defaults and writes it in the screen's operations. LF is an index and then a new line, and IL scrolls the rows from the cursor down. | How the grid stores cells. |
| `Screen` | Cursor, margins, cells, wraps, history and both buffers, through five operations: `print`, `move`, `scroll`, `shift` and `erase`. The rest is state the functions set and read, such as whether a row starts a new line. | Escape sequences, or which function a change came from. |

`Terminal.CharacterSet` translates printable ASCII using the mapping the program selected, such as ASCII or DEC line drawing. `Terminal.CharacterSets` holds the four slots G0 through G3 and tracks which mapping is active.

Input runs the other way through one key table that maps each `Terminal.Input.Key` to its sequence, with a single shared modifier rule. Option is Meta on a character key, sending Escape before the chord without it, so Option-B sends `ESC b`. Text that Option composes, as the Mac keyboard does by default, arrives as text instead.

## Following one chunk

A shell that prints a green prompt sends these 17 bytes.

```
ESC [ 3 2 m ~ / s r c ESC [ 0 m ␠ $ ␠
```

Here is how ThrushCore turns them into cells.

1. **The chunk arrives.** The session calls `Terminal.write(_:)` with a `Span` over the bytes, and `write` asks the parser for the next piece. The first byte is ESC, which starts a sequence.
2. **The parser enters a control sequence.** ESC followed by `[` introduces CSI, the control sequence introducer. The parser forgets the previous header. A chunk can end right after ESC, after `[`, or between digits. In each case the parser keeps what it needs for the next read.
3. **The parser finds the final byte.** It scans past the digits `3` and `2` to `m` and names the function, `.csi(.graphicRendition)`. The whole header is in this chunk, so the parser lends the range that holds `32` instead of copying it. If the read had ended between the digits, `Parameters` would keep the first digit and append the rest on the next read, so a split header reads exactly like a whole one.
4. **The pen changes.** SGR is `write`'s one named case. `style.applySGR` reads 32 from the chunk and selects palette color 2, green. The change affects only future cells, so the frame generation stays the same. Any other function, such as cursor position, copies its header into `Parameters` and goes to `perform`.
5. **Text takes the fast path.** The parser is back in the ground state and `~` is printable, so it reads a run. `TextScanner.endOfASCII` finds where the run stops, at the next ESC, checking a long run 16 bytes at a time. The parser returns the run as a range of the chunk, and `print` hands those five bytes to `Screen.print` as one `Span`. It wraps at the right margin if needed, then `Row.writeASCII` stores each byte as a cell with the green style. The cursor advances five columns and the generation goes up by one, so the renderer knows to draw.
6. **The rest repeats the pattern.** `ESC [ 0 m` resets the pen the same way, and ` $ ` is one more run in the default style.

When a program asks a question, the answer comes back from the same call. If the chunk ended with `ESC [ 6 n`, a cursor position request, `perform` would append `ESC [ 1 ; 9 R` to the replies, which `write` returns for the session to send to the shell.

Keys flow the other way. Pressing Up calls `Terminal.encode(.key(.up))`. The key table maps Up to cursor final `A`, so it sends `ESC [ A`. If the program enabled application cursor keys with `ESC [ ? 1 h`, it sends `ESC O A` instead. Enter sends a carriage return, and so does Shift-Enter until the program pushes keyboard flags with `ESC [ > 1 u`, after which Shift-Enter sends `ESC [ 1 3 ; 2 u`.

Scrolling reaches a program that takes it, which is one that reports the mouse or draws the alternate screen. The view sends one wheel press per row of travel, and `encode` turns each into a wheel report. On the alternate screen without reporting it becomes Up or Down through the same key table, without modifiers or position, as in the reference. The reference sends one arrow per wheel event, and Thrush sends one per row so a long swipe moves as far as it would through history.

## Where the speed lives

Each technique sits behind one name in one place, and none is spelled in `write`, `print` or `perform`. The cost of each is how many more instructions per pass the [comparison workloads](../Benchmarks/comparison.md) took at 80 × 24 with that technique alone removed. Pointer input is a ThrushBench workload. The unsafe rotation is measured in cycles against its best safe form instead, since safe swaps save instructions and then stall.

**Text**

| Technique | Lives behind | Removing it costs |
| --- | --- | --- |
| Printable ASCII is found 16 bytes at a time | `TextScanner.endOfASCII`, called by `Parser.next` | ascii +48%, scroll +11%, vim +10% |
| Other text decodes into a run of up to 64 glyphs that carry their widths | `TextScanner.decodeText`, called by `Parser.next` | wide +214%, shell +24% |
| Each character is decoded from one four-byte read, branching on the lead byte | inside `decodeText` | wide +23.5% |
| Short ASCII stretches join a glyph run in one widening store | inside `decodeText` | shell +5.1%, wide +2.7% |
| A run of ASCII is stored as cells in one pass | `Screen.print` for a span of bytes | ascii +2396%, scroll +622%, vim +609% |
| A run of glyphs is stored in one loop | `Screen.print` for a span of glyphs | wide +157%, shell +134% |
| ASCII written past a row's last used cell takes its own branch | inside `Row` | sgr +4.4% |
| Widths come from two table lookups | `ColumnWidth.of` | It's the width table itself |

**Control functions**

| Technique | Lives behind | Removing it costs |
| --- | --- | --- |
| Text and lone C0 controls never enter the state machine | the ground path of `Parser.next` | scroll +33%, region +19%, ascii +15% |
| One table load per state and byte | `Parser.transition(from:scalar:)` | It's the state machine itself. Holding the table in each parser is worth codex +7.3% |
| A control sequence that arrived whole is read in one pass | `Parser.readWholeSequence` | cursor +10.6%, codex +13.5%, vim +9.5%, sgr +11% |
| A whole SGR is lent from the chunk, not copied | `Parameters.lend`, read only by `write`'s SGR case | sgr +4.3% |
| Parameter bytes are read as runs | `Parser.endOfParameters`, used by both readers | pointer input +11%, sgr +3.4% if inlined instead |
| String payloads are read as runs | the string states in `Parser.readSequence` | codex +22.8% |
| SGR applies its operands as it reads them, in order | `Style.applySGR`, one reader kept out of line | sgr +41%, codex +21.5%, vim +17%, sgr +8% if inlined |
| Each family's functions are performed by their own small function | `perform`'s family switch | scroll +10.3%, region +6.1%, ascii +5.1% |
| C0's `perform` stays small enough to inline into `write`, with tabs kept out of line | `Terminal.tab` | scroll +8.9%, region +3.4%, ascii +2% in cycles |
| Hot helpers are always inlined | `TextScanner`, `Parser`, `Parameters` and `GraphicsRendition` | wide +39.5%, cursor +29%, sgr +20.8%, codex +10.9% |

**Storage**, described in the next section

| Technique | Lives behind | Removing it costs |
| --- | --- | --- |
| History is a ring | `History` | scroll +2047%, ascii +1729% |
| Rows are recycled, never allocated | `History.append` and `Screen` | scroll +170%, ascii +144% |
| A full history's swap inlines into every scroll, and filling it stays out of line | `History.append` | scroll +6.1%, ascii +6% in cycles |
| The visible rows are a ring | `Screen`'s buffers | scroll +91%, ascii +80% |
| Scroll regions rotate in place, as do the cells after an inserted or deleted character | `Array.rotate` in Rotation.swift | region +2696% |
| A rotation moves its elements in three block moves, without retaining or releasing them | inside `Array.rotate` | region +8% in cycles with a ring of slot indices, +42% with swaps. A stream of character insertions and deletions +42% with a loop of single cells, though no comparison workload edits a line |
| Clearing a row resets its length instead of blanking its cells | `Row.clear` | ascii +12.6%, scroll +12.3% |
| Rarely taken row paths are kept out of line | `Row` | scroll +1.8% to +9.2% across code layouts |

A few details complete the picture.

- **Text.** In the ground state the parser reads where printable ASCII ends straight from the 16-byte block that holds the end. Other text decodes into the parser's 64-glyph buffer, each glyph a scalar with a flag for its width. A stretch of printable ASCII shorter than a block joins the glyph run, and a longer one ends it and takes the vector path, as does ASCII after a lone byte order mark. The scanner skips a byte order mark and discards malformed input before the screen opens a row for writing. An encoded C1 control ends the run and is read as a function. A partial scalar stays in the scanner for the next chunk, and any ASCII byte, a control included, abandons it.
- **Printing.** With autowrap on, insert mode off and the ASCII character set active, `print` hands a run to the screen whole. Otherwise it writes one translated character at a time. The screen writes an ASCII run one row at a time. It stores the glyphs that fit at or past the end of a row's cells in use in one loop, with continuation cells for double-width characters, and leaves overwrites, combining marks and right-margin wraps to the one-character writer.
- **Widths.** The high bits of a scalar select a 256-scalar page, and the low bits select its two-bit width within that page. The generated Unicode 11 table shares identical pages across the code space, so its 4,352 one-byte page indices and 99 distinct 64-byte pages occupy 10,688 bytes.
- **The state machine is data.** [The transition table](../Sources/ThrushCore/Parser+Transitions.swift) gives the next state and operation for a state and byte in one load. Each parser holds the table, because reading the lazy static calls out to `swift_once` on every lookup for tens of milliseconds after its first use.
- **Parameters stay as bytes.** `Parameters` keeps the digits, colons and semicolons as they arrived, and a function converts only the numbers it reads, by position. A header split across reads appends to the same bytes. A header too long for the 1 KiB buffer compacts to what a reader can see, dropping leading zeros, digits past saturation and fields past the limits. A whole SGR is the one header left in the chunk, and SGR reads it before the chunk changes. A cancelled header is never named, so it never reaches the pen.
- **A function is only a name.** Its parameters and payload stay in the parser, where `perform` reads them. An early draft that carried parameters in an enum payload ran about 12 times slower on control-heavy output.
- **Where the calls are.** `next`, the whole-sequence reader, `print` and the family switch inline into `write`. C0's `perform` inlines too, which carriage returns and line feeds rely on, and performing any other function calls its family's `perform`. A sequence that arrives in pieces or carries a private marker, such as `CSI ? 1006 h`, walks the table in one call to `Parser.readSequence`. `endOfParameters` and SGR's reader stay out of line, since a copy at each caller cost more than the call.
- **Unsafe code.** `Array.rotate` is the only unsafe code, because safe Swift can only move elements one at a time. It moves rows between slots without retaining or releasing them, and slides a row's cells when characters are inserted or deleted. It checks its bounds before it takes the array's buffer. Everything else is safe, including the scanner's 16-byte blocks, the temporary table that compacts a row's styles and the payload's byte runs.

## Storage

Nearly every printed byte ends as a store into a row, and every line feed moves rows. Storage is shaped so that printing writes each cell once, scrolling moves no cells and steady output allocates nothing, while a renderer keeps reading the frame it was handed. Rows reserve their width once and clear by resetting a length, cells are 8 bytes with each style stored once per row, line feeds and erases recycle rows, and scroll regions rotate them. The comparison's [change since the previous report](../Benchmarks/comparison.md#change-since-the-previous-report) records what they gained together.

- **A row reserves its width once.** A row stores the cells it has written and a length that counts the ones in use. The columns from the length on are blank in the default style, so a new blank row holds nothing. The first write reserves the full width. Text past the stored cells is appended rather than filled with blanks and then overwritten, so a growing row never reallocates.
- **Clearing a row resets its length.** The cleared row keeps its cells, and the next write overwrites them in place. A write that starts past the length blanks only the gap before it, so cells past the length are never read and never need clearing.
- **A cell is 8 bytes of plain data.** `StoredCell` holds the glyph, a scalar in 21 bits with the width flags above it, and `stylePosition`, which selects a style from the row. A blank cell in the default style is all zero bits, so blanking cells is a memset and printing a run stores one word per cell. A glyph with combining marks keeps its string in the row's cluster table, keyed by column. Clearing the row empties the table but keeps its storage, so the next mark on a recycled row doesn't allocate a table.
- **A row stores each style once.** The row keeps a short list of the styles its cells use, and each cell holds a position in that list. Printing finds the current style once per run. The default style needs no entry, and a run in the style added last reuses that entry. Any other style is appended, even if an older entry matches. The list travels with its row, so a row in history or in a snapshot can be read on its own, and nothing tracks when a style falls out of use. Clearing the row empties its list, and a list that fills twice the row's width is compacted to the styles still in use. A style is two 64-bit words. The first packs both colors, eight flags and the underline style, and the second holds the underline color and a link number. The default style is zero in both, so comparing two styles is two compares, and the style grew without making cells bigger. Output that changes style on every cell pays for the list, since each of those cells appends an entry. That takes about 6% of the SGR workload's time.
- **A link is a number in the style.** OSC 8 opens a link, and the screen's link table gives it a number that the current style carries until OSC 8 closes it. SGR 0 and restoring the cursor leave the open link alone, and erased cells hold no link. A link with an id keeps one number, so text a program redraws or splits across rows stays one link. A link without an id gets a new number each time it opens. The table frees a number once no cell on either screen or in history holds it and the current style doesn't, and checks only after opening as many new links as it kept the last time, so the cost per link stays small. A table that holds 65,536 links or 4 MiB of their text checks every 64 opens instead, so it takes new links as soon as the old ones are gone. A target longer than 2,083 bytes or an id longer than 250 opens no link, the lengths VTE and iTerm2 accept. A snapshot holds only the table's entries, and `snapshot.link(for: style)` returns a cell's link.
- **A line feed recycles a row.** Once history is full, `History.append` hands back the row it evicts, and the scroll clears it in place as the new bottom row. It keeps its reserved width, so scrolling at full speed allocates nothing. Erasing the display clears whole rows in place the same way.
- **A scroll region rotates.** Scrolling inside a region rotates the row slots between its margins, and the row that leaves becomes the new blank row, cleared in place. No row is copied, retained or released. Index, reverse index, inserting and deleting lines and scrolling up and down share the same rotation.
- **The screen and history are rings.** The visible rows rotate through a circular index, so a full-height scroll moves one index. History is a ring of up to 1,000 rows that keeps its oldest row at index zero. When a new shell replaces an expired one, the session moves the old main screen's content into the same ring. The first live row starts blank. An absolute index marks where earlier shells end, so eviction advances through older and newer output in order. A reconnect reconstructs only the current shell from the server's replay. A resize reflows the earlier rows at the new width and keeps them above the live screen.

### What a snapshot holds

`Terminal.snapshot()` returns an immutable value with the visible rows, the history, the cursor, modes, the app's palette, the program's colors and generation. It copies no cells. Rows and the history ring are copy-on-write values, so a snapshot shares their storage, and the terminal copies one only when it changes something a snapshot still holds. Recycling follows the same rule. Clearing a row that the renderer's snapshot still shares only resets the terminal row's length. Its next write copies the cells first, so the snapshot's row stays untouched. A frame never changes under the renderer, and a live snapshot costs at most one copy for each row it holds that changes, about 1,024 rows at 80 × 24.

A renderer reads cells through `row[column]`, which returns a `Cell` with its text, width and resolved `style`, and caches each row's geometry by `row.generation`. Every write, erase and recycle stamps the row with a new screen revision, as creating a blank row does, so a cleared row never matches geometry cached for its old content. Both stay the same through every storage step, so the view doesn't change. The conformance harness checks after every step of every case that each generation names one row's cells.

When a reader resumes, `Terminal.ReplayWriter` writes VT bytes that redraw the screen. It tracks the client’s active style in `currentStyle` so adjacent cells with the same style need no intervening SGR.

## Modern Swift we use

- **Swift 6 language mode with strict concurrency.** The core has no isolation of its own. It's a `Sendable` value owned by the session’s internal actor. The public `TerminalSession` is a `@MainActor @Observable` class, like SwiftUI's `WebPage`, and publishes state such as `title` only when it changes.
- **`Span` and `MutableSpan` in hot loops.** `write(_:)` and the scanner read a `Span<UInt8>`, and printing writes rows through a `MutableSpan`. That keeps zero-copy access with compile-time lifetime safety.
- **`InlineArray` for parameters.** `Parameters` keeps a header's bytes in a fixed 1 KiB `InlineArray` and lends them to readers as a `Span`. CSI accepts up to 32 semicolon fields and 32 colon fields shared across the whole header, and the readers enforce both limits on stored and lent bytes alike. SGR keeps at most five components of the current colon group, enough for an RGB color with a color-space identifier. An empty colon field stays distinct from zero.
- **Named values instead of raw integers.** Handlers receive enums such as `EraseRange` and `Mode`, never bare `Int` mode numbers. Raw numbers appear only at the boundary where a sequence is decoded.
- **Dictionary-style defaults.** `parameters[0, default: 1]` applies the rule that zero or omitted means the default, mirroring `Dictionary`'s `subscript(_:default:)`.
- **Names that follow the API Design Guidelines.** Functions are named by meaning, such as `.insertCharacters`, with the mnemonic and sequence form in the doc comment (`ICH, CSI Ps @`) so a search for either finds it.
- **`package` access** for everything below the README's public API.
- **Swift Testing for new tests.** Conformance cases run as one parameterized `@Test(arguments:)`, so each case reports on its own. `CustomTestReflectable` shows a readable grid diff on failure. Existing XCTest suites can migrate gradually.

## What we avoid

- Dictionaries of closures, or a protocol with one conforming type per function. A `switch` is the table, compiles to direct calls and keeps every mutation of `self` visible.
- Macros or result builders for the dispatch. Plain Swift is easier to read and debug.
- Interpreting payloads inside the parser, as the original color-query parsing did.
- Callbacks out of the core.
- Foundation, existentials and `Any` in ThrushCore.

## Building for WebAssembly

Because ThrushCore uses only the standard library, it also builds with Embedded Swift, which specializes every generic and leaves out runtime metadata. [Wasm](../Wasm) compiles the same sources into a 334 KB WebAssembly module behind a small JavaScript `Terminal`, which each release attaches as `thrush-wasm` for servers that keep terminals. The module links the standard library's Unicode tables for grapheme breaking, and imports nothing from its host but random bytes to seed hashing. `scripts/check-wasm.sh` writes every program capture to the module and to native ThrushCore and requires the same replies and replays from both, byte for byte. CI runs it whenever the core changes, so code Embedded Swift can't compile fails there.

## Adding a control function

1. Add cases for the function to the conformance corpus, with omitted and zero parameters, its edges and a delivery split inside the sequence. Run `scripts/check-conformance.sh --write` to record the reference’s cells, cursor, modes and replies. The new cases join the known gaps until Thrush matches them. [Conformance harness](../Fixtures/reference/conformance/README.md)
2. Add the named function to the appropriate family in [ControlFunctions.swift](../Sources/ThrushCore/ControlFunctions.swift). For example, `ControlFunction.CSI.cursorForward` has wire value `0x43` and the comment `CUF, CSI Ps C`.
3. Add its case to its family's `perform` in [Terminal.swift](../Sources/ThrushCore/Terminal.swift) and write it in the screen's five operations. The CUF case is `screen.move(toRow: screen.row, column: screen.column + parser.parameters[0, default: 1])`. The same subscript handles both missing and zero counts. A function longer than a line gets a helper beside the others in Terminal.swift. [Screen.swift](../Sources/ThrushCore/Screen.swift) changes only when the grid needs an operation the five can't express. A string function reads `parser.payload`, which the parser hands over only once the string has ended whole and within its limit.
4. Run `scripts/check-conformance.sh --write --report gaps.md` so the matching cases leave the known gaps. The report shows anything that still differs. Then run `swift test`, `swift run -c release ThrushBench` and `python3 scripts/check-benchmark-report.py`. The benchmark checks each reference checkpoint before measuring the recording.

## Adding a key

1. Add a case to `Terminal.Input.Key` in [TerminalInput.swift](../Sources/ThrushCore/TerminalInput.swift) and route the native key event to it. Keep committed text on the input method’s existing path.
2. In `encodeKey(_:modifiers:)`, choose the family and final byte or number. For example, Up uses `.cursor(UInt8(ascii: "A"))`, F1 uses `.ss3(UInt8(ascii: "P"))` and F5 uses `.numbered(15)`. The shared encoder applies the active cursor mode, the modifier parameter and any keyboard flags the program pushed. Numbered keys can specify which modifiers the view handles locally.
3. Record plain and modified presses using the reference keyboard evaluator. Add them to the [key encoding checks](../Tests/ThrushCoreTests/KeySequenceTests.swift) and the recorded input workload for the program that uses them.
