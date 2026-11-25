# Live Codex transcript

`codex-session` records the installed `codex-cli 0.166.0` running inside a real 80 × 16 PTY with `TERM=xterm-256color`. The CLI submitted one question to OpenAI's GPT-6.1-Sol through an authorized ChatGPT login. The question was “Name 12 songbirds on numbered lines. Start with Song thrush and end with European robin.”

The interactive Bash shell started at `thrush$ ` in a fresh Git workspace inside a disposable home. The CLI ran with read-only sandboxing, approval prompts disabled, no daemon, and web search disabled. Its only link to the existing profile was the login file opened by the CLI. The recording shows `~/workspace` in the Codex header.

The checked-in capture contains 18,382 application-output bytes across 222 PTY reads. Each read retains its original relative timestamp and size. User input and automatic terminal replies have separate fields. During the first synchronized repaint, xterm answered primary device attributes, cursor position, foreground and background queries. The recorder immediately wrote those replies to the PTY. The keyboard protocol query produced no reply.

The exit message includes a command for resuming the live conversation. The public capture replaces the 36 ASCII bytes of its thread ID with `00000000-0000-4000-8000-000000000000`. This is the only byte substitution. The recorder validates the location and count, preserves the read boundaries and offsets, and checks the sanitized stream against the live terminal replies. All reference checkpoints, including the final shell view, use the public bytes.

| Checkpoint | Pinned xterm observation |
| --- | --- |
| Shell prompt | Bash displays `thrush$ ` on the normal screen. |
| Synchronized Codex repaint pending / complete | The first split repaint leaves synchronized output enabled at the end of one actual PTY read. The next read resets it 6,532 µs later. |
| Codex ready / Entered Codex prompt | The alternate screen shows the CLI header, model name and composer. The entered question wraps across two rows. |
| Codex working / First three songbirds streamed | The working indicator appears first. A later completed repaint shows Song thrush, Common blackbird and Eurasian blue tit. |
| Received Codex answer | The completed response ends with `12. European robin`. |
| Earlier transcript page / Later transcript page | After Ctrl-T and Page Up, the viewport shows item 1 and the “Back to bottom” indicator. Page Down restores the final item and clears the indicator. |
| Returned to shell | Submitting `/quit` restores the normal screen, prints the CLI's exit summary and returns to `thrush$ `. |

The raw stream contains 155 synchronized updates (DEC private mode 2026). Of those, 34 cross PTY reads. The longest observed interval between the reads carrying the opening and closing controls was 6,532 µs. Every reset arrived within the pinned browser renderer's 1,000 ms timeout. The checkpoint oracle samples the pinned headless parser's synchronized-output flag and cell state after each named read.

## Regenerate checkpoints offline

With the [pinned reference](../README.md) installed, the generator uses `@xterm/headless`, the color-report handler and ThemeService from `@xterm/xterm`, and Unicode 11. It checks every recorded automatic reply while rebuilding the reference cells and checkpoints.

```sh
bun Fixtures/reference/m2/generate.mjs codex-session
```

## Record another live session

Run the following only to collect a fresh provider response. It uses an authorized Codex login and a native CLI with the exact recorded version. The fresh response, read boundaries and timings can vary. The existing capture provides deterministic replay.

```sh
python3 Fixtures/reference/m4/codex-capture.py --codex-bin /path/to/native/codex --output /tmp/codex-session.capture.json
```

The recorder keeps the fresh session only after observing the answer, both transcript positions and the shell's return, verifying replies, and redacting the exit identifier. The output path above leaves the checked-in recording available for comparison.
