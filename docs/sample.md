# Run the sample app

The sample in `examples/swiftui` is one SwiftUI app for Mac and iPhone, built as a separate package whose only dependency is the `Thrush` library product. `SwiftUIExample.swift` opens the window, `ShellWindow.swift` shows a `TerminalView` and offers **New Shell** once the shell ends, and `ShellTab.swift` opens each session's WebSocket to the server.

From the repository root, start the local server. It listens on `ws://127.0.0.1:9138` and opens a real shell when the app connects.

```sh
swift run ThrushServer
```

In a second terminal, build and open the Mac app. It builds with only Command Line Tools too.

```sh
scripts/build-app.sh sample mac && open .build/sample/mac/Thrush.app
```

The iPhone Simulator shares the Mac's loopback, so the same server works there.

```sh
scripts/build-app.sh sample simulator
xcrun simctl install booted .build/sample/simulator/Thrush.app
xcrun simctl launch booted app.thrush.sample
```

To use another server, set the app's `endpoint` default on its command line, as in `open .build/sample/mac/Thrush.app --args -endpoint ws://127.0.0.1:9200` or `xcrun simctl launch booted app.thrush.sample -endpoint ws://127.0.0.1:9200`. The app adds `/socket` and its query to that URL.

The [proofs app](proofs.md) mounts this same window to record scenes, capture the running app and check its interactions.

## Embed the terminal view

Keep a `TerminalSession` for each tab and pass it to `TerminalView(session)` from SwiftUI. Supply `isActive: selected` when a tab stays in the view hierarchy while another is selected. The view measures its grid, applies the palette and routes input. SwiftUI can read `session.title` for the tab title and observe `session.hasEnded` when the shell exits or the app calls `try await session.close()`. The user can still read and copy the last screen and history. The app decides when to remove that view or present another `TerminalSession`. The sample offers **New Shell** in its toolbar after the session ends. Choosing it presents another session in the same view and removes the toolbar action. When an orphan expires, the existing session instead opens the new shell at row one and keeps the previous main screen in history.

Pass `theme:` or `fontSize:` to customize the running view. With the default theme it follows system appearance. On iPhone, pass `showsKeyRow: false` to hide the key row above the keyboard.

To change individual colors, edit a copy of `TerminalTheme.dark` or `.light` and pass it to the view. The view uses the same palette on screen and in its answers to shell color queries. [Render and interaction benchmarks](../Benchmarks/rendering.md) · [Theme palettes and cell metrics](design/README.md)
