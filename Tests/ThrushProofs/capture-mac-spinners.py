#!/usr/bin/env python3
"""Capture the active and visibly inactive Mac connection indicators in both appearances."""
import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import signal
import struct
import subprocess
import sys
import tempfile
import time
from urllib.request import urlopen

import proof
from proof import HERE, advance, application, save, wait
import spinner


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


def capture(out, label, path, process, appearance, focus_pid, waiting, helper=None, ended=None):
    active = helper is None

    def settled():
        state = read_state(path, process)
        if (state.get("visible") and state["appearance"] == appearance and state["keyWindow"] == active
                and state["activeApp"] == active and state.get("frontmostPID") == focus_pid
                and bool(state.get("spinnerFrame")) == waiting and state.get("cursorCellFrame")
                and not state["reduceMotion"] and (ended is None or (state["shellEnded"] == ended
                     and bool(state.get("newShellButtonFrame")) == ended))):
            return state

    image = out / (label + ".png")
    fields = ("pid", "windowID", "scene", "appearance", "keyWindow", "activeApp", "visible", "frontmostPID",
              "reduceMotion", "windowFrame", "scale", "spinnerFrame", "cursorSpinnerLabel", "cursorCellFrame", "firstCellFrame",
              "gridFrame", "rows", "columns", "hasTranscript", "shellEnded", "newShellButtonFrame")
    for attempt in (1, 2):
        before = wait(label, settled)
        time.sleep(.35)
        proof.capture_window(process.pid, image)
        after = read_state(path, process)
        if all(before.get(key) == after.get(key) for key in fields):
            save(out / (label + ".json"), dict(before, helperRect=helper))
            return image, before
        save(out / f"{label}-transition-{attempt}.json", dict(before=before, after=after))
    raise RuntimeError(f"{label} changed focus, geometry or cursor during both captures.")


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
    bundle = proof.mac_app(out)
    if opts.prepare_hosted_motion:
        proof.prepare_hosted_motion(out)
    results, errors = {}, {}
    with tempfile.TemporaryDirectory(dir=out.parent, prefix="thrush-spinner-") as scratch, proof.peer(out) as endpoint:
        focus = proof.build_cover(Path(scratch))
        for appearance in ("dark", "light"):
            for scene in ("spinner-opening", "spinner-reconnecting"):
                name = f"{scene}-{appearance}"
                path = out / (name + "-state.json")
                args = ["--endpoint", endpoint, "--scene", scene, "--appearance", appearance,
                        "--spinner-capture-state", str(path), str(focus)]
                try:
                    with application(bundle, args, out / (name + "-host.log")) as process:
                        wait("mounted terminal", lambda: read_state(path, process))
                        subprocess.run(["open", "-a", bundle], check=True, timeout=20)
                        opening = scene == "spinner-opening"
                        if not opening:
                            wait("acknowledged transcript", lambda: read_state(path, process).get("hasTranscript"))
                        def grab(label, waiting, *, focus_pid=process.pid, helper=None):
                            return capture(out, name + "-" + label, path, process, appearance, focus_pid, waiting, helper)
                        active_before = grab("active" if opening else "active-live", opening)
                        with focus_helper(path, process) as (pid, rect):
                            inactive_before = grab("inactive" if opening else "inactive-live", opening, focus_pid=pid, helper=rect)
                            advance(endpoint, "release-opening" if opening else "interrupt-reconnecting")
                            inactive_after = grab("inactive-live" if opening else "inactive", not opening, focus_pid=pid, helper=rect)
                        subprocess.run(["open", "-a", bundle], check=True, timeout=20)
                        active_after = grab("active-live" if opening else "active", not opening)
                        row, column = (0, 0) if opening else (8, len("~/thrush % "))
                        ax_label = "Connecting" if opening else "Reconnecting"
                        for label, before, after in (("active", active_before, active_after), ("inactive", inactive_before, inactive_after)):
                            paused, live = (before, after) if opening else (after, before)
                            results[name + "-" + label] = spinner.measure(*paused, appearance, row, column, ax_label)
                            results[name + "-" + label].update(spinner.compare(*paused, *live, appearance))
                except (OSError, ValueError, RuntimeError, KeyError, subprocess.SubprocessError) as error:
                    errors[name] = str(error)
                save(out / "cursor-spinners.json", dict(samples=results, errors=errors))
        try:
            check_new_shell(out, bundle, endpoint, focus, Path(scratch))
        except (OSError, ValueError, RuntimeError, KeyError, subprocess.SubprocessError) as error:
            errors["new-shell-toolbar"] = str(error)
        save(out / "cursor-spinners.json", dict(samples=results, errors=errors))

    if errors or len(results) != 8:
        sys.exit("Incomplete cursor spinner captures: " + str(errors))


def check_new_shell(out, bundle, endpoint, focus, work):
    path = out / "new-shell-state.json"
    args = ["--endpoint", endpoint, "--scene", "shell-ended", "--appearance", "dark",
            "--spinner-capture-state", str(path), str(focus)]
    def observed(count):
        with urlopen(endpoint + "/toolbar-state", timeout=5) as response:
            state = json.load(response)
        return state if state["opened"] == state["acknowledged"] == count else None
    with application(bundle, args, out / "new-shell-host.log") as process:
        wait("initial shell output acknowledged", lambda: observed(1))
        subprocess.run(["open", "-a", bundle], check=True, timeout=20)
        def capture_phase(label, ended):
            return capture(out, "new-shell-" + label, path, process, "dark", process.pid, False, ended=ended)
        _, live = capture_phase("live", False)
        advance(endpoint, "exit-shell")
        image, ended = capture_phase("ended", True)
        (x, y), (w, h) = ended["newShellButtonFrame"]
        (_, grid_top), _ = ended["gridFrame"]
        if min(w, h) <= 0 or y < 0 or y + h > grid_top + 1:
            raise ValueError("The New Shell toolbar button is not above the terminal grid.")
        checker = work / "check-toolbar-label"
        subprocess.run(["xcrun", "swiftc", HERE / "check-pane-capture.swift", "-o", checker], check=True, timeout=120)
        # ScreenCaptureKit and screencapture can return different image scales.
        _, (window_w, _) = ended["windowFrame"]
        with image.open("rb") as png:
            png.seek(16)
            pixel_width, = struct.unpack(">I", png.read(4))
        scale = pixel_width / window_w
        crop = [str(round(n*scale)) for n in (x, y, w, h)]
        subprocess.run([checker, image, "--crop", *crop, "New Shell"], check=True, timeout=60)
        path.with_suffix(path.suffix + ".new-shell").touch()
        peer = wait("replacement shell output acknowledged", lambda: observed(2))
        _, fresh = capture_phase("fresh", False)
        for k in ("pid", "gridFrame", "windowFrame", "rows", "columns", "firstCellFrame"):
            if not live[k] == ended[k] == fresh[k]:
                raise ValueError(f"Starting another shell changed native {k}.")
        save(out / "new-shell-toolbar.json", dict(peer=peer, frame=ended["newShellButtonFrame"],
                                                grid=ended["gridFrame"], buttonTitle="New Shell",
                                                visibleByPhase=[False, True, False]))


if __name__ == "__main__":
    main()
