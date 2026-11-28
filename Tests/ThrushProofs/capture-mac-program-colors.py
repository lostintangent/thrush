#!/usr/bin/env python3
"""Capture colors a program sets in the packaged Mac window, in both appearances: under the sample's
transparent title bar, under a full-size window toolbar with and without its background, and in a split
view's detail beside a sidebar. The colors scene picks the canvas the system didn't, so every frame puts
program colors against the host's chrome. The program's canvas must run beneath each toolbar, which takes
the canvas's appearance while a sidebar's toolbar items keep the window's. Under the toolbar, a host's own
`.ignoresSafeArea()` must change no pixel by more than two levels, the most the toolbar's glass rim varies
between launches. Live takes then switch the program's palette and the system appearance under one open
window, and each settled frame must pass the same checks."""
import argparse
import collections
import os
from pathlib import Path
import plistlib
import runpy
import subprocess
import tempfile
import urllib.request

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SCRIPTS = ROOT / "scripts"
luminance = runpy.run_path(str(HERE / "check-spinner-contrast.py"))["luminance"]
spinners = runpy.run_path(str(HERE / "capture-mac-spinners.py"))
application, save, wait = (spinners[name] for name in ("application", "save", "wait"))
blink = runpy.run_path(str(HERE / "capture-mac-text-blink.py"))
WINDOW, window, screenshot = (blink[name] for name in ("WINDOW", "window", "screenshot"))
Capture = runpy.run_path(str(HERE / "check-demo-capture.py"))["Capture"]
# The palettes in Tests/ThrushProofs/peers/demo-peer.ts, the one the colors scene opens with by system appearance, and the
# window's width, compact toolbar height and split view sidebar in points.
PALETTES = {"paper": "F4EFE4", "night": "17151F"}
PROGRAM = {"dark": "paper", "light": "night"}
CANVAS = {"dark": "131D27", "light": "FBFDFE"}
WIDTH, BAR, SIDEBAR = 720, 40, 200
# Each window's proof arguments.
WINDOWS = {
    "colors": [],
    "colors-toolbar": ["--toolbar-proof"],
    "colors-toolbar-host-ignores-safe-area": ["--toolbar-proof", "--host-ignores-safe-area"],
    "colors-toolbar-background": ["--toolbar-proof", "--toolbar-background"],
    "colors-split": ["--toolbar-proof", "split"],
    "colors-split-background": ["--toolbar-proof", "split", "--toolbar-background"],
}
# A live take's steps: what changes, then the palette and system appearance the open window must settle on.
LIVE = (("launch", "night", "light"), ("palette", "paper", "light"), ("system", "paper", "dark"),
        ("palette", "night", "dark"), ("system", "night", "light"))


def check(image, appearance, palette, args, checker):
    canvas = PALETTES[palette]
    pixels = Capture(image, appearance)
    scale = pixels.width / WIDTH
    toolbar, split = "--toolbar-proof" in args, "split" in args

    def near(pixel, hex, tolerance=8):
        return max(abs(a - b) for a, b in zip(pixels.rgb(pixel), bytes.fromhex(hex))) <= tolerance

    def read(box, *labels, exact_line=False):
        left, top, right, bottom = (round(edge * scale) for edge in box)
        crop = [str(n) for n in (left, top, right - left, bottom - top)]
        options = ["--exact-line"] if exact_line else []
        result = subprocess.run([checker, image, "--crop", *crop, *options, *labels],
                                capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise ValueError((result.stdout + result.stderr).strip())

    bar, height, sidebar = BAR, pixels.height / scale, SIDEBAR if split else 0
    total = pixels.width * pixels.height
    below = collections.Counter(pixels.pixels[round(bar * scale) * pixels.width:])
    if sum(count for value, count in below.items() if near(value, CANVAS[appearance], 3)) > total * 0.005:
        raise ValueError("The theme's canvas shows through the program's colors.")
    if sum(pixels.hist[v] for v in pixels.hist if near(v, canvas, 3)) < total * 0.5:
        raise ValueError(f"The {palette} canvas covers less than half the window.")
    # Vision reads text a person can't, so the strongest strokes of the title and of a toolbar's Close
    # label must also reach 4.5:1 against their ground. The title's span starts after the window buttons,
    # or a split view's sidebar, and ends before the toolbar items.
    def crop(left, right, top, bottom):
        return pixels.crop((round(left * pixels.width), round(top * scale), round(right * pixels.width), round(bottom * scale)))

    def contrasts(span):
        ground = luminance(max(set(span), key=span.count))
        return [(max(a, ground) + 0.05) / (min(a, ground) + 0.05) for a in map(luminance, span)]

    title = (0.29, 0.45) if split else (0.12, 0.40)
    # Read each native control independently. A tighter vertical margin can help Vision
    # separate 1x title strokes from the surrounding bar without changing the expected word.
    title_left, title_right = (edge * WIDTH for edge in title)
    try:
        read((title_left, 0, title_right, bar), "Terminal", exact_line=True)
    except ValueError:
        read((title_left, 4, title_right, bar - 4), "Terminal", exact_line=True)
    if toolbar:
        # Inside the button's border, which Vision can read as a comma.
        read((WIDTH - 50, 5, WIDTH - 8, 39), "Close", exact_line=True)
    if max(contrasts(crop(*title, 4, bar - 4))) < 4.5:
        raise ValueError("The window title doesn't stand out from its bar.")
    # The palette command opens the scene. A live take's later ones land among the canvas's last six rows.
    try:
        read((sidebar, bar, WIDTH, bar + 48), "palette " + palette)
    except ValueError:
        read((sidebar, height - 112, WIDTH, height - 4), "palette " + palette)
    if split:
        read((0, bar, sidebar, bar + 48), "Thrush")
    if toolbar:
        if max(contrasts(crop(0.93, 0.98, 12, 30))) < 4.5:
            raise ValueError("The Close label doesn't stand out from its button.")
        # Between the leading title and the trailing Close button, the program's canvas runs beneath the
        # toolbar.
        y, left, right = round(bar / 2 * scale), *(round(x * pixels.width) for x in ((0.45, 0.60) if split else (0.40, 0.55)))
        row = pixels.pixels[y * pixels.width + left:y * pixels.width + right]
        shown = sum(near(value, canvas, 3) for value in row)
        if shown < 0.8 * len(row):
            raise ValueError(f"The {palette} canvas is missing beneath the window toolbar.")
    if split:
        # The sidebar's toolbar buttons keep the window's appearance, so they mostly match the sidebar.
        ratios = contrasts(crop(0.12, 0.275, 4, bar - 4))
        if sum(ratio >= 3 for ratio in ratios) > 0.15 * len(ratios):
            raise ValueError("The sidebar's toolbar buttons left the window's appearance.")


def settle(label, path, window_id, expect):
    """Waits for a frame that passes `expect` and that the next frame repeats, since the toolbar's controls
    animate to a new appearance. Returns the last error on timeout."""
    error, previous = None, None

    def drawn():
        nonlocal error, previous
        screenshot(window_id, path)
        try:
            expect(path)
        except ValueError as failure:
            error, previous = str(failure), None
            return False
        frame, previous = previous, Capture(path, "dark").pixels.tobytes()
        error = "The window kept changing."
        return frame == previous
    try:
        wait(label, drawn)
        return None
    except TimeoutError:
        return error


def dark_mode(dark=None):
    """Reads the system appearance, or sets it through System Events."""
    if dark is None:
        result = subprocess.run(["defaults", "read", "-g", "AppleInterfaceStyle"], capture_output=True, text=True)
        return result.stdout.strip() == "Dark"
    subprocess.run(["osascript", "-e", "tell application \"System Events\" to tell appearance preferences "
                    f"to set dark mode to {str(dark).lower()}"], check=True, timeout=60)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    opts = parser.parse_args()
    os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    out = opts.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if any(out.iterdir()):
        parser.error("Use an empty output directory.")
    subprocess.run([SCRIPTS / "build-app.sh", "proofs", "mac"], cwd=ROOT, check=True)
    bundle = ROOT / ".build/proofs/mac/Thrush.app"
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    save(out / "source.json", dict(commit=info["ThrushGitCommit"], dirty=info["ThrushWorktreeDirty"],
                                 toolchain=info["ThrushToolchain"],
                                 os=subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip()))
    peer = runpy.run_path(str(HERE / "capture-simulator.py"))["peer"]
    failures = {}
    with tempfile.TemporaryDirectory(dir=out.parent, prefix="thrush-program-colors-") as scratch, peer(out) as endpoint:
        source, finder, checker = Path(scratch) / "window.swift", Path(scratch) / "window", Path(scratch) / "check"
        source.write_text(WINDOW)
        subprocess.run(["xcrun", "swiftc", source, "-o", finder], check=True, timeout=300)
        subprocess.run(["xcrun", "swiftc", HERE / "check-pane-capture.swift", "-o", checker], check=True, timeout=300)
        for appearance in ("dark", "light"):
            for name, extra in WINDOWS.items():
                label, palette = f"{name}-{appearance}", PROGRAM[appearance]
                args = ["--endpoint", endpoint, "--scene", "colors", "--appearance", appearance, *extra]
                path = out / (label + ".png")
                with application(bundle, args, out / (label + ".log")) as process:
                    window_id = window(finder, process)
                    subprocess.run(["open", "-a", bundle], check=True)
                    error = settle(label, path, window_id, lambda path: check(path, appearance, palette, extra, checker))
                if error:
                    failures[label] = error
                    print(f"{label}: {error}", flush=True)
                else:
                    print(f"Verified the program's canvas and readable chrome in {path.name}", flush=True)
            label = f"colors-toolbar-host-ignores-safe-area-{appearance}"
            if not ({label, f"colors-toolbar-{appearance}"} & failures.keys()):
                pane, host = (Capture(out / f"colors-toolbar-{name}.png", appearance)
                              for name in (appearance, "host-ignores-safe-area-" + appearance))
                # After the toolbar changes appearance, its glass rim can settle two levels apart between launches.
                moved = (pane.width, pane.height) != (host.width, host.height) or any(
                    max(abs(a - b) for a, b in zip(Capture.rgb(p), Capture.rgb(h))) > 2
                    for p, h in zip(pane.pixels, host.pixels) if p != h)
                if moved:
                    failures[label] = "The host's .ignoresSafeArea() changed the window's pixels."
                else:
                    print(f"The host's .ignoresSafeArea() changes no pixel by more than two levels in {label}.png", flush=True)
        # Each live take follows the system, so it starts from a light system and puts it back afterwards.
        was_dark = dark_mode()
        try:
            for name in ("colors-toolbar", "colors-toolbar-background", "colors-split"):
                extra = WINDOWS[name]
                dark_mode(False)
                args = ["--endpoint", endpoint, "--scene", "colors", "--appearance", "system", *extra]
                with application(bundle, args, out / f"live-{name}.log") as process:
                    window_id = window(finder, process)
                    subprocess.run(["open", "-a", bundle], check=True)
                    for index, (change, palette, appearance) in enumerate(LIVE, 1):
                        label = f"live-{name}-{index}-{palette}-{appearance}"
                        if change == "palette":
                            request = urllib.request.Request(f"{endpoint}/palette?name={palette}", method="POST")
                            urllib.request.urlopen(request, timeout=10).close()
                        elif change == "system":
                            dark_mode(appearance == "dark")
                            # System Events can take the focus, and an inactive window dims its title.
                            subprocess.run(["open", "-a", bundle], check=True)
                        path = out / (label + ".png")
                        error = settle(label, path, window_id,
                                       lambda path: check(path, appearance, palette, extra, checker))
                        if error:
                            failures[label] = error
                            print(f"{label}: {error}", flush=True)
                            break
                        print(f"Verified the program's canvas and readable chrome in {path.name}", flush=True)
        finally:
            dark_mode(was_dark)
    if failures:
        raise SystemExit(f"Program colors proof failed: {failures}")


if __name__ == "__main__":
    main()
