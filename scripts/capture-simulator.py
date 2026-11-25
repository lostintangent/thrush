#!/usr/bin/env python3
"""Capture a named demo scene, or run the complete iPhone rendering proof on a disposable simulator."""
import argparse
import contextlib
import filecmp
import json
import os
from pathlib import Path
import plistlib
import re
import runpy
import signal
import struct
import subprocess
import sys
import tempfile
import time
import uuid
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parent.parent
APP_ID = "app.thrush.demo"
ORACLE = ROOT / "scripts/check-demo-capture.py"
PIXEL_CHECKED_SCENES = {"glyphs", "shell", "editor", "prompt"}
NOTICE_SCENES = {
    "notice-connecting": ("Connecting", None, None, None),
    "notice-reconnecting": ("Reconnecting", "Typing waits for this shell to resume.", None, None),
    "notice-replacement": ("Previous shell ended", "New shell ready.", None, None),
    "notice-displaced": ("Open in another window", None, "Use Here", "Use shell in this window"),
    "notice-ended": ("Ended", None, "New Shell", "New Shell"),
}
TERMINAL_SCENES = PIXEL_CHECKED_SCENES | {"log", "vim"}


def run(*command, timeout=90, check=True):
    result = subprocess.run(command, text=True, capture_output=True, timeout=timeout, cwd=ROOT)
    if check and result.returncode:
        raise RuntimeError(f"{Path(command[0]).name} {command[1]} failed ({result.returncode}): "
                           + (result.stdout + result.stderr)[-2000:])
    return result


def sim(*args, **kwargs):
    return run("xcrun", "simctl", *args, **kwargs)


def wait_for(description, condition, timeout):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        value = condition()
        if value:
            return value
        time.sleep(0.25)
    raise TimeoutError(f"Timed out waiting for {description}")


def save_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def runtime():
    runtimes = json.loads(sim("list", "runtimes", "--json").stdout)["runtimes"]
    available = [r for r in runtimes if r["isAvailable"] and r["name"].startswith("iOS 27.")
                 and any(t["name"] == "iPhone 17" for t in r["supportedDeviceTypes"])]
    if not available:
        raise RuntimeError("An installed iOS 27 runtime supporting iPhone 17 is required.")
    return max(available, key=lambda r: tuple(map(int, r["version"].split("."))))


@contextlib.contextmanager
def disposable_phone(out):
    device = None
    try:
        chosen = runtime()
        device_type = next(t["identifier"] for t in chosen["supportedDeviceTypes"] if t["name"] == "iPhone 17")
        name = "Thrush capture " + uuid.uuid4().hex[:8]
        print(f"Creating {name} on {chosen['name']}", flush=True)
        device = str(uuid.UUID(sim("create", name, device_type, chosen["identifier"]).stdout.strip())).upper()
        save_json(out / "device.json", dict(device=device, deviceType=device_type, runtime=chosen["identifier"],
                                            version=chosen["version"], build=chosen.get("buildversion")))
        print(f"Booting {device} and waiting for system services", flush=True)
        with (out / "boot.log").open("w") as log:
            subprocess.run(["xcrun", "simctl", "bootstatus", device, "-b"], stdout=log, stderr=subprocess.STDOUT,
                           timeout=300, check=True)
        print(f"Boot finished for {device}", flush=True)
        yield device
    except BaseException:
        try:
            inventory = sim("list", "devices", "--json", timeout=15, check=False)
            (out / "simulator-inventory.log").write_text(inventory.stdout + inventory.stderr)
        except (OSError, subprocess.SubprocessError) as error:
            (out / "simulator-inventory.log").write_text(str(error) + "\n")
        raise
    finally:
        original_failure = sys.exc_info()[0] is not None
        if device:
            print(f"Cleaning up {device}", flush=True)
            try:
                sim("shutdown", device, timeout=45, check=False)
            except (OSError, subprocess.SubprocessError) as error:
                print(f"Simulator shutdown: {error}", file=sys.stderr, flush=True)
            try:
                sim("delete", device, timeout=45)
            except (OSError, subprocess.SubprocessError, RuntimeError) as error:
                if not original_failure:
                    raise
                print(f"Simulator deletion: {error}", file=sys.stderr, flush=True)


@contextlib.contextmanager
def peer(out, notices=False):
    log = out / "peer.log"
    with log.open("w") as output:
        server = subprocess.Popen(["bun", "scripts/notice-peer.ts" if notices else "scripts/demo-peer.ts"], stdout=output, stderr=subprocess.STDOUT,
                                  cwd=ROOT, env=dict(os.environ, THRUSH_HOST="127.0.0.1", THRUSH_PORT="0"))
        try:
            def endpoint():
                if server.poll() is not None:
                    raise RuntimeError("Demo peer exited: " + log.read_text())
                match = re.search(r"^Thrush demo peer listening at (http://127\.0\.0\.1:\d+)$", log.read_text(), re.M)
                return match.group(1) if match else None
            address = wait_for("the loopback peer", endpoint, 90)
            print(f"Loopback peer ready at {address}", flush=True)
            yield address
        finally:
            server.terminate()
            try:
                server.wait(10)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()


class Phone:
    def __init__(self, device, endpoint, app, out, scratch):
        self.device, self.endpoint, self.app, self.out, self.scratch = device, endpoint, app, out, scratch
        for attempt in (1, 2):
            print(f"Installing on {device} (attempt {attempt})", flush=True)
            try:
                sim("install", device, str(app), timeout=180)
                break
            except subprocess.TimeoutExpired:
                # The host client may time out while MobileInstallation finishes its work.
                if self.has_matching_installation():
                    print("Verified the installed bundle after the client timed out", flush=True)
                    break
                if attempt == 2:
                    raise
        data = Path(sim("get_app_container", device, APP_ID, "data").stdout.strip())
        self.state_path = data / "Documents/capture-state.json"

    def has_matching_installation(self):
        try:
            result = sim("get_app_container", self.device, APP_ID, "app", timeout=30, check=False)
            if result.returncode:
                return False
            installed = Path(result.stdout.strip())
            expected = plistlib.loads((self.app / "Info.plist").read_bytes())
            actual = plistlib.loads((installed / "Info.plist").read_bytes())
            provenance = ("CFBundleIdentifier", "CFBundleExecutable", "ThrushGitCommit", "ThrushWorktreeDirty", "ThrushToolchain")
            return (all(actual.get(key) == expected[key] for key in provenance)
                    and filecmp.cmp(installed / actual["CFBundleExecutable"],
                                    self.app / expected["CFBundleExecutable"], shallow=False))
        except (OSError, KeyError, ValueError, plistlib.InvalidFileException, subprocess.TimeoutExpired):
            return False

    def launch(self, scene, appearance, orientation, keyboard):
        self.set_appearance(appearance)
        args = ["--endpoint", self.endpoint, "--scene", scene, "--capture-state"]
        if orientation == "landscape":
            args.append("--capture-landscape")
        if keyboard == "hidden":
            args.append("--hide-keyboard")
        elif keyboard == "visible":
            args.append("--keyboard")
        result = sim("launch", "--terminate-running-process", self.device, APP_ID, *args, timeout=100)
        match = re.search(rf"^{re.escape(APP_ID)}: (\d+)$", result.stdout, re.M)
        if not match:
            raise RuntimeError("Missing simulator application PID: " + result.stdout)
        return int(match.group(1))

    def warm_keyboard(self, appearance):
        # A fresh runtime can cover its first keyboard with the system QuickPath
        # introduction. Give that first attachment its own process before recording.
        pid = self.launch("prompt", appearance, "portrait", "visible")
        observed = None
        since = time.monotonic()

        def ready():
            nonlocal observed, since
            state = self.state()
            if (state.get("pid") != pid or state.get("keyboardHeight", 0) <= 90
                    or state.get("accessoryHeight", 0) < 44):
                observed = None
                return False
            geometry = (state["keyboardHeight"], state["accessoryHeight"], state["gridFrame"])
            if observed != geometry:
                observed, since = geometry, time.monotonic()
            return state if time.monotonic() - since >= 0.7 else False

        print("Waiting for the first native keyboard attachment", flush=True)
        state = wait_for("the warm-up keyboard and accessory", ready, 100)
        save_json(self.out / "keyboard-warmup.json", state)
        sim("terminate", self.device, APP_ID, timeout=45)

    def interrupt_after_focus(self, pid, keyboard):
        def ready():
            state = self.state()
            if state.get("pid") != pid or state.get("scene") != "notice-reconnecting" or not state.get("gpuCompleted") or not state.get("generation"):
                return False
            if keyboard == "visible":
                return (state["keyboardHeight"] > 90 and state["accessoryHeight"] >= 44 and
                        (state.get("keyboardLanguage") or "").lower().startswith("en"))
            return state["keyboardHeight"] < 90

        wait_for("the live shell and its requested keyboard", ready, 90)
        with urlopen(Request(self.endpoint + "/interrupt-reconnecting", method="POST"), timeout=10) as response:
            if response.status != 204:
                raise RuntimeError("The notice peer did not interrupt the acknowledged terminal.")

    def set_appearance(self, style):
        sim("ui", self.device, "appearance", style)
        style_now = sim("ui", self.device, "appearance").stdout.strip()
        if not re.search(rf"\b{style}\s*$", style_now, re.IGNORECASE):
            raise RuntimeError(f"Requested system appearance {style}, simulator reported {style_now!r}")

    def state(self):
        try:
            return json.loads(self.state_path.read_text())
        except FileNotFoundError:
            return {}

    def oriented_image(self, raw, orientation):
        # simctl may return a portrait-mounted framebuffer even after UIKit rotated the
        # window scene left. Preserve that raw capture alongside its upright presentation.
        with raw.open("rb") as f:
            header = f.read(24)
        if header[:8] != b"\x89PNG\r\n\x1a\n":
            raise ValueError("simctl did not return a PNG framebuffer.")
        width, height = struct.unpack(">II", header[16:24])
        if orientation == "landscape" and width < height:
            upright = self.scratch / "landscape.png"
            run("/usr/bin/sips", "-r", "90", str(raw), "--out", str(upright))
            return upright
        return raw

    def frame(self, scene, appearance, orientation, keyboard, pid, oracle, previous=None, layout_only=False):
        name = f"{scene}-{appearance}-{orientation}"
        path = self.out / (name + ".png")
        last_error = "The scene has not reported a GPU-completed draw."
        candidate = self.scratch / "frame.png"
        print(f"Waiting for {name}", flush=True)
        observed = None
        since = time.monotonic()

        def matches(state):
            ready = (state.get("pid") == pid and state.get("scene") == scene and
                     state.get("appearance") == appearance and state.get("orientation") == orientation)
            if not ready or (scene in TERMINAL_SCENES and (not state.get("gpuCompleted") or not state["generation"])):
                return False
            if scene in NOTICE_SCENES:
                notice = state.get("notice") or {}
                if tuple(notice.get(k) for k in ("title", "detail", "action", "actionLabel")) != NOTICE_SCENES[scene]:
                    return False
                if scene != "notice-connecting" and (not state.get("gpuCompleted") or not state["generation"]):
                    return False
            if keyboard == "visible":
                if scene == "notice-reconnecting" and not (state.get("keyboardLanguage") or "").lower().startswith("en"):
                    return False
                return state["keyboardHeight"] > 90 and state["accessoryHeight"] >= 44
            if keyboard == "hidden":
                return state["keyboardHeight"] < 90
            return True

        def capture():
            nonlocal last_error, observed, since
            state = self.state()
            if not matches(state):
                observed = None
                last_error = f"Requested {scene}, {appearance}, {orientation}, keyboard {keyboard}, PID {pid}; received {state}"
                return False
            if state != observed:
                observed, since = state, time.monotonic()
                save_json(self.out / (name + "-observed.json"), state)
                print(f"{name}: {state['columns']} × {state['rows']} cells, "
                      f"{state['keyboardHeight']:g} pt keyboard guide, {state['accessoryHeight']:g} pt accessory",
                      flush=True)
            if layout_only:
                if time.monotonic() - since < 0.7:
                    return False
                save_json(self.out / (name + ".json"), state)
                return state
            for attempt in (1, 2):
                candidate.unlink(missing_ok=True)
                try:
                    sim("io", self.device, "screenshot", "--mask=black", str(candidate), timeout=75)
                    break
                except (RuntimeError, subprocess.TimeoutExpired) as error:
                    print(f"{name} screenshot attempt {attempt}: {error}", file=sys.stderr, flush=True)
                    if attempt == 2:
                        raise
            if self.state() != state:
                last_error = "The displayed generation or layout changed during capture."
                return False
            upright = self.oriented_image(candidate, orientation)
            if keyboard == "visible":
                metadata = self.scratch / "keyboard-frame.json"
                save_json(metadata, state)
                keys = run(sys.executable, str(ORACLE), str(upright), "keyboard", appearance,
                           "--metadata", str(metadata), timeout=50, check=False)
                if keys.returncode:
                    last_error = (keys.stdout + keys.stderr).strip()
                    return False
            if scene in NOTICE_SCENES:
                checker = self.scratch / "check-pane-capture"
                if not checker.exists():
                    run("xcrun", "swiftc", "scripts/check-pane-capture.swift", "-o", str(checker), timeout=120)
                labels = [label for label in NOTICE_SCENES[scene][:3] if label]
                proof = run(str(checker), str(upright), *labels, check=False, timeout=50)
                if proof.returncode:
                    last_error = (proof.stdout + proof.stderr).strip()
                    return False
            if oracle:
                command = [sys.executable, str(oracle), str(upright), scene, appearance]
                if scene == "editor" and oracle == ORACLE:
                    metadata = self.scratch / "submitted-frame.json"
                    save_json(metadata, state)
                    command += ["--metadata", str(metadata)]
                if previous:
                    command += ["--same-grid-as", str(previous)]
                result = run(*command, check=False, timeout=50)
                if result.returncode:
                    last_error = (result.stdout + result.stderr).strip()
                    return False
                print(result.stdout.strip(), flush=True)
            if upright != candidate:
                candidate.replace(self.out / (name + "-framebuffer.png"))
            upright.replace(path)
            save_json(self.out / (name + ".json"), dict(state, framebufferRotationDegrees=90 if upright != candidate else 0))
            return state

        candidate.unlink(missing_ok=True)
        try:
            return wait_for(name, capture, 100)
        except TimeoutError as error:
            if candidate.exists():
                candidate.replace(self.out / (name + "-failed.png"))
            elif not layout_only and observed is None:
                try:
                    sim("io", self.device, "screenshot", "--mask=black", str(self.out / (name + "-failed.png")),
                        timeout=15, check=False)
                except subprocess.TimeoutExpired:
                    pass
            raise RuntimeError(f"{name}: {last_error}") from error

    @contextlib.contextmanager
    def record_switch(self, name="appearance-switch"):
        log = self.out / "recording.log"
        with log.open("w") as output:
            process = subprocess.Popen(["xcrun", "simctl", "io", self.device, "recordVideo", "--codec=h264",
                                        "--mask=black", "--force", str(self.out / (name + ".mov"))],
                                       stdout=output, stderr=subprocess.STDOUT)
            try:
                def started():
                    if process.poll() is not None:
                        raise RuntimeError("Simulator video recorder exited: " + log.read_text())
                    return "Recording started" in log.read_text()
                wait_for("the first real video frame", started, 35)
                yield
            finally:
                if process.poll() is None:
                    process.send_signal(signal.SIGINT)
                try:
                    process.wait(30)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                    raise RuntimeError("Simulator did not finalize the screen recording.")
                movie = self.out / (name + ".mov")
                if process.returncode not in (0, -signal.SIGINT, 128 + signal.SIGINT) or not movie.exists() or not movie.stat().st_size:
                    raise RuntimeError("Simulator recording failed: " + log.read_text())

    def suite(self):
        failures = {}

        def attempt(label, action, *arguments):
            try:
                action(*arguments)
            except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
                failures[label] = str(error)
                print(f"{label}: {error}", file=sys.stderr, flush=True)
                save_json(self.out / "failures.json", failures)

        attempt("render-benchmark", self.benchmark)
        for scene, appearance, orientation in [
            ("prompt", "dark", "portrait"), ("shell", "dark", "portrait"), ("editor", "dark", "portrait"),
            ("editor", "dark", "landscape"), ("prompt", "light", "portrait"), ("shell", "light", "portrait"),
            ("editor", "light", "portrait"),
            ("editor", "light", "landscape"),
        ]:
            attempt(f"{scene}-{appearance}-{orientation}", self.capture_scene, scene, appearance, orientation)
        attempt("appearance-switch", self.capture_switch)
        if failures:
            raise RuntimeError("iPhone checks failed: " + ", ".join(failures))

    def capture_scene(self, scene, appearance, orientation):
        pid = self.launch(scene, appearance, orientation, "visible")
        self.frame(scene, appearance, orientation, "visible", pid, ORACLE)

    def capture_switch(self):
        pid = self.launch("glyphs", "dark", "portrait", "visible")
        dark = self.frame("glyphs", "dark", "portrait", "visible", pid, ORACLE)
        with self.record_switch():
            self.set_appearance("light")
            light = self.frame("glyphs", "light", "portrait", "visible", pid, ORACLE,
                               self.out / "glyphs-dark-portrait.png")
        for key in ("pid", "generation", "columns", "rows", "selection"):
            if dark[key] != light[key]:
                raise RuntimeError(f"System appearance changed {key}: {dark[key]} → {light[key]}")
        if light["rowsPrepared"] or light["glyphUploads"]:
            raise RuntimeError("Appearance change rebuilt rows or rasterized new glyphs.")

    def benchmark(self):
        report = self.out / "render.json"
        result = run("scripts/benchmark-simulator.sh", self.device, str(self.app), str(report), "--installed",
                     timeout=270, check=False)
        (self.out / "benchmark.log").write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError("Simulator benchmark failed: " + (result.stdout + result.stderr)[-1800:])
        environment = json.loads(report.read_text())["environment"]
        source = json.loads((self.out / "source.json").read_text())
        if environment["commit"] != source["commit"]:
            raise RuntimeError("Benchmark and captured app report different source revisions.")
        print(result.stdout.strip(), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="An empty directory for captures, metadata, logs and video.")
    parser.add_argument("--app", type=Path, help="A packaged simulator app. By default the script builds the current checkout.")
    parser.add_argument("--scene", default="", help="A demo scene, 'notices' for all five mounted pane states, or 'render-benchmark'. Leave empty for the full rendering proof.")
    parser.add_argument("--layout-only", action="store_true", help="Save a stable named-scene layout without screenshot IO.")
    parser.add_argument("--appearance", choices=("dark", "light"), default="dark")
    parser.add_argument("--orientation", choices=("portrait", "landscape"), default="portrait")
    parser.add_argument("--keyboard", choices=("visible", "hidden", "any"), default="any")
    parser.add_argument("--oracle", default="", help="Optional Python checker under scripts/. Receives PNG, scene and appearance.")
    args = parser.parse_args()
    if args.scene and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,64}", args.scene):
        parser.error("A scene name must contain only letters, digits, underscores or hyphens.")
    if args.layout_only and (not args.scene or args.oracle):
        parser.error("--layout-only requires a named scene and provides native metadata only.")
    if args.scene in {"render-benchmark", "notice-reconnect-motion"} and (args.layout_only or args.oracle):
        parser.error("The named workload produces its own evidence.")
    oracle = None
    if args.oracle:
        oracle = (ROOT / args.oracle).resolve()
        if (not args.scene or not oracle.is_relative_to(ROOT / "scripts") or
                oracle.suffix != ".py" or not oracle.is_file()):
            parser.error("A named scene's oracle must be a Python file in scripts/.")
    elif args.scene in PIXEL_CHECKED_SCENES:
        oracle = ORACLE
    os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if any(out.iterdir()):
        parser.error("The output directory must be empty.")
    app = args.app.resolve() if args.app else ROOT / ".build/demo/simulator/Thrush.app"
    if not args.app:
        build = run("scripts/build-demo.sh", "simulator", timeout=400, check=False)
        (out / "build.log").write_text(build.stdout + build.stderr)
        if build.returncode:
            raise RuntimeError("Simulator packaging failed: " + (build.stdout + build.stderr)[-1600:])
    with (app / "Info.plist").open("rb") as f:
        info = plistlib.load(f)
    save_json(out / "source.json", dict(commit=info["ThrushGitCommit"], dirty=info["ThrushWorktreeDirty"],
                                        toolchain=info["ThrushToolchain"]))
    notices = args.scene in NOTICE_SCENES or args.scene in {"notices", "notice-reconnect-motion"}
    with peer(out, notices=notices) as endpoint, disposable_phone(out) as device, tempfile.TemporaryDirectory(dir=out) as work:
        phone = None
        try:
            phone = Phone(device, endpoint, app, out, Path(work))
            opens_keyboard = (not args.scene or args.keyboard == "visible" or
                              (args.scene in {"notices", "notice-reconnecting", "notice-reconnect-motion"} and args.keyboard == "any"))
            if not args.layout_only and args.scene != "render-benchmark" and opens_keyboard:
                phone.warm_keyboard(args.appearance if args.scene else "dark")
            if args.scene == "render-benchmark":
                phone.benchmark()
            elif args.scene == "notice-reconnect-motion":
                runpy.run_path(str(ROOT / "scripts/interaction-capture/reconnect.py"))["record"](phone, args.appearance, wait_for, save_json)
            elif args.scene:
                scenes = NOTICE_SCENES if args.scene == "notices" else [args.scene]
                for scene in scenes:
                    keyboard = args.keyboard
                    if scene in NOTICE_SCENES and keyboard == "any":
                        keyboard = "visible" if scene == "notice-reconnecting" else "hidden"
                    pid = phone.launch(scene, args.appearance, args.orientation, keyboard)
                    if scene == "notice-reconnecting":
                        phone.interrupt_after_focus(pid, keyboard)
                    phone.frame(scene, args.appearance, args.orientation, keyboard, pid, oracle, layout_only=args.layout_only)
            else:
                phone.suite()
        except Exception:
            if phone:
                state = phone.state()
                if state:
                    save_json(out / "last-native-state.json", state)
            try:
                logs = sim("spawn", device, "log", "show", "--last", "3m", "--style", "compact",
                           "--predicate", 'process == "ThrushDemo"', timeout=20, check=False)
                (out / "app.log").write_text((logs.stdout + logs.stderr)[-100_000:])
            except subprocess.TimeoutExpired:
                pass
            raise


if __name__ == "__main__":
    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)
    signal.signal(signal.SIGTERM, interrupted)
    main()
