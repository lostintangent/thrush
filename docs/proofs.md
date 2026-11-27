# Prove Thrush in the sample's window

ThrushProofs is the internal app that proves Thrush in the [sample app](sample.md)'s own window. It compiles the sample's `ShellWindow.swift` and `ShellTab.swift` by path, hands its `TerminalView` a package-scoped probe and adds the recorded scenes, checks, captures and benchmarks around it. Nothing it adds is public API.

```sh
scripts/build-app.sh proofs mac
scripts/build-app.sh proofs simulator
```

The Mac app is `.build/proofs/mac/Thrush.app`. The iPhone app at `.build/proofs/simulator/Thrush.app` installs as `app.thrush.proofs`. Pass `--endpoint` with the http or ws base URL of a server, and the proofs hand it to the sample as its `endpoint` default.

## Scenes and appearance

For the recorded scenes, start the mock peer with `bun scripts/demo-peer.ts`. It listens on port 9138 by default, so stop any shell server there first. Pass `--scene` to open one. The shell scene shows the numbered build log from the design study. The others are the isolated first prompt, the recorded compiler log, the recorded scratch-file Vim session, a styled Swift buffer, a wide-glyph sample with a selection, every text style, including blinking and concealed text, a program that sets its own colors, and the links an `rg` search and Claude Code’s trust prompt send, with the web address `gh browse` prints as plain text. The colors program asks for the terminal’s background, then sets the opposite canvas. The proofs put the scene in the endpoint's path, where the peer reads it.

Pass `--scene shell|prompt|log|vim|editor|glyphs|styles|colors|links` and `--appearance system|dark|light` as application arguments. On Mac, `--cycle-appearance` switches the open window to Dark, Light and a custom palette 4 s apart, starting at its first output. The iPhone app uses the system keyboard and its layout guide. Pass `--hide-keyboard` to start with the keyboard dismissed.

```sh
open -n .build/proofs/mac/Thrush.app --args --scene editor --appearance light
xcrun simctl launch --terminate-running-process "$udid" app.thrush.proofs --scene glyphs --appearance dark
```

## Capture the running iPhone

Run the full hosted simulator check from this checkout with `gh workflow run headless.yml --ref main`. The “iPhone simulator proof” job builds the app, starts its loopback peer and boots a disposable iPhone Duo. The job’s artifact contains the original screen captures, native grid and keyboard measurements, a recording of the live system appearance switch, and the render benchmark.

To capture a single registered scene, pass its name, system appearance, orientation and expected keyboard state. The same command supports scenes supplied by the app that embeds the view. Use the optional `oracle` input for a repository checker under `scripts/` that accepts the captured PNG, scene and appearance.

```sh
gh workflow run headless.yml --ref main -f scene=editor -f appearance=light -f orientation=landscape -f keyboard=visible
```

Run `gh workflow run headless.yml --ref main -f scene=render-benchmark` for the packaged simulator render benchmark alone.

Pass `-f scene=cursor-spinners -f appearance=dark` to the hosted iPhone workflow for the opening and reconnect captures. Repeat with `light` for the other appearance. Each pair brackets a controlled WebSocket handshake or interruption in the same app process. The checker measures spoke contrast at the expected cursor cell and compares every grid pixel outside that cell against the live capture. For the Mac matrix, run `gh workflow run window-lifecycle.yml --ref main -f spinner_matrix=true`. It captures each appearance with the window active and inactive. A separate pair of shell attachments verifies that the sample's **New Shell** toolbar item appears on exit and starts another shell in the same view. [Session lifecycle checks](design/lifecycle.md)

Pass `-f scene=text-blink` to check blinking and concealed text in the styles scene. The simulator opens the scene in both appearances, first with motion and then with Reduce Motion, and takes a jittered burst of screenshots each time. `scripts/check-text-blink.py` requires blinking rows to alternate between fully shown and fully hidden while every other row holds still, Reduce Motion frames to match the shown text, and concealed text to leave its cells blank. The artifact keeps a shown, hidden and Reduce Motion still for each appearance. On a disposable Mac runner, `gh workflow run window-lifecycle.yml --ref main -f text_blink=true` runs the packaged Mac render benchmark, then the same captures and checks in a real window.

Pass `-f scene=toolbar-proof` to check the initial spinner and the first prompt inside the same safe-area grid. The app owns the navigation title and Close button.

Pass `-f scene=program-colors` to capture the colors scene in both appearances, full screen and under the same navigation stack. Each frame must show the program's canvas around the first row, above the grid and beside the home indicator, and none of the theme's. Vision reads the first command and, under the navigation stack, the title and Close. The title must reach 4.5:1 against the canvas. On a disposable Mac runner, `gh workflow run window-lifecycle.yml --ref main -f program_colors=true` makes the same checks under the sample's title bar, a full-size window toolbar with and without its background, and in a split view's detail beside a sidebar. The program's canvas must run beneath the toolbar, the window title and Close must reach 4.5:1, and the sidebar's toolbar buttons must keep the window's appearance. Live takes then switch the program's palette, through the peer's `POST /palette?name=paper` or `night`, and the system appearance under one open window, and each settled frame must pass the same checks. Pass `--toolbar-proof`, `--toolbar-proof split` and `--toolbar-background` to open the same Mac windows.

`gh workflow run window-lifecycle.yml --ref main -f appearance_reports=true` checks that programs follow the window between dark and light. The Mac proofs open `--cycle-appearance` over a real shell that runs a printer, which sets mode 2031 and logs every reply. Choosing Dark again sends nothing, Light reports `CSI ? 997 ; 2 n` and the dark Custom theme reports `CSI ? 997 ; 1 n`, once each. A background the printer sets itself sends nothing. Neovim then runs under the same flips, and its `background` option must follow each one. The artifact keeps a screenshot of each program after each step.

`gh workflow run window-lifecycle.yml --ref main -f links=true` opens the links scene in a packaged Mac window, in both appearances. Holding ⌘ with the pointer resting on Claude Code's "Security guide" must turn it into a pointing hand and draw the link engaged. Output that clears the scene, through the peer's `POST /links?draw=0`, must let the link go, and output that lays it out again under the resting pointer, through `draw=1`, must engage it and draw it the same way. Letting go of ⌘ must bring back the cursor the pointer rested with. A ⌘-click on the link must bring the default browser forward, while a plain click or a ⌘-click dragged off the link must not. A right-click must put Open Link and Copy Link above Copy, Paste and Select All, with nothing to AutoFill, and Copy Link must copy the destination. A right-click away from links must offer no AutoFill either. A ⌘-click on an `rg` file name must show a menu titled with its destination that offers only Copy Path, which copies the path. The web address `gh browse` prints as plain text wraps onto a second row. A right-click there must offer Open Link and Copy Link, Copy Link must copy the whole address, and ⌘ must engage it from that row, and a ⌘-click there must bring the browser forward. The artifact keeps stills at rest, with the tooltip, under ⌘ before and after the output and with each menu open. To run it on your own Mac, use `python3 scripts/interaction-capture/mac-links.py --output /tmp/thrush-mac-links`.

Pass `-f scene=reconnect-typing` to record held input with the iPhone software keyboard. The test types `git` in the live shell, interrupts its WebSocket and types ` status` during the outage. After replay the shell should echo the full `git status` command. Compare the bytes before and after replay and check that the keyboard kept its position.

When preparing a recorded workflow for the phone, add `-f layout_only=true` to the named-scene command. Its JSON gives the settled columns, rows, keyboard and key row measurements for the PTY recorder.

## Run a recorded interaction

Start a fresh peer with `bun scripts/demo-peer.ts --workflow shell`, `--workflow vim` or `--workflow codex`. The peer waits for the recorded user input before sending the following PTY bytes. Vim also waits for the recorded resizes, detach and same-ID reattachment. Once the workflow reaches its original shell prompt, an explicit close ends it.

Use `scripts/check-workflows.sh` for an automated pass over all three with Apple’s WebSocket client at the recorded grids. For a native app at a different grid or palette, append `--view` to the peer command. That mode accepts the app’s actual cursor position and color query replies, and ignores its focus reports. PTY output still has the source application’s recorded layout. [Inputs, grid sizes and checkpoints](../Fixtures/reference/m4/README.md)

On macOS 27 with Xcode 27, this check opens the packaged Mac terminal. VoiceOver navigates the build log line by line and reads `Build complete.` while the displayed text stays unchanged. The test restores the previous VoiceOver setting. The output directory contains the spoken text in `voiceover.log`.

```sh
python3 scripts/interaction-capture/mac-voiceover.py --run-on-this-mac --output /tmp/thrush-mac-voiceover
```

## Verify window and scene lifetime

A covered, minimized or hidden Mac window keeps its socket. Thrush continues parsing while it draws zero frames, then displays the latest generation on reveal. A foreground iPhone scene keeps its socket during Control Center and system alerts. A background scene, a removed destination or a tab hidden by the app detaches the WebSocket. With an app-supplied transport, the session keeps reading while the view is hidden and the app can run.

On an unlocked Mac desktop, the following check covers the proofs app with a second app, minimizes it, then hides the app. Each interval exceeds the server’s 30-second orphan deadline. The report checks the live shell PID, socket count, incoming output and Metal submissions across each interval. The same proof runs in the **Mac terminal window lifecycle** workflow.

```sh
python3 scripts/pty/check-window.py --output /tmp/thrush-window-proof
```

## Check the iPhone interactions

Run the UIKit, Metal and recorded workflow tests on a designated iOS 27.2 simulator. Use its identifier from `xcrun simctl list devices available`.

```sh
scripts/check-ios-ui.sh "$udid"
```

The command builds the package sources, shader and recordings in an isolated test scheme. It uses one simulator and keeps the Xcode test result under `.build/ios-ui/$udid/Logs/Test`. The **Headless checks** workflow runs it on a fresh iPhone Duo simulator for every push and pull request.

The **M4 iPhone interaction proof** Actions workflow runs the same native tests and drives the installed Release proofs app with XCUITest on a fresh iPhone Duo simulator. Its artifact contains portrait and landscape screenshots, the modifier chooser with Control, Shift and a held slide to Option armed and with Shift armed in landscape, a still with the keyboard hidden, a word selected on the last row under the home indicator, four short gesture recordings per appearance for the modifier chooser, the keyboard, selection and history, the source revision and the device profile. The simulated Duo's resizable scene doesn't turn with the device, so the proof opens the shell already turned for its landscape stills, and the UIKit tests cover the turn itself. To run the same proof locally on a Mac with Xcode, pass a new or empty output directory.

```sh
python3 scripts/interaction-capture/run.py --output /tmp/thrush-iphone-interactions
```

Add `--swipes-only` (`-f swipes_only=true`) to swipe through `less`, vim and the shell's history on a real Bash in both appearances, then make the same gestures in Settings. Each program reads through a logger that timestamps its input, so the check counts the rows every gesture sent. One synthesized flick can lift about 12% faster than the next, so the app reports UIKit's own measure of each lift: how far the finger moved the content and the velocity UIKit glides on from. The run fails if any glide through `less`, vim or the history lands more than two rows from UIKit's glide for that velocity, or if a program's last row arrives more than a quarter second after UIKit's glide comes to rest. It also fails if a program moves further than a finger that rests before lifting or moves at all once it lifts, if a flick caught by a touch 150 ms after it lifts moves further than the finger did, clicks or opens the keyboard, or if the tap after a glide comes to rest doesn't bring the keyboard back. The flick and that touch play as one XCTest event record, since XCUITest waits for UIScrollView to come to rest before its next action. `swipes-dark.json` and `swipes-light.json` report each gesture's rows beside the finger's travel, the lift velocity and the rows UIScrollView's deceleration glides from it, and the artifact keeps a recording of each segment. The UIKit tests run too, including VoiceOver's three-finger page.

Add `--links-only` (`-f links_only=true`) to open the links scene with the keyboard down in both appearances. A tap on the second row of a wrapped `rg` file name must show the link's menu, titled with its destination and offering only Copy Path, clear of both of the name's rows and without raising the keyboard. The name must stay pressed while its menu is up and let go as the menu closes. Output through the peer's `POST /links?draw=2`, where Claude exits and the search runs again, wraps the name across the bottom rows, and a tap there must open the menu upward, clear of those rows too. A long press on the last row of the web address `gh browse` prints as plain text must show a menu titled with the whole address that offers Open Link. A long press on Claude Code's "Security guide" must lift it into the context menu with Open Link, Copy Link and Share… rather than select a word. A tap beside the link on the same row must raise the keyboard, and a tap on the link must bring Safari forward. The artifact keeps a still at rest, with each menu open and with the keyboard up, and a recording of the first three menus. The UIKit tests run too.

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
