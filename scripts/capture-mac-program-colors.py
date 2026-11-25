#!/usr/bin/env python3
"""Capture colors a program sets in the packaged Mac window, in both Slate appearances, under the
demo's transparent title bar and under a full-size window toolbar. The colors scene picks the canvas
the system didn't, so every frame puts program colors against the host's chrome. Under the toolbar,
a host's own `.ignoresSafeArea()` must change no pixel."""
import argparse
import collections
import os
from pathlib import Path
import plistlib
import runpy
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
luminance = runpy.run_path(str(SCRIPTS / "check-spinner-contrast.py"))["luminance"]
spinners = runpy.run_path(str(SCRIPTS / "capture-mac-spinners.py"))
application, save, wait = (spinners[name] for name in ("application", "save", "wait"))
blink = runpy.run_path(str(SCRIPTS / "capture-mac-text-blink.py"))
WINDOW, window, screenshot = (blink[name] for name in ("WINDOW", "window", "screenshot"))
Capture = runpy.run_path(str(SCRIPTS / "check-demo-capture.py"))["Capture"]
# The palettes in scripts/demo-peer.ts, by system appearance, and the demo window's width in points.
PROGRAM = {"dark": ("paper", "F4EFE4"), "light": ("night", "17151F")}
SLATE = {"dark": "131D27", "light": "FBFDFE"}
WIDTH = 720


def check(image, appearance, toolbar, checker):
    name, paper = PROGRAM[appearance]
    pixels = Capture(image, appearance)
    scale = pixels.width / WIDTH

    def near(pixel, hex, tolerance=8):
        return max(abs(a - b) for a, b in zip(pixels.rgb(pixel), bytes.fromhex(hex))) <= tolerance

    def read(top, bottom, labels):
        y, height = round(top * scale), round((bottom - top) * scale)
        result = subprocess.run([checker, image, "--crop", "0", str(y), str(pixels.width), str(height), *labels],
                                capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise ValueError((result.stdout + result.stderr).strip())

    bar = 52 if toolbar else 28
    # A full-size toolbar's title follows the system appearance, so the theme's canvas stays beneath it.
    below = collections.Counter(pixels.pixels[round(bar * scale) * pixels.width:]) if toolbar else pixels.hist
    total = pixels.width * pixels.height
    if sum(below[v] for v in below if near(v, SLATE[appearance], 3)) > total * 0.005:
        raise ValueError("The theme's canvas shows through the program's colors.")
    if sum(below[v] for v in below if near(v, paper, 3)) < total * 0.5:
        raise ValueError(f"The {name} canvas covers less than half the window.")
    read(0, bar, ["Terminal", "Close"] if toolbar else ["Thrush"])
    # Vision reads text a person can't, so the title's strongest strokes must also reach 4.5:1
    # against the bar. The span starts after the window buttons and ends before the toolbar items.
    title = pixels.crop((round(0.12 * pixels.width), round(4 * scale), round(0.40 * pixels.width), round((bar - 4) * scale)))
    ground = luminance(max(set(title), key=title.count))
    if max((max(a, ground) + 0.05) / (min(a, ground) + 0.05) for a in map(luminance, title)) < 4.5:
        raise ValueError("The window title doesn't stand out from its bar.")
    read(bar, bar + 48, ["palette " + name])
    if toolbar:
        # Between the leading title and the trailing Close button, the toolbar shows the theme's canvas.
        y = round(bar / 2 * scale)
        row = pixels.pixels[y * pixels.width + round(0.40 * pixels.width):y * pixels.width + round(0.55 * pixels.width)]
        if sum(near(value, SLATE[appearance], 3) for value in row) < 0.8 * len(row):
            raise ValueError("The theme's canvas is missing beneath the window toolbar.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    opts = parser.parse_args()
    os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    out = opts.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if any(out.iterdir()):
        parser.error("Use an empty output directory.")
    subprocess.run([SCRIPTS / "build-demo.sh", "mac"], cwd=ROOT, check=True)
    bundle = ROOT / ".build/demo/mac/Thrush.app"
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    save(out / "source.json", dict(commit=info["ThrushGitCommit"], dirty=info["ThrushWorktreeDirty"],
                                 toolchain=info["ThrushToolchain"],
                                 os=subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip()))
    peer = runpy.run_path(str(SCRIPTS / "capture-simulator.py"))["peer"]
    failures = {}
    with tempfile.TemporaryDirectory(dir=out.parent, prefix="thrush-program-colors-") as scratch, peer(out) as endpoint:
        source, finder, checker = Path(scratch) / "window.swift", Path(scratch) / "window", Path(scratch) / "check"
        source.write_text(WINDOW)
        subprocess.run(["xcrun", "swiftc", source, "-o", finder], check=True, timeout=300)
        subprocess.run(["xcrun", "swiftc", SCRIPTS / "check-pane-capture.swift", "-o", checker], check=True, timeout=300)
        for appearance in ("dark", "light"):
            for toolbar, host in ((False, False), (True, False), (True, True)):
                label = f"colors-{'toolbar-' if toolbar else ''}{'host-ignores-safe-area-' if host else ''}{appearance}"
                args = ["--endpoint", endpoint, "--scene", "colors", "--appearance", appearance,
                        *(["--toolbar-proof"] if toolbar else []), *(["--host-ignores-safe-area"] if host else [])]
                path = out / (label + ".png")
                error = None

                def drawn():
                    nonlocal error
                    screenshot(window_id, path)
                    try:
                        check(path, appearance, toolbar, checker)
                        return True
                    except ValueError as failure:
                        error = str(failure)
                        return False
                with application(bundle, args, out / (label + ".log")) as process:
                    window_id = window(finder, process)
                    subprocess.run(["open", "-a", bundle], check=True)
                    try:
                        wait(label, drawn)
                        print(f"Verified the program's canvas and readable chrome in {path.name}", flush=True)
                    except TimeoutError:
                        failures[label] = error
                        print(f"{label}: {error}", flush=True)
            label = f"colors-toolbar-host-ignores-safe-area-{appearance}"
            if not ({label, f"colors-toolbar-{appearance}"} & failures.keys()):
                pane, host = (Capture(out / f"colors-toolbar-{name}.png", appearance)
                              for name in (appearance, "host-ignores-safe-area-" + appearance))
                if pane.pixels.tobytes() != host.pixels.tobytes():
                    failures[label] = "The host's .ignoresSafeArea() changed the window's pixels."
                else:
                    print(f"The host's .ignoresSafeArea() changes no pixel in {label}.png", flush=True)
    if failures:
        raise SystemExit(f"Program colors proof failed: {failures}")


if __name__ == "__main__":
    main()
