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

Both builds compile the shared SwiftPM package in Release. Each app carries its platform's compiled `default.metallib` in the `Thrush_ThrushUI.bundle` resource bundle. The development peer defaults to port 9138. Use `THRUSH_PORT` on the peer and pass `--endpoint http://127.0.0.1:PORT` to the app to choose another port.

## Scenes and appearance

The initial shell scene shows the numbered build transcript from the design study. The Mac **Replay** menu also opens the isolated first prompt, the recorded compiler log, the recorded scratch-file Vim session, a styled Swift buffer and a wide-glyph sample with a selection. The **Appearance** menu can follow the system or switch the running window to Light, Dark or the host's custom palette.

For repeatable launches, pass `--scene shell|prompt|log|vim|editor|glyphs`, `--appearance system|dark|light` or `--theme custom` as application arguments. The iPhone host uses the system keyboard and its layout guide. Pass `--hide-keyboard` to start with the keyboard dismissed.

```sh
open -n .build/demo/mac/Thrush.app --args --scene editor --appearance light
xcrun simctl launch --terminate-running-process "$udid" app.thrush.demo --scene glyphs --appearance dark
```

## Run a recorded interaction

Start a fresh peer with `bun scripts/demo-peer.ts --workflow shell`, `--workflow vim` or `--workflow codex`. The peer waits for the recorded user input before sending the following PTY bytes. Vim also waits for the recorded resizes, detach and same-ID reattachment. Once the workflow reaches its original shell prompt, an explicit close ends it.

Use `scripts/check-workflows.sh` for an automated pass over all three with Apple’s WebSocket client at the recorded grids. For a native host at a different grid or palette, append `--view` to the peer command. That mode accepts the host’s actual cursor position and color query replies. PTY output still has the source application’s recorded layout. [Inputs, grid sizes and checkpoints](../Fixtures/reference/m4/README.md)

## Embed the view

Create one `TerminalView(frame:)` from ThrushUI for the lifetime of the viewport. On the main actor, `display(_:receivedAt:)` accepts a terminal value captured by its serial owner. The package-private connection uses the same API with an immutable screen snapshot. A terminal can continue parsing while hidden. Call `reset()` on the view when replacing that terminal, and use `setRenderingActive(_:)` for native lifecycle transitions. Apply distinct sizes from `onGridSizeChange` to the emulator and transport.

A nil `view.theme` follows AppKit or UIKit appearance. To customize the 22 terminal colors, edit a copy of `TerminalTheme.slateDark` or `.slateLight` and assign it to the view. Supply `view.resolvedTheme.palette` when creating the terminal and update its `palette` from `onThemeChange`. This keeps OSC replies consistent with indexed colors on screen. The host owns the window and accessory materials.

The shader resolves palette colors from one buffer. Each immutable row has its own generation, so cursor moves and theme changes reuse its Metal geometry. The atlas stores premultiplied color emoji and coverage for tinted glyphs. A new drawable receives a complete frame, including every reused row.

See [the render benchmark](../Benchmarks/rendering.md) for the native measurement commands and [the Slate design](design/dark-demo.md) for the palettes and cell metrics.
