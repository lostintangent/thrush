# Run the Thrush demo

Start a real shell server from the repository root and leave it running. The Mac app and iPhone Simulator share the loopback address it prints. Each app gets an interactive shell in a private working directory. When the shell exits, its final screen stays available for reading and copying. Choose **New Shell** in the app’s toolbar to start another.

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

For the recorded scenes, stop the shell server and start the mock peer with `bun scripts/demo-peer.ts`. The peer listens on port 9138 by default. The initial recorded shell scene shows the numbered build log from the design study. The Mac **Replay** menu also opens the isolated first prompt, the recorded compiler log, the recorded scratch-file Vim session, a styled Swift buffer, a wide-glyph sample with a selection, every text style, including blinking and concealed text, and a program that sets its own colors. That program asks for the terminal’s background, then sets the opposite canvas. The **Appearance** menu can follow the system or switch the running window to Light, Dark or the app’s custom palette.

For repeatable launches, pass `--scene shell|prompt|log|vim|editor|glyphs|styles|colors`, `--appearance system|dark|light` or `--theme custom` as application arguments. The iPhone app uses the system keyboard and its layout guide. Pass `--hide-keyboard` to start with the keyboard dismissed.

```sh
open -n .build/demo/mac/Thrush.app --args --scene editor --appearance light
xcrun simctl launch --terminate-running-process "$udid" app.thrush.demo --scene glyphs --appearance dark
```

## Capture the running iPhone

Run the full hosted simulator check from this checkout with `gh workflow run headless.yml --ref main`. The “iPhone simulator proof” job builds the app, starts its loopback peer and boots a disposable iPhone 17. The job’s artifact contains the original screen captures, native grid and keyboard measurements, a recording of the live system appearance switch, and the render benchmark.

To capture a single registered scene, pass its name, system appearance, orientation and expected keyboard state. The same command supports scenes supplied by the app that embeds the view. Use the optional `oracle` input for a repository checker under `scripts/` that accepts the captured PNG, scene and appearance.

```sh
gh workflow run headless.yml --ref main -f scene=editor -f appearance=light -f orientation=landscape -f keyboard=visible
```

Run `gh workflow run headless.yml --ref main -f scene=render-benchmark` for the packaged simulator render benchmark alone.

Pass `-f scene=cursor-spinners -f appearance=dark` to the hosted iPhone workflow for the opening and reconnect captures. Repeat with `light` for the other appearance. Each pair brackets a controlled WebSocket handshake or interruption in the same app process. The checker measures spoke contrast at the expected cursor cell and compares every grid pixel outside that cell against the live capture. For the Mac matrix, run `gh workflow run window-lifecycle.yml --ref main -f spinner_matrix=true`. It captures each appearance with the window active and inactive. A separate pair of shell attachments verifies the Mac titlebar action appears on exit, starts another shell and leaves the terminal grid in place. [Session lifecycle checks](design/lifecycle.md)

Pass `-f scene=text-blink` to check blinking and concealed text in the styles scene. The simulator opens the scene in both appearances, first with motion and then with Reduce Motion, and takes a jittered burst of screenshots each time. `scripts/check-text-blink.py` requires blinking rows to alternate between fully shown and fully hidden while every other row holds still, Reduce Motion frames to match the shown text, and concealed text to leave its cells blank. The artifact keeps a shown, hidden and Reduce Motion still for each appearance. On a disposable Mac runner, `gh workflow run window-lifecycle.yml --ref main -f text_blink=true` runs the packaged Mac render benchmark, then the same captures and checks in a real window.

Pass `-f scene=toolbar-proof` to check the initial spinner and the first prompt inside the same safe-area grid. The app owns the navigation title and Close button.

Pass `-f scene=program-colors` to capture the colors scene in both appearances, full screen and under the same navigation stack. Each frame must show the program's canvas around the first row and beyond the grid, and none of the theme's. Vision reads the first command and, under the navigation stack, the title and Close. The status bar clock and the title must each reach 4.5:1 against the canvas. On a disposable Mac runner, `gh workflow run window-lifecycle.yml --ref main -f program_colors=true` makes the same checks under the demo's title bar, a full-size window toolbar with and without its background, and in a split view's detail beside a sidebar. The program's canvas must run beneath the toolbar, the window title and Close must reach 4.5:1, and the sidebar's toolbar buttons must keep the window's appearance. Live takes then switch the program's palette, through the peer's `POST /palette?name=paper` or `night`, and the system appearance under one open window, and each settled frame must pass the same checks. Pass `--toolbar-proof`, `--toolbar-proof split` and `--toolbar-background` to open the same Mac windows.

`gh workflow run window-lifecycle.yml --ref main -f appearance_reports=true` checks that programs follow the window between dark and light. The Mac demo opens `--cycle-appearance` over a real shell that runs a printer, which sets mode 2031 and logs every reply. Choosing Dark again sends nothing, Light reports `CSI ? 997 ; 2 n` and the dark Custom theme reports `CSI ? 997 ; 1 n`, once each. A background the printer sets itself sends nothing. Neovim then runs under the same flips, and its `background` option must follow each one. The artifact keeps a screenshot of each program after each step.

Pass `-f scene=reconnect-typing` to record held input with the iPhone software keyboard. The test types `git` in the live shell, interrupts its WebSocket and types ` status` during the outage. After replay the shell should echo the full `git status` command. Compare the bytes before and after replay and check that the keyboard kept its position.

When preparing a recorded workflow for the phone, add `-f layout_only=true` to the named-scene command. Its JSON gives the settled columns, rows, keyboard and key row measurements for the PTY recorder.

## Run a recorded interaction

Start a fresh peer with `bun scripts/demo-peer.ts --workflow shell`, `--workflow vim` or `--workflow codex`. The peer waits for the recorded user input before sending the following PTY bytes. Vim also waits for the recorded resizes, detach and same-ID reattachment. Once the workflow reaches its original shell prompt, an explicit close ends it.

Use `scripts/check-workflows.sh` for an automated pass over all three with Apple’s WebSocket client at the recorded grids. For a native app at a different grid or palette, append `--view` to the peer command. That mode accepts the app’s actual cursor position and color query replies, and ignores its focus reports. PTY output still has the source application’s recorded layout. [Inputs, grid sizes and checkpoints](../Fixtures/reference/m4/README.md)

On macOS 27 with Xcode 27, this check opens the packaged Mac terminal. VoiceOver navigates the build log line by line and reads `Build complete.` while the displayed text stays unchanged. The test restores the previous VoiceOver setting. The output directory contains the spoken text in `voiceover.log`.

```sh
python3 scripts/interaction-capture/mac-voiceover.py --run-on-this-mac --output /tmp/thrush-mac-voiceover
```

## Embed the terminal view

Keep a `TerminalSession` for each tab and pass it to `TerminalView(session)` from SwiftUI. Supply `isActive: selected` when a tab stays in the view hierarchy while another is selected. The view measures its grid, applies the palette and routes input. SwiftUI can read `session.title` for the tab title and observe `session.hasEnded` when the shell exits or the app calls `try await session.close()`. The user can still read and copy the last screen and history. The app decides when to remove that view or present another `TerminalSession`. Both sample apps offer **New Shell** in their toolbar after the session ends. Choosing it presents another session in the same view and removes the toolbar action. When an orphan expires, the existing session instead opens the new shell at row one and keeps the previous main screen in history.

Pass `theme:` or `fontSize:` to customize the running view. With the default theme it follows system appearance. On iPhone, pass `showsKeyRow: false` to hide the key row above the keyboard.

To change individual colors, edit a copy of `TerminalTheme.slateDark` or `.slateLight` and pass it to the view. The view uses the same palette on screen and in its answers to shell color queries. [Render and interaction benchmarks](../Benchmarks/rendering.md) · [Slate palettes and cell metrics](design/README.md)

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

The command builds the package sources, shader and recordings in an isolated test scheme. It uses one simulator and keeps the Xcode test result under `.build/ios-ui/$udid/Logs/Test`. The **Headless checks** workflow runs it on a fresh iPhone 17 simulator for every push and pull request.

The **M4 iPhone interaction proof** Actions workflow runs the same native tests and drives the installed Release demo with XCUITest on a fresh iPhone 17 simulator. Its artifact contains portrait and landscape screenshots, a still with the keyboard hidden, five short gesture recordings per appearance, the source revision and the device profile. To run the same proof locally on a Mac with Xcode, pass a new or empty output directory.

```sh
python3 scripts/interaction-capture/run.py --output /tmp/thrush-iphone-interactions
```

For a keyboard-open rotation check in both appearances, add `--rotation-only` or dispatch the workflow with `-f rotation_only=true`. The capture turns to landscape and back twice, then opens a full log, hides the keyboard with the key row's button and taps the terminal to bring it back. The check compares the complete shell resize sequence with the two settled grids and keeps the native recordings, screenshots and peer trace. Add `--trace-rotation-layout` (`-f trace_rotation_layout=true`) to record UIKit's layouts, keyboard frames and the row a reader follows in every displayed frame. The run then fails if that row changes, leaves the viewport or jumps against it in any frame of the turn. A jump moves the row further than either viewport edge carried it and more than half a row against both for each display frame since the previous sample. Frames before the window's turn begins in its layer's time are skipped, since UIKit can hold the turn until the keyboard lays out. After a stall the main thread can read a turn further along than the one the screen then begins, so a frame further from where its turn settles than a later one is skipped too. One frame per turn whose row doesn't span its viewport is skipped too, since every commit lays out the whole tree and it was read between layout passes. A second such frame fails the turn, and so does a skipped frame where the turn settles. Each direction must be sampled while it turns, since a stalled main thread can miss a turn entirely. The row is held above the key row once the system's keyboard animations finish.

Add `--accessibility-only` to run with the largest Dynamic Type size, Reduce Motion and Reduce Transparency. The check records VoiceOver speech in `voiceover.log` and the focused element in `accessibility-spinner-reconnecting.json`. The hosted iOS 27.2 simulator returned `No speech available` in both Settings and Thrush. On a physical iPhone, read a terminal line, interrupt the socket and listen for “Reconnecting” once. Verify that the reading cursor stays on the same line. Let the orphan expire and return to the tab. Listen for “New shell” once and check that the prompt accepts input. End the shell and listen for “Shell ended” once. Reopening that session should be silent. [Hosted accessibility results](https://github.com/lostintangent/thrush/actions/runs/45707888711)

## Tour a release

Before a release, dispatch the **Release tour** workflow to see every visible surface on both platforms in both appearances. It runs the iPhone interaction proof, the four live workflow runs, the Mac spinner, program color and appearance report captures and the iPhone spinner, navigation bar and program color scenes, then lays their screenshots out on four labeled contact sheets. The `thrush-release-tour` artifact holds the sheets and `tour.json`, which names the capture behind each tile. A surface with no capture keeps a dashed tile on its sheet and an entry under `missing`, so a failed job shows as a gap rather than disappearing.

```sh
gh workflow run release-tour.yml
```

To lay out sheets from artifacts you have already downloaded, pass their parent directory and an output directory.

```sh
xcrun swift scripts/release-tour.swift ~/Downloads/thrush-captures /tmp/thrush-release-tour
```
