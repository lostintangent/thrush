# Prove Thrush in the sample's window

ThrushProofs is the internal app that proves Thrush in the [sample app](sample.md)'s own window. It compiles the sample's `ShellWindow.swift` and `ShellTab.swift` by path, hands its `TerminalView` a package-scoped probe and adds the recorded scenes, checks, captures and benchmarks around it. Nothing it adds is public API.

```sh
scripts/build-app.sh proofs mac
scripts/build-app.sh proofs simulator
```

The Mac app is `.build/proofs/mac/Thrush.app`. The iPhone app at `.build/proofs/simulator/Thrush.app` installs as `app.thrush.proofs`. Pass `--endpoint` with the http or ws base URL of a server, and the proofs hand it to the sample as its `endpoint` default.

Each proof runs on a disposable hosted runner through one workflow per platform, fails unless its checks pass and uploads its captures and checks as an artifact.

## Scenes and appearance

The recorded scenes come from the mock peer, `bun Tests/ThrushProofs/peers/demo-peer.ts`, which listens on port 9138.

| Scene | Shows |
| --- | --- |
| `shell` | The numbered build log from the design study |
| `prompt` | The first prompt alone |
| `log` | A recorded compiler log |
| `vim` | A recorded scratch-file Vim session |
| `editor` | A styled Swift buffer |
| `glyphs` | Wide glyphs with a selection |
| `styles` | Every text style, including blinking and concealed text |
| `colors` | A program that asks for the terminal's background, then sets the opposite canvas |
| `links` | The links an `rg` search and Claude Code's trust prompt send, and the web address `gh browse` prints as plain text |

Pass `--scene` and `--appearance system|dark|light` as application arguments. On Mac, `--cycle-appearance` switches the open window to Dark, Light and a custom palette 4 s apart, starting at its first output. On iPhone, `--hide-keyboard` starts with the keyboard dismissed.

```sh
open -n .build/proofs/mac/Thrush.app --args --scene editor --appearance light
xcrun simctl launch --terminate-running-process "$udid" app.thrush.proofs --scene glyphs --appearance dark
```

## iPhone proofs

`gh workflow run iphone-proofs.yml --ref main` runs the rendering proof on a disposable iPhone Duo with its own loopback peer. It runs the packaged render benchmark, then captures the prompt, shell and editor scenes in both appearances with the keyboard up, and the editor in landscape. Each capture's pixels must pass its scene's checks and the keyboard's. A recorded switch from dark to light must keep the process, grid and selection without preparing rows or rasterizing glyphs.

Pass `-f proof=` for one of the interaction proofs below, or `-f scene=` with an optional `-f appearance=light` for one scene. A terminal scene also takes `-f orientation=landscape` and `-f keyboard=visible` or `hidden`. Add `-f layout_only=true` to save only the settled columns, rows, keyboard and key row measurements a PTY recording needs.

```sh
gh workflow run iphone-proofs.yml --ref main -f scene=editor -f appearance=light -f orientation=landscape -f keyboard=visible
```

These named scenes run their own checks:

- `render-benchmark` runs the packaged render benchmark alone.
- `cursor-spinners` captures the opening and reconnecting spinners around a controlled handshake and interruption. Each must reach contrast at the expected cursor cell and leave every other grid pixel as the live capture has it.
- `toolbar-proof` makes the same captures under the app's own navigation title and Close button, with the spinner and first prompt inside the safe-area grid.
- `text-blink` bursts screenshots of the styles scene in both appearances, with motion and then with Reduce Motion. Blinking rows must alternate between fully shown and fully hidden while other rows hold still, Reduce Motion must hold the shown text, and concealed text must leave its cells blank.
- `program-colors` captures the colors scene in both appearances, full screen and under a navigation stack. The program's canvas, never the theme's, must show around the first row, above the grid and beside the home indicator, and the navigation title must reach 4.5:1 against it.
- `under-bars` mounts the pane under an inline navigation bar in both appearances and orientations, with the keyboard hidden and shown. The canvas must reach every edge while the grid stays in the safe area above the keyboard, or runs under the home indicator while it's down, and a host's `.ignoresSafeArea()` must change no pixel.
- `reconnect-typing` types `git` with the software keyboard, interrupts the WebSocket and types ` status` during the outage. After the replay the shell must echo `git status` exactly once, across two attachments, while the keyboard holds its place.

### Interactions

`-f proof=interactions` drives the installed proofs app with XCUITest and runs the UIKit tests. In each appearance it captures the shell in portrait and landscape, the modifier chooser with keys armed, the keyboard hidden and a word selected on the last row under the home indicator, and records the chooser, the keyboard, selection and history. Every still must show the terminal, a selection must show the Metal selection, the chooser its armed key and choice, and landscape the shell's checks above the prompt. The simulated Duo's scene doesn't turn with the device, so the proof opens the shell already turned, and the UIKit tests cover the turn. `-f proof=swipes`, `links` or `accessibility` runs one of the scopes below instead, also with the UIKit tests. On a Mac with Xcode, `run.py` runs the same proofs into an empty directory, with `--swipes-only`, `--links-only` or `--accessibility-only` for a scope.

```sh
python3 Tests/ThrushProofs/run.py --output /tmp/thrush-iphone-interactions
```

- `swipes` swipes through `less`, Vim and the shell's history on a real Bash in both appearances, then makes the same gestures in Settings. Each glide must land within two rows of UIKit's own glide for its lift velocity and finish within a quarter second of it. A finger that rests before lifting must stop the program where the finger stopped. A touch that catches a flick 150 ms after it lifts must stop it too, without clicking or raising the keyboard, and a tap after a glide comes to rest must bring the keyboard back. `swipes-dark.json` and `swipes-light.json` report each gesture.
- `links` taps and presses the links scene's links with the keyboard down in both appearances. A tap on a wrapped file name must show a Copy Path menu titled with its destination, clear of the name's rows, opening upward when the name wraps across the bottom rows, and without raising the keyboard. A long press on a web link must lift it into a menu with Open Link, Copy Link and Share…, and the wrapped `gh browse` address must act as one link from its last row. A tap on a link must bring Safari forward, while a tap beside it raises the keyboard. `PhoneLinkProof.swift` holds every check.
- `accessibility` runs at the largest Dynamic Type size with Reduce Motion and Reduce Transparency. UIKit must observe all three, and VoiceOver's focus must stay on a terminal line while the socket reconnects. The hosted simulator speaks nothing, so listen on a physical iPhone. VoiceOver must say “Reconnecting” once when the socket drops, with its cursor still on the line, “New shell” once when you return to the tab after the orphan expires, with a prompt that accepts input, and “Shell ended” once when the shell ends, then nothing when that session reopens.

### UIKit tests

`scripts/check-ios-ui.sh "$udid"` runs the UIKit, Metal and recorded workflow tests on one iOS 27.2 simulator from `xcrun simctl list devices available`. It builds the package sources, shader and recordings in an isolated test scheme and keeps the Xcode result under `.build/ios-ui/$udid/Logs/Test`. The **Headless checks** workflow runs it on a fresh iPhone Duo for every push and pull request.

## Mac proofs

`gh workflow run mac-proofs.yml --ref main -f proof=NAME` runs one proof in a packaged window on a disposable Mac. A push to main that could change the window runs `window-lifecycle`.

- `window-lifecycle` covers the window with a second app, minimizes it, then hides the app, each for longer than the server's 30-second orphan deadline. Throughout, the same shell must keep one socket and keep parsing its output while the window submits no frames, and the window must show the latest output when it returns, as the [lifetime rules](design/lifecycle.md) promise. On an unlocked Mac, run `python3 Tests/ThrushProofs/check-window.py --output /tmp/thrush-window-proof`.
- `voiceover` has VoiceOver navigate the build log line by line. It must read `Build complete.` while the displayed text stays unchanged. The test restores the previous VoiceOver setting and keeps the spoken text in `voiceover.log`.
- `spinners` makes the cursor spinner checks in each appearance with the window active and inactive. A separate pair of shell attachments must show the sample's **New Shell** toolbar item when the shell exits, and the item must start another shell in the same view.
- `text-blink` runs the packaged Mac render benchmark, then the iPhone's text blink captures and checks in a real window.
- `program-colors` makes the iPhone's program color checks under the sample's title bar, a full-size window toolbar with and without its background, and a split view's detail beside a sidebar. The window title and Close must reach 4.5:1, and the sidebar's toolbar buttons must keep the window's appearance. Every check must hold again after the program's palette and the system appearance switch under one open window. `--toolbar-proof`, `--toolbar-proof split` and `--toolbar-background` open these windows.
- `appearance-reports` cycles a real shell's window through Dark, Light and the dark custom theme under programs that set mode 2031. A printer must receive `CSI ? 997 ; 2 n` for Light and `CSI ? 997 ; 1 n` for the custom theme, once each, and nothing for Dark again or for a background it sets itself. Neovim's `background` option must follow each flip.
- `links` points at the links scene's links in both appearances. Holding ⌘ over a link must engage it under a pointing hand, including when output clears it and draws it again under the resting pointer, and letting go must restore the pointer. A ⌘-click must open it in the browser, while a plain click or a ⌘-click dragged off it must not. A right-click must put Open Link and Copy Link above Copy, Paste and Select All, with no AutoFill anywhere, and a ⌘-click on a file name must offer only Copy Path. The wrapped `gh browse` address must act as one link from its second row. `MacLinkProof.swift` holds every check.

`python3 Tests/ThrushProofs/mac-ui-test.py links` or `voiceover`, with `--output` and an empty directory, runs either UI test on your own Mac.

## Drive a workflow

The [live workflow runner](../Benchmarks/live-workflows.md) takes the shell, Vim and Codex workflows through real programs in the proofs app's window, and `scripts/check-workflows.sh` plays their [recordings](../Fixtures/reference/workflows/README.md) to Apple’s WebSocket client. The runner launches the app with `--endpoint TERMINAL_ORIGIN --workflow-driver CONTROL_ORIGIN --workflow-output DIRECTORY`. The Mac driver types through AppKit's responder and a private pasteboard, and the iPhone driver through the terminal's UIKit text client, the English software keyboard and native rotation, both at the host's normal font and geometry.

The app's `WorkflowDriver.swift` and the runner's `controller.ts` talk over loopback HTTP. The controller holds each step until the app reports a settled layout or acknowledges a checkpoint, and each checkpoint must match the reference's cells and lines for the pane's actual geometry in a frame the GPU completed. On the iPhone, each captured checkpoint must show all eight key row controls and three rows of letter keys, and hold the Duo's 45 × 18 portrait grid, or 71 × 11 after Vim turns to landscape. A resumed Vim attachment keeps its last frame until the replay, so every RGB pixel inside the grid must match before detach and after replay, with the block cursor in the expected cell.

## Tour a release

Before a release, dispatch the **Release tour** workflow to see every visible surface on both platforms in both appearances. It runs the iPhone rendering, interaction and link proofs and the spinner, navigation bar, text blink, program color and under-bar scenes, the Mac spinner, text blink, program color, appearance report and link proofs, and the four live workflow runs. Each proof uploads its captures and checks as its own artifact.

```sh
gh workflow run release-tour.yml
```
