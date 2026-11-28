"""Check the public pane under an inline navigation bar on the iPhone, in both appearances, in portrait
and landscape, with the keyboard hidden and shown. The canvas must reach every edge of the window
while the grid stays inside the safe area and above the keyboard, or runs on under the home indicator
while the keyboard is down, and a host's own `.ignoresSafeArea()` must change nothing, down to the pixel."""
import json
from pathlib import Path
import runpy
import subprocess

ROOT = Path(__file__).resolve().parents[2]
Capture = runpy.run_path(str(ROOT / "Tests/ThrushProofs/check-demo-capture.py"))["Capture"]
LAYOUTS = (("portrait", "hidden"), ("landscape", "hidden"), ("portrait", "visible"), ("landscape", "visible"))
VARIANTS = {"pane": (), "host-ignores-safe-area": ("--host-ignores-safe-area",)}
GEOMETRY = ("windowPoints", "gridFrame", "columns", "rows", "keyboardHeight", "accessoryHeight", "toolbar",
            "cellGridPixels")


def edges(rect):
    (x, y), (w, h) = rect
    return x, y, x + w, y + h


def check(image, state, appearance):
    toolbar = state.get("toolbar")
    if not toolbar:
        raise ValueError("Missing mounted navigation bar or canvas geometry.")
    scale = state["displayScale"]
    epsilon = 1 / scale
    window = edges(state["windowPoints"])
    canvas = edges(toolbar["canvasFrame"])
    safe = edges(toolbar["safeAreaFrame"])
    bar = edges(toolbar["navigationBarFrame"])
    grid = edges(state["gridFrame"])
    first = edges(toolbar["firstCellFrame"])
    shown = state["keyboardHeight"] >= 90
    if any(abs(canvas[i] - window[i]) > epsilon for i in range(4)):
        raise ValueError(f"The canvas doesn't reach every edge of the window: {canvas}, {window}")
    usable = (safe[0], safe[1], safe[2], window[3] - state["keyboardHeight"] if shown else window[3])
    if any(abs(grid[i] - usable[i]) > epsilon for i in range(4)):
        raise ValueError(f"The grid doesn't fill the safe area {'above the keyboard' if shown else 'and the strip below'}: "
                         f"{grid}, {usable}")
    if abs(safe[1] - bar[3]) > epsilon or first[1] + epsilon < bar[3]:
        raise ValueError(f"Row one doesn't start below the navigation bar: {first}, {bar}, {safe}")
    if not shown:
        # Rows run on under the home indicator. The last ends within a row of the grid's bottom inset.
        row, inset = first[3] - first[1], first[1] - grid[1]
        last = first[1] + state["rows"] * row
        if not grid[3] - inset - row - epsilon < last <= grid[3] - inset + epsilon:
            raise ValueError(f"The last row doesn't reach within a row of the grid's bottom inset: {last}, {grid}")

    pixels = Capture(image, appearance)
    if (pixels.width, pixels.height) != (round((window[2] - window[0]) * scale), round((window[3] - window[1]) * scale)):
        raise ValueError("Simulator framebuffer does not match the mounted window.")
    background = pixels.matches("background", tolerance=8)

    def canvas(left, top, right, bottom, where):
        # Points in the window to framebuffer pixels. Nearly every sample must be the canvas.
        x0, x1 = round((left - window[0]) * scale), round((right - window[0]) * scale)
        y0, y1 = round((top - window[1]) * scale), round((bottom - window[1]) * scale)
        samples = [pixels.pixels[y * pixels.width + x] for y in range(y0, y1) for x in range(x0, x1)]
        if not samples or sum(value in background for value in samples) < 0.95 * len(samples):
            raise ValueError(f"The canvas is missing {where}: x={x0}…{x1}, y={y0}…{y1}.")

    # Between the leading title and the trailing Close button, the bar shows the pane's canvas.
    width, middle = bar[2] - bar[0], (bar[1] + bar[3]) / 2
    canvas(bar[0] + 0.4 * width, middle - 1, bar[0] + 0.55 * width, middle + 1, "beneath the navigation bar")
    if not shown:
        canvas(max(window[0] + 24, grid[0]), safe[3] + 1, min(window[2] - 24, grid[2]), window[3] - 16,
               "beside the home indicator")
    if state["orientation"] == "landscape":
        # Just below the bar, clear of the display's rounded corners and the camera.
        for left, right, side in ((window[0], grid[0], "leading"), (grid[2], window[2], "trailing")):
            if right - left < 1:
                continue
            canvas(left + 0.3 * (right - left), bar[3] + 4, left + 0.7 * (right - left), bar[3] + 24,
                   f"in the {side} landscape inset")


def compare(first, second, appearance, scale):
    a, b = Capture(first, appearance), Capture(second, appearance)
    if (a.width, a.height) != (b.width, b.height):
        raise ValueError(f"{second.name} is {b.width} × {b.height}, not {a.width} × {a.height}.")
    if a.pixels.tobytes() == b.pixels.tobytes():
        return
    # Two system layers composite on their own clocks across launches: the home indicator fades
    # its adaptive tint in and out, and glass and the display mask resample their edges by a
    # few levels. Everything the pane and its host draw must still match.
    indicator_top, indicator_left, indicator_right = a.height - round(16 * scale), a.width // 4, a.width * 3 // 4
    changed = []
    for i in range(len(a.pixels)):
        if a.pixels[i] == b.pixels[i]:
            continue
        x, y = i % a.width, i // a.width
        if y >= indicator_top and indicator_left <= x < indicator_right:
            continue
        if max(abs(p - q) for p, q in zip(Capture.rgb(a.pixels[i]), Capture.rgb(b.pixels[i]))) <= 4:
            continue
        changed.append((x, y))
    if changed:
        xs, ys = [x for x, _ in changed], [y for _, y in changed]
        raise ValueError(f"{len(changed)} pixels differ from {first.name} within x={min(xs)}…{max(xs)}, "
                         f"y={min(ys)}…{max(ys)}.")


def capture(phone, options, sim):
    phone.warm_keyboard(None)
    failures = {}
    for appearance in ("dark", "light"):
        for orientation, keyboard in LAYOUTS:
            layout = f"under-bars-{appearance}-{orientation}{'-keyboard' if keyboard == 'visible' else ''}"
            states = {}
            for variant, extra in VARIANTS.items():
                label = f"{layout}-{variant}"
                try:
                    pid = phone.launch("prompt", appearance, orientation, keyboard,
                                       extra_arguments=("--toolbar-proof", *extra))
                    state = phone.frame("prompt", appearance, orientation, keyboard, pid, None, layout_only=True)
                    image = phone.out / (label + ".png")
                    phone.screenshot(image)
                    if state != phone.state():
                        raise ValueError("Native geometry changed during the framebuffer capture.")
                    image = phone.oriented_image(image, orientation)
                    if image.parent != phone.out:
                        image.replace(phone.out / (label + ".png"))
                        image = phone.out / (label + ".png")
                    (phone.out / (label + ".json")).write_text(json.dumps(state, indent=2) + "\n")
                    states[variant] = {key: state.get(key) for key in GEOMETRY}
                    check(image, state, appearance)
                    print(f"Verified the canvas under every bar and the grid in the safe area in {image.name}",
                          flush=True)
                except (KeyError, ValueError, OSError, RuntimeError, subprocess.SubprocessError) as error:
                    failures[label] = str(error)
                    (phone.out / (label + "-last-state.json")).write_text(json.dumps(phone.state(), indent=2) + "\n")
                    print(f"{label}: {error}", flush=True)
            if len(states) == len(VARIANTS):
                try:
                    pane, host = states.values()
                    if pane != host:
                        raise ValueError(f"The host's modifier changed the native layout: {pane} versus {host}")
                    names = [phone.out / f"{layout}-{variant}.png" for variant in VARIANTS]
                    compare(*names, appearance, state["displayScale"])
                    print(f"The host's .ignoresSafeArea() changes no pixel in {layout}", flush=True)
                except (ValueError, OSError, subprocess.SubprocessError) as error:
                    failures[layout] = str(error)
                    print(f"{layout}: {error}", flush=True)
    sim("status_bar", phone.device, "clear", check=False)
    if failures:
        raise RuntimeError(f"Pane under bars proof failed: {failures}")
