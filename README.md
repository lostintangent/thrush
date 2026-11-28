<p align="center"><img src="docs/Thrush-logo-amber.png" alt="The Thrush mark, an amber-chested bird with a terminal chevron in its blue-gray wing" width="240"></p>

# Thrush

Thrush is a native terminal for Mac and iPhone apps. A Swift emulator with no dependencies turns PTY output into a screen, one Metal renderer draws it on both platforms, and native text input, selection, the pasteboard and VoiceOver handle everything a person does with it. An app can use the built-in WebSocket transport with any server that speaks Thrush’s protocol. [Toy Box](https://github.com/lostintangent/toy-box) is the first app to use it, bringing its shells to Mac and iPhone.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/thrush-dark.png">
  <img src="docs/images/thrush-light.png" alt="Thrush running Codex in a Mac window and Vim on an iPhone with the software keyboard and its Esc, Ctrl, Tab and arrow key row">
</picture>

## Add a terminal to an app

Add the package and link the `Thrush` product to your app target. Thrush needs macOS 27 or iOS 27.2 and Swift 6.4. It builds from the command line with Xcode 27.2 or, for Mac, Command Line Tools.

```swift
.package(url: "https://github.com/lostintangent/thrush", from: "0.5.0")
```

Keep the tab’s `TerminalSession` in a main-actor model that outlives the view. The session owns the terminal and its history. To use the WebSocket transport, capture the tab’s stable client ID in the socket factory and pass the session to a `TerminalView`.

```swift
import Thrush

let session = TerminalSession { size in
    api.terminalSocket(clientID: tabID, size: size)
}

TerminalView(session)
```

The view fits its grid to the safe area and reports each new size to the session. Like a SwiftUI background, its canvas runs under a navigation bar, a Mac toolbar, the home indicator or any other safe area its frame meets, with no `.ignoresSafeArea()`, while its first row starts below the bar. On iPhone with the keyboard down, its rows run on under the home indicator too. It follows the system appearance between its light and dark themes, floats a glass key row of Esc, Ctrl, Tab, the arrows and Hide Keyboard above the iPhone keyboard, with Option and Shift a tap away from Ctrl, and handles focus, selection, copying and scrolling, through history or in full-screen programs like Vim and less. Links a program prints, and the web addresses in its plain text, open with ⌘-click on Mac or a tap on iPhone through SwiftUI’s `openURL`, so an app can send them to its own browser. A program that asks can tell Shift-Enter from Enter, and hears whenever the view gains or loses keyboard focus or its theme turns dark or light. The WebSocket stays attached while the view is shown, including in a Mac window behind other apps, minimized or hidden. It detaches when the view leaves the screen or the iPhone app goes to the background.

A small spinner appears at the cursor while the session opens or reconnects, and a lost socket retries on its own. Typing waits until replay restores the same shell. If another window takes the shell, the view keeps its last screen until a tap or a keystroke takes it back. If the server has already released the shell, the same session opens its replacement at the top of the screen, with the previous shell’s main screen and history above it. VoiceOver announces a sustained reconnect, a new shell or a shell exit once. [Session lifecycle](docs/design/lifecycle.md)

An app can choose which tab accepts input and set the appearance. On iPhone, it can also hide the key row above the keyboard. Each argument after the session is optional.

```swift
TerminalView(
    session,
    isActive: isSelectedTab,        // false while a tab stays in the hierarchy but is hidden
    theme: .dark,                   // nil follows the system appearance
    fontSize: 15,
    showsKeyRow: false              // iPhone only. The row is shown by default
)
```

To customize the colors, edit a copy of `TerminalTheme.dark` or `.light` and pass it as `theme:`. A `Terminal.Palette` holds the foreground, background and 16 ANSI colors as `Terminal.RGB` values.

SwiftUI observes `session.title` and `session.hasEnded` directly. When the shell exits or the app closes the session, its final screen and history remain readable. The sample app keeps that screen until the user chooses **New Shell** in its toolbar. The button makes a new `TerminalSession` with the app’s socket factory. [Session lifecycle](docs/design/lifecycle.md)

```swift
TerminalView(model.tab.session)
    .toolbar {
        if model.tab.session.hasEnded {
            Button("New Shell", action: model.newShell)
        }
    }
```

Pass a different `TerminalSession` to the same `TerminalView` and it shows that session’s screen and history. A newly created session starts with a fresh screen. The tab model’s `newShell()` does this by changing `model.tab.session`. SwiftUI keeps the view’s identity, so no `.id` modifier is needed. To end a session explicitly, call `try await session.close()`. [Complete SwiftUI example](examples/swiftui/Sources/Sample/ShellWindow.swift)

### WebSocket transport

On every attachment, the socket factory receives the current `Terminal.Size` in columns and rows. Return a fresh, suspended `URLSessionWebSocketTask` for the same client ID each time, created from your app’s `URLSession` so its authentication and TLS settings apply. Connect to `/socket?service=terminal&clientId=…&cols=…&rows=…`. Binary messages carry terminal input and output in order. Small JSON messages handle ready, resize, close and exit. Reattaching with the same ID during the orphan window restores the previous shell. [Terminal protocol](docs/protocol.md)

### Supply a transport

Instead of a socket, an app can supply a `TerminalTransport` for a local PTY or a remote shell over SSH. In this example, the app provides the SSH client and its sendable `ShellChannel`.

```swift
import Foundation
import Thrush

struct SSHTransport: TerminalTransport {
    let channel: ShellChannel

    func read() async throws -> Data? { try await channel.readOutput() }
    func write(_ bytes: Data) async throws { try await channel.sendInput(bytes) }
    func resize(to size: Terminal.Size) async throws {
        try await channel.setWindowSize(columns: size.columns, rows: size.rows)
    }
    func close() async { await channel.shutdown() }
}

let session = TerminalSession(openTransport: { size in
    let channel = try await ssh.openShell(columns: size.columns, rows: size.rows)
    return SSHTransport(channel: channel)
})

TerminalView(session)
```

The factory opens a shell at the view’s measured grid size. A local PTY implements the same four transport methods. Return `nil` from `read()` after the last output bytes. Make `close()` release the transport’s resources and wake pending I/O. While the app can run, the session keeps reading and answering terminal queries with the view hidden. Showing it again displays the current screen. EOF or a transport error ends the session with its final screen intact. A new session calls the factory to open its own shell. [External app example](examples/swiftui/Sources/Sample/ShellTab.swift)

## Keep terminals on a JavaScript server

A server that runs shells keeps a terminal for each one, so a client that attaches later sees the screen it missed. Thrush’s own server does this in Swift. For a server in Bun or Node 22 and later, each release attaches the same emulator built for WebAssembly as `thrush-wasm.tgz`, a package named `thrush` with types and no dependencies. Its replay redraws a terminal on any client that speaks VT, such as Thrush in a Mac or iPhone app or xterm.js in a browser.

Install it from a release’s own URL. A lockfile records the tarball’s hash, so a URL that moves to a newer release breaks the next fresh install.

```sh
bun add https://github.com/lostintangent/thrush/releases/download/v0.5.0/thrush-wasm.tgz
```

```ts
import { Terminal } from "thrush";

const terminal = new Terminal(80, 24);

// Write each chunk of the shell's output to the terminal. An attached client also receives it and
// answers its queries, such as a cursor position request, so send the terminal's reply to the shell
// only when no client is attached.
const reply = terminal.write(output);
if (client) client.send(output);
else if (reply) pty.write(reply);

// Resize the terminal with the shell's PTY.
terminal.resize(120, 40);

// A client that attaches at the terminal's size gets the replay, and then live output.
client.send(terminal.replay());

// Free the terminal when its shell ends.
terminal.dispose();
```

The package carries ThrushCore as a 333 KB WebAssembly module and starts it synchronously, in a few milliseconds, when it makes the first terminal. It also runs in a binary compiled with `bun build --compile`. CI checks that it returns the same replies and replays as native ThrushCore, byte for byte, through every recorded program.

## Try the sample app

The sample in `examples/swiftui` is one SwiftUI app for Mac and iPhone whose only dependency is the `Thrush` library product. `Sample.swift` opens the window, `ShellWindow.swift` shows a `TerminalView` and offers **New Shell** once the shell ends, and `ShellTab.swift` opens each session's WebSocket.

From the repository root, start the local server. It prints its loopback URL and opens a real shell when the app connects.

```sh
swift run ThrushServer
```

In a second terminal, build and open the Mac app.

```sh
scripts/build-app.sh sample mac && open .build/sample/mac/Thrush.app
```

The same server works with the iPhone Simulator.

```sh
scripts/build-app.sh sample simulator
xcrun simctl install booted .build/sample/simulator/Thrush.app
xcrun simctl launch booted app.thrush.sample
```

Launch either app with `-endpoint ws://host:port` to use another server.

## Benchmarks

`swift run -c release ThrushBench` checks every recording against an independent reference emulator, then writes its measurements to `.build/benchmarks`.

| Measure | Result | Report |
| --- | --- | --- |
| Sustained output | 1,596 MiB/s at 80 × 24, against a 100 MiB/s target | [Headless](Benchmarks/headless.md#recorded-mac-measurements) |
| Recorded workflows | Shell 199, resumable Vim 570 and Codex 270 MiB/s, with every checkpoint matching the reference | [Headless](Benchmarks/headless.md#recorded-interaction-measurements) |
| Resize with full history | Worst p95 0.662 ms, against one 120 Hz frame of 8.333 ms | [Headless](Benchmarks/headless.md#recorded-mac-measurements) |
| Warm full-grid redraw | p95 0.340 ms CPU and 0.947 ms GPU in the Mac app | [Rendering](Benchmarks/rendering.md) |
| Idle | Zero frames while idle or hidden | [Rendering](Benchmarks/rendering.md) |
| Reattach | Foreground ready and replay to Up p95 0.721 ms over loopback | [WebSocket lifecycle](Benchmarks/transport.md) |
| Real shells | Bash, Vim, Codex and shell lifecycle on Mac and iPhone, with 34 checkpoints per platform and end-to-end byte counts | [Live workflows](Benchmarks/live-workflows.md) |

The timings come from one M1 Max, so they show headroom rather than a timing baseline. [All benchmarks](Benchmarks/README.md) covers each command, what it checks and the real PTY runs.

## Develop

[AGENTS.md](AGENTS.md) lists the build, test and check commands. [The plan](docs/plan.md) is the source of truth for requirements, contracts and budgets, and [the design docs](docs/design) cover the themes, glass and the session lifecycle.

## License

Thrush is available under the [MIT License](LICENSE).
