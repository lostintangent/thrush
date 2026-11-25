#!/usr/bin/env python3
"""Run the normal packaged Mac terminal on an interactive desktop, with a second app covering its window."""
import argparse
import contextlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]


@contextlib.contextmanager
def real_shell(out):
    with (out / "peer.log").open("w") as log, subprocess.Popen(
        ["bun", "scripts/pty/cover-peer.ts"], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT
    ) as peer:
        try:
            for _ in range(200):
                match = re.search(r"^http://127\.0\.0\.1:\d+$", (out / "peer.log").read_text(), re.M)
                if match:
                    yield match[0]
                    return
                if peer.poll() is not None:
                    break
                time.sleep(0.05)
            raise RuntimeError("The isolated shell peer did not start.")
        finally:
            peer.terminate()
            try:
                peer.wait(5)
            except subprocess.TimeoutExpired:
                peer.kill()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / ".build/demo/mac/Thrush.app")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--endpoint", help="Optional isolated Toy Box terminal endpoint. The check runs a shell loop and closes it.")
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if any(out.iterdir()):
        parser.error("The output directory must be empty.")
    app = args.app.resolve()
    if not app.is_dir():
        subprocess.run(["scripts/build-demo.sh", "mac"], cwd=ROOT, check=True)
    with (app / "Contents/Info.plist").open("rb") as f:
        info = plistlib.load(f)
    (out / "source.json").write_text(json.dumps({"commit": info["ThrushGitCommit"], "dirty": info["ThrushWorktreeDirty"]}) + "\n")
    with tempfile.TemporaryDirectory() as scratch:
        cover = Path(scratch) / "Thrush Cover.app"
        contents = cover / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        with (contents / "Info.plist").open("wb") as f:
            plistlib.dump(dict(CFBundleIdentifier="app.thrush.lifecycle-cover", CFBundleName="Thrush Cover",
                               CFBundleExecutable="Cover", CFBundlePackageType="APPL"), f)
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", ROOT / "scripts/pty/cover-window.swift",
                        "-o", contents / "MacOS/Cover"], check=True)
        subprocess.run(["codesign", "--force", "--sign", "-", cover], check=True)
        peer = contextlib.nullcontext(args.endpoint) if args.endpoint else real_shell(out)
        report = out / "window-lifecycle.json"
        with peer as endpoint, (out / "host.log").open("w") as log:
            subprocess.run([app / "Contents/MacOS/ThrushDemo", "--endpoint", endpoint, "--appearance", "dark",
                            "--window-lifecycle-check", report, cover], stdout=log, stderr=subprocess.STDOUT,
                           check=True, timeout=195)
        result = json.loads(report.read_text())
        rows = result["intervals"]
        if ({r["phase"] for r in rows} != {"covered", "minimized", "hidden"} or
                any(r["durationSeconds"] < 31 or r["hiddenSubmissions"] for r in rows) or
                len({r["shellPID"] for r in rows}) != 1 or result["socketAttempts"] != 1 or result["readyEvents"] != 1):
            raise RuntimeError("Window lifecycle measurements failed.")
        if not args.endpoint:
            shell = re.search(r"^PTY shell PID (\d+)$", (out / "peer.log").read_text(), re.M)
            if not shell or int(shell[1]) != rows[0]["shellPID"]:
                raise RuntimeError("The terminal PID did not match the independent PTY process.")
        print(json.dumps(result, indent=2))


if __name__ == "__main__":
    os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    main()
