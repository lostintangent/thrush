"""Check the packaged terminal under an inline NavigationStack toolbar in original simulator pixels."""
from pathlib import Path
import runpy
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def edges(rect):
    (x, y), (w, h) = rect
    return x, y, x + w, y + h


def check_copy(image, rect, state, checker, labels):
    # Crop only the checked geometry so a transcript line cannot masquerade as a toolbar title.
    scale = state["displayScale"]
    window_x, window_y, _, _ = edges(state["windowPoints"])
    left, top, right, bottom = edges(rect)
    x, y = round((left - window_x) * scale), round((top - window_y) * scale)
    width, height = round((right - left) * scale), round((bottom - top) * scale)
    subprocess.run([checker, image, "--crop", str(x), str(y), str(width), str(height), *labels],
                   check=True, timeout=60)


def check(image, state, appearance, scene, checker):
    toolbar = state.get("toolbar")
    if not toolbar:
        raise ValueError("Missing mounted navigation bar or canvas geometry.")
    scale = state["displayScale"]
    epsilon = 1 / scale
    canvas = edges(toolbar["canvasFrame"])
    safe = edges(toolbar["safeAreaFrame"])
    bar = edges(toolbar["navigationBarFrame"])
    grid = edges(state["gridFrame"])
    window = edges(state["windowPoints"])
    first = edges(toolbar["firstCellFrame"])
    if not (window[0] <= bar[0] < bar[2] <= window[2] and window[1] <= bar[1] < bar[3] <= window[3]):
        raise ValueError(f"Invalid native navigation bar: {bar}, {window}")
    if abs(canvas[1] - window[1]) > epsilon:
        raise ValueError(f"The canvas does not reach the physical top of the window: {canvas}, {window}")
    if state["orientation"] == "portrait" and abs(grid[1] - bar[3]) > epsilon:
        raise ValueError(f"The terminal grid does not begin at the inline bar’s bottom: {grid}, {bar}")
    if (first[1] + epsilon < max(bar[3], safe[1]) or first[0] + epsilon < grid[0] or
            first[3] <= first[1] or first[2] <= first[0]):
        raise ValueError(f"Row one overlaps toolbar chrome or falls outside the grid: {first}, {bar}, {grid}")
    check_copy(image, toolbar["navigationBarFrame"], state, checker, ["Terminal", "Close"])
    pixels = runpy.run_path(str(ROOT / "Tests/ThrushProofs/check-demo-capture.py"))["Capture"](image, appearance)
    if (pixels.width, pixels.height) != (round((window[2] - window[0]) * scale), round((window[3] - window[1]) * scale)):
        raise ValueError("Simulator framebuffer does not match the mounted window.")
    # The inline title leads the bar, with Close on the trailing edge. Sample the
    # unobstructed bar between them, where the canvas must show through.
    bar_width = bar[2] - bar[0]
    left = round((bar[0] - window[0] + 0.4 * bar_width) * scale)
    right = round((bar[0] - window[0] + 0.55 * bar_width) * scale)
    middle = round(((bar[1] + bar[3]) / 2 - window[1]) * scale)
    background = pixels.matches("background", tolerance=8)
    for y in range(middle - 1, middle + 2):
        sample = pixels.pixels[y * pixels.width + left:y * pixels.width + right]
        if not sample or sum(value in background for value in sample) < 0.95 * len(sample):
            raise ValueError(f"The canvas is missing beneath the unoccupied bar at x={left}…{right}, y={y}.")
    if scene == "spinner-reconnecting":
        row = ((grid[0], first[1]), (grid[2] - grid[0], first[3] - first[1]))
        check_copy(image, row, state, checker, ["swift test"])
