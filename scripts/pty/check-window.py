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
sys.path.insert(0, str(ROOT / "Tests/ThrushWebSocketCheck/pty"))


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


def sample_server(pids, host, root, out):
    from check import wait_for

    def ticking():
        pid = pids.read_text().strip() if pids.exists() else ""
        return pid.isdecimal() and subprocess.run(
            ["/usr/bin/pgrep", "-P", pid, "-x", "sleep"], stdout=subprocess.DEVNULL).returncode == 0

    wait_for("the PTY shell's live tick loop", ticking, host)
    # Only the listener is our direct child. Each shell has a separate supervisor.
    pid = int(subprocess.check_output(["/usr/bin/pgrep", "-P", str(os.getpid()), "-x", "ThrushServer"]))
    sample = root / "server-sample.txt"
    subprocess.run(["/usr/bin/sample", str(pid), "5", "1", "-file", sample], check=True, timeout=25)
    _, marker, stacks = sample.read_text().partition("Call graph:")
    stacks = stacks.partition("Binary Images:")[0].strip()
    if not marker or not stacks:
        raise RuntimeError("System sample contained no server call graph.")
    (out / "server-sample.txt").write_text(
        f"ThrushServer PID {pid}, 5 seconds at 1 ms during live shell ticks.\nCall graph:\n{stacks}\n")


def main():
    sys.dont_write_bytecode = True
    from check import server

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--sample-server", action="store_true", help="Save a system stack sample while the local ThrushServer carries the shell’s live ticks.")
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if any(out.iterdir()):
        parser.error("The output directory must be empty.")
    app = ROOT / ".build/proofs/mac/Thrush.app"
    if not app.is_dir():
        subprocess.run(["scripts/build-app.sh", "proofs", "mac"], cwd=ROOT, check=True)
    with (app / "Contents/Info.plist").open("rb") as f:
        info = plistlib.load(f)
    (out / "source.json").write_text(json.dumps({"commit": info["ThrushGitCommit"], "dirty": info["ThrushWorktreeDirty"]}) + "\n")
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
        with server(root, shell, out / "server.log", server_binary) as endpoint:
            shutil.copyfile(root / "data" / "source.json", out / "server.json")
            launch = ["/usr/bin/open", "-W", "-n", "-a", app, "--stdout", out / "host.stdout.log",
                      "--stderr", out / "host.log", "--args", "--endpoint", endpoint, "--appearance", "dark",
                      "--window-lifecycle-check", report, cover]
            with subprocess.Popen(launch) as host:
                try:
                    if args.sample_server:
                        sample_server(pids, host, root, out)
                finally:
                    try:
                        status = host.wait(timeout=195)
                    except subprocess.TimeoutExpired:
                        host.kill()
                        raise
                if status:
                    raise subprocess.CalledProcessError(status, launch)
        if not report.exists():
            raise RuntimeError("The native window check did not finish. " + (out / "host.log").read_text()[-1200:])
        result = json.loads(report.read_text())
        rows = result["intervals"]
        if ({r["phase"] for r in rows} != {"covered", "minimized", "hidden"} or
                any(r["durationSeconds"] < 31 or r["hiddenSubmissions"] for r in rows) or
                len({r["shellPID"] for r in rows}) != 1 or result["socketAttempts"] != 1 or result["readyEvents"] != 1):
            raise RuntimeError("Window lifecycle measurements failed.")
        if pids.read_text().splitlines() != [str(rows[0]["shellPID"])]:
            raise RuntimeError("The terminal PID did not match the independent PTY process.")
        print(json.dumps(result, indent=2))


if __name__ == "__main__":
    os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    main()
