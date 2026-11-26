#!/usr/bin/env python3
"""Check screenshot bursts of the styles scene. Blinking text alternates between fully shown
and fully hidden, Reduce Motion holds it shown, and concealed text keeps its cells undrawn."""
import argparse
import json
from pathlib import Path
import runpy
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
_demo = runpy.run_path(str(ROOT / "scripts/check-demo-capture.py"))
Capture, require = _demo["Capture"], _demo["require"]

# The styles scene in scripts/demo-peer.ts: one row per style, then a prompt.
PLAIN, BLINK, CONCEALED, BLINK_INVERSE, BLINK_UNDERLINE, BLINK_GREEN, PROMPT = 1, 14, 15, 16, 17, 18, 19
BLINKING = (BLINK, BLINK_INVERSE, BLINK_UNDERLINE, BLINK_GREEN)
SAMPLE, PROMPT_COLUMNS = 16, 11


class Grid:
    """Cell geometry from the block cursor that follows the final prompt."""

    def __init__(self, image):
        self.image = image
        self.paper = image.matches("background", tolerance=12)
        left, top, right, bottom = image.bounds("cursor")
        self.row = bottom - top + 1
        self.top = top - PROMPT * self.row
        require(self.top >= 0 and top + self.row <= image.height, "The styles scene does not fit the capture")
        # The prompt's first glyph sits at the left margin, so the cursor column
        # measures eleven advances more precisely than one cursor cell does. Start
        # inside the margin, clear of any window border.
        self.left = min(self.ink(PROMPT, max(2, left - round((PROMPT_COLUMNS + 0.75) * (right - left + 1))), left))
        self.cell = (left - self.left) / PROMPT_COLUMNS
        require(abs(self.cell - (right - left + 1)) <= 1.5, "The prompt and cursor disagree about the cell width")

    def y(self, row):
        return self.top + row * self.row

    def x(self, column):
        return round(self.left + column * self.cell)

    def ink(self, row, start=0, end=None, image=None):
        """Columns of pixels in a row that differ from the terminal background."""
        image = image or self.image
        end = image.width if end is None else end
        found = set()
        for y in range(self.y(row) + 1, self.y(row + 1) - 1):
            line = image.pixels[y * image.width + start:y * image.width + end]
            found.update(start + x for x, value in enumerate(line) if value not in self.paper)
        return sorted(found)

    def band(self, image):
        return image.pixels[self.y(0) * image.width:self.y(PROMPT + 1) * image.width].tobytes()

    def changed_rows(self, image, other):
        width = image.width
        return {(y - self.top) // self.row for y in range(self.y(0), self.y(PROMPT + 1))
                if image.pixels[y * width:(y + 1) * width] != other.pixels[y * width:(y + 1) * width]}


def widest_gap(columns):
    return max((b - a for a, b in zip(columns, columns[1:])), default=0)


def check(blinking, steady, theme):
    steady_images = [Capture(path, theme) for path in steady]
    shown = steady_images[0]
    grid = Grid(shown)
    reference = grid.band(shown)
    for path, image in zip(steady, steady_images):
        require((image.width, image.height) == (shown.width, shown.height) and grid.band(image) == reference,
                f"{Path(path).name} changed under Reduce Motion")

    # Concealed text leaves 14 blank cells between its brackets. The label padding on
    # an ordinary row stays well short of that.
    text = grid.x(0) - round(grid.cell / 2), grid.x(SAMPLE + 16)
    concealed = widest_gap(grid.ink(CONCEALED, *text)) / grid.cell
    plain = widest_gap(grid.ink(PLAIN, *text)) / grid.cell
    require(plain < 12.5 <= concealed, f"Concealed text drew ink: widest blank run {concealed:.1f} cells, plain {plain:.1f}")
    sample = grid.x(SAMPLE) - round(grid.cell / 2), text[1]
    paper_start, paper_end = grid.x(SAMPLE) + 2, grid.x(SAMPLE + 14) - 2
    inverse = shown.matches("ink")

    def inverse_glyphs(image):
        return sum(value not in inverse for y in range(grid.y(BLINK_INVERSE) + 1, grid.y(BLINK_INVERSE + 1) - 1)
                   for value in image.pixels[y * image.width + paper_start:y * image.width + paper_end])

    for row in (BLINK, BLINK_UNDERLINE, BLINK_GREEN):
        require(grid.ink(row, *sample), f"Row {row} shows no blinking text under Reduce Motion")
    require(inverse_glyphs(shown) > 0, "Blinking inverse text is missing under Reduce Motion")

    frames = [Capture(path, theme) for path in blinking]
    bands = [grid.band(image) for image in frames]
    require(all((image.width, image.height) == (shown.width, shown.height) for image in frames),
            "The blinking burst changed size")
    shown_frames = [i for i, band in enumerate(bands) if band == reference]
    others = [band for band in bands if band != reference]
    require(len(shown_frames) >= 2, f"Only {len(shown_frames)} blinking frames matched the steady text")
    require(others, "Blinking text never changed")
    hidden_band = max(set(others), key=others.count)
    hidden_frames = [i for i, band in enumerate(bands) if band == hidden_band]
    require(len(hidden_frames) >= 2, "No two frames agreed on the hidden blink state")
    hidden = frames[hidden_frames[0]]
    require(grid.changed_rows(hidden, shown) == set(BLINKING),
            f"Hiding blinking text changed rows {sorted(grid.changed_rows(hidden, shown))}")
    for row in (BLINK, BLINK_UNDERLINE, BLINK_GREEN):
        require(not grid.ink(row, *sample, image=hidden), f"Row {row} kept ink while hidden")
    require(inverse_glyphs(hidden) == 0, "Blinking inverse text kept its glyphs or lost its paper while hidden")
    fading = [i for i, band in enumerate(bands) if band not in (reference, hidden_band)]
    for i in fading:
        require(grid.changed_rows(frames[i], shown) <= set(BLINKING), f"{Path(blinking[i]).name} changed steady rows")
    return dict(shown=[blinking[i] for i in shown_frames], hidden=[blinking[i] for i in hidden_frames],
                fading=[blinking[i] for i in fading], steady=list(steady),
                cell=[round(grid.cell, 3), grid.row], concealedBlankCells=round(concealed, 2),
                plainBlankCells=round(plain, 2))


def check_bursts(bursts, out):
    """Check the blinking and steady bursts for each appearance and keep one still per state."""
    summary = {}
    for appearance in ("dark", "light"):
        blinking, steady = bursts[appearance, "blinking"], bursts[appearance, "steady"]
        result = check(blinking, steady, appearance)
        stills = dict(shown=result["shown"][0], hidden=result["hidden"][0], reduceMotion=steady[0])
        if result["fading"]:
            stills["fading"] = result["fading"][0]
        for name, path in stills.items():
            shutil.copyfile(path, Path(out) / f"text-blink-{appearance}-{name}.png")
        summary[appearance] = dict(frames=len(blinking), shown=len(result["shown"]), hidden=len(result["hidden"]),
                                   fading=len(result["fading"]), steady=len(steady), cell=result["cell"],
                                   concealedBlankCells=result["concealedBlankCells"],
                                   plainBlankCells=result["plainBlankCells"])
        print(f"{appearance}: {json.dumps(summary[appearance])}", flush=True)
    (Path(out) / "text-blink.json").write_text(json.dumps(summary, indent=2) + "\n")
    return summary


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("theme", choices=("dark", "light"))
    parser.add_argument("--blinking", type=Path, nargs="+", required=True)
    parser.add_argument("--steady", type=Path, nargs="+", required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(check(args.blinking, args.steady, args.theme), default=str, indent=2))
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"{error}\n")
