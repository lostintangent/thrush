# Emulator design

ThrushCore turns shell output into a screen and turns keys into shell input. Pinned xterm defines what every byte means, and the differential harness proves Thrush matches it. Swift defines the shape of the code. This document records that shape so the emulator stays easy to read and easy to extend.

## Principles

- **Behavior comes from xterm, structure comes from Swift.** Match pinned xterm's results exactly, but don't copy its classes, callbacks or handler registries.
- **The dispatch reads like the spec.** Every supported control function appears once, by name, in one `switch`. Anything absent there is unsupported, and the harness says so.
- **State, not events.** `Terminal` is a `Sendable` value. Hosts read what they need, such as the title or modes, after applying output. Nothing in the core calls back into the host.
- **Safe by default, fast where measured.** Use safe Swift throughout. Drop below it only where ThrushBench shows a real cost, in one documented place.

## Layers

```
bytes ─▶ UTF8Decoder ─▶ Parser ─▶ Terminal.perform ─▶ Screen operations
                       framing     dispatch            grid mutation
```

| Layer | Knows | Doesn't know |
| --- | --- | --- |
| `UTF8Decoder` | Streaming UTF-8 across chunk boundaries, with xterm's replacement rules. | Escape sequences. |
| `Parser` | The VT500 state machine: where a sequence starts and ends, its prefix, intermediates, parameters and bounded string payloads. It emits print, execute, escape, control and command events. | What any sequence does. Adding a function never changes it. |
| `Terminal.perform` | Which named function a sequence is, its parameter defaults and which screen operation or mode it drives. | How the grid stores cells. |
| `Screen` | Cursor, margins, cells, wraps, history and both buffers, through intention-revealing operations such as `insertBlanks(_:)` and `deleteCharacters(_:)`. | Escape sequences. |

Input runs the other way through one key table that maps each `Terminal.Input.Key` to its xterm sequence, with a single shared modifier rule.

## Modern Swift we use

- **Swift 6 language mode with strict concurrency.** The core has no isolation of its own. It's a `Sendable` value owned by the shell's internal actor. The public `TerminalShell` is a `@MainActor @Observable` class, like SwiftUI's `WebPage`, and publishes state such as `title` only when it changes.
- **`Span<UInt8>` for input.** `receive(_:)` and the ASCII fast path take a `Span` instead of an `UnsafeBufferPointer`. That keeps zero-copy reads and gains compile-time lifetime safety.
- **`InlineArray` for parameters.** CSI parameters live in a fixed `InlineArray` sized to xterm's limit of 32, with colon sub-parameters tracked alongside. Parsing a sequence allocates nothing.
- **Named values instead of raw integers.** Handlers receive enums such as `EraseRange` and `Mode`, never bare `Int` mode numbers. Raw numbers appear only at the boundary where a sequence is decoded.
- **Dictionary-style defaults.** `parameters[0, default: 1]` applies xterm's rule that zero or omitted means the default, mirroring `Dictionary`'s `subscript(_:default:)`.
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

1. Add a conformance case with the bytes a real program sends, then run the harness to see xterm's result beside Thrush's.
2. Give the function a name in the dispatch, with its mnemonic and form in a doc comment.
3. Add one line to `Terminal.perform` that decodes its parameters and calls a screen operation. Add the operation to `Screen` if none fits.
4. Run the harness and ThrushBench. The case must match xterm and throughput must hold.

## Adding a key

1. Add the case to `Terminal.Input.Key`.
2. Add one line to the key table naming its xterm sequence family, such as CSI final, SS3 final or tilde number.
3. Add the expected bytes for plain and modified presses to the key encoding tests.

Core finalizes these recipes with the real type and file names when the restructure lands.
