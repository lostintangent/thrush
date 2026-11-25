# Styled Swift Vim frames

`vim-swift-dark` and `vim-swift-light` show the same `Prompt.swift` in Vim 9.1, patches 1–1752. The source fits 40 columns including its three-column line-number gutter. Both sessions use the same `styled.vim`, Swift runtime syntax, `laststatus=2`, keyboard input and resize sequence. Vim chooses its own background and syntax colors. The host supplies the foreground, background and 16 ANSI slots from the Slate design. [Slate palettes](../../../docs/design/README.md)

The recorder sends actual PTY reads into the pinned xterm emulator and returns its browser color replies to Vim. For OSC 11, Slate Dark returns `rgb:1313/1d1d/2727` and Slate Light returns `rgb:fbfb/fdfd/fefe`. For OSC 10, they return `rgb:e3e3/eaea/f0f0` and `rgb:2323/3434/4242`. After the replies, the same Vim command in both sessions writes `&background`, `&filetype`, `b:current_syntax` and `&t_Co` to a temporary file. The recorder checks and retains these observations and the hashes of the source and vimrc. The generated replay header reports Vim's measured `vimBackground`.

| Checkpoint | Grid | Zero-based cursor (row, column) | Status row |
| --- | --- | --- | --- |
| Styled Swift buffer | 80 × 24 | (4, 20) | 22 |
| Styled Swift portrait | 47 × 25 | (4, 20) | 23 |
| Styled Swift landscape | 90 × 9 | (1, 20) | 7 |

Both iPhone checkpoint sizes match the packaged Slate Dark prompt on the iPhone 17 simulator running iOS 27.2 at 3× scale. Each keyboard measurement includes the 44 pt terminal accessory.

| Orientation | Window (pt) | Terminal view origin and size (pt) | Keyboard layout guide height (pt) |
| --- | --- | --- | --- |
| [Portrait measurement](https://github.com/lostintangent/thrush/actions/runs/45561741803) | 402 × 874 | (0, 62), 402 × 467 | 345 |
| [Landscape measurement](https://github.com/lostintangent/thrush/actions/runs/45563805563) | 874 × 402 | (62, 0), 750 × 178 | 224 |

For the complete session, apply the palette, PTY output and grid changes in recorded order. For a stand-alone renderer frame, start with a clean terminal at the checkpoint's grid and its recorded host palette. The two `Paint Swift buffer` output chunks come from a real Ctrl-L repaint at 80 × 24. For portrait or landscape, use the `Redraw after resize` output chunks between the corresponding resize and styled checkpoint. These are Vim's responses to the PTY's native size change. The generator separately replays each paint on a fresh target-sized grid and checks every visible row, cell, style, wrap flag and cursor position against the continuous session.

The runtime paints the `struct` keyword at row 1, column 3 with index 81 on dark and 5 on light. The gutter uses 11 on dark and 130 on light. Both status lines use Vim's native bold and reverse flags. In landscape, Vim naturally scrolls line 4 into the first row. The source, visual status-line format and cursor position are shared across appearances.

## Reproduce

Run from the repository root with the [pinned reference](../README.md) installed. The first command records new PTY reads and timestamps. The second deterministically rebuilds expected screens from the checked-in captures. The generator checks the source and vimrc against their recorded hashes. [Capture setup](../m2/README.md)

```sh
python3 Fixtures/reference/m3/capture-styled.py
bun Fixtures/reference/m2/generate.mjs
```
