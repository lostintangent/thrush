#!/usr/bin/env python3
"""Record native typing into oshen on a real PTY through the packaged Mac or iPhone demo.

oshen leaves typed input unechoed until its terminal reports focus, so the echo proves the report.
"""
import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import runpy
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
import run as capture

NAME = "FocusEchoProof"
ROOT = capture.ROOT


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


@contextlib.contextmanager
def oshen_server(out, work, oshen):
    live = runpy.run_path(str(ROOT / "scripts/live-workflow/launch.py"))
    version = subprocess.check_output([oshen, "--version"], text=True, timeout=15).strip()
    shell = work / "oshen-at-home"
    shell.write_text("#!/bin/sh\ncd \"$HOME\" && exec " + shlex.quote(str(oshen)) + "\n")
    shell.chmod(0o700)
    server = live["build_server"](out)
    log = out / "pty-server.log"
    with live["service"]([server, "--port", "0", "--data-dir", work / "pty", "--shell", shell], log, os.environ) as process:
        listening = live["wait_for"](process, log, lambda: re.search(
            r"Listening on: (http://127\.0\.0\.1:\d+)/?", log.read_text(errors="replace")), 30)
        (out / "server.json").write_text(json.dumps(dict(
            oshen=version, oshenSHA256=digest(oshen), serverSHA256=digest(server)), indent=2) + "\n")
        yield listening[1]


def runner(work, out, mac, endpoint):
    plan = capture.build_test_runner(work, out, capture.HERE / (NAME + ".swift"), mac=mac, name=NAME)
    settings = plistlib.loads(plan.read_bytes())
    settings[NAME]["EnvironmentVariables"]["THRUSH_CAPTURE_ENDPOINT"] = endpoint
    plan.write_bytes(plistlib.dumps(settings))
    return plan


def run_proof(plan, destination, result, out, platform):
    interval = None
    try:
        capture.run_logged(["xcodebuild", "test-without-building", "-xctestrun", plan, "-destination", destination,
                            "-parallel-testing-enabled", "NO", "-resultBundlePath", result],
                           out / f"{platform}-ui.log", 420)
    finally:
        # XCTest keeps the stills taken before a failed step.
        if result.exists():
            interval = export(result, out, platform)
    return interval


def export(result, out, platform):
    exported = result.with_suffix(".attachments")
    capture.run_logged(["xcrun", "xcresulttool", "export", "attachments", "--path", result,
                        "--output-path", exported], out / f"{platform}-attachments.log", 90)
    interval = None
    for test in json.loads((exported / "manifest.json").read_text()):
        for attachment in test["attachments"]:
            match = re.search(r"thrush-proof__focus-echo-([a-z]+)__", attachment["suggestedHumanReadableName"])
            if not match:
                continue
            source = exported / Path(attachment["exportedFileName"]).name
            if match[1] == "interval":
                interval = json.loads(source.read_text())
            else:
                shutil.copyfile(source, out / f"focus-echo-{platform}-{match[1]}.png")
    return interval


def trim(movie, interval, started, work, lead):
    if not interval or len(interval) != 2 or not 0 < interval[1] - interval[0] <= 60:
        raise RuntimeError(f"The proof did not report its typing interval for {movie.name}.")
    start = max(0, interval[0] - started - lead)
    capture.run_logged(["/usr/bin/avconvert", "--source", movie, "--output", movie.with_suffix(".mp4"),
                        "--preset", "PresetHighestQuality", "--start", f"{start:.3f}",
                        "--duration", f"{interval[1] - interval[0] + lead + 0.6:.3f}"], work / (movie.stem + "-trim.log"), 180)
    movie.unlink()


def iphone(out, work, endpoint):
    simulator = capture.load_helper("capture-simulator")
    plan = runner(work, out, False, endpoint)
    with simulator.disposable_phone(out) as device:
        phone = simulator.Phone(device, endpoint, ROOT / ".build/demo/simulator/Thrush.app", out, work)
        phone.warm_keyboard("dark")
        with phone.record_switch("focus-echo-iphone"):
            started = time.time()
            interval = run_proof(plan, f"platform=iOS Simulator,id={device}", work / "iphone.xcresult", out, "iphone")
        (out / "focus-echo-iphone-state.json").write_text(json.dumps(phone.state(), indent=2) + "\n")
    trim(out / "focus-echo-iphone.mov", interval, started, work, 1.2)


def mac(out, work, endpoint):
    plan = runner(work, out, True, endpoint)
    recorder = work / "record-window"
    capture.run_logged(["xcrun", "swiftc", "-O", capture.HERE / "record-window.swift", "-o", recorder],
                       out / "recorder-build.log", 300)
    bundle = ROOT / ".build/demo/mac/Thrush.app"
    executable = bundle / "Contents/MacOS" / plistlib.loads((bundle / "Contents/Info.plist").read_bytes())["CFBundleExecutable"]
    movie, ready, stop = out / "focus-echo-mac.mov", work / "recording-ready", work / "recording-stop"
    with (out / "mac-app.log").open("w") as app_log, subprocess.Popen(
        [executable, "-NSAppSleepDisabled", "YES", "--endpoint", endpoint, "--scene", "shell", "--appearance", "dark"],
        stdout=app_log, stderr=subprocess.STDOUT
    ) as app, (out / "recorder.log").open("w") as recorder_log, subprocess.Popen(
        [recorder, str(app.pid), movie, ready, stop], stdout=recorder_log, stderr=subprocess.STDOUT
    ) as recording:
        try:
            deadline = time.monotonic() + 60
            while not ready.exists():
                if recording.poll() is not None or app.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("The Mac window recorder did not start. See recorder.log and mac-app.log.")
                time.sleep(0.05)
            started = time.time()
            try:
                interval = run_proof(plan, "platform=macOS", work / "mac.xcresult", out, "mac")
            finally:
                stop.touch()
                if recording.wait(120) != 0 or not movie.is_file():
                    raise RuntimeError("The Mac window movie could not be finalized. See recorder.log.")
        finally:
            for process in (recording, app):
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(10)
                    except subprocess.TimeoutExpired:
                        process.kill()
    trim(movie, interval, started, work, 2.5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--oshen", type=Path, required=True, help="The oshen executable to run on each PTY.")
    parser.add_argument("--platform", action="append", choices=("mac", "iphone"), help="Defaults to both.")
    parser.add_argument("--output", type=Path, required=True, help="A new or empty directory for movies, stills and logs.")
    args = parser.parse_args()
    os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if any(out.iterdir()):
        parser.error("Use an empty output directory.")
    platforms = args.platform or ["mac", "iphone"]
    failures = {}
    for platform in platforms:
        capture.run_logged(["scripts/build-demo.sh", "simulator" if platform == "iphone" else "mac"],
                           out / f"{platform}-app-build.log", 600)
    with tempfile.TemporaryDirectory(prefix="thrush-focus-echo-") as scratch:
        # oshen abbreviates the home directory only when it matches the resolved working directory.
        work = Path(scratch).resolve()
        with oshen_server(out, work, args.oshen.resolve()) as endpoint:
            for platform in platforms:
                print(f"Recording oshen in the packaged {platform} demo", flush=True)
                directory = work / platform
                directory.mkdir()
                try:
                    (mac if platform == "mac" else iphone)(out, directory, endpoint)
                except Exception as error:
                    failures[platform] = str(error)
                    print(f"{platform} failed: {error}", file=sys.stderr, flush=True)
    (out / "checks.json").write_text(json.dumps({"failures": failures}, indent=2) + "\n")
    if failures:
        raise SystemExit("Failed: " + ", ".join(failures))
    print("oshen echoed native typing in " + " and ".join(platforms) + ".")


if __name__ == "__main__":
    main()
