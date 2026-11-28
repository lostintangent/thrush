# Conformance harness

The harness feeds the same bytes to the [pinned reference emulator](../README.md) and to ThrushCore. It compares everything a program can observe: cells and their attributes, wrap flags, history, the cursor, modes, the title and every reply. It also checks what a person would see. After every write and resize, ThrushCore's screen is drawn the way the renderer draws it, which reuses a row's drawing until the row's generation changes. A cell that would show a stale drawing differs as `drawn[row][column]`. The Swift tests replay the generated cases on every `swift test`, so CI fails when Thrush stops matching. CI also runs the harness against the reference and fails if any generated file would change.

```sh
scripts/check-conformance.sh            # fail if any generated file would change
scripts/check-conformance.sh --write    # regenerate the cases and lists
```

The script installs the reference from its lockfile, builds ThrushConformance in release and runs the harness, then the [replay check](#replays) and the Swift conformance tests.

## Corpora

- **Functions** ([functions.mjs](functions.mjs)) have one case per control function, parameter form and edge. Each case draws a canvas of text, wide characters and colors, runs a setup, applies the subject, takes a checkpoint and prints a marker, so the next write shows where the subject left the cursor and rendition. Focus reporting cases also move the terminal's focus between writes. The harness asserts that function cases reach every handler the reference registers.
- **Programs** ([programs.mjs](programs.mjs)) are real PTY recordings: the shell, Vim, Codex and Clang fixtures under `m2`–`m4`, and the scenarios in [programs/](programs/) covering zsh, Bash, a pager, git, editors, process monitors, tmux and screen, Python, lazygit, ripgrep's links with Vim's spelling underlines, Neovim and Helix with sourcekit-lsp, fzf, btop, Claude Code and Copilot CLI. Each replays read by read with every resize.
- **Streams** ([streams.mjs](streams.mjs)) are 400 seeded random mixes of text and control functions, written in chunks split inside UTF-8 scalars and escape sequences.

[capture-programs.py](capture-programs.py) records the scenarios in disposable PTYs with an `xterm-256color` environment. [replies.mjs](replies.mjs) answers the programs' queries as the reference would, so each recording follows the replies a terminal sends. Re-record with `python3 Fixtures/reference/conformance/capture-programs.py [--only NAME]`, then regenerate.

## What the harness writes

- `Tests/ThrushConformanceTests/Cases/{functions,programs,streams}.json` holds every case with the reference's checkpoints. Cells and lines are interned, so long histories stay small.
- `Tests/ThrushConformanceTests/KnownGaps.json` lists the cases Thrush doesn't match yet, by the function they exercise. The tests expect each listed case to fail. A case that starts matching fails as an unrecorded known issue, so the list only shrinks. After a fix, regenerate with `--write` and commit the shorter list. A gap Thrush keeps by choice has a reason written by hand, which the harness keeps when it regenerates.
- `Tests/ThrushConformanceTests/ReferenceDefects.json` lists the cases where the reference is wrong, such as a crash or corrupted history. Each entry has a reason written by hand and the exact differences, which the harness regenerates. Thrush must differ in exactly those ways, so a change on either side shows up in review. Any case where the reference throws must be listed.

The `zsh-clear` program seeds 38 numbered lines on an 80 × 24 terminal before each invocation. macOS `/usr/bin/clear` sends ED 3, CUP, ED 2. Homebrew ncurses `clear` sends CUP, ED 2, ED 3. In the recording both programs finish their erase in a separate PTY read before zsh draws `thrush$ `. To capture a new session on a Mac with both commands, run `python3 Fixtures/reference/conformance/capture-programs.py --only zsh-clear`. To reproduce the benchmark recording from the checked-in capture, run `bun Fixtures/reference/m2/generate.mjs zsh-clear`. Both generators use the reference installed from `Fixtures/reference/bun.lock`.

The `neovim` and `helix` programs need `nvim` or `hx` on the PATH and Xcode's `sourcekit-lsp`, which reports two errors in a small Swift file. `fzf` and `btop` need those commands. The `claude` and `copilot` programs need Claude Code or Copilot CLI on the PATH and no account: the recorder serves a scripted model on a local port, which reads a note, edits it and answers in Markdown, so the agents run their real permission, diff and Markdown views without a network or cost.

The `decorations` program needs ripgrep's `rg` on the PATH. rg links each match to its file's real path and host, so the scenario searches a project at `/tmp/thrush-decorations` and reports the host as `thrush`, which keeps the links the same on every Mac. Vim leaves underline styles and colors off for `xterm-256color`, so the scenario turns them on the way configurations do, first with 256 colors and then with true color.

## Replays

A client that falls behind or reconnects gets ThrushCore's [replay](../../../docs/protocol.md#replay) in place of the output it missed, so a replay has to rebuild everything the live terminal holds. [replays.mjs](replays.mjs) checks that for every recorded program, and for the two resize cases that show what a replay [can't rebuild](../../../docs/protocol.md#replay). ThrushCore takes its replay after every write and resize, and a terminal resumed from it, in ThrushCore and in the reference, has to match a live terminal of its own kind right after the replay, after every later step and at the end. Right after the replay and at the end, the comparison includes history and the normal screen behind the alternate one.

A checkpoint can't show everything a replay carries, such as the saved cursor, tab stops, character sets, keyboard flags or the colors a program set. So a probe runs on a copy of each terminal. It asks for that state or prints what reveals it, on the screen the program is on and then on each screen, in parts that each end with a visible checkpoint. ThrushCore is probed right after the replay and at the end. The reference can't be copied, so it's probed only at the end. The only reply a replay may produce is the focus report that turning on mode 1004 sends, which tells the program whether the resumed client has focus.

[replay-gaps.json](replay-gaps.json) lists the programs and cases whose resumed terminals differ, each with a reason written by hand. For each emulator, it lists the steps whose replays differ in the same way together, with where they first differ and how. The check regenerates the lists and keeps the reasons.

```sh
bun Fixtures/reference/conformance/replays.mjs --thrush .build/release/ThrushConformance            # regenerate the gaps
bun Fixtures/reference/conformance/replays.mjs --thrush .build/release/ThrushConformance --check    # fail if they would change
```

`--reference <directory>` resumes the reference's terminals in the `@xterm/headless` and `@xterm/addon-unicode11` that resolve from another directory, such as an app's, and `--options <file>` starts them with the options in a JSON file instead of the pin's. Either holds that reference to the listed gaps, so the output shows where it resumes differently.
