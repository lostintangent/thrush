<p align="center"><img src="docs/Thrush-logo-amber.png" alt="The Thrush mark, an amber-chested bird with a terminal chevron in its slate wing" width="240"></p>

# Thrush

Thrush is a native terminal for Mac and iPhone apps. A Swift emulator with no dependencies turns PTY output into a screen, one Metal renderer draws it on both platforms, and native text input, selection, the pasteboard and VoiceOver handle everything a person does with it. [Toy Box](https://github.com/lostintangent/toy-box) uses Thrush to bring its shells to its Mac and iPhone apps.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/thrush-dark.png">
  <img src="docs/images/thrush-light.png" alt="Thrush running Codex in a Mac window and Vim on an iPhone with the software keyboard and its Esc, Ctrl, Tab and arrow key row">
</picture>

The terminal pixels are unretouched captures from the sample apps. The Mac window is streaming Codex from a real PTY, and the iPhone is replaying a recorded Vim session over the mock connection. The image follows your appearance setting, just as Thrush does.

## Add a terminal to an app

Add the package and depend on its `ThrushUI` and `ThrushConnection` products. Until the first release is tagged, depend on `main`.

```swift
.package(url: "https://github.com/lostintangent/thrush", branch: "main")
```

Create one connection per shell in a model that outlives the view, and give it a socket factory. Then show it with one view.

```swift
import ThrushConnection
import ThrushUI

let terminal = TerminalConnection(clientID: clientID) { id, size in
    api.terminalSocket(clientID: id, size: size)
}

TerminalPane(terminal)
```

That's the whole integration. The pane paints its whole frame, fits its grid to the safe area inside it and reports each new size to the shell. Give it `.ignoresSafeArea()` and the terminal's background runs under a navigation bar or Mac toolbar while its first row starts below. It follows the system appearance between Slate Light and Slate Dark, shows the Esc, Ctrl, Tab and arrow key row above the iPhone keyboard, and owns focus, selection, copy and history. It stays attached while it's shown, including in a Mac window behind other apps, minimized or hidden, and detaches when it leaves the screen or the iPhone app goes to the background. A lost socket reconnects after 250 ms, backing off to 4 s, and typing waits for the same shell to resume. When something needs a person's attention, the pane says so in a native status strip.

| State | What the pane shows |
| --- | --- |
| Opening | **Connecting**, after 200 ms |
| A lost socket retries | **Reconnecting**, with the transcript kept and typing held for the same shell |
| The shell was replaced | **Previous shell ended**, with the new shell ready |
| Another window took the shell | **Open in another window**, with **Use Here** |
| The shell exited | **Ended**, with **New Shell** |

Every other argument is optional.

```swift
TerminalPane(
    terminal,
    isActive: isSelectedTab,        // false while a tab stays in the hierarchy but is hidden
    theme: .slateDark,              // or a TerminalTheme of your own; nil follows the system
    fontSize: 15,
    keyboardAccessory: .none,       // iPhone only: .standard, .none or .custom(view)
    onExit: { closeTab() }          // when the shell ends. The pane keeps its last screen and offers New Shell
)
```

To close a tab, end its shell with `try await terminal.closeShell()`. [Pane states and behavior](docs/design/pane-states.md)

### The socket

The factory returns a fresh, suspended `URLSessionWebSocketTask` from the host's own session for each attachment, so the host keeps its authentication and configuration. The connection speaks the Toy Box terminal protocol. Binary frames carry PTY output. The server sends JSON `ready`, with `resumed` telling a resumed shell from a fresh one, and `exit`. The client sends keystrokes as binary frames and JSON `resize` and `close`. The client ID names the shell, so reattaching with the same ID resumes it.

### Use the emulator on its own

The `Thrush` product is the emulator alone. It uses only the Swift standard library, so it runs anywhere Swift does, with no view.

```swift
import Thrush

var terminal = Terminal(size: .init(columns: 80, rows: 24))
let reply = terminal.receive("thrush$ \u{1b}[6n".utf8)  // the bytes of "\u{1b}[1;9R"
let prompt = terminal.text(inRow: 0)                    // "thrush$ "
```

`receive` applies output in order regardless of how it was chunked, and returns any reply the program asked for. `encode` turns keys, text and paste into bytes under the terminal's current modes. `resize(to:)` reflows the grid. [The headless consumer](examples/headless-consumer)

## Products

| Product | What it is |
| --- | --- |
| `Thrush` | The emulator: grids, 1,000 rows of history, styles, modes, Unicode 11 widths and replies. Swift standard library only. |
| `ThrushUI` | `TerminalPane` for SwiftUI and the `TerminalView` it hosts. One Metal renderer, Core Text shaping, Slate themes, native input and accessibility. No resource bundle, since the shader compiles from embedded source. |
| `ThrushConnection` | `TerminalConnection`, which attaches, resumes and reconnects one shell over the host's WebSocket. |
| `ThrushBench` | The Release benchmark for parsing, replays, rendering and the connection. |

Thrush needs macOS 27 or iOS 27 and Swift 6.4. It builds from the command line with Xcode 27.2 or, for Mac, Command Line Tools. There's no Xcode project.

## Try the sample apps

Start the mock shell, then build and open the Mac app from a second terminal.

```sh
bun scripts/demo-peer.ts
scripts/build-demo.sh mac && open .build/demo/mac/Thrush.app
```

`scripts/build-demo.sh simulator` builds the iPhone app for the iOS Simulator. To run a real shell, start a disposable Toy Box server with `scripts/serve-pty.py` and pass the URL it prints to either app with `--endpoint`. [Running the sample apps](docs/demo.md) · [A disposable Toy Box server](Benchmarks/pty.md)

## Benchmarks

`swift run -c release ThrushBench` checks every recorded replay against an independent xterm reference, then writes its measurements to `.build/benchmarks`.

| Measure | Result | Report |
| --- | --- | --- |
| Sustained output | 193 MiB/s at 80 × 24, against a 100 MiB/s target | [Headless](Benchmarks/headless.md#recorded-mac-measurements) |
| Recorded workflows | Shell 72, Vim 146 and Codex 70 MiB/s, with every checkpoint matching xterm | [Headless](Benchmarks/headless.md#recorded-interaction-measurements) |
| Resize with full history | Worst p95 0.582 ms, against one 120 Hz frame of 8.333 ms | [Headless](Benchmarks/headless.md#recorded-mac-measurements) |
| Warm full-grid redraw | p95 0.274 ms CPU and 0.102 ms GPU in the Mac app | [Rendering](Benchmarks/rendering.md) |
| Idle | Zero frames while idle or hidden | [Rendering](Benchmarks/rendering.md) |
| Reattach | Foreground ready and replay to Up p95 0.872 ms over loopback | [Connection](Benchmarks/connection.md) |
| Real shells | Bash, Vim, Codex and every lifecycle branch on Mac and iPhone against a Toy Box server, 34 of 34 checkpoints on each with every byte applied | [Live workflows](Benchmarks/live-workflows.md) |

The timings come from one contended M1 Max, so they show headroom rather than a timing baseline. [All benchmarks](Benchmarks/README.md) covers each command, what it checks and the real PTY runs.

## Develop

[AGENTS.md](AGENTS.md) lists the build, test and check commands. [The plan](docs/plan.md) is the source of truth for requirements, contracts, budgets and milestones, and [the design docs](docs/design) cover Slate, glass and the pane states.
