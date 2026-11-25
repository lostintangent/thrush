#!/usr/bin/env python3
"""Capture the active and visibly inactive Mac connection indicators in both Slate appearances."""
import argparse
from contextlib import contextmanager
import json
import math
import os
from pathlib import Path
import plistlib
import runpy
import signal
import struct
import subprocess
import sys
import tempfile
import time
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"


def save(path, data):
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")


def wait(description, predicate):
    stop = time.monotonic() + 22
    while time.monotonic() < stop:
        result = predicate()
        if result:
            return result
        time.sleep(.15)
    raise TimeoutError("Timed out waiting for " + description)


@contextmanager
def application(bundle, args, log):
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    binary = bundle / "Contents/MacOS" / info["CFBundleExecutable"]
    with log.open("w") as output, subprocess.Popen([binary, *args], stdout=output, stderr=subprocess.STDOUT) as process:
        try:
            yield process
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(5)
                except subprocess.TimeoutExpired:
                    process.kill()


def read_state(path, process):
    if process.poll() is not None:
        raise RuntimeError(f"Application {process.pid} exited with status {process.returncode}")
    if path.is_file():
        state = json.loads(path.read_text())
        if state["pid"] == process.pid:
            return state
    return {}


def helper_rect(state):
    # The existing cover helper expands this rect by 12 points. Put it in a free
    # screen corner, so activation changes while every terminal pixel stays visible.
    (x, y), (w, h) = state["windowFrame"]
    (sx, sy), (sw, sh) = state["screenVisibleFrame"]
    for left in (sx + 20, sx + sw - 44):
        for bottom in (sy + 20, sy + sh - 44):
            if left + 36 < x or left - 12 > x + w or bottom + 36 < y or bottom - 12 > y + h:
                return [left, bottom, 24, 24]
    raise ValueError("No free desktop corner for the inactive-window focus helper.")


@contextmanager
def focus_helper(path, process):
    rect = helper_rect(read_state(path, process))
    temporary = path.with_suffix(".request.tmp")
    save(temporary, rect)
    temporary.replace(str(path) + ".focus")
    def launched():
        state = read_state(path, process)
        if state.get("helperError"):
            raise RuntimeError(state["helperError"])
        return state.get("helperPID")
    pid = wait("foreground app to launch its focus helper", launched)
    try:
        geometry = Path(str(path) + ".helper-frame")
        wait("focus helper window geometry", geometry.is_file)
        actual = json.loads(geometry.read_text())
        (hx, hy), (hw, hh) = actual
        (tx, ty), (tw, th) = read_state(path, process)["windowFrame"]
        if hx < tx + tw and tx < hx + hw and hy < ty + th and ty < hy + hh:
            raise ValueError("The inactive terminal would be obscured by the focus helper.")
        yield pid, actual
    finally:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass


def capture(out, label, path, process, title, appearance, focus_pid, helper=None):
    active = helper is None

    def settled():
        state = read_state(path, process)
        if (state.get("visible") and state["appearance"] == appearance and state["keyWindow"] == active and state["activeApp"] == active
                and state.get("frontmostPID") == focus_pid and (state.get("notice") or {}).get("title") == title
                and state.get("spinnerFrame") and not state["reduceMotion"]):
            return state
        return None

    wait(label, settled)
    image = out / (label + ".png")
    # The Dock can change the screen's available desktop area when focus moves to a
    # helper. Only the target window's actual content, geometry and activation matter.
    fields = ("pid", "windowID", "scene", "appearance", "keyWindow", "activeApp", "visible",
              "hasTranscript", "reduceMotion", "frontmostPID", "windowFrame", "scale", "notice", "spinnerFrame")
    for attempt in (1, 2):
        time.sleep(.6)
        before = wait(label, settled)
        subprocess.run([SCRIPTS / "capture-demo.sh", "mac", str(process.pid), image], check=True, timeout=60)
        after = read_state(path, process)
        if all(before.get(key) == after.get(key) for key in fields):
            break
        save(out / f"{label}-transition-{attempt}.json", dict(before=before, after=after))
        if attempt == 2:
            raise RuntimeError(f"{label} changed focus, geometry or notice during both capture attempts.")
    with image.open("rb") as png:
        header = png.read(24)
    if header[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{label} is not a PNG.")
    width, height = struct.unpack(">II", header[16:24])
    _, (window_w, window_h) = before["windowFrame"]
    scale = width / window_w
    if abs(height / window_h - scale) > .01:
        raise ValueError(f"{label} screenshot does not cover the complete window.")
    (x, y), (w, h) = before["spinnerFrame"]
    if not (8 <= w <= 32 and 8 <= h <= 32):
        raise ValueError(f"{label} unexpected native spinner size {w} × {h}.")
    left, top = math.floor((x - 2) * scale), math.floor((y - 2) * scale)
    region = [left, top, math.ceil((x + w + 2) * scale) - left, math.ceil((y + h + 2) * scale) - top]
    before.update(imagePixels=[width, height], imageScale=scale, region=region, helperRect=helper)
    save(out / (label + ".json"), before)
    return image, region


def prepare_hosted_motion(out, reduced=False):
    # The disposable runner image can ship with Reduce Motion on. Query AppKit in
    # fresh processes before and after writing the user's macOS preference.
    if os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted":
        raise RuntimeError("Hosted motion preparation requires a disposable GitHub runner.")
    pref = ["com.apple.universalaccess", "reduceMotion"]
    probe = ["xcrun", "swift", "-e", "import AppKit; print(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)"]
    def effective():
        value = subprocess.check_output(probe, text=True, timeout=30).strip()
        if value not in ("true", "false"):
            raise ValueError("Unexpected AppKit motion response: " + value)
        return value == "true"
    def preference():
        result = subprocess.run(["defaults", "read", *pref], text=True, capture_output=True)
        return result.stdout.strip() if result.returncode == 0 else None

    report = dict(requested=reduced, before=effective(), previousPreference=preference())
    if report["before"] != reduced:
        write = subprocess.run(["defaults", "write", *pref, "-bool", str(reduced).lower()], text=True, capture_output=True)
        report.update(writeStatus=write.returncode, writeOutput=(write.stdout + write.stderr).strip())
    for _ in range(5):
        report["after"] = effective()
        if report["after"] == reduced:
            break
        time.sleep(.5)
    report["currentPreference"] = preference()
    save(out / ("motion-reduced.json" if reduced else "motion-settings.json"), report)
    if report["after"] != reduced:
        raise RuntimeError(f"AppKit reports Reduce Motion {report['after']} after setting the disposable host preference: {report}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--prepare-hosted-motion", action="store_true",
                        help="Select and verify normal motion on the disposable macOS runner.")
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
    if opts.prepare_hosted_motion:
        prepare_hosted_motion(out)
    samples, errors = {}, {}
    peer = runpy.run_path(str(SCRIPTS / "capture-simulator.py"))["peer"]
    measure = runpy.run_path(str(SCRIPTS / "check-spinner-contrast.py"))["measure"]
    with tempfile.TemporaryDirectory(dir=out.parent, prefix="thrush-spinner-") as scratch, peer(out, notices=True) as endpoint:
        work = Path(scratch)
        focus = runpy.run_path(str(SCRIPTS / "pty/check-window.py"))["build_cover"](work)
        for appearance in ("dark", "light"):
            for scene in ("connecting", "reconnecting"):
                name = f"{scene}-{appearance}"
                path = out / (name + "-state.json")
                args = ["--endpoint", endpoint, "--scene", "notice-" + scene, "--appearance", appearance,
                        "--spinner-capture-state", str(path), str(focus)]
                try:
                    with application(bundle, args, out / (name + "-host.log")) as process:
                        wait("mounted terminal", lambda: read_state(path, process))
                        subprocess.run(["open", "-a", bundle], check=True)
                        if scene == "reconnecting":
                            wait("acknowledged shell transcript", lambda: read_state(path, process).get("hasTranscript"))
                            with urlopen(Request(endpoint + "/interrupt-reconnecting", method="POST"), timeout=5) as reply:
                                if reply.status != 204:
                                    raise RuntimeError("The mock shell did not enter the requested outage.")
                        title = scene.capitalize()
                        active = name + "-active"
                        samples[active] = capture(out, active, path, process, title, appearance, process.pid)
                        with focus_helper(path, process) as (pid, actual):
                            inactive = name + "-inactive"
                            samples[inactive] = capture(out, inactive, path, process, title, appearance, pid, actual)
                except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
                    errors[name] = str(error)
    results = {}
    for name, (frame, region) in samples.items():
        try:
            ratio, point, spoke, background = measure(frame, region)
            results[name] = dict(ratio=ratio, spoke=spoke, pixel=point, background=background)
            if ratio < 3:
                errors[name] = f"Leading spoke contrast {ratio:.4f}:1 is below 3:1."
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            errors[name] = str(error)
    save(out / "contrast.json", dict(samples=results, errors=errors))
    print(json.dumps(results, indent=2), flush=True)
    if errors or len(results) != 8:
        sys.exit("Incomplete spinner capture or insufficient contrast: " + str(errors))


if __name__ == "__main__":
    main()
