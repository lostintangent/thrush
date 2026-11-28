# Real PTY workflows in the sample app

The Release Mac or iPhone Simulator app connects to the package’s standalone `ThrushServer` on loopback. The native responder types, pastes, navigates and copies through the same terminal view an app embeds. A loopback relay forwards the original WebSocket messages and gives each output frame to the pinned independent reference emulator. At each checkpoint the native driver compares the model and the rendered generation against the reference at the view’s actual grid. It also verifies the session’s received and applied byte counts. [Native checkpoint driver](../Sources/ThrushProofs/WorkflowDriver.swift)

From the repository root, set `DEVELOPER_DIR` to the full Xcode toolchain. Supply the path to GNU Bash 5 or later and the native Codex CLI 0.166.0. Each output directory must be new or empty.

```sh
python3 -B scripts/live-workflow/launch.py --platform mac --appearance dark \
  --bash /opt/homebrew/bin/bash --codex-bin /path/to/codex \
  --output .build/benchmarks/live-mac

python3 -B scripts/live-workflow/launch.py --platform simulator --appearance dark \
  --bash /opt/homebrew/bin/bash --codex-bin /path/to/codex \
  --output .build/benchmarks/live-iphone
```

The launcher builds the [proofs app](../docs/proofs.md), which mounts the sample's window, starts a private server and removes its shell workspace after the run. For another implementation, add `--endpoint http://127.0.0.1:3129` and use a disposable server on the same Mac that can start the fixture through a POSIX shell. The simulator launcher opens the system keyboard in a throwaway prompt before testing the terminal, accessory controls and keyboard letter rows on screen. It deletes its disposable iPhone after the run.

The default runs shell, Vim, Codex and lifecycle. Use `--workflow recovery` for a separate 8 MiB backpressure run, or select an individual flow by name. Use `--app /path/to/Thrush.app` for an existing build and `--appearance light` for the light palette. The hosted workflow verifies the Codex executable against its release checksum. [Hosted workflow](../.github/workflows/live-pty.yml)

| Workflow | What to check |
| --- | --- |
| Shell | Correct a mistyped build command, paste its arguments, run units 126 through 130, and copy the exact soft-wrapped path for unit 128 with the native pasteboard. The compiler writes a Mach-O object. |
| Vim | Edit a scratch file, resize or rotate, detach, resume with the same client ID, save the exact Unicode text on disk and quit to the original prompt. |
| Codex | Run the installed CLI, enter the songbird question, follow the streamed answer, navigate both transcript pages and return to Bash with `/quit`. The disposable Codex profile uses a local Responses provider serving the recorded answer without credentials. |
| Lifecycle | Check the PID and environment after a brief detach. Reclaim a displaced shell by tapping or typing. After the 30-second orphan timeout, the same session must accept the replacement shell, keep the old main screen in history and discard held input. Capture the replacement prompt, then scroll to capture the old screen directly above it. Verify the replacement PID. After exit, copy the final output, use the app’s New Shell button in the same view and verify process termination after explicit close. |
| Recovery | Suspend the upstream reader through an 8 MiB burst. The same socket repairs the silent tail, and typing a confirmation in the same view reaches the original producer. |

The Codex check records the view’s OSC 11 reply, the CLI’s truecolor background SGRs, and the cell attributes across the editable and submitted user rows. Codex 0.166.0 uses different blends for the composer and transcript in each appearance. The expected RGB values come from the CLI’s pinned style definitions. [Composer](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/tui/src/style.rs#L261) · [Submitted message](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/tui/src/style.rs#L68)

`server.json` records the server source, CLI version and response source. `source.json` identifies the app build, executable SHA-256, platform and appearance. Each workflow directory contains its native `workflow-report.json`, independent `controller-report.json`, and original captures. Mac window capture requires a logged-in graphical session. The driver records GPU completion and any drawable presentation timestamp separately. Physical iPhone measurements require a device run.

For a frame-level comparison of the finite lifecycle script, pass `--trace-lifecycle-frames` or select that option when dispatching the hosted run. The relay records the attachment, ordinal and payload of each message. The sample records what URLSession returned, which bytes the terminal received and applied, and each input and control write in `native-wire.jsonl`. On iPhone Simulator, `lifecycle.mov` records the replacement prompt, scrolling back to the earlier shell and choosing New Shell after exit. If the workflow fails, `controller-at-failure.json` retains the relay's observations before teardown.

## Standalone validation

Both packaged apps passed 37 checkpoints on real shells. The four-workflow runs used revision `6b1fa7f` and captured its lifecycle controls. The cursor spinner and tap or key reclaim require separate captures. For each platform, the first four workflows ran in one hosted job and the 8 MiB recovery check ran separately. The native app received and applied every byte forwarded by its observer. Each checkpoint verified a GPU-completed frame. Neither runner reported a compositor presentation timestamp.

| Platform | Shell, Vim, Codex and lifecycle | Silent recovery | Framebuffers | Vim grid before and after replay |
| --- | --- | --- | ---: | ---: |
| [Mac, macOS 27.0.1](live-workflows-mac.json) | 34 checkpoints, 29,511 bytes | 3 checkpoints, 296-byte replay at 80 × 24 | 15 | 298,944 matching RGB pixels |
| [iPhone 17, iOS 27.2 Simulator](live-workflows-iphone.json) | 34 checkpoints, 24,943 bytes | 3 checkpoints, 1,319-byte replay at 47 × 24 | 15 | 1,529,550 matching RGB pixels |

Vim’s block cursor remained visible at row 0, column 9, and both apps saved the exact 36-byte UTF-8 edit. Both copied the full soft-wrapped compiler path for unit 128. The Mac captures matched all 1,802 expected glyph cells and 84 selection fills. The iPhone captures matched all 2,090 expected glyph cells. Its leading selection handle covers one of 84 highlight fills and the trailing handle adds ink in the adjacent cell. Eleven iPhone captures also verified the software keyboard and its accessory controls.

The lifecycle traces matched frame by frame across five attachments on each platform, with 728 bytes applied on Mac and 814 on iPhone. Both shells survived a brief detach and takeover, and each orphan expired after its 30-second deadline. Each final screen preserved the shell’s last output through exit. Both recovery runs displayed the repaired screen and confirmed new input on the same socket.

Headless clients also passed all 37 checkpoints on a clean M1 Max checkout of `6b33bf2`. Bash compiled a 520-byte object, Vim saved the Unicode edit, and Codex streamed the answer and navigated both transcript pages. The lifecycle trace matched all 805 bytes through Apple URLSession. The 8 MiB burst restored the silent tail in one 310-byte repair. [Headless workflow results](live-workflows-headless.json)

To verify Mac window lifetime on an unlocked desktop, run `python3 scripts/pty/check-window.py --output .build/window-check` with an empty output directory. The driver covers, minimizes and hides the window for over 30 seconds apiece. The server’s shell wrapper records the original PID independently. The hosted Mac retained one shell and one connection through 32.000 seconds covered, 32.022 seconds minimized and 32.005 seconds hidden. The shell continued printing ticks throughout, with zero hidden Metal submissions. On reveal, the view displayed the latest generation in each case. The hosted job also sampled the standalone server for five seconds during live ticks. [Window measurements](live-workflows-mac.json) · [Hosted run and sample](https://github.com/lostintangent/thrush/actions/runs/45673878161)
