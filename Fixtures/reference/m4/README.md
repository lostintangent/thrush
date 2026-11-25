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
