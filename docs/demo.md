# Run the Thrush demo

Start the mock peer from the repository root and leave it running. The Mac app and iPhone Simulator connect to the same loopback address.

```sh
bun scripts/demo-peer.ts
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

Both commands build the shared SwiftPM package in Release. ThrushUI embeds its shader source in the binary. Creating a view starts Metal’s asynchronous compiler, and other views on that device reuse the pipeline. On Mac, `DEVELOPER_DIR=/Library/Developer/CommandLineTools scripts/build-demo.sh mac` builds the same app with Command Line Tools. The development peer defaults to port 9138. Use `THRUSH_PORT` on the peer and pass `--endpoint http://127.0.0.1:PORT` to the app to choose another port.

## Scenes and appearance

The initial shell scene shows the numbered build transcript from the design study. The Mac **Replay** menu also opens the isolated first prompt, the recorded compiler log, the recorded scratch-file Vim session, a styled Swift buffer and a wide-glyph sample with a selection. The **Appearance** menu can follow the system or switch the running window to Light, Dark or the host's custom palette.

For repeatable launches, pass `--scene shell|prompt|log|vim|editor|glyphs`, `--appearance system|dark|light` or `--theme custom` as application arguments. The iPhone host uses the system keyboard and its layout guide. Pass `--hide-keyboard` to start with the keyboard dismissed.

```sh
open -n .build/demo/mac/Thrush.app --args --scene editor --appearance light
xcrun simctl launch --terminate-running-process "$udid" app.thrush.demo --scene glyphs --appearance dark
```

## Capture the running iPhone

Run the full hosted simulator check from this checkout with `gh workflow run headless.yml --ref main`. The “iPhone simulator proof” job builds the app, starts its loopback peer and boots a disposable iPhone 17. The job’s artifact contains the original screen captures, native grid and keyboard measurements, a recording of the live system appearance switch, and the render benchmark.

To capture a single registered scene, pass its name, system appearance, orientation and expected keyboard state. The same command supports scenes supplied by the pane host. Use the optional `oracle` input for a repository checker under `scripts/` that accepts the captured PNG, scene and appearance.

```sh
gh workflow run headless.yml --ref main -f scene=editor -f appearance=light -f orientation=landscape -f keyboard=visible
```

Run `gh workflow run headless.yml --ref main -f scene=render-benchmark` for the packaged simulator render benchmark alone.

When preparing a recorded workflow for the phone, add `-f layout_only=true` to the named-scene command. Its JSON gives the settled columns, rows, keyboard and accessory measurements for the PTY recorder.

## Run a recorded interaction

Start a fresh peer with `bun scripts/demo-peer.ts --workflow shell`, `--workflow vim` or `--workflow codex`. The peer waits for the recorded user input before sending the following PTY bytes. Vim also waits for the recorded resizes, detach and same-ID reattachment. Once the workflow reaches its original shell prompt, an explicit close ends it.

Use `scripts/check-workflows.sh` for an automated pass over all three with Apple’s WebSocket client at the recorded grids. For a native host at a different grid or palette, append `--view` to the peer command. That mode accepts the host’s actual cursor position and color query replies. PTY output still has the source application’s recorded layout. [Inputs, grid sizes and checkpoints](../Fixtures/reference/m4/README.md)

## Embed the view

Create one `TerminalView(frame:)` from ThrushUI for the lifetime of the viewport. On the main actor, `display(_:receivedAt:)` accepts a terminal value captured by its serial owner. The package-private connection uses the same API with an immutable screen snapshot. A terminal can continue parsing while hidden. Call `reset()` on the view when replacing that terminal, and use `setRenderingActive(_:)` for native lifecycle transitions. Apply distinct sizes from `onGridSizeChange` to the emulator and transport.

A nil `view.theme` follows AppKit or UIKit appearance. To customize the 22 terminal colors, edit a copy of `TerminalTheme.slateDark` or `.slateLight` and assign it to the view. Supply `view.resolvedTheme.palette` when creating the terminal and update its `palette` from `onThemeChange`. This keeps OSC replies consistent with indexed colors on screen. The host owns the window. ThrushUI supplies the iPhone keyboard accessory. Set `keyboardAccessory` to `.none` to hide it or `.custom(...)` to install a native replacement.

The shader resolves palette colors from one buffer. Each immutable row has its own generation, so cursor moves and theme changes reuse its Metal geometry. The atlas stores premultiplied color emoji and coverage for tinted glyphs. A new drawable receives a complete frame, including every reused row.

See [the render and interaction benchmarks](../Benchmarks/rendering.md) for the native measurement commands and [the Slate design](design/dark-demo.md) for the palettes and cell metrics.

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
