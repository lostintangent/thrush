# Real PTY workflows in the sample apps

The Release Mac or iPhone Simulator app connects to a disposable production Toy Box terminal. The native responder types, pastes, navigates and copies through the same pane the host embeds. A loopback relay forwards the original WebSocket messages and gives a copy of each output frame to Toy Box’s pinned xterm 6.0.0. At each checkpoint the native driver compares the model and the rendered generation against xterm at the pane’s actual grid. It also verifies the connection’s received and applied byte counts. [Native checkpoint driver](../scripts/check-pane-workflows.py)

From the repository root, set `DEVELOPER_DIR` to the full Xcode toolchain. Supply the path to GNU Bash 5 or later and the native Codex CLI 0.166.0. Each output directory must be new or empty.

```sh
python3 -B scripts/live-workflow/launch.py --platform mac --appearance dark \
  --toy-box ../toy-box --bash /opt/homebrew/bin/bash --codex-bin /path/to/codex \
  --output .build/benchmarks/live-mac

python3 -B scripts/live-workflow/launch.py --platform simulator --appearance dark \
  --toy-box ../toy-box --bash /opt/homebrew/bin/bash --codex-bin /path/to/codex \
  --output .build/benchmarks/live-iphone
```

The launcher builds the sample, starts the pinned server on an ephemeral loopback port with a private home, and removes its shell workspace when the run ends. The simulator command creates and deletes its own iPhone. Use `--workflow shell`, `vim`, `codex` or `lifecycle` to select a single flow. Use `--app /path/to/Thrush.app` to exercise an existing build, or `--appearance light` to verify the light palette. The [packaged-app workflow](../.github/workflows/live-pty.yml) fetches the pinned public Toy Box revision and verifies the Codex binary against its release checksum. Its `--public-web-build` option uses Toy Box Core’s public-build recipe in a temporary checkout. Two unrelated web components receive local stand-ins for their animations. The launcher checks that the retained package versions and integrity hashes match the original lockfile. It records the original Git tree, SHA-256 of the build inputs, and five patched-file hashes in `server.json`. The terminal WebSocket, PTY and scrollback sources come from the pin.

| Workflow | Checked outcome |
| --- | --- |
| Shell | Correct a mistyped build command, paste its arguments, run units 126 through 130, and copy the exact soft-wrapped path for unit 128 with the native pasteboard. The compiler writes a Mach-O object. |
| Vim | Edit a scratch file, resize or rotate, detach, resume with the same client ID, save the exact Unicode text on disk and quit to the original prompt. |
| Codex | Run the installed CLI, enter the songbird question, follow the streamed answer, navigate both transcript pages and return to Bash with `/quit`. The disposable Codex profile uses a local Responses provider serving the recorded answer without credentials. |
| Lifecycle | Check the shell PID and environment after reactivating the pane, displace it with a second owner, reclaim with Use Here, and leave the pane inactive through the server’s real 30-second orphan expiry. Check the replacement PID, final output at exit, the New Shell button and process termination after explicit close. |

The Codex check records the pane’s OSC 11 reply, the CLI’s truecolor background SGRs, and the cell attributes across the editable and submitted user rows. Codex 0.166.0 uses different blends for the composer and transcript in each appearance. The expected RGB values come from the CLI’s pinned style definitions. [Composer](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/tui/src/style.rs#L261) · [Submitted message](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/tui/src/style.rs#L68)

`server.json` records the server source, CLI version and response source. `source.json` identifies the app build, platform and appearance. Each workflow directory contains its native `workflow-report.json`, independent `controller-report.json`, and original captures. A locked Mac can supply window pixels and GPU completion while leaving presentation timestamps unavailable. The physical iPhone pass uses Toy Box’s TestFlight build.


## Mac sample result

The clean `f8c58c4` sample passed all 34 checkpoints across the four workflows on Slate Dark. All 32,429 original and replay bytes agreed between the server relay and the native received and applied counters. Thirteen window images matched 1,592 reference glyph cells and all 84 cells of the wrapped selection. The locked Mac reported GPU completion. [Run evidence](live-workflows-mac.json)
