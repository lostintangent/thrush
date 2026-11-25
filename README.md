<p align="center"><img src="docs/Thrush-logo-amber.png" alt="The Thrush mark, an amber-chested bird with a terminal chevron in its slate wing" width="240"></p>

# Thrush

Thrush is a native terminal for Mac and iPhone apps. A Swift emulator with no dependencies turns PTY output into a screen, one Metal renderer draws it on both platforms, and native text input, selection, the pasteboard and VoiceOver handle everything a person does with it. An app points it at any server that speaks Thrush's small WebSocket protocol. [Toy Box](https://github.com/lostintangent/toy-box) is the first app to use it, bringing its shells to Mac and iPhone.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/thrush-dark.png">
  <img src="docs/images/thrush-light.png" alt="Thrush running Codex in a Mac window and Vim on an iPhone with the software keyboard and its Esc, Ctrl, Tab and arrow key row">
</picture>

## Add a terminal to an app

Add the package and link the `Thrush` product to your app target.

```swift
.package(url: "https://github.com/lostintangent/thrush", from: "0.2.0")
```

Keep one `TerminalSession` per tab in a main-actor model that outlives the view. Capture the tab’s stable client ID in the socket factory and pass the session to a pane.

```swift
import Thrush

let session = TerminalSession { size in
    api.terminalSocket(clientID: tabID, size: size)
}

TerminalPane(session)
```

The pane paints its whole frame, fits its grid to the safe area inside it and reports each new size to the session. Give it `.ignoresSafeArea()` and the terminal's background runs under a navigation bar or Mac toolbar while its first row starts below. It follows the system appearance between Slate Light and Slate Dark, shows the Esc, Ctrl, Tab and arrow key row above the iPhone keyboard, and owns focus, selection, copy and history. It stays attached while it's shown, including in a Mac window behind other apps, minimized or hidden, and detaches when it leaves the screen or the iPhone app goes to the background. A lost socket reconnects after 250 ms, backing off to 4 s, and typing waits for the same shell to resume. When something needs a person's attention, the pane says so in a native status strip.

| State | What the pane shows |
| --- | --- |
| Opening | **Connecting**, after 200 ms |
| A lost socket retries | **Reconnecting**, with the transcript kept and typing held for the same shell |
| The shell was replaced | **Previous shell ended**, with the new shell ready |
| Another window took the shell | **Open in another window**, with **Use Here** |
| The shell exited | **Ended**, with **New Shell** |

On iPhone, a host can choose which tab accepts input, set the appearance and customize the keyboard accessory. Each argument after the session is optional.

```swift
TerminalPane(
    session,
    isActive: isSelectedTab,        // false while a tab stays in the hierarchy but is hidden
    theme: .slateDark,              // nil follows the system appearance
    fontSize: 15,
    keyboardAccessory: .none        // .standard, .none or .custom(view)
)
```

To customize the colors, edit a copy of `TerminalTheme.slateDark` or `.slateLight` and pass it as `theme:`. A `Terminal.Palette` holds the foreground, background and 16 ANSI colors as `Terminal.RGB` values. On iPhone, a custom accessory is a `UIView` that conforms to `TerminalInputAccessory`. Its buttons call `onKeyPress` with a UIKit key string and modifiers, for example `onKeyPress?(UIKeyCommand.inputUpArrow, [])` or `onKeyPress?("c", .control)`.

SwiftUI observes `session.title` and `session.hasEnded` directly. The title starts empty and changes when a terminal program sets it. A tab can display it with `.navigationTitle(session.title.isEmpty ? "Terminal" : session.title)`. The session ends when the shell exits or the host calls `try await session.close()`. On shell exit, the pane keeps its last screen and offers **New Shell**. A host that closes ended tabs can observe `session.hasEnded` with `.onChange`. [Pane states and behavior](docs/design/pane-states.md)

### The socket

On every attachment, the socket factory receives only the current `Terminal.Size` in columns and rows. Your app’s transport returns a fresh, suspended `URLSessionWebSocketTask` for the same client ID each time. Use the app’s `URLSession` so its authentication and TLS settings apply. Connect to `/socket?service=terminal&clientId=…&cols=…&rows=…`. Binary messages carry terminal input and output in order. Small JSON messages handle ready, resize, close and exit. Reattaching with the same ID during the orphan window restores the previous shell. [Terminal protocol](docs/protocol.md)

Thrush needs macOS 27 or iOS 27 and Swift 6.4. It builds from the command line with Xcode 27.2 or, for Mac, Command Line Tools.

## Try the sample apps

From the repository root, start the local server. It prints its loopback URL and opens a real shell when the app connects.

```sh
swift run ThrushServer
```

In a second terminal, build and open the Mac app. The same server works with the iPhone Simulator.

```sh
scripts/build-demo.sh mac && open .build/demo/mac/Thrush.app
```

`scripts/build-demo.sh simulator` builds the iPhone app. Pass `--endpoint URL` to either app to use another server. A scripted peer supplies the recorded demo scenes for offline playback. [Running the sample apps](docs/demo.md)

## Benchmarks

`swift run -c release ThrushBench` checks every recorded replay against an independent reference emulator, then writes its measurements to `.build/benchmarks`.

| Measure | Result | Report |
| --- | --- | --- |
| Sustained output | 445 MiB/s at 80 × 24, against a 100 MiB/s target | [Headless](Benchmarks/headless.md#recorded-mac-measurements) |
| Recorded workflows | Shell 135, resumable Vim 330 and Codex 219 MiB/s, with every checkpoint matching the reference | [Headless](Benchmarks/headless.md#recorded-interaction-measurements) |
| Resize with full history | Worst p95 0.796 ms, against one 120 Hz frame of 8.333 ms | [Headless](Benchmarks/headless.md#recorded-mac-measurements) |
| Warm full-grid redraw | p95 0.274 ms CPU and 0.102 ms GPU in the Mac app | [Rendering](Benchmarks/rendering.md) |
| Idle | Zero frames while idle or hidden | [Rendering](Benchmarks/rendering.md) |
| Reattach | Foreground ready and replay to Up p95 0.872 ms over loopback | [Connection](Benchmarks/connection.md) |
| Real shells | Bash, Vim, Codex and shell lifecycle on Mac and iPhone, with 34 checkpoints per platform and end-to-end byte counts | [Live workflows](Benchmarks/live-workflows.md) |

The timings come from one contended M1 Max, so they show headroom rather than a timing baseline. [All benchmarks](Benchmarks/README.md) covers each command, what it checks and the real PTY runs.

## Develop

[AGENTS.md](AGENTS.md) lists the build, test and check commands. [The plan](docs/plan.md) is the source of truth for requirements, contracts, budgets and milestones, and [the design docs](docs/design) cover Slate, glass and the pane states.

## License

Thrush is available under the [MIT License](LICENSE).
