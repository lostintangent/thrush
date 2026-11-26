"""Check program-set colors on the iPhone in both system appearances, full screen and under an inline
navigation bar. The colors scene picks the canvas the system didn't, so every frame puts program
colors against the host's chrome."""
import json
from pathlib import Path
import runpy
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
luminance = runpy.run_path(str(ROOT / "scripts/check-spinner-contrast.py"))["luminance"]
# The palettes in scripts/demo-peer.ts, by system appearance.
PROGRAM = {"dark": ("paper", "F4EFE4"), "light": ("night", "17151F")}
SLATE = {"dark": "131D27", "light": "FBFDFE"}


class StatusBarTrails(ValueError):
    """SpringBoard draws the status bar, so on a starved runner it can show the app's new style seconds late."""


def edges(rect):
    (x, y), (w, h) = rect
    return x, y, x + w, y + h


def check(image, state, appearance, toolbar, checker):
    name, paper = PROGRAM[appearance]
    pixels = runpy.run_path(str(ROOT / "scripts/check-demo-capture.py"))["Capture"](image, appearance)
    scale = state["displayScale"]
    window = edges(state["windowPoints"])
    grid = edges(state["gridFrame"])
    if (pixels.width, pixels.height) != (round((window[2] - window[0]) * scale), round((window[3] - window[1]) * scale)):
        raise ValueError("Simulator framebuffer does not match the mounted window.")

    def near(pixel, hex, tolerance=8):
        return max(abs(a - b) for a, b in zip(pixels.rgb(pixel), bytes.fromhex(hex))) <= tolerance

    def band(left, top, right, bottom, what):
        # Points in the window to framebuffer pixels. Every sample must be the program canvas.
        x0, x1 = round((left - window[0]) * scale), round((right - window[0]) * scale)
        y0, y1 = round((top - window[1]) * scale), round((bottom - window[1]) * scale)
        samples = [pixels.pixels[y * pixels.width + x] for y in range(y0, y1) for x in range(x0, x1)]
        if not samples or sum(near(value, paper) for value in samples) < 0.95 * len(samples):
            raise ValueError(f"The {name} canvas is missing {what}: x={x0}…{x1}, y={y0}…{y1}.")

    def legible(left, top, right, bottom, what, error=ValueError):
        # Vision reads text a person can't, so the strongest strokes must reach 4.5:1 against their ground.
        x0, x1 = round((left - window[0]) * scale), round((right - window[0]) * scale)
        y0, y1 = round((top - window[1]) * scale), round((bottom - window[1]) * scale)
        samples = pixels.crop((x0, y0, x1 - 1, y1 - 1))
        ground = luminance(max(set(samples), key=samples.count))
        if max((max(a, ground) + 0.05) / (min(a, ground) + 0.05) for a in map(luminance, samples)) < 4.5:
            raise error(f"The {what} doesn't stand out from the {name} canvas.")

    def read(rect, labels):
        left, top, right, bottom = edges(rect)
        x, y = round((left - window[0]) * scale), round((top - window[1]) * scale)
        width, height = round((right - left) * scale), round((bottom - top) * scale)
        subprocess.run([checker, image, "--crop", str(x), str(y), str(width), str(height), *labels],
                       check=True, timeout=60)

    # The theme's canvas must not show anywhere, and the program's must fill most of the window.
    total = pixels.width * pixels.height
    if sum(pixels.hist[v] for v in pixels.hist if near(v, SLATE[appearance], 3)) > total * 0.005:
        raise ValueError("The theme's canvas shows through the program's colors.")
    if sum(pixels.hist[v] for v in pixels.hist if near(v, paper, 3)) < total * 0.5:
        raise ValueError(f"The {name} canvas covers less than half the window.")
    (cell_x, cell_y), (cells_width, cells_height) = state["cellGridPixels"]
    first = toolbar["firstCellFrame"] if toolbar else (
        (grid[0] + cell_x / scale, grid[1] + cell_y / scale), (cells_width / scale, cells_height / scale / state["rows"]))
    top, bottom = edges(first)[1], edges(first)[3]
    read(((grid[0], top), (grid[2] - grid[0], bottom - top)), ["palette " + name])
    # Past the first command, the row is bare canvas out to the grid's trailing edge.
    band(grid[0] + 0.7 * (grid[2] - grid[0]), top + 1, grid[2] - 1, bottom - 1, "beside the first row")
    # The demo draws the canvas beneath the vertical status bar, so its clock must follow the canvas.
    # The clock sits below the camera in the trailing inset, 72 to 104 points down the Duo's display.
    legible(grid[2] + 4, window[1] + 72, window[2] - 12, window[1] + 104, "status bar clock", StatusBarTrails)
    if toolbar:
        bar = edges(toolbar["navigationBarFrame"])
        read(toolbar["navigationBarFrame"], ["Terminal", "Close"])
        # The inline title leads the bar, and Close is on the trailing edge.
        width = bar[2] - bar[0]
        legible(bar[0] + 4, bar[1] + 4, bar[0] + 0.4 * width, bar[3] - 4, "navigation title")
        # Between them, the unoccupied bar shows the program canvas.
        middle = (bar[1] + bar[3]) / 2
        band(bar[0] + 0.4 * width, middle - 1, bar[0] + 0.55 * width, middle + 1, "beneath the navigation bar")
    else:
        # The frame reaches the physical edges. The vertical status bar leaves the top to the grid and
        # insets its trailing side, so sample that strip at mid-height, below the bar's items.
        middle = (grid[1] + grid[3]) / 2
        band(grid[2] + 8, middle - 20, window[2] - 8, middle + 20, "beside the grid")
    # With the keyboard down, the grid runs on under the home indicator, and the root's keyboard guide
    # spans the strip beneath the safe area.
    band(window[0] + 24, window[3] - state["keyboardHeight"] + 1, window[2] - 24, window[3] - 16,
         "beside the home indicator")


def capture(phone, options, checker):
    failures = {}
    for appearance in ("dark", "light"):
        for toolbar in (False, True):
            prefix = f"colors-{'toolbar-' if toolbar else ''}{appearance}"
            try:
                extra = ("--toolbar-proof",) if toolbar else ()
                pid = phone.launch("colors", appearance, "portrait", "hidden", extra_arguments=extra)
                state = phone.frame("colors", appearance, "portrait", "hidden", pid, None, layout_only=True)
                image = phone.out / (prefix + ".png")
                (phone.out / (prefix + ".json")).write_text(json.dumps(state, indent=2) + "\n")
                if toolbar and not state.get("toolbar"):
                    raise ValueError("Missing mounted navigation bar geometry.")
                settles = time.monotonic() + 20
                while True:
                    phone.screenshot(image)
                    if state != phone.state():
                        raise ValueError("Native geometry changed during the framebuffer capture.")
                    try:
                        check(image, state, appearance, state.get("toolbar") if toolbar else None, checker)
                        break
                    except StatusBarTrails:
                        if time.monotonic() > settles:
                            raise
                        print(f"{prefix}: the status bar hasn't followed the canvas yet", flush=True)
                        time.sleep(1)
                print(f"Verified the program's canvas and readable chrome in {image.name}", flush=True)
            except (KeyError, ValueError, OSError, RuntimeError, subprocess.SubprocessError) as error:
                failures[prefix] = str(error)
                (phone.out / (prefix + "-last-state.json")).write_text(json.dumps(phone.state(), indent=2) + "\n")
                print(f"{prefix}: {error}", flush=True)
    if failures:
        raise RuntimeError(f"Program colors proof failed: {failures}")
