# Run the Thrush demo

Start a real shell server from the repository root and leave it running. The Mac app and iPhone Simulator share the loopback address it prints. Each app gets an interactive shell in a private working directory.

```sh
swift run ThrushServer
```

Build and open the Mac app from a second terminal.

```sh
scripts/build-demo.sh mac
open .build/demo/mac/Thrush.app
```

Build the iPhone app, then install it on a booted iOS 27 simulator. Use the device identifier from `simctl list devices` in place of `$udid`.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
scripts/build-demo.sh simulator
xcrun simctl install "$udid" .build/demo/simulator/Thrush.app
xcrun simctl launch "$udid" app.thrush.demo
```

Both commands build the shared SwiftPM package in Release. Thrush embeds its shader source in the binary. Creating a view starts Metal’s asynchronous compiler, and other views on that device reuse the pipeline. On Mac, `DEVELOPER_DIR=/Library/Developer/CommandLineTools scripts/build-demo.sh mac` builds the same app with Command Line Tools. The server defaults to port 9138. Use `swift run ThrushServer --port 0` to choose an available port, then pass the URL to either app.

```sh
open -n .build/demo/mac/Thrush.app --args --endpoint http://127.0.0.1:PORT
xcrun simctl launch --terminate-running-process "$udid" app.thrush.demo --endpoint http://127.0.0.1:PORT
```

The same `--endpoint` accepts the base URL of another server implementing the [terminal protocol](protocol.md).

## Scenes and appearance

For the recorded scenes, stop the shell server and start the mock peer with `bun scripts/demo-peer.ts`. The peer listens on port 9138 by default. The initial recorded shell scene shows the numbered build log from the design study. The Mac **Replay** menu also opens the isolated first prompt, the recorded compiler log, the recorded scratch-file Vim session, a styled Swift buffer, a wide-glyph sample with a selection and every text style, including blinking and concealed text. The **Appearance** menu can follow the system or switch the running window to Light, Dark or the app’s custom palette.

For repeatable launches, pass `--scene shell|prompt|log|vim|editor|glyphs|styles`, `--appearance system|dark|light` or `--theme custom` as application arguments. The iPhone app uses the system keyboard and its layout guide. Pass `--hide-keyboard` to start with the keyboard dismissed.

```sh
open -n .build/demo/mac/Thrush.app --args --scene editor --appearance light
xcrun simctl launch --terminate-running-process "$udid" app.thrush.demo --scene glyphs --appearance dark
```

## Capture the running iPhone

Run the full hosted simulator check from this checkout with `gh workflow run headless.yml --ref main`. The “iPhone simulator proof” job builds the app, starts its loopback peer and boots a disposable iPhone 17. The job’s artifact contains the original screen captures, native grid and keyboard measurements, a recording of the live system appearance switch, and the render benchmark.

To capture a single registered scene, pass its name, system appearance, orientation and expected keyboard state. The same command supports scenes supplied by the app that embeds the pane. Use the optional `oracle` input for a repository checker under `scripts/` that accepts the captured PNG, scene and appearance.

```sh
gh workflow run headless.yml --ref main -f scene=editor -f appearance=light -f orientation=landscape -f keyboard=visible
```

Run `gh workflow run headless.yml --ref main -f scene=render-benchmark` for the packaged simulator render benchmark alone.

Pass `-f scene=notices -f appearance=dark` to capture Connecting, Reconnecting, Previous shell ended, Open in another window and Ended in one simulator. The suite leaves the keyboard down for opening, replacement, takeover and exit. Before interrupting the live shell for Reconnecting, it verifies the software keyboard and terminal keys are visible. The peer opens real terminal WebSockets, waits for a cursor-position reply before interrupting an active shell, attaches a second client for takeover and sends the server exit message for Ended. Each PNG has a JSON sidecar with the native notice, its frame and its action. Vision checks the visible copy in the captured pixels. A capture with terminal output also requires a completed GPU frame. Use `notice-connecting`, `notice-reconnecting`, `notice-replacement`, `notice-displaced` or `notice-ended` for an individual capture.

Pass `-f scene=text-blink` to check blinking and concealed text in the styles scene. The simulator opens the scene in both appearances, first with motion and then with Reduce Motion, and takes a jittered burst of screenshots each time. `scripts/check-text-blink.py` requires blinking rows to alternate between fully shown and fully hidden while every other row holds still, Reduce Motion frames to match the shown text, and concealed text to leave its cells blank. The artifact keeps a shown, hidden and Reduce Motion still for each appearance. On a disposable Mac runner, `gh workflow run window-lifecycle.yml --ref main -f text_blink=true` runs the packaged Mac render benchmark, then the same captures and checks in a real window.

Pass `-f scene=toolbar-proof -f appearance=dark` to capture Connecting and takeover in a real iPhone navigation stack with a title and Close button. Each frame has the measured window, navigation bar, pane, first cell and notice geometry.

Pass `-f scene=notice-reconnect-motion` to record typing on the English software keyboard through an interrupted socket and a resumed replay. The UI test taps `git` on the live shell, taps ` status` during the outage, and waits for the complete remote echo. The movie and `reconnect-view.json` show the live, reconnecting and resumed keyboard geometry. The peer records the exact bytes received before and after replay in `reconnect-wire.json`.

When preparing a recorded workflow for the phone, add `-f layout_only=true` to the named-scene command. Its JSON gives the settled columns, rows, keyboard and accessory measurements for the PTY recorder.

## Run a recorded interaction

Start a fresh peer with `bun scripts/demo-peer.ts --workflow shell`, `--workflow vim` or `--workflow codex`. The peer waits for the recorded user input before sending the following PTY bytes. Vim also waits for the recorded resizes, detach and same-ID reattachment. Once the workflow reaches its original shell prompt, an explicit close ends it.

Use `scripts/check-workflows.sh` for an automated pass over all three with Apple’s WebSocket client at the recorded grids. For a native app at a different grid or palette, append `--view` to the peer command. That mode accepts the app’s actual cursor position and color query replies. PTY output still has the source application’s recorded layout. [Inputs, grid sizes and checkpoints](../Fixtures/reference/m4/README.md)

On macOS 27 with Xcode 27, this check opens the packaged Mac terminal. VoiceOver navigates the build log line by line and reads `Build complete.` while the displayed text stays unchanged. The test restores the previous VoiceOver setting. The output directory contains the spoken text in `voiceover.log`.

```sh
python3 scripts/interaction-capture/mac-voiceover.py --run-on-this-mac --output /tmp/thrush-mac-voiceover
```

## Embed the pane

Keep one `TerminalSession` for each terminal tab and pass it to `TerminalPane(session)` from SwiftUI. Supply `isActive: selected` if a tab can stay in the view hierarchy while another is selected. The pane measures its grid, applies the palette and routes native input through the session. The pane shows the final screen on exit. With the WebSocket transport it also presents reconnect and takeover notices. SwiftUI can read `session.title` for the tab title and observe `session.hasEnded` when the shell exits or the app calls `try await session.close()`. The user can still read and copy the final screen and history. Both native sample apps embed this pane.

Pass `theme:` or `fontSize:` to customize the running pane. With the default theme it follows system appearance. On iPhone, pass `showsKeyRow: false` to hide the key row above the keyboard.

To change individual colors, edit a copy of `TerminalTheme.slateDark` or `.slateLight` and pass it to the pane. The pane uses the same palette on screen and in its answers to shell color queries. [Render and interaction benchmarks](../Benchmarks/rendering.md) · [Slate palettes and cell metrics](design/README.md)

## Verify window and scene lifetime

A covered, minimized or hidden Mac window keeps its socket. Thrush continues parsing while it draws zero frames, then displays the latest generation on reveal. A foreground iPhone scene keeps its socket during Control Center and system alerts. A background scene, a removed destination or a tab hidden by the app detaches the WebSocket. With an app-supplied transport, the session keeps reading while the view is hidden and the app can run.

On an unlocked Mac desktop, the following check covers the demo with a second app, minimizes it, then hides the app. Each interval exceeds the server’s 30-second orphan deadline. The report checks the live shell PID, socket count, incoming output and Metal submissions across each interval. The same proof runs in the **Mac terminal window lifecycle** workflow.

```sh
python3 scripts/pty/check-window.py --output /tmp/thrush-window-proof
```

## Check the iPhone interactions

Run the UIKit, Metal and recorded workflow tests on a designated iOS 27 simulator. Use its identifier from `xcrun simctl list devices available`.

```sh
scripts/check-ios-ui.sh "$udid"
```

The command builds the package sources, shader and replay fixtures in an isolated test scheme. It uses one simulator and keeps the Xcode test result under `.build/ios-ui/$udid/Logs/Test`.

The **M4 iPhone interaction proof** Actions workflow runs the same native tests and drives the installed Release demo with XCUITest on a fresh iPhone 17 simulator. Its artifact contains portrait and landscape screenshots, four short gesture recordings per appearance, the source revision and the device profile. To run the same proof locally on an available Xcode host, pass a new or empty output directory.

```sh
python3 scripts/interaction-capture/run.py --output /tmp/thrush-iphone-interactions
```

Add `--accessibility-only` to run with the largest Dynamic Type size, Reduce Motion and Reduce Transparency. The test asks VoiceOver to read a control in Settings, then a known terminal line and the pane actions. It saves the spoken responses in `voiceover.log` and the app’s focus and announcement events in JSON. On the hosted iOS 27.2 simulator, Settings and Thrush both returned `No speech available`. Use the physical iPhone TestFlight pass to hear the line, confirm the reading position survives a reconnect and count the reconnect announcements. [Hosted accessibility results](https://github.com/lostintangent/thrush/actions/runs/45577502508)
