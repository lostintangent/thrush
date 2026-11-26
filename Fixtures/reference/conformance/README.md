# Conformance harness

The harness feeds the same bytes to the [pinned reference emulator](../README.md) and to ThrushCore. It compares everything a program can observe: cells and their attributes, wrap flags, history, the cursor, modes, the title and every reply. The Swift tests replay the generated cases on every `swift test`, so CI fails when Thrush stops matching. CI also runs the harness against the reference and fails if any generated file would change.

```sh
scripts/check-conformance.sh                     # fail if any generated file would change
scripts/check-conformance.sh --write             # regenerate the cases and lists
scripts/check-conformance.sh --report gaps.md    # also write the ranked gap report
```

The script installs the reference from its lockfile, builds ThrushConformance in release and runs the harness, then the Swift conformance tests.

## Corpora

- **Functions** ([functions.mjs](functions.mjs)) have one case per control function, parameter form and edge. Each case draws a canvas of text, wide characters and colors, runs a setup, applies the subject, takes a checkpoint and prints a marker, so the next write shows where the subject left the cursor and rendition. Focus reporting cases also move the terminal's focus between writes. The harness asserts that function cases reach every handler the reference registers.
- **Programs** ([programs.mjs](programs.mjs)) are real PTY recordings: the shell, Vim, Codex and Clang fixtures under `m2`–`m4`, and the scenarios in [programs/](programs/) covering zsh, Bash, a pager, git, editors, process monitors, tmux and screen, Python, lazygit, ripgrep's links with Vim's spelling underlines, Neovim and Helix with sourcekit-lsp, fzf, btop, Claude Code and Copilot CLI. Each replays read by read with every resize.
- **Streams** ([streams.mjs](streams.mjs)) are 400 seeded random mixes of text and control functions, written in chunks split inside UTF-8 scalars and escape sequences.

[capture-programs.py](capture-programs.py) records the scenarios in disposable PTYs with an `xterm-256color` environment. [replies.mjs](replies.mjs) answers the programs' queries as the reference would, so each recording follows the replies a terminal sends. Re-record with `python3 Fixtures/reference/conformance/capture-programs.py [--only NAME]`, then regenerate.

## What the harness writes

- `Tests/ThrushConformanceTests/Cases/{functions,programs,streams}.json` holds every case with the reference's checkpoints. Cells and lines are interned, so long histories stay small.
- `Tests/ThrushConformanceTests/KnownGaps.json` lists the cases Thrush doesn't match yet, by the function they exercise. The tests expect each listed case to fail. A case that starts matching fails as an unrecorded known issue, so the list only shrinks. After a fix, regenerate with `--write` and commit the shorter list. A gap Thrush keeps by choice has a reason written by hand, which the harness keeps when it regenerates. The report lists these gaps apart from the ranking.
- `Tests/ThrushConformanceTests/ReferenceDefects.json` lists the cases where the reference is wrong, such as a crash or corrupted history. Each entry has a reason written by hand and the exact differences, which the harness regenerates. Thrush must differ in exactly those ways, so a change on either side shows up in review. Any case where the reference throws must be listed.
- `reference.json` records the reference configuration and how often each recorded program emits each function.

The `zsh-clear` program seeds 38 numbered lines on an 80 × 24 terminal before each invocation. macOS `/usr/bin/clear` sends ED 3, CUP, ED 2. Homebrew ncurses `clear` sends CUP, ED 2, ED 3. In the recording both programs finish their erase in a separate PTY read before zsh draws `thrush$ `. To capture a new session on a Mac with both commands, run `python3 Fixtures/reference/conformance/capture-programs.py --only zsh-clear`. To reproduce the benchmark replay from the checked-in capture, run `bun Fixtures/reference/m2/generate.mjs zsh-clear`. Both generators use the reference installed from `Fixtures/reference/bun.lock`.

The `neovim` and `helix` programs need `nvim` or `hx` on the PATH and Xcode's `sourcekit-lsp`, which reports two errors in a small Swift file. `fzf` and `btop` need those commands. The `claude` and `copilot` programs need Claude Code or Copilot CLI on the PATH and no account: the recorder serves a scripted model on a local port, which reads a note, edits it and answers in Markdown, so the agents run their real permission, diff and Markdown views without a network or cost.

The `decorations` program needs ripgrep's `rg` on the PATH. rg links each match to its file's real path and host, so the scenario searches a project at `/tmp/thrush-decorations` and reports the host as `thrush`, which keeps the links the same on every Mac. Vim leaves underline styles and colors off for `xterm-256color`, so the scenario turns them on the way configurations do, first with 256 colors and then with true color.

## The gap report

The report ranks what to fix next by real use.

1. Each failing function case is shrunk to the fewest bytes that still disagree in the same kind of state. The functions left in the minimal input are its cause, so a failing setup is charged to the function that's actually wrong.
2. Causes rank by how many recorded programs emit every function in them, then by how often.
3. Each program is replayed with a checkpoint after every read. For each kind of state that differs, the reads up to the first disagreement are shrunk to a minimal input.
4. Failing random streams are shrunk and grouped by cause.
5. A table lists every function the programs emit, with how Thrush does on the cases that exercise it.

[shrink.mjs](shrink.mjs) does the shrinking with delta debugging over whole escape sequences, then individual parameters and scalars. [names.mjs](names.mjs) names every function the same way in the corpus, the program counts and the report.
