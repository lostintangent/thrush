"""Implementation of check-pane-workflows.sh. Paths are relative to the package root."""
import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import re
import runpy
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time

WORKFLOWS = {"shell": "shell-workflow", "vim": "vim-resume", "codex": "codex-session"}
CAPTURES = {
    "shell": {"Pasted build command", "Copy soft-wrapped compiler path"},
    "vim": {"Edited scratch file", "Vim before detach", "Vim serialized replay", "Returned to shell"},
    "codex": {"Codex ready", "First three songbirds streamed", "Received Codex answer", "Earlier transcript page", "Returned to shell"},
}
BUNDLE_ID = "app.thrush.demo"
XTERM = {"@xterm/headless": "6.0.0", "@xterm/addon-unicode11": "0.9.0"}


def arguments():
    parser = argparse.ArgumentParser(prog="scripts/check-pane-workflows.sh")
    modes = parser.add_subparsers(dest="platform", required=True)
    for platform in ("mac", "simulator"):
        mode = modes.add_parser(platform)
        if platform == "simulator":
            mode.add_argument("udid", help="a booted iPhone UDID, or new to create a disposable iPhone 17")
        mode.add_argument("output", type=Path, help="fresh evidence directory for this platform")
        mode.add_argument("workflows", nargs="*", metavar="WORKFLOW", help="shell, vim, codex (default: all)")
    args = parser.parse_args()
    args.workflows = args.workflows or list(WORKFLOWS)
    if set(args.workflows) - WORKFLOWS.keys() or len(set(args.workflows)) != len(args.workflows):
        parser.error("choose each of shell, vim and codex at most once")
    return args


def reference_modules(temp, output):
    supplied = os.environ.get("THRUSH_XTERM_MODULES")
    if supplied:
        modules = Path(supplied).resolve()
    else:
        project = Path(temp)
        (project / "package.json").write_text(json.dumps({"private": True, "dependencies": XTERM}))
        with (output / "xterm-install.log").open("xb") as log:
            subprocess.run(["bun", "install", "--ignore-scripts"], cwd=project, check=True,
                           stdout=log, stderr=subprocess.STDOUT, timeout=120)
        modules = project / "node_modules"
    for name, version in XTERM.items():
        manifest = json.loads((modules / name / "package.json").read_bytes())
        if manifest["version"] != version:
            raise ValueError(f"{name} version {manifest['version']} in {modules}; expected {version}")
    return str(modules)


def simctl(*args, timeout=60):
    return subprocess.check_output(["xcrun", "simctl", *args], text=True, timeout=timeout).strip()


@contextlib.contextmanager
def reserve_phone(udid):
    devices = json.loads(simctl("list", "devices", "booted", "-j"))["devices"]
    matches = [d for group in devices.values() for d in group
               if d["udid"].lower() == udid.lower() and d["state"] == "Booted" and d["isAvailable"]
               and d["deviceTypeIdentifier"] == "com.apple.CoreSimulator.SimDeviceType.iPhone-17"]
    if not matches:
        raise ValueError("pass the exact UDID of an available, already booted iPhone 17 Simulator")
    device = matches[0]["udid"]
    # flock releases on exit, including crashes. Other worktrees must see the same lock.
    path = Path("/tmp") / f"thrush-pane-workflows-{os.getuid()}-{device}.lock"
    with path.open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError(f"another pane workflow run is using {device}") from None
        yield device


def ensure_demo_idle(device):
    jobs = simctl("spawn", device, "launchctl", "list").splitlines()
    for job in jobs:
        fields = job.split(None, 2)
        if len(fields) == 3 and fields[0].isdigit() and fields[2].startswith(f"UIKitApplication:{BUNDLE_ID}["):
            raise RuntimeError(f"{BUNDLE_ID} already running on {device} (PID {fields[0]})")


@contextlib.contextmanager
def running(command, log, **kwargs):
    with log.open("xb") as stream:
        process = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT, **kwargs)
        try:
            yield process
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def check_alive(process, label, log):
    status = process.poll()
    if status is not None:
        raise RuntimeError(f"{label} exited with status {status}; see {log}")


def peer_origins(peer, log):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        lines = log.read_text(errors="replace").splitlines()
        origins = {}
        for line in lines:
            match = re.fullmatch(r"Thrush (demo peer|workflow driver) listening at (http://127\.0\.0\.1:[0-9]+)/?", line)
            if match:
                origins[match[1]] = match[2]
        if len(origins) == 2:
            if origins["demo peer"] == origins["workflow driver"]:
                raise RuntimeError("peer assigned the same port to the socket and workflow driver")
            return origins["demo peer"], origins["workflow driver"]
        check_alive(peer, "peer", log)
        time.sleep(0.1)
    raise RuntimeError(f"peer did not publish its socket and driver origins; see {log}")


def collect_capture(marker, output, platform, target):
    request = json.loads(marker.read_bytes())
    index = request["eventIndex"]
    if (type(index) is not int or index < 0 or marker.stem != f"capture-{index:03d}"
            or not isinstance(request["name"], str) or not request["name"].strip()):
        raise ValueError(f"invalid screenshot request in {marker}")
    name = re.sub(r"[^a-z0-9]+", "-", request["name"].lower()).strip("-")[:80]
    image = output / f"{marker.stem}-{name}.png"
    raw = output / (marker.stem + "-framebuffer.png")
    deadline = time.monotonic() + 160
    error = "No native image received"
    with (output / "capture.log").open("ab") as log:
        while time.monotonic() < deadline:
            remaining = deadline - time.monotonic()
            try:
                subprocess.run(["scripts/capture-demo.sh", platform, target, str(raw)], check=True,
                               stdout=log, stderr=subprocess.STDOUT, timeout=min(75, remaining))
                with raw.open("rb") as stream:
                    header = stream.read(24)
                if header[:8] != b"\x89PNG\r\n\x1a\n":
                    raise ValueError("Native capture did not produce a PNG")
                width, height = struct.unpack(">II", header[16:24])
                if platform == "simulator" and request["windowSize"][0] > request["windowSize"][1] and width < height:
                    subprocess.run(["/usr/bin/sips", "-r", "90", str(raw), "--out", str(image)], check=True,
                                   stdout=log, stderr=subprocess.STDOUT, timeout=10)
                else:
                    raw.replace(image)
                subprocess.run([sys.executable, "scripts/check-workflow-capture.py", str(image), str(marker)],
                               check=True, stdout=log, stderr=subprocess.STDOUT, timeout=15)
                break
            except (OSError, ValueError, subprocess.SubprocessError) as exc:
                error = str(exc)
                log.write((error + "\n").encode())
                log.flush()
                time.sleep(0.25)
        else:
            raise RuntimeError(f"no matching native framebuffer for {request['name']}: {error}")
    marker.with_suffix(".done").touch()
    print(f"  {image.name}", flush=True)


def await_report(name, app, peer, driver, output, platform, target, *, verify_fixture=True):
    completed_captures = set()
    deadline = time.monotonic() + 90
    trace_size = -1
    while True:
        trace = driver / "workflow-events.log"
        if trace.exists() and (size := trace.stat().st_size) != trace_size:
            trace_size = size
            deadline = time.monotonic() + 90
        failure = driver / "workflow-error.txt"
        if failure.exists():
            raise RuntimeError(failure.read_text(errors="replace").strip() or str(failure))
        for marker in sorted(driver.glob("capture-*.json")):
            if marker not in completed_captures:
                collect_capture(marker, output, platform, target)
                completed_captures.add(marker)
                deadline = time.monotonic() + 90
        report = driver / "workflow-report.json"
        if report.exists():
            result = json.loads(report.read_bytes())
            if (result.get("completed") is not True or result.get("workflow") not in (name, WORKFLOWS.get(name))
                    or not isinstance(result.get("checkpoints"), list) or not result["checkpoints"]
                    or not completed_captures):
                raise RuntimeError(f"incomplete {name} checkpoint or capture evidence in {report}")
            images = {json.loads(marker.read_bytes())["name"] for marker in completed_captures}
            if verify_fixture and images != CAPTURES[name]:
                raise ValueError(f"{name} images differ: got {sorted(images)}, expected {sorted(CAPTURES[name])}")
            if verify_fixture and platform == "simulator":
                fixture_root = Path("Fixtures/replays") if name == "shell" else Path("Fixtures/reference/m4/phone")
                fixture = json.loads((fixture_root / (WORKFLOWS[name] + ".json")).read_bytes())
                expected = {}
                grid = (47, 25)
                for index, event in enumerate(fixture["events"]):
                    if "resize" in event:
                        change = event["resize"]
                        grid = (change["columns"], change["rows"])
                    if event.get("checkpoint"):
                        expected[index] = grid
                measured = {step["eventIndex"]: (step["columns"], step["rows"]) for step in result["checkpoints"]}
                if measured != expected:
                    raise ValueError(f"{name} iPhone 17 keyboard geometry differs: got {measured}, expected {expected}")
            return
        check_alive(app, "packaged app", output / "app.log")
        check_alive(peer, "peer", output / "peer.log")
        if time.monotonic() >= deadline:
            raise RuntimeError(f"no {name} phase, capture or final report within 90 seconds; see {output}")
        time.sleep(0.1)


def run_workflow(name, output, platform, device, documents, app_bundle, modules, *, disposable=False):
    output.mkdir()
    driver = Path(tempfile.mkdtemp(prefix=f"thrush-{name}-", dir=documents)) if device else output
    try:
        peer_log = output / "peer.log"
        command = ["bun", "scripts/demo-peer.ts", "--workflow", name, "--view", "--driver"]
        environment = {**os.environ, "THRUSH_PORT": "0", "THRUSH_DRIVER_PORT": "0", "THRUSH_XTERM_MODULES": modules}
        environment["THRUSH_WORKFLOW_GEOMETRY"] = "iphone" if device else "mac"
        with running(command, peer_log, env=environment) as peer:
            endpoint, control = peer_origins(peer, peer_log)
            options = ["--endpoint", endpoint, "--workflow-driver", control,
                       "--workflow-output", str(driver), "--keyboard" if device else "--hide-keyboard"]
            if device:
                launch = ["xcrun", "simctl", "launch", "--console"]
                if disposable:
                    # Every launch on this phone belongs to this run, including the previous workflow.
                    launch.append("--terminate-running-process")
                else:
                    ensure_demo_idle(device)
                launch.extend([device, BUNDLE_ID])
            else:
                # An obscured capture window still needs its foreground input and network turns.
                launch = [app_bundle / "Contents/MacOS/ThrushDemo", "-NSAppSleepDisabled", "YES"]
            with running([*launch, *options], output / "app.log") as host:
                await_report(name, host, peer, driver, output, platform, device or str(host.pid))
    finally:
        if device:
            # Keep failures, partial events and the exact handshakes with the screenshots.
            shutil.copytree(driver, output, dirs_exist_ok=True)
            shutil.rmtree(driver)


def main():
    args = arguments()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise ValueError(f"use an empty output directory to preserve existing evidence: {output}")
    reservation = contextlib.nullcontext(None)
    disposable = args.platform == "simulator" and args.udid == "new"
    if args.platform == "simulator":
        if disposable:
            capture = runpy.run_path("scripts/capture-simulator.py")
            reservation = capture["disposable_phone"](output)
        else:
            reservation = reserve_phone(args.udid)
    with tempfile.TemporaryDirectory(prefix="thrush-workflow-reference-") as temp:
        modules = reference_modules(temp, output)
        print(f"Building packaged {args.platform} host; see {output / 'build.log'}", flush=True)
        with (output / "build.log").open("xb") as log:
            subprocess.run(["scripts/build-demo.sh", args.platform], check=True, stdout=log,
                           stderr=subprocess.STDOUT, timeout=900)
        app = Path(".build/demo", args.platform, "Thrush.app").resolve()
        with reservation as device:
            documents = None
            if device:
                if not disposable:
                    ensure_demo_idle(device)
                try:
                    simctl("install", device, str(app), timeout=180)
                except subprocess.TimeoutExpired:
                    # CoreSimulator sometimes completes an install just after the host command times out.
                    try:
                        simctl("get_app_container", device, BUNDLE_ID, "app")
                    except subprocess.SubprocessError:
                        simctl("install", device, str(app), timeout=180)
                documents = Path(simctl("get_app_container", device, BUNDLE_ID, "data")) / "Documents"
                documents.mkdir(exist_ok=True)
            for name in args.workflows:
                print(f"Checking {name} in {output / name}", flush=True)
                try:
                    run_workflow(name, output / name, args.platform, device, documents, app, modules,
                                 disposable=disposable)
                except Exception as error:
                    (output / name / "runner-error.txt").write_text(str(error) + "\n")
                    raise
            print(f"Passed {len(args.workflows)} packaged pane workflow(s). Evidence in {output}", flush=True)


if __name__ == "__main__":
    def terminate(signum, frame):
        raise SystemExit(128 + signum)
    signal.signal(signal.SIGTERM, terminate)
    try:
        main()
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as exc:
        sys.exit(f"Pane workflow check failed: {exc}")
