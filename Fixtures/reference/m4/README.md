# Recorded shell, Vim and Codex workflows

The three recordings drive the standalone peer through the same WebSocket protocol as the native demo. Each PTY read keeps its original byte boundary. Checkpoints carry the pinned xterm viewport, attributes, cursor, modes and scrollback. Replaying the committed files is offline. [Reference setup](../m2/README.md)

| Recording | Starting grid | Interactions and checkpoints |
| --- | --- | --- |
| `shell-workflow` | 80 × 24 | Resize to 47 × 25, type `./builx`, press Backspace, paste `d 126 130`, then press Enter. Bash 5.3.9 enables bracketed paste. The executed command compiles five numbered headers and returns to the shell. |
| `vim-resume` | 80 × 24 | Open `scratch.txt`, insert wide and combining text, resize through portrait and landscape, detach, resume on the same client ID, save and quit. The recorded Vim session checks the saved file on disk. |
| `codex-session` | 80 × 16 | Launch Codex CLI 0.166.0 in a disposable workspace, enter a question about songbirds, watch the answer stream, press Ctrl-T, Page Up and Page Down, then enter `/quit`. |

## Shell selection

At `Copy soft-wrapped compiler path`, xterm selected from absolute buffer row 3, column 0 to row 4, column 37 (exclusive). The expected copy is the `copy.text` field, including the original combining accent. The intermediate soft wrap contributes no newline. `shell-selection.mjs` obtains this string through the pinned browser selection service. The recorded bytes include Bash enabling and disabling bracketed paste, the input delimiters and the PTY’s echo of the corrected command.

## Vim reattachment

`vim-resume.mjs` feeds the real, saved-file-checked Vim recording to the pinned Toy Box server’s `ScrollbackBuffer`. It adds a scripted detach and a serialized replay at the restored 80 × 24 size. The original terminal stays alive on the server. The resumed client starts with a new terminal at the same size and palette.

| Boundary | Expected event |
| --- | --- |
| `Vim before detach` | Edited alternate screen with cursor at row 0, column 9 |
| `Vim detached` | Close the socket and retain client ID `r5-vim` |
| `Vim resumed ready` | Receive the ready control with `resumed: true`. The fresh client grid is empty. |
| `Vim serialized replay` | Apply one 1,848-byte binary frame. The recorded server restores the edited text and modes, with the cursor at row 0, column 8. |
| `Vim first live output after replay` | Apply Vim’s response to `:wq` after the replay |
| `Returned to shell` | Read the original `thrush$ ` prompt |

## Codex transcript

The captured response came from OpenAI’s GPT-6.1-Sol through the installed Codex CLI. The recording includes the submitted prompt, the working indicator, a partial numbered answer, the twelfth answer, the earlier transcript page and the return to the shell. The default Release, CI and demo workflows consume these captured bytes and make no model request. The public trace replaces the resumable thread UUID with a sample of identical length, preserving every read boundary. [Codex capture procedure and checkpoints](codex-readme.md)

Codex uses synchronized output while drawing its interface. The core continues parsing and answering queries in each batch. The screen snapshot carries the active batch identifier so the view can delay presentation until the reset or xterm’s one-second presentation timeout.

## Reproduction

Regenerate the xterm checkpoints from the committed source recordings. A single name after the checkout path selects one recording.

```sh
NODE_PATH="$PWD/../toy-box/node_modules/@xterm/xterm/src" bun Fixtures/reference/m2/generate.mjs ../toy-box
scripts/check-workflows.sh
```

To record new shell bytes, run the following with the captured Bash version and the pinned Toy Box checkout. The Vim overlay is reproducible from the existing M2 scratch-file session.

```sh
python3 Fixtures/reference/m4/shell-workflow.py ../toy-box --bash /opt/homebrew/bin/bash
NODE_PATH="$PWD/../toy-box/node_modules/@xterm/xterm/src" bun Fixtures/reference/m4/vim-resume.mjs ../toy-box
```

`codex-capture.py --help` describes the separate live recording procedure. A new recording uses the specified Codex binary and login and makes a new model request. The text, timing and PTY chunks can differ between live runs.

## Native pointer input

The Codex transcript pager enables X11 button, drag and all-motion tracking and requests SGR coordinates. The pointer replay exercises those modes through xterm's mouse service at 240 × 8, including legacy binary coordinates above ASCII, the 223-column limit, SGR release and wheel events, modifiers and the return to local selection. Its expected frames come from the reference terminal's binary and text streams. Regenerate from the repository root.

```sh
NODE_PATH="$PWD/../toy-box/node_modules/@xterm/xterm/src" bun Fixtures/reference/m2/generate.mjs ../toy-box pointer-input
```

## Running the native pane

The packaged demo can attach to a terminal server and take workflow actions from a separate loopback controller. The Mac driver uses AppKit's responder and a private pasteboard. The iPhone driver uses the terminal's UIKit text client, English software keyboard and native view rotation. Both retain the host's normal font and geometry. The app drives actual window or scene layout, checks the remote byte count, reads the live terminal and checks which submitted grid completed successfully on the GPU. The report records whether the drawable supplied a presentation timestamp by the checkpoint.

```sh
scripts/check-pane-workflows.sh mac /tmp/thrush-mac-workflows
scripts/check-pane-workflows.sh simulator new /tmp/thrush-phone-workflows
```

The second command creates a disposable iPhone 17 Simulator. Supply its UDID in place of `new` to use an existing booted iPhone. Add one or more of `shell`, `vim` and `codex` to run a subset. A separate prompt opens the first system keyboard before recording. The image check verifies all seven accessory controls and three rows of native letter keys in each recorded iPhone screenshot. Keep the output directory empty before the run. Each workflow leaves its report, peer log and selected native window or framebuffer images there. An offline run can set `THRUSH_XTERM_MODULES` to an installation of `@xterm/headless` 6.0.0 and `@xterm/addon-unicode11` 0.9.0. Otherwise the runner installs those exact versions in a temporary directory.

The phone fixture uses real Vim, its server's serializer and the installed Codex CLI at handset dimensions. The narrow Codex recording uses a localhost Responses endpoint that streams the existing published twelve-line answer into the CLI. The wide capture retains the original external provider response. [Handset recording procedure](phone/README.md)

### Control protocol

Launch the packaged app with `--endpoint TERMINAL_ORIGIN --workflow-driver CONTROL_ORIGIN --workflow-output DIRECTORY`. Only the controller must be an HTTP listener on loopback. The shared test client ID is `thrush-native-workflow`. The terminal receives normal binary input and JSON resize, attach and close messages.

| Request | Meaning |
| --- | --- |
| `GET /fixture` | Return the complete v1 workflow with its semantic actions, lifecycle events and expected checkpoint names. |
| `GET /state?clientId=ID` | Return `phase`, zero-based `eventIndex`, `name`, cumulative `outputBytes`, `attachments` and current `grid`. A failure includes `error`. |
| `POST /layout?clientId=ID` | The app reports `eventIndex`, `columns` and `rows` after the layout settles. Return 204 once the real socket matches, or 409 while the resize is still in flight. Initial layout uses index −1. |
| `GET /checkpoint?clientId=ID&eventIndex=N` | While checkpoint N is held, return a v1 recording containing its single expected event and the xterm cells and lines for the actual pane geometry. |
| `POST /ack?clientId=ID` | After the comparison and any screenshot, the app sends the checkpoint observation, including `eventIndex`, grid, byte counts, render generations and any UTF-8 copy result. Return 204 to release this boundary. |

The controller holds a phase until the corresponding action or acknowledgement arrives. `attaching` and `playing` require no action. `layout` confirms the initial native grid. `input` uses the recorded responder action and `resize` uses native geometry. `detach` and `resume` change pane visibility. `useHere` and `newShell` activate the available native status button. `checkpoint` checks the xterm snapshot and the GPU-completed generation. A controller may add `capture: true` or `false` to that phase to override the default screenshot selection. `close` explicitly ends the shell, `completed` writes the final report and `failed` writes the reason to `workflow-error.txt`.

For a new live PTY recording, keep the actual input and output on the terminal server connection. Derive the xterm expectation from the bytes, resizes and replay that server delivered. The recorded fixture peer provides the same control interface with `bun scripts/demo-peer.ts --workflow shell --view --driver`. Its terminal and control listeners can select separate free ports with `THRUSH_PORT=0 THRUSH_DRIVER_PORT=0`.

The capture handshake uses `capture-NNN.json` for the app's verified, settled checkpoint. The runner writes its PNG and touches `capture-NNN.done`, then the app releases the peer. An intermediate synchronized Codex repaint checks that the previous coherent native frame stayed visible and immediately releases the batch. On a resumed Vim attachment, the parser starts empty while the last editor frame remains displayed until the serialized replay.
