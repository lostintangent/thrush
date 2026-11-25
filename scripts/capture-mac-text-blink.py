#!/usr/bin/env python3
"""Measure blinking text in the packaged Mac renderer, then burst-capture the styles scene in both
Slate appearances, first blinking and then under Reduce Motion. Runs only on a disposable GitHub
runner, because it changes the Reduce Motion preference."""
import argparse
import os
from pathlib import Path
import plistlib
import random
import runpy
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
spinners = runpy.run_path(str(SCRIPTS / "capture-mac-spinners.py"))
application, prepare_hosted_motion, save, wait = (spinners[name] for name in
                                                  ("application", "prepare_hosted_motion", "save", "wait"))
oracle = runpy.run_path(str(SCRIPTS / "check-text-blink.py"))
# Jittered screenshots sample every phase of the 1.2 s cycle instead of aliasing with it.
BLINKING_FRAMES, STEADY_FRAMES = 30, 8
WINDOW = """
import CoreGraphics
let pid = Int(CommandLine.arguments[1])
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
if let window = windows.first(where: {
    ($0[kCGWindowOwnerPID as String] as? Int) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
}), let id = window[kCGWindowNumber as String] as? Int { print(id) }
"""


def benchmark(bundle, out):
    report = out / "render.json"
    result = subprocess.run(["swift", "run", "-c", "release", "ThrushBench", "--render", str(bundle), "--output", str(report)],
                            cwd=ROOT, text=True, capture_output=True, timeout=600)
    (out / "render.log").write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError("Mac render benchmark failed: " + (result.stdout + result.stderr)[-1800:])
    subprocess.run([SCRIPTS / "check-render-report.py", report], check=True, timeout=60)


def window(finder, process):
    def found():
        if process.poll() is not None:
            raise RuntimeError(f"Application {process.pid} exited with status {process.returncode}")
        return subprocess.run([finder, str(process.pid)], text=True, capture_output=True, timeout=10).stdout.strip()
    return wait("the terminal window", found)


def screenshot(window_id, path):
    subprocess.run(["/usr/sbin/screencapture", "-x", "-o", "-l", window_id, path], check=True, timeout=30)


def burst(window_id, folder, appearance, count):
    folder.mkdir(parents=True)
    probe = folder / "probe.png"

    def drawn():
        screenshot(window_id, probe)
        try:
            return oracle["Grid"](oracle["Capture"](probe, appearance))
        except ValueError:
            return None
    wait(f"the styles scene in {appearance}", drawn)
    time.sleep(0.7)
    frames = []
    for index in range(count):
        path = folder / f"{index:02}.png"
        screenshot(window_id, path)
        frames.append(path)
        time.sleep(random.uniform(0.03, 0.29))
    return frames


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    opts = parser.parse_args()
    os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    out = opts.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if any(out.iterdir()):
        parser.error("Use an empty output directory.")
    if os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted":
        parser.error("This capture changes Reduce Motion and runs only on a disposable GitHub runner.")
    subprocess.run([SCRIPTS / "build-demo.sh", "mac"], cwd=ROOT, check=True)
    bundle = ROOT / ".build/demo/mac/Thrush.app"
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    save(out / "source.json", dict(commit=info["ThrushGitCommit"], dirty=info["ThrushWorktreeDirty"],
                                 toolchain=info["ThrushToolchain"],
                                 os=subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip()))
    prepare_hosted_motion(out)
    benchmark(bundle, out)
    peer = runpy.run_path(str(SCRIPTS / "capture-simulator.py"))["peer"]
    bursts = {}
    with tempfile.TemporaryDirectory(dir=out.parent, prefix="thrush-text-blink-") as scratch, peer(out) as endpoint:
        source, finder = Path(scratch) / "window.swift", Path(scratch) / "window"
        source.write_text(WINDOW)
        subprocess.run(["xcrun", "swiftc", source, "-o", finder], check=True, timeout=300)
        for reduced in (False, True):
            prepare_hosted_motion(out, reduced=reduced)
            for appearance in ("dark", "light"):
                label = "steady" if reduced else "blinking"
                args = ["--endpoint", endpoint, "--scene", "styles", "--appearance", appearance]
                with application(bundle, args, out / f"{appearance}-{label}-host.log") as process:
                    window_id = window(finder, process)
                    subprocess.run(["open", "-a", bundle], check=True)
                    bursts[appearance, label] = burst(window_id, Path(scratch) / f"{appearance}-{label}", appearance,
                                                      STEADY_FRAMES if reduced else BLINKING_FRAMES)
                    if process.poll() is not None:
                        raise RuntimeError(f"The styles scene exited during the {appearance} burst.")
        prepare_hosted_motion(out)
        oracle["check_bursts"](bursts, out)


if __name__ == "__main__":
    main()
