#!/usr/bin/env python3
"""Run the normal packaged Mac terminal on an interactive desktop, with a second app covering its window."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import tempfile
import sys

ROOT = Path(__file__).resolve().parents[2]


def build_cover(scratch):
    cover = scratch / "Thrush Cover.app"
    contents = cover / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    with (contents / "Info.plist").open("wb") as f:
        plistlib.dump(dict(CFBundleIdentifier="app.thrush.lifecycle-cover", CFBundleName="Thrush Cover",
                           CFBundleExecutable="Cover", CFBundlePackageType="APPL"), f)
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", ROOT / "scripts/pty/cover-window.swift",
                    "-o", contents / "MacOS/Cover"], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", cover], check=True)
    return cover


def main():
    sys.dont_write_bytecode = True
    from check import local_endpoint, server

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / ".build/demo/mac/Thrush.app")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--endpoint", type=local_endpoint, help="Optional disposable loopback terminal. The check runs a shell loop and closes it.")
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
    server_binary = None
    if not args.endpoint:
        build = ["swift", "build", "--package-path", ROOT, "-c", "release"]
        subprocess.run([*build, "--product", "ThrushServer"], check=True)
        server_binary = Path(subprocess.check_output([*build, "--show-bin-path"], text=True).strip()) / "ThrushServer"
    with tempfile.TemporaryDirectory() as scratch:
        root = Path(scratch)
        cover = build_cover(root)
        pids = out / "shell-pids.txt"
        shell = root / "shell"
        shell.write_text(f'#!/bin/sh\nprintf "%s\\n" "$$" >> {shlex.quote(str(pids))}\nexec /bin/sh -i\n')
        shell.chmod(0o700)
        report = out / "window-lifecycle.json"
        with server(root, shell, out / "server.log", server_binary, args.endpoint) as endpoint:
            shutil.copyfile(root / "data" / "source.json", out / "server.json")
            subprocess.run(["/usr/bin/open", "-W", "-n", "-a", app, "--stdout", out / "host.stdout.log",
                            "--stderr", out / "host.log", "--args", "--endpoint", endpoint, "--appearance", "dark",
                            "--window-lifecycle-check", report, cover], check=True, timeout=195)
        if not report.exists():
            raise RuntimeError("The native window check did not finish. " + (out / "host.log").read_text()[-1200:])
        result = json.loads(report.read_text())
        rows = result["intervals"]
        if ({r["phase"] for r in rows} != {"covered", "minimized", "hidden"} or
                any(r["durationSeconds"] < 31 or r["hiddenSubmissions"] for r in rows) or
                len({r["shellPID"] for r in rows}) != 1 or result["socketAttempts"] != 1 or result["readyEvents"] != 1):
            raise RuntimeError("Window lifecycle measurements failed.")
        if not args.endpoint:
            if pids.read_text().splitlines() != [str(rows[0]["shellPID"])]:
                raise RuntimeError("The terminal PID did not match the independent PTY process.")
        print(json.dumps(result, indent=2))


if __name__ == "__main__":
    os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    main()
