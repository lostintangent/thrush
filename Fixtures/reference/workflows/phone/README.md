# Native-width PTY recordings

The conformance cases and ThrushCore's replay tests use these recordings at the iPhone Duo's grids. Bash and Vim receive the PTY dimensions before launch. The recorded replay restores the edited alternate buffer after Vim returns to portrait. Thrush's own serializer produced it, the one `ThrushServer` sends a resuming client. The 1,011-byte replay matches every cell, color and style and leaves the cursor at row 0, column 9. After `:wq`, all eight cells of `thrush$ ` use the default colors. The recorder also checks the saved scratch file on disk. [Serializer](../../../../Sources/ThrushCore/TerminalReplay.swift)

Both recordings run at the iPhone Duo's grids with the keyboard up. Codex runs at 45 columns by 18 rows throughout. The Vim recording starts at 45 by 18, confirms portrait, rotates to 71 columns by 11 rows, and returns to 45 by 18 before detach and replay. The packaged proofs app measured both grids on the Duo simulator under the English keyboard and key row. [Hosted measurement](https://github.com/lostintangent/thrush/actions/runs/45900075988/job/140198693096)

Codex CLI 0.166.0 runs in a fresh home and trusted Git workspace, with the release's `codex-code-mode-host` beside it so the status line carries no warning. Its loopback Responses endpoint streams the twelve numbered lines from the published live session. The CLI draws the prompt, working indicator, partial answer and both transcript pages inside the narrow PTY. The source records every PTY read, independent terminal reply, user action and relative timestamp. The exit resume ID receives the same length-preserving replacement used for the original capture. The wide recording retains the live provider turn. [Original Codex recording](../codex-readme.md)

Rebuild the Vim recording's saved reference checkpoints at the repository root, with the [pinned reference](../../README.md) installed. The Codex capture has no recording, because its conformance case replays the capture itself.

```sh
bun Fixtures/reference/generate.mjs phone/vim-resume
```

To record fresh PTY timings, pass the measured starting columns and rows to both recorders. Repeat `--resize COLSxROWS` for each Vim orientation stop in order. The last stop uses the original portrait dimensions. Preserve all three steps, including the initial portrait confirmation at the existing size. The separate output paths keep both original wide sources available. A fresh Vim recording needs its own server replay: the bytes your server's serializer produces for the restored grid at `Vim before detach`, passed as `--replay`.

```sh
python3 -B Fixtures/reference/shell-and-vim/capture-shell-and-vim.py --only vim-edit \
  --columns "$portrait_cols" --rows "$portrait_rows" \
  --resize "${portrait_cols}x${portrait_rows}" --resize "${landscape_cols}x${landscape_rows}" \
  --resize "${portrait_cols}x${portrait_rows}" --destination Fixtures/reference/workflows/phone

bun Fixtures/reference/workflows/vim-resume.mjs --replay "$server_replay" \
  Fixtures/reference/workflows/phone/vim-edit.capture.json Fixtures/reference/workflows/phone/vim-resume.capture.json

python3 -B Fixtures/reference/workflows/codex-capture.py \
  --codex-bin "$codex_binary" --columns "$portrait_cols" --rows "$portrait_rows" \
  --local-response --output Fixtures/reference/workflows/phone/codex-session.capture.json
```

## Run the same answer in a disposable hosted PTY

Start the local provider on the PTY host. Its first line gives the endpoint as `THRUSH_RESPONSES_URL=http://127.0.0.1:<port>/v1`. It serves the recorded songbird question and its short title. SIGINT or SIGTERM closes the listener.

```sh
python3 -B Fixtures/reference/workflows/songbird_stream.py --port 0
```

In the disposable Codex home's `config.toml`, supply the printed URL and the local provider. Start the native binary in the disposable trusted workspace with `--no-daemon -s read-only -a never`.

```toml
model = "gpt-6.1-sol"
model_provider = "thrush"
check_for_update_on_startup = false
web_search = "disabled"

[model_providers.thrush]
name = "Thrush local fixture"
base_url = "http://127.0.0.1:<port>/v1"
wire_api = "responses"
requires_openai_auth = false

[analytics]
enabled = false
```

Submit “Name 12 songbirds on numbered lines. Start with Song thrush and end with European robin.” Ctrl-T and Page Up scroll the real transcript back to its first item. Page Down restores the final item, and `/quit` returns to the shell.
