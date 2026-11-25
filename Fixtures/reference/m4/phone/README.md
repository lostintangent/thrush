# Native-width PTY recordings

The running-pane driver uses these recordings when the phone has the recorded grid. Bash and Vim receive the PTY dimensions before launch. The pinned Toy Box server serializes the edited alternate buffer after Vim returns to portrait. The recorder checks the saved scratch file on disk and the serializer checks its restored text and modes.

Codex CLI 0.166.0 runs in a fresh home and trusted Git workspace. Its loopback Responses endpoint streams the twelve numbered lines from the published live session. The CLI draws the prompt, working indicator, partial answer and both transcript pages inside the narrow PTY. The source records every PTY read, independent terminal reply, user action and relative timestamp. The exit resume ID receives the same length-preserving replacement used for the original capture. The wide recording retains the live provider turn. [Original Codex recording](../codex-readme.md)

Rebuild the saved xterm checkpoints from the phone sources at the repository root. Use the Toy Box checkout pinned in the reference generator.

```sh
NODE_PATH="$PWD/../toy-box/node_modules/@xterm/xterm/src" \
  bun Fixtures/reference/m2/generate.mjs ../toy-box --phone
```

To record fresh PTY timings, pass the measured starting columns and rows to both recorders. Repeat `--resize COLSxROWS` for each Vim orientation stop in order. The last stop uses the original portrait dimensions. Preserve all three steps, including the initial portrait confirmation at the existing size. The separate output paths keep both original wide sources available.

```sh
python3 -B Fixtures/reference/m2/capture.py ../toy-box --only vim-edit \
  --columns "$portrait_cols" --rows "$portrait_rows" \
  --resize "${portrait_cols}x${portrait_rows}" --resize "${landscape_cols}x${landscape_rows}" \
  --resize "${portrait_cols}x${portrait_rows}" --destination Fixtures/reference/m4/phone

NODE_PATH="$PWD/../toy-box/node_modules/@xterm/xterm/src" \
  bun Fixtures/reference/m4/vim-resume.mjs ../toy-box \
  Fixtures/reference/m4/phone/vim-edit.capture.json Fixtures/reference/m4/phone/vim-resume.capture.json

python3 -B Fixtures/reference/m4/codex-capture.py --checkout ../toy-box \
  --codex-bin "$codex_binary" --columns "$portrait_cols" --rows "$portrait_rows" \
  --local-response --output Fixtures/reference/m4/phone/codex-session.capture.json
```

## Run the same answer in a disposable hosted PTY

Start the local provider on the PTY host. Its first line gives the endpoint as `THRUSH_RESPONSES_URL=http://127.0.0.1:<port>/v1`. It serves the recorded songbird question and its short title. SIGINT or SIGTERM closes the listener.

```sh
python3 -B Fixtures/reference/m4/songbird_stream.py --port 0
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
