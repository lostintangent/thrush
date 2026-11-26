#!/usr/bin/env python3
"""Record Terminal.app and Ghostty on the disposable macOS workflow runner.

Usage: python3 scripts/interaction-capture/clear-reference.py OUTPUT
Each app produces two original window movies. recorded-oshen replays the exact PTY reads
from the pane test. live-zsh drives a real interactive zsh through its PTY in the app.
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shlex
import signal
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
FIXTURE = HERE / "clear-oshen.json"
GHOSTTY_VERSION = "1.4.0"
GHOSTTY_URL = f"https://release.files.ghostty.org/{GHOSTTY_VERSION}/Ghostty.dmg"
# Homebrew's ghostty cask for the upstream universal release.
GHOSTTY_SHA = "3a02075dbd24318d778426af41dee5507d53ecc4578ede96912ec9ce6d18d3e8"
GHOSTTY_TEAM = "24VZTF6M5V"


def run(*args, timeout=60):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT, timeout=timeout).strip()


def bundle(app):
    return plistlib.loads((app / "Contents/Info.plist").read_bytes())


def ghostty(work):
    app = Path("/Applications/Ghostty.app")
    if app.is_dir() and bundle(app)["CFBundleShortVersionString"] == GHOSTTY_VERSION:
        return app, {"source": "preinstalled signed bundle"}
    dmg = work / "Ghostty.dmg"
    run("curl", "--fail", "--location", "--proto", "=https", "--retry", "2", "--output", dmg, GHOSTTY_URL, timeout=180)
    if hashlib.sha256(dmg.read_bytes()).hexdigest() != GHOSTTY_SHA:
        raise ValueError("Ghostty release image does not match the pinned SHA-256")
    mount = work / "disk"
    mount.mkdir()
    run("hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", mount, dmg)
    try:
        app = work / "Ghostty.app"
        run("ditto", mount / "Ghostty.app", app)
    finally:
        run("hdiutil", "detach", mount)
    return app, {"source": GHOSTTY_URL, "sha256": GHOSTTY_SHA,
                 "digestSource": "https://formulae.brew.sh/api/cask/ghostty.json"}


def provenance(app, requirement):
    run("codesign", "--verify", "--strict", "-R", "=" + requirement, app)
    info = bundle(app)
    return {"path": str(app), "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
            "bundleID": info["CFBundleIdentifier"], "codeSignature": run("codesign", "-dv", "--verbose=4", app)}


def wait(path, out, timeout, recorder=None):
    end = time.monotonic() + timeout
    while not path.exists():
        failure = out / "worker-error.txt"
        if failure.exists():
            raise RuntimeError(failure.read_text())
        if recorder is not None and recorder.poll() is not None:
            raise RuntimeError(f"window recorder exited {recorder.returncode}; see {out}/recorder.log")
        if time.monotonic() >= end:
            raise TimeoutError(f"waiting for {path}")
        time.sleep(0.04)


def capture(app, mode, out, work, recorder, fixture):
    out.mkdir()
    worker = [sys.executable, str(HERE / "clear-reference-terminal.py"), str(out), app.stem, mode, str(FIXTURE)]
    if app.stem == "Terminal":
        command = work / f"{mode}.command"
        command.write_text("#!/bin/sh\nexec " + shlex.join(worker) + "\n")
        command.chmod(0o700)
        run("open", "-n", "-F", "-a", app, command)
    else:
        run("open", "-n", "-F", "-a", app, "--args", f"--window-width={fixture['columns']}",
            f"--window-height={fixture['rows']}", "-e", *worker)
    pid = None
    movie = None
    try:
        wait(out / "terminal.json", out, 35)
        info = json.loads((out / "terminal.json").read_text())
        pid = info["appPID"]
        if info["columns"] < len("thrush$ clear") or fixture["historyLines"] - info["rows"] < 1:
            raise ValueError(f"native grid cannot show the prompt or retain seed history: {info}")
        with (out / "recorder.log").open("w") as log:
            movie = subprocess.Popen([recorder, str(pid), out / "window.mov", out / "ready", out / "stop"],
                                     stdout=log, stderr=log,
                                     env=dict(os.environ, THRUSH_WINDOW_TITLE="Thrush Clear Reference"))
            wait(out / "ready", out, 25, movie)
            (out / "go").touch()
            wait(out / "result.json", out, 30, movie)
            time.sleep(1.2)  # Leave the final prompt on film before the worker exits.
            (out / "stop").touch()
            if movie.wait(timeout=25):
                raise RuntimeError((out / "recorder.log").read_text())
        if not (out / "window.mov").stat().st_size:
            raise ValueError("empty reference movie")
    finally:
        (out / "release").touch()
        if movie is not None and movie.poll() is None:
            movie.terminate()
            movie.wait(timeout=5)
        if pid is not None:
            try:
                os.kill(pid, signal.SIGTERM)  # New app instance verified by the worker's PTY ancestry.
            except ProcessLookupError:
                pass


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    out = Path(sys.argv[1]).resolve()
    if (sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true"
            or os.environ.get("RUNNER_OS") != "macOS" or not os.environ.get("RUNNER_TEMP")):
        raise SystemExit("Run clear-reference only on the disposable hosted macOS workflow runner.")
    out.mkdir(parents=True, exist_ok=True)
    fixture = json.loads(FIXTURE.read_bytes())
    with tempfile.TemporaryDirectory(prefix="thrush-clear-", dir=os.environ["RUNNER_TEMP"]) as directory:
        work = Path(directory)
        recorder = work / "record-window"
        run("xcrun", "swiftc", "-O", HERE / "record-window.swift", "-o", recorder, timeout=120)
        terminal = Path("/System/Applications/Utilities/Terminal.app")
        report = {"macOS": run("sw_vers"), "apps": {}, "fixtureSHA256": hashlib.sha256(FIXTURE.read_bytes()).hexdigest(),
                  "recorded": "Exact Oshen output reads with original within-phase timing. Inter-phase pauses are scripted.",
                  "live": "Scripted input on the child PTY; actual zsh, system clear, window, and renderer."}
        for name in ["terminal", "ghostty"]:
            if name == "terminal":
                app = terminal
                details = provenance(app, 'identifier "com.apple.Terminal" and anchor apple')
            else:
                app, source = ghostty(work)
                requirement = (f'identifier "com.mitchellh.ghostty" and anchor apple generic '
                               f'and certificate leaf[subject.OU] = "{GHOSTTY_TEAM}"')
                details = dict(provenance(app, requirement), **source)
                if details["version"] != GHOSTTY_VERSION:
                    raise ValueError("unexpected Ghostty bundle version")
            report["apps"][name] = details
            (out / "reference.json").write_text(json.dumps(report, indent=2))
            for mode in ["recorded-oshen", "live-zsh"]:
                capture(app, mode, out / f"{name}-{mode}", work, recorder, fixture)


if __name__ == "__main__":
    main()
