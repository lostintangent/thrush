# Real PTY workflows in the sample apps

The Release Mac or iPhone Simulator app connects to a disposable production Toy Box terminal. The native responder types, pastes, navigates and copies through the same pane the host embeds. A loopback relay forwards the original WebSocket messages and gives a copy of each output frame to the pinned reference emulator Toy Box’s server runs. At each checkpoint the native driver compares the model and the rendered generation against the reference at the pane’s actual grid. It also verifies the connection’s received and applied byte counts. [Native checkpoint driver](../scripts/check-pane-workflows.py)

From the repository root, set `DEVELOPER_DIR` to the full Xcode toolchain. Supply the path to GNU Bash 5 or later and the native Codex CLI 0.166.0. Each output directory must be new or empty.

```sh
python3 -B scripts/live-workflow/launch.py --platform mac --appearance dark \
  --toy-box ../toy-box --bash /opt/homebrew/bin/bash --codex-bin /path/to/codex \
  --output .build/benchmarks/live-mac

python3 -B scripts/live-workflow/launch.py --platform simulator --appearance dark \
  --toy-box ../toy-box --bash /opt/homebrew/bin/bash --codex-bin /path/to/codex \
  --output .build/benchmarks/live-iphone
```

The launcher builds the sample, starts the pinned server on an ephemeral loopback port with a private home, and removes its shell workspace when the run ends. The simulator command creates its own iPhone and opens the system keyboard in a throwaway prompt before the workflows start. The Bash, Vim and Codex captures check the terminal, accessory controls and keyboard letter rows in the actual framebuffer. The launcher deletes the simulator after the run. Use `--workflow shell`, `vim`, `codex` or `lifecycle` to select a single flow. Use `--app /path/to/Thrush.app` to exercise an existing build, or `--appearance light` to verify the light palette. The [packaged-app workflow](../.github/workflows/live-pty.yml) fetches the pinned public Toy Box revision and verifies the Codex binary against its release checksum. Its `--public-web-build` option uses Toy Box Core’s public-build recipe in a temporary checkout. Two unrelated web components receive local stand-ins for their animations. The launcher checks that the retained package versions and integrity hashes match the original lockfile. It records the original Git tree, SHA-256 of the build inputs, and five patched-file hashes in `server.json`. The terminal WebSocket, PTY and scrollback sources come from the pin.

| Workflow | Checked outcome |
| --- | --- |
| Shell | Correct a mistyped build command, paste its arguments, run units 126 through 130, and copy the exact soft-wrapped path for unit 128 with the native pasteboard. The compiler writes a Mach-O object. |
| Vim | Edit a scratch file, resize or rotate, detach, resume with the same client ID, save the exact Unicode text on disk and quit to the original prompt. |
| Codex | Run the installed CLI, enter the songbird question, follow the streamed answer, navigate both transcript pages and return to Bash with `/quit`. The disposable Codex profile uses a local Responses provider serving the recorded answer without credentials. |
| Lifecycle | Check the shell PID and environment after reactivating the pane, displace it with a second owner, reclaim with Use Here, and leave the pane inactive through the server’s real 30-second orphan expiry. Check the replacement PID, final output at exit, the New Shell button and process termination after explicit close. On iPhone, Use Here leaves the keyboard down. The driver activates the live grid before typing again. |

The Codex check records the pane’s OSC 11 reply, the CLI’s truecolor background SGRs, and the cell attributes across the editable and submitted user rows. Codex 0.166.0 uses different blends for the composer and transcript in each appearance. The expected RGB values come from the CLI’s pinned style definitions. [Composer](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/tui/src/style.rs#L261) · [Submitted message](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/tui/src/style.rs#L68)

`server.json` records the server source, CLI version and response source. `source.json` identifies the app build, executable SHA-256, platform and appearance. Each workflow directory contains its native `workflow-report.json`, independent `controller-report.json`, and original captures. A locked Mac can supply window pixels and GPU completion while leaving presentation timestamps unavailable. The physical iPhone pass uses Toy Box’s TestFlight build.

For a frame-level comparison of the finite lifecycle script, pass `--trace-lifecycle-frames` or select that option when dispatching the hosted run. The relay records the attachment, ordinal and payload of each message. The sample records what URLSession returned and which bytes the terminal received and applied in `native-wire.jsonl`. If the workflow fails, `controller-at-failure.json` retains the relay's observations before teardown.


## Mac sample result

The hosted `7826b55` sample passed all 34 checkpoints on macOS 27.0.1. All 28,910 bytes agreed at the relay and the native terminal. Thirteen window captures matched all 1,616 expected glyph cells and all 84 selection fills. After natural exit, the bounded pixel check read **Ended** and **New Shell** in the notice, while the final shell PID stayed visible. The five lifecycle sockets matched frame by frame. The hosted runner reported GPU completion at each checkpoint. [Hosted evidence](live-workflows-mac-hosted.json) · [Run](https://github.com/lostintangent/thrush/actions/runs/45583895283)

The clean `f8c58c4` sample passed all 34 checkpoints across the four workflows on Slate Dark. All 32,429 original and replay bytes agreed between the server relay and the native received and applied counters. Thirteen window images matched 1,592 reference glyph cells and all 84 cells of the wrapped selection. The locked Mac reported GPU completion. [Run evidence](live-workflows-mac.json)

## iPhone Simulator result

The clean `7826b55` sample passed all 34 checkpoints in one iPhone 17 Simulator session on iOS 27.2. The relay forwarded 170 binary frames and the native terminal received and applied all 22,667 bytes, including 1,422 replay bytes. Vim rotated from 47×25 to 90×9 and back, resumed from a 1,204-byte replay and saved the expected 36 UTF-8 bytes. Bash copied the exact soft-wrapped Unicode path. All eleven interactive captures showed the software keyboard and seven accessory controls. Across thirteen screenshots, all 1,904 expected glyph cells matched. The copy frame had one extra ink cell and matched 83 of 84 selection fills. Metal completed each checkpoint. The simulator provided no drawable presentation timestamps. [iPhone evidence](live-workflows-iphone.json) · [Full four-workflow run](https://github.com/lostintangent/thrush/actions/runs/45581538459/attempts/2)

An earlier trace caught a 13-byte Bash prompt redraw still queued on the old socket during detach. The driver now waits for that redraw and its native acknowledgement before detaching. [Paired traces](pty-detach.json)

All 646 lifecycle bytes and six server controls matched on the five sockets. The original shell, PID 13330, survived a brief detach, foreground return and takeover. After a 30.073-second orphan interval, Bash started a fresh shell with PID 14873. The final frame preserved `FINAL:14873` and showed **Ended** and **New Shell** inside the measured panel. New Shell opened PID 17324, and the explicit close terminated that process. Both Use Here and New Shell sent zero terminal input bytes. A separate native run repeated all seven lifecycle checkpoints. [Independent lifecycle run](https://github.com/lostintangent/thrush/actions/runs/45583533253)
