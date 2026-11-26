"""Record a focused shell clearing a full transcript in the packaged Mac or iPhone app."""
import argparse
import base64
import contextlib
import json
import os
from pathlib import Path
import runpy
import shutil
import signal
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parents[2]
scripts = root / "scripts"
capture = runpy.run_path(str(scripts / "capture-simulator.py"))
panes = runpy.run_path(str(scripts / "check-pane-workflows.py"))
here = Path(__file__).resolve().parent
app_id = "app.thrush.demo"


def until(what, predicate, deadline=100):
    end = time.monotonic() + deadline
    while time.monotonic() < end:
        value = predicate()
        if value:
            return value
        time.sleep(.05)
    raise RuntimeError("Timed out waiting for " + what)


@contextlib.contextmanager
def record_mac(out, pid, window_id, binary):
    movie, ready, stop = out / "clear.mov", out / "recording-start", out / "recording-stop"
    with panes["running"]([binary, str(pid), movie, ready, stop, str(window_id)], out / "recorder.log") as recording:
        def started():
            if recording.poll() is not None:
                raise RuntimeError("Window recorder exited: " + (out / "recorder.log").read_text())
            return ready.exists()
        until("the first window frame", started)
        try:
            yield
        finally:
            stop.touch()
            if recording.wait(25) != 0 or not movie.is_file():
                raise RuntimeError("The Mac window movie could not be finalized")


def inspect_return(frames, wire, fixture):
    # The command moves to the penultimate row on CRLF. Starting any later would
    # hide a frame which presented just the editor's first Return message.
    typed = next((i for i, f in enumerate(frames) if f["history"] > 20 and
                  f["text"][-2:] == ["128", "~ # clear"]), None)
    if typed is None:
        raise RuntimeError("The complete typed clear was never submitted on the bottom row")
    before = frames[typed]
    returned = [m for m in wire if m["section"] == "returned"][:3]
    reads = fixture["returned"][:3]
    if len(returned) != 3 or [bytes.fromhex(m["hex"]) for m in returned] != [base64.b64decode(r["base64"]) for r in reads]:
        raise RuntimeError("Missing distinct Return messages for the bare prompt, command text and CRLF")
    prefixes = [{"frame": n, "generation": f["generation"], "bottom": f["text"][-1]}
                for n, f in enumerate(frames[typed + 1:], typed + 1)
                if f["history"] == before["history"] and f["generation"] > before["generation"]
                and f["text"][:-1] == before["text"][:-1]]
    return typed, {
        "sourceOffsetsUs": [round(1000 * (r["elapsedMs"] - reads[0]["elapsedMs"])) for r in reads],
        "peerSendOffsetsUs": [round(1000 * (m["timeMs"] - returned[0]["timeMs"])) for m in returned],
        "partialSubmissions": prefixes,
    }


def one(platform, mode, out, device, docs, bundle, binary):
    out.mkdir()
    driver = Path(tempfile.mkdtemp(prefix="clear-", dir=docs)) if device else out
    pid = None
    peer_args = ["bun", here / "clear-peer.ts", here / "clear-oshen.json", out, mode]
    if not device:
        peer_args.append("--after-camera")
    try:
        with panes["running"](peer_args, out / "peer.log") as peer:
            def endpoint():
                panes["check_alive"](peer, "peer", out / "peer.log")
                line = (out / "peer.log").read_text().strip()
                return line if line.startswith("http://127.0.0.1:") else None
            url = until("the clear peer", endpoint)
            args = ["--endpoint", url, "--scene", "prompt", "--clear-capture", str(driver), "--appearance", "dark"]
            if device:
                launch = ["xcrun", "simctl", "launch", "--console", "--terminate-running-process", device, app_id, *args, "--keyboard"]
            else:
                launch = ["open", "-n", "-W", "-F", "-a", bundle, "--stdout", out / "host.stdout.log",
                          "--stderr", out / "host.stderr.log", "--args", "-NSAppSleepDisabled", "YES", *args]
            with panes["running"](launch, out / "app.log") as app:
                def received(path):
                    for name in [driver / "error.txt", out / "peer-error.txt"]:
                        if name.exists():
                            raise RuntimeError(name.read_text())
                    panes["check_alive"](app, "demo", out / "app.log")
                    return path.exists()
                until("native window and socket", lambda: received(driver / "ready") and received(out / "attached"))
                if device:
                    recorder = capture["record_simulator"](device, out, "clear")
                else:
                    window = json.loads((driver / "ready").read_text())
                    pid = window["pid"]
                    subprocess.run(["open", "-a", bundle], check=True)
                    recorder = record_mac(out, pid, window["windowID"], binary)
                # The seed includes 128 numbered lines. Let the software keyboard and
                # its resulting PTY resize settle before recording its unchanged geometry.
                time.sleep(1)
                with recorder:
                    until("numbered terminal history", lambda: received(out / "seeded"))
                    time.sleep(.7)
                    (driver / "type").touch()
                    until("the recording's typed clear", lambda: received(out / "echoed"))
                    time.sleep(.8)
                    (driver / "return").touch()
                    until("every recorded PTY read", lambda: received(out / "wire.json"))
                    time.sleep(1)
                    (driver / "finish").touch()
                    until("the submitted frame report", lambda: received(driver / "frames.json"))
    finally:
        if pid:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        if device and driver.is_dir():
            shutil.copytree(driver, out, dirs_exist_ok=True)
            shutil.rmtree(driver)
    frames = json.loads((out / "frames.json").read_text())
    typed, burst = inspect_return(frames, json.loads((out / "wire.json").read_text()),
                                  json.loads((here / "clear-oshen.json").read_text()))
    final = frames[-1]
    if final["history"] != 0 or final["offset"] or final["text"][0].strip() != "~ #" or any(s.strip() for s in final["text"][1:]):
        raise RuntimeError("Did not observe the typed clear and the final row-zero prompt")
    if device and not (final["keyboardHeight"] > 90 and "scrollHeight" in final):
        raise RuntimeError("Keyboard or transcript geometry missing")
    if not device:
        captured = json.loads((out / "clear.frames.json").read_text())
        width, height = final["window"]
        scale = round(captured["width"] / width)
        if scale < 1 or abs(captured["width"] - scale * width) > 2 or abs(captured["height"] - scale * height) > 2:
            raise RuntimeError(f"Captured {captured['width']}×{captured['height']} pixels for a {width}×{height} point window")
    before = frames[typed]
    stable = frames[typed:]
    summary = {"frames": len(frames), "returnBurst": burst, "historyBefore": before["history"], "historyAfter": final["history"],
               "gridBefore": before["grid"], "gridAfter": final["grid"],
               "keyboardBefore": before.get("keyboardHeight"), "keyboardAfter": final.get("keyboardHeight"),
               "scrollBefore": before.get("scrollHeight"), "scrollAfter": final.get("scrollHeight"),
               "blankSubmissions": sum(not any(s.strip() for s in f["text"]) for f in stable),
               "offsets": sorted(set(f["offset"] for f in stable)),
               "grids": len(set(tuple(f["grid"]) for f in stable))}
    (out / "summary.json").write_text(json.dumps(summary, indent=2))
    print(platform, mode, summary, flush=True)
    if burst["partialSubmissions"]:
        raise RuntimeError("A frame presented a partial Return burst before the command and CRLF were complete")
    if summary["offsets"] != [0] or summary["grids"] != 1:
        raise RuntimeError("The visible grid moved while the shell cleared its history")
    if device:
        row_height = (before["scrollHeight"] - before["viewportHeight"]) / before["history"]
        for f in stable:
            if (abs(f["scrollHeight"] - (f["viewportHeight"] + f["history"] * row_height)) > 1 or
                    abs(f["scrollY"] - (f["history"] - f["offset"]) * row_height) > 1):
                raise RuntimeError("The transcript extent and visible terminal history disagree")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("platform", choices=["mac", "simulator"])
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    os.chdir(root)
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    with (out / "build.log").open("w") as log:
        subprocess.run([scripts / "build-demo.sh", args.platform], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=900)
    bundle = root / ".build/demo" / args.platform / "Thrush.app"
    binary = out / "record-window"
    if args.platform == "mac":
        subprocess.run(["xcrun", "swiftc", here / "record-window.swift", "-o", binary], check=True)
    reservation = capture["disposable_phone"](out) if args.platform == "simulator" else contextlib.nullcontext(None)
    with reservation as device:
        docs = capture["prepare_workflow_phone"](device, bundle, out) if device else None
        for mode in ["recorded", "split"]:
            one(args.platform, mode, out / mode, device, docs, bundle, binary)


if __name__ == "__main__":
    main()
