# Recorded shell, Vim and Codex workflows

The three recordings drive the standalone peer through the same WebSocket protocol as the native app. Each PTY read keeps its original byte boundary. Checkpoints carry the pinned xterm viewport, attributes, cursor, modes and scrollback. Replaying the committed files is offline. [Reference setup](../shell-and-vim/README.md)

The [native workflow runner](../../../Benchmarks/live-workflows.md) checks the bytes the native pane received against the reference with `live.mjs`, which reads the reference's screen and builds each expected checkpoint.

| Recording | Starting grid | Interactions and checkpoints |
| --- | --- | --- |
| `shell-workflow` | 80 × 24 | Resize to the iPhone Duo's 45 × 18, type `./builx`, press Backspace, paste `d 126 130`, then press Enter. Bash 5.3.9 enables bracketed paste. The executed command compiles five numbered headers and returns to the shell. |
| `vim-resume` | 80 × 24 | Open `scratch.txt`, insert wide and combining text, resize through portrait and landscape, detach, resume on the same client ID, save and quit. The recorded Vim session checks the saved file on disk. |
| `codex-session` | 80 × 16 | Launch Codex CLI 0.166.0 in a disposable workspace, enter a question about songbirds, watch the answer stream, press Ctrl-T, Page Up and Page Down, then enter `/quit`. |

## Shell selection

At `Copy soft-wrapped compiler path`, xterm selected from absolute buffer row 3, column 0 to row 4, column 39 (exclusive). The expected copy is the `copy.text` field, including the original combining accent. The intermediate soft wrap contributes no newline. `shell-selection.mjs` obtains this string through the pinned browser selection service. The recorded bytes include Bash enabling and disabling bracketed paste, the input delimiters and the PTY’s echo of the corrected command.

## Vim reattachment

`vim-resume.mjs` derives this recording from the real, saved-file-checked Vim recording. It adds a scripted detach and a server's serialized replay at the restored 80 × 24 size. A reference terminal stands in for the server's, which stays alive and never detaches. The resumed client starts with a new terminal at the same size and palette, applies the replay and then the rest of the live output.

| Boundary | Expected event |
| --- | --- |
| `Vim before detach` | Edited alternate screen with cursor at row 0, column 9 |
| `Vim detached` | Close the socket and retain client ID `r5-vim` |
| `Vim resumed ready` | Receive the ready control with `resumed: true`. The fresh client grid is empty. |
| `Vim serialized replay` | Apply one 1,858-byte binary frame. Both buffers, cell colors and styles, modes and the cursor at row 0, column 9 match the uninterrupted session. |
| `Vim first live output after replay` | Apply Vim’s response to `:wq` after the replay |
| `Returned to shell` | Read the eight default-colored cells of the original `thrush$ ` prompt. The cursor follows the trailing space. |

The wide and iPhone replays are part of their recordings. A PTY server's scrollback serializer produced the wide one, from the reviewed source `scrollback.ts` with SHA-256 `f524554edbd7c721e42fb22536fb3faa6556f132e4029e8b17ac804d9e226641`. Its reset before entering the alternate screen and absolute cursor placement add ten bytes to the serialized replay. On iPhone the restored frame is 1,011 bytes at 45 × 18. Thrush's own serializer produced it, the one `ThrushServer` sends a resuming client, and `ThrushBench --serialize-replay` checked that it restores the source recording's checkpoint. [Serializer](../../../Sources/ThrushCore/TerminalReplay.swift) The generator checks that each replay restores Vim's exact screen and that the later live output lands as it does on the uninterrupted terminal. `--replay FILE` substitutes another server's serialized bytes.

## Codex transcript

The captured response came from OpenAI’s GPT-6.1-Sol through the installed Codex CLI. The recording includes the submitted prompt, the working indicator, a partial numbered answer, the twelfth answer, the earlier transcript page and the return to the shell. The default Release, CI and proofs workflows consume these captured bytes and make no model request. The public trace replaces the resumable thread UUID with a sample of identical length, preserving every read boundary. [Codex capture procedure and checkpoints](codex-readme.md)

Codex uses synchronized output while drawing its interface. The core continues parsing and answering queries in each batch. The screen snapshot carries the active batch identifier so the view can delay presentation until the reset or xterm’s one-second presentation timeout.

## Reproduction

Regenerate the reference checkpoints from the committed source recordings. A single name selects one recording.

```sh
bun Fixtures/reference/generate.mjs
scripts/check-workflows.sh
```

To record new shell bytes, run the first command with the captured Bash version. The second rebuilds the Vim resume recording from the `vim-edit` capture and its recorded replay. Add `--check` to verify the checked-in recording instead.

```sh
python3 Fixtures/reference/workflows/shell-workflow.py --bash /opt/homebrew/bin/bash
bun Fixtures/reference/workflows/vim-resume.mjs
```

`codex-capture.py --help` describes the separate live recording procedure. A new recording uses the specified Codex binary and login and makes a new model request. The text, timing and PTY chunks can differ between live runs.

## Native pointer input

The Codex transcript pager enables X11 button, drag and all-motion tracking and requests SGR coordinates. The pointer recording exercises those modes through the reference's mouse service at 240 × 8, including legacy binary coordinates above ASCII, the 223-column limit, SGR release and wheel events, modifiers and the return to local selection. Its expected frames come from the reference terminal's binary and text streams. Regenerate from the repository root.

```sh
bun Fixtures/reference/generate.mjs pointer-input
```

## iPhone recordings

The phone recordings use real Vim, its server's serializer and the installed Codex CLI at the iPhone Duo's grids. The narrow Codex recording uses a localhost Responses endpoint that streams the existing published twelve-line answer into the CLI. The wide capture retains the original external provider response. Both recorded Codex sessions received white foreground and black background in their OSC 10 and 11 replies. [Handset recording procedure](phone/README.md)
