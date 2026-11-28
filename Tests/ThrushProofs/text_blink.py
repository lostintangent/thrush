"""Burst-capture the styles scene on the iPhone in both appearances, first blinking and then under
Reduce Motion, and check the bursts. Blinking text alternates between fully shown and fully hidden,
Reduce Motion holds it shown, and concealed text keeps its cells undrawn."""
import json
from pathlib import Path
import random
import shutil
import time

import proof
from proof import Capture, require

# Jittered screenshots sample every phase of the 1.2 s cycle instead of aliasing with it.
BLINKING_FRAMES, STEADY_FRAMES = 30, 8
# The styles scene in Tests/ThrushProofs/peers/demo-peer.ts: one row per style, then a prompt.
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

    def changed_span(self, image, other):
        xs = [i % image.width for i in range(self.y(0) * image.width, self.y(PROMPT + 1) * image.width)
              if image.pixels[i] != other.pixels[i]]
        return f"{min(xs)}…{max(xs)}" if xs else "none"

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
        require((image.width, image.height) == (shown.width, shown.height), f"{Path(path).name} changed size")
        require(grid.band(image) == reference, f"{Path(path).name} changed under Reduce Motion: "
                f"rows {sorted(grid.changed_rows(image, shown))}, pixels x={grid.changed_span(image, shown)}")

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
    if len(shown_frames) < 2:
        closest = min(frames, key=lambda image: len(grid.changed_rows(image, shown)))
        require(False, f"Only {len(shown_frames)} blinking frames matched the steady text. The closest "
                f"changed rows {sorted(grid.changed_rows(closest, shown))}, pixels x={grid.changed_span(closest, shown)}")
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
        try:
            result = check(blinking, steady, appearance)
        except ValueError:
            # Keep the bursts beside the logs so a failure can be read from the uploaded captures.
            for label, paths in (("blinking", blinking), ("steady", steady)):
                for path in paths:
                    shutil.copyfile(path, Path(out) / f"text-blink-{appearance}-{label}-{Path(path).stem}.png")
            raise
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


def set_reduce_motion(phone, sim, enabled):
    sim("spawn", phone.device, "defaults", "write", "com.apple.Accessibility", "ReduceMotionEnabled",
        "-bool", "true" if enabled else "false")
    sim("spawn", phone.device, "notifyutil", "-p", "com.apple.accessibility.reduce.motion.status", check=False)


def burst(phone, folder, count):
    folder.mkdir(parents=True)
    frames = []
    for index in range(count):
        path = folder / f"{index:02}.png"
        phone.screenshot(path)
        frames.append(path)
        time.sleep(random.uniform(0.03, 0.29))
    return frames


def capture(phone, sim):
    bursts = {}
    for reduced in (False, True):
        set_reduce_motion(phone, sim, reduced)
        for appearance in ("dark", "light"):
            pid = phone.launch("styles", appearance, "portrait", "hidden")

            def ready():
                state = phone.state()
                return state if (state.get("pid") == pid and state.get("scene") == "styles" and
                                 state.get("appearance") == appearance and state.get("gpuCompleted") and
                                 state.get("generation") and state.get("keyboardHeight", 0) < 90 and
                                 state.get("reducesMotion") == reduced) else False

            state = proof.wait(f"styles in {appearance}{' with Reduce Motion' if reduced else ''}", ready, 90)
            time.sleep(0.7)
            label = "steady" if reduced else "blinking"
            proof.save(phone.out / f"text-blink-{appearance}-{label}.json", state)
            bursts[appearance, label] = burst(phone, phone.scratch / f"{appearance}-{label}",
                                              STEADY_FRAMES if reduced else BLINKING_FRAMES)
            if phone.state().get("pid") != pid:
                raise RuntimeError(f"The styles scene exited during the {appearance} burst.")
    set_reduce_motion(phone, sim, False)

    check_bursts(bursts, phone.out)
