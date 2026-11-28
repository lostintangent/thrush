#!/usr/bin/env python3
"""Run a packaged Thrush host against real processes on a disposable terminal server."""
import argparse
from contextlib import ExitStack, contextmanager
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit
from urllib.request import urlopen

import proof
from proof import ROOT
import simulator

WORKFLOWS = ("shell", "vim", "codex", "lifecycle")
RECORDINGS = {"shell": "shell-workflow", "vim": "vim-resume", "codex": "codex-session"}
ORIGIN = re.compile(r"http://127\.0\.0\.1:[0-9]+")
CODEX_VERSION = "codex-cli 0.166.0"
BUNDLE_ID = "app.thrush.proofs"
# Longer than the native driver's 150 seconds without a new controller phase.
DRIVER_PATIENCE = 180
# The iPhone Duo's grids with the keyboard up, as the phone recordings measured them.
PORTRAIT, LANDSCAPE = (45, 18), (71, 11)


def load(path):
    spec = importlib.util.spec_from_file_location(path.stem.replace("-", "_"), path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def private_environment(root):
    home, temp = root / "tools-home", root / "tools-tmp"
    home.mkdir(mode=0o700)
    temp.mkdir(mode=0o700)
    return {"PATH": os.environ["PATH"], "HOME": str(home), "CFFIXED_USER_HOME": str(home),
            "TMPDIR": str(temp), "LC_ALL": "en_US.UTF-8", "DEVELOPER_DIR": os.environ.get(
                "DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer"),
            "LIBDISPATCH_COOPERATIVE_POOL_STRICT": "1", "GIT_TERMINAL_PROMPT": "0"}


def executable(path, contents):
    path.write_text(contents)
    path.chmod(0o700)


@contextmanager
def service(argv, log, env):
    with log.open("xb") as output, subprocess.Popen(
        argv, cwd=ROOT, env=env, stdout=output, stderr=subprocess.STDOUT, start_new_session=True
    ) as process:
        try:
            yield process
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()


def wait_for(process, log, read, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = read()
        if result:
            return result
        if process.poll() is not None:
            raise RuntimeError(f"{process.args[0]} exited with status {process.returncode}. See {log}")
        time.sleep(0.05)
    raise TimeoutError(f"Timed out waiting for {process.args[0]}. See {log}")


def configure_workspace(work, home, env, codex, responses):
    bin_dir = home / "bin"
    bin_dir.mkdir()
    (home / "inputrc").write_text("set editing-mode emacs\nset enable-bracketed-paste on\n")
    vim = load(ROOT / "Fixtures/reference/shell-and-vim/capture-shell-and-vim.py")
    executable(bin_dir / "vim", vim.VIM)
    (home / "vimrc").write_text(vim.VIMRC)
    (work / "scratch.txt").write_text("first line\nsecond line\n")
    shutil.copyfile(ROOT / "Fixtures/reference/shell-and-vim/build-log.py", work / "build")
    (work / "build").chmod(0o700)
    subprocess.run(["/usr/bin/git", "init", "-q", work], env=env, check=True)
    if responses:
        # Run the installed CLI itself and keep its profile, model traffic and tools local. Plugins stay off,
        # since their first sync clones a 100 MB marketplace that slows Codex's start on a busy runner.
        # A disabled server holds the name of Codex's in-process worktree tools, so Codex skips them. On a busy
        # runner their handshake can outlast Codex's 30 s MCP timeout and print a warning into the transcript.
        if not codex:
            raise ValueError("Pass --codex-bin pointing to the installed native Codex 0.166.0 executable")
        binary = Path(codex).absolute()
        version = subprocess.check_output([binary, "--version"], env=env, text=True, timeout=15).strip()
        if version != CODEX_VERSION:
            raise ValueError(f"Expected {CODEX_VERSION}, found {version}")
        executable(bin_dir / "codex", f'#!/bin/sh\nexec {shlex.quote(str(binary))} --no-daemon -s read-only -a never "$@"\n')
        profile = home / ".codex"
        profile.mkdir(mode=0o700)
        (profile / "config.toml").write_text(
            'model = "gpt-6.1-sol"\nmodel_provider = "thrush"\ncheck_for_update_on_startup = false\nweb_search = "disabled"\n'
            '[model_providers.thrush]\nname = "Thrush local Responses"\n'
            f'base_url = {json.dumps(responses)}\nwire_api = "responses"\nrequires_openai_auth = false\n'
            f'[projects.{json.dumps(str(work))}]\ntrust_level = "trusted"\n[analytics]\nenabled = false\n'
            '[features]\nplugins = false\n'
            '[mcp_servers.codex_worktrees]\ncommand = "false"\nenabled = false\n'
        )


def loopback_origin(value):
    url = urlsplit(value)
    if (url.scheme not in ("http", "https", "ws", "wss") or url.hostname not in ("127.0.0.1", "localhost", "::1")
            or url.username is not None or url.password is not None or url.query or url.fragment
            or url.path not in ("", "/", "/socket")):
        raise argparse.ArgumentTypeError("Pass a disposable loopback terminal URL, such as http://127.0.0.1:9138")
    try:
        url.port  # Reject a malformed or out-of-range port before starting the app.
    except ValueError as error:
        raise argparse.ArgumentTypeError(str(error)) from error
    scheme = "https" if url.scheme in ("https", "wss") else "http"
    return f"{scheme}://{url.netloc}"


@contextmanager
def live_pty(root, output, bash, codex, workflows, endpoint=None):
    """Prepare an isolated fixture shell and use either the local server or a supplied loopback endpoint."""
    # Codex keys workspace trust by the canonical path of its PTY's current directory.
    root = root.resolve()
    env = private_environment(root)
    bash = Path(bash).absolute()
    bash_version = subprocess.check_output([bash, "--version"], env=env, text=True).splitlines()[0]
    if not bash_version.startswith("GNU bash, version "):
        raise ValueError("Pass --bash pointing to GNU Bash with Readline bracketed paste")
    data = root / "data"
    home, temp = data / "home", data / "tmp"
    work = home / "workspace"  # Keep the Codex header and footer at ~/workspace on every machine.
    shell = root / "shell"
    shell_env = dict(HOME=str(home), CFFIXED_USER_HOME=str(home), TMPDIR=str(temp), PATH=f"{home}/bin:/usr/bin:/bin",
                     SHELL=str(bash), INPUTRC=str(home / "inputrc"), HISTFILE="/dev/null", PS1="thrush$ ",
                     TERM="xterm-256color", COLORTERM="truecolor", LC_ALL="en_US.UTF-8")
    # For an already running server, exec this same fixture from its ordinary interactive shell.
    # Clear the setup command from the screen, then acknowledge it on the shared local filesystem.
    executable(shell, "#!/bin/sh\nset -eu\ncd " + shlex.quote(str(work)) + "\n"
               + """if [ "$#" -gt 0 ]; then
    case "${2:-}" in
        --keep-history) printf '\\033[2J\\033[H' ;;
        *) printf '\\033c' ;;
    esac
    : > "$1"
fi
"""
               + "exec " + shlex.join(["/usr/bin/env", "-i", *(f"{k}={v}" for k, v in shell_env.items()),
                                      str(bash), "--noprofile", "--norc", "-i"]) + "\n")
    with ExitStack() as stack:
        responses = None
        if "codex" in workflows:
            provider = load(ROOT / "Fixtures/reference/workflows/songbird_stream.py")
            responses = stack.enter_context(provider.local_responses(provider.QUESTION, provider.MODEL))
        if endpoint:
            home.mkdir(mode=0o700, parents=True)
            temp.mkdir(mode=0o700)
            source = {"endpoint": endpoint, "source": "external"}
        else:
            server = proof.build_server(output)
            digest = hashlib.sha256(server.read_bytes()).hexdigest()
            endpoint = stack.enter_context(proof.server(server, data, shell, output / "pty-server.log"))
            source = json.loads((data / "source.json").read_bytes())
            source["executableSHA256"] = digest
        work.mkdir(mode=0o700)
        configure_workspace(work, home, env, codex, responses)
        if "recovery" in workflows:
            shutil.copyfile(ROOT / "Tests/ThrushProofs/live/recovery-producer.py", work / "recovery-producer.py")
        metadata = dict(source, bash=bash_version, workflows=list(workflows))
        if responses:
            metadata.update(codex=CODEX_VERSION, responses="local published songbird stream")
        (output / "server.json").write_text(json.dumps(metadata, indent=2) + "\n")
        yield endpoint, work, env


def controller_origins(log):
    for line in log.read_text(errors="replace").splitlines():
        if not line.startswith("{"):
            continue
        try:
            info = json.loads(line)
        except ValueError:
            continue
        endpoint, driver = info.get("endpoint", ""), info.get("driver", "")
        if ORIGIN.fullmatch(endpoint) and ORIGIN.fullmatch(driver) and endpoint != driver:
            return endpoint, driver


def verify_controller(name, output, driver):
    # The controller commits its wire and workflow checks before releasing the app's completed event.
    controller = json.loads((output / "controller-report.json").read_bytes())
    native = json.loads((driver / "workflow-report.json").read_bytes())
    if controller.get("completed") is not True or controller.get("workflow") != name:
        raise RuntimeError(controller.get("error") or f"Incomplete live {name} controller report in {output}")
    if controller.get("checkpoints") != native["checkpoints"]:
        raise RuntimeError(f"Live {name} controller acknowledgements differ from native checkpoints in {output}")


def image_path(output, marker, checkpoint_name):
    name = re.sub(r"[^a-z0-9]+", "-", checkpoint_name.lower()).strip("-")[:80]
    return output / f"{marker.stem}-{name}.png"


def collect_capture(marker, output, platform, target, *, require_keyboard=False):
    request = json.loads(marker.read_bytes())
    index = request["eventIndex"]
    if (type(index) is not int or index < 0 or marker.stem not in (f"capture-{index:03d}", f"capture-{index:03d}-history")
            or not isinstance(request["name"], str) or not request["name"].strip()):
        raise ValueError(f"invalid screenshot request in {marker}")
    image = image_path(output, marker, request["name"])
    raw = output / (marker.stem + "-framebuffer.png")
    deadline = time.monotonic() + 160
    error = "No native image received"
    with (output / "capture.log").open("ab") as log:
        while time.monotonic() < deadline:
            remaining = deadline - time.monotonic()
            try:
                if platform == "mac":
                    proof.capture(int(target), raw)
                else:
                    simulator.screenshot(target, raw, timeout=min(75, remaining))
                with raw.open("rb") as stream:
                    header = stream.read(24)
                if header[:8] != b"\x89PNG\r\n\x1a\n":
                    raise ValueError("Native capture did not produce a PNG")
                width, height = struct.unpack(">II", header[16:24])
                if platform == "simulator" and request["windowSize"][0] > request["windowSize"][1] and width < height:
                    subprocess.run(["/usr/bin/sips", "-r", "90", raw, "--out", image], check=True,
                                   stdout=log, stderr=subprocess.STDOUT, timeout=10)
                else:
                    raw.replace(image)
                verify = [sys.executable, ROOT / "Tests/ThrushProofs/check-workflow-capture.py", image, marker]
                if require_keyboard:
                    verify.append("--require-keyboard")
                subprocess.run(verify, check=True, stdout=log, stderr=subprocess.STDOUT, timeout=15)
                break
            except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
                error = str(exc)
                log.write((error + "\n").encode())
                log.flush()
                time.sleep(0.25)
        else:
            raise RuntimeError(f"no matching native framebuffer for {request['name']}: {error}")
    marker.with_suffix(".done").touch()
    print(f"  {image.name}", flush=True)


def await_report(name, host, controller, driver, output, platform, target):
    """Capture each checkpoint the native driver requests until it writes its final report."""
    captured = set()
    deadline = time.monotonic() + DRIVER_PATIENCE
    trace_size = -1
    while True:
        trace = driver / "workflow-events.log"
        if trace.exists() and (size := trace.stat().st_size) != trace_size:
            trace_size = size
            deadline = time.monotonic() + DRIVER_PATIENCE
        failure = driver / "workflow-error.txt"
        if failure.exists():
            raise RuntimeError(failure.read_text(errors="replace").strip() or str(failure))
        for marker in sorted(set(driver.glob("capture-*.json")) - captured):
            collect_capture(marker, output, platform, target,
                            require_keyboard=platform == "simulator" and name in RECORDINGS)
            captured.add(marker)
            deadline = time.monotonic() + DRIVER_PATIENCE
        report = driver / "workflow-report.json"
        if report.exists():
            result = json.loads(report.read_bytes())
            if (result.get("completed") is not True or result.get("workflow") != RECORDINGS.get(name, "live-" + name)
                    or not result.get("checkpoints") or not captured):
                raise RuntimeError(f"Incomplete {name} checkpoint or capture evidence in {report}")
            return result
        for process, log in ((host, output / "app.log"), (controller, output / "controller.log")):
            if process.poll() is not None:
                raise RuntimeError(f"{process.args[0]} exited with status {process.returncode}. See {log}")
        if time.monotonic() >= deadline:
            raise RuntimeError(f"No {name} phase, capture or final report within {DRIVER_PATIENCE} seconds. See {output}")
        time.sleep(0.1)


def recorded_events(name):
    return json.loads((ROOT / "Fixtures/recordings" / f"{RECORDINGS[name]}.json").read_bytes())["events"]


def verify_duo_grids(name, checkpoints):
    # The driver turns the Duo to landscape for Vim's second recorded resize and back for its third.
    resizes, expected = 0, {}
    for index, event in enumerate(recorded_events(name)):
        resizes += "resize" in event
        if event.get("checkpoint"):
            expected[index] = LANDSCAPE if name == "vim" and resizes == 2 else PORTRAIT
    measured = {step["eventIndex"]: (step["columns"], step["rows"]) for step in checkpoints}
    if not measured.items() <= expected.items():
        raise ValueError(f"{name} iPhone keyboard geometry differs: got {measured}, expected {expected}")


def verify_vim_replay(driver, output):
    # The resumed view must draw every grid pixel it drew before detach, including Vim's steady block cursor.
    events = recorded_events("vim")
    index = {event["name"]: i for i, event in enumerate(events)}
    pair = []
    for name in ("Vim before detach", "Vim serialized replay"):
        marker = driver / f"capture-{index[name]:03d}.json"
        pair += [image_path(output, marker, name), marker]
    cursor = events[index["Vim before detach"]]["checkpoint"]["cursor"]
    subprocess.run([sys.executable, ROOT / "Tests/ThrushProofs/check-workflow-capture.py", *pair[:2], "--compare-grid", *pair[2:],
                    "--block-cursor", str(cursor["row"]), str(cursor["column"])], check=True, timeout=60)


def stall_upstream(proxy, host, log, work, output, device):
    wait_for(proxy, log, (work / "recovery-stop-now").exists, 60)
    # Stop the process that owns the real server socket. The native window keeps running.
    proxy.send_signal(signal.SIGSTOP)
    try:
        _, status = os.waitpid(proxy.pid, os.WUNTRACED)
        if not os.WIFSTOPPED(status):
            raise RuntimeError("The real upstream reader failed to stop")
        stopped = time.monotonic()
        (work / "recovery-go").touch()
        wait_for(host, log, (work / "recovery-produced.json").exists, 30)
        produced = time.monotonic()
        time.sleep(2)  # Let the server parse the finite silent tail before the reader drains.
    finally:
        proxy.send_signal(signal.SIGCONT)
    resumed = time.monotonic()
    (output / "recovery-stall.json").write_text(json.dumps(dict(
        upstreamReaderPID=proxy.pid, nativeProcessPID=host.pid if not device else None,
        readerStopSignal=os.WSTOPSIG(status), producerDoneAfterSeconds=produced - stopped,
        readerResumedAfterSeconds=resumed - stopped), indent=2) + "\n")


def run_workflow(name, upstream, work, env, app_executable, output, appearance, device, documents, trace_lifecycle_frames=False, bootstrap_shell=None):
    output.mkdir()
    log = output / "controller.log"
    controller = ["bun", ROOT / "Tests/ThrushProofs/live/controller.ts", "--workflow", name,
                  "--upstream", upstream, "--work", work, "--report", output / "controller-report.json"]
    if bootstrap_shell:
        controller.extend(["--bootstrap-shell", str(bootstrap_shell)])
    trace = ["--trace-lifecycle-frames"] if trace_lifecycle_frames and name == "lifecycle" else []
    with service([*controller, *trace], log, env) as proxy:
        endpoint, control = wait_for(proxy, log, lambda: controller_origins(log), 30)
        driver = Path(tempfile.mkdtemp(prefix="thrush-live-", dir=documents)) if device else output
        try:
            options = ["--endpoint", endpoint, "--workflow-driver", control, "--workflow-output", str(driver),
                       "--appearance", appearance, *trace,
                       "--keyboard" if device else "--hide-keyboard"]
            if device:
                command = ["xcrun", "simctl", "launch", "--console", "--terminate-running-process", device, BUNDLE_ID]
            else:
                command = [app_executable, "-NSAppSleepDisabled", "YES"]
            with ExitStack() as processes:
                host = None
                try:
                    if device and trace:
                        processes.enter_context(simulator.record_screen(device, output / "lifecycle.mov"))
                    host = processes.enter_context(service([*command, *options], output / "app.log",
                                                           os.environ if device else env))
                    if not device:
                        # macOS keeps a script-launched app behind the active one. Once its driver starts,
                        # Launch Services brings the window to the front as opening it from the Finder would.
                        wait_for(host, output / "app.log", (driver / "workflow-events.log").exists, 60)
                        subprocess.run(["open", "-a", app_executable.parents[2]], check=True, timeout=20)
                    if name == "recovery":
                        stall_upstream(proxy, host, log, work, output, device)
                    report = await_report(name, host, proxy, driver, output, "simulator" if device else "mac",
                                          device or str(host.pid))
                    verify_controller(name, output, driver)
                    if device and name in RECORDINGS:
                        verify_duo_grids(name, report["checkpoints"])
                    if name == "vim":
                        verify_vim_replay(driver, output)
                except Exception as failure:
                    # The controller can still be waiting for the native acknowledgement that failed.
                    try:
                        with urlopen(control + "/observations", timeout=5) as response:
                            observations = json.load(response)
                        (output / "controller-at-failure.json").write_text(json.dumps(observations, indent=2) + "\n")
                    except (OSError, ValueError) as error:
                        print(f"Could not retain controller observations: {error}", file=sys.stderr)
                    if device and name == "lifecycle" and ("app toolbar" in str(failure) or "Final framebuffer" in str(failure)):
                        try:
                            simulator.screenshot(device, output / "view-at-failure.png", timeout=20)
                        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
                            print(f"Could not retain the simulator view image: {error}", file=sys.stderr)
                    raise
                finally:
                    if device and host is not None and host.poll() is None:
                        # simctl --console is the console reader. Release our app before the next
                        # workflow, which also replaces it if a loaded runner's simctl hangs here.
                        try:
                            subprocess.run(["xcrun", "simctl", "terminate", device, BUNDLE_ID],
                                           timeout=20, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                        except subprocess.TimeoutExpired as error:
                            print(f"Simulator termination: {error}", file=sys.stderr)
        finally:
            if device:
                shutil.copytree(driver, output, dirs_exist_ok=True)
                shutil.rmtree(driver)


def stopped_before_attach(output, device):
    try:
        observed = json.loads((output / "controller-at-failure.json").read_bytes())
        state = observed["state"]
        if (observed["workflow"] != output.name or state["phase"] != "attaching"
                or state["attachments"] != 0 or state["outputBytes"] != 0
                or observed["attachments"] != 0 or observed["inputBytes"] != 0
                or any(observed[key] for key in ("ready", "closures", "checkpoints", "perAttachment",
                                                 "queuedFrames", "queuedBytes", "exits", "explicitCloses"))
                or not observed["wire"] or any(observed["wire"].values())):
            return False
        # A traced lifecycle first uses simctl to start the recorder, then to launch the app.
        startup_log = output / "app.log"
        if not startup_log.exists():
            startup_log = output / "recording.log"
        message = startup_log.read_text(errors="replace")
        if "com.apple.CoreSimulator.SimError, code=405" not in message or "current state: Shutdown" not in message:
            return False
        inventory = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "--json"], timeout=15))["devices"]
        return any(row["udid"] == device and row["isAvailable"] and row["state"] == "Shutdown"
                   for group in inventory.values() for row in group)
    except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError):
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", required=True, choices=("mac", "simulator"))
    parser.add_argument("--appearance", choices=("dark", "light"), default="dark", help="Native terminal appearance (default: dark)")
    parser.add_argument("--output", type=Path, required=True, help="New or empty native evidence directory")
    parser.add_argument("--endpoint", type=loopback_origin,
                        help="Use an existing disposable loopback PTY with a POSIX shell on this Mac instead of starting ThrushServer")
    parser.add_argument("--workflow", action="append", choices=(*WORKFLOWS, "recovery"),
                        help="Select workflows. Defaults to shell, vim, codex and lifecycle; recovery exercises a stalled reader.")
    parser.add_argument("--trace-lifecycle-frames", action="store_true", help="Record bounded relay and native WebSocket frames, plus an iPhone Simulator movie, for the lifecycle workflow")
    parser.add_argument("--bash", default=shutil.which("bash"), help="GNU Bash with Readline bracketed paste")
    parser.add_argument("--codex-bin", default=shutil.which("codex"), help="Installed native Codex 0.166.0 executable")
    args = parser.parse_args()
    workflows = args.workflow or list(WORKFLOWS)
    if args.trace_lifecycle_frames and "lifecycle" not in workflows:
        parser.error("--trace-lifecycle-frames requires the lifecycle workflow")
    if len(set(workflows)) != len(workflows):
        parser.error("Choose each workflow once")
    if args.bash is None:
        parser.error("Pass --bash pointing to GNU Bash with Readline bracketed paste")
    out = args.output.resolve()
    app = ROOT / ".build/proofs" / args.platform / "Thrush.app"
    bash = Path(args.bash).absolute()
    codex = Path(args.codex_bin).absolute() if args.codex_bin else None
    os.chdir(ROOT)
    out.mkdir(parents=True, exist_ok=True)
    if any(out.iterdir()):
        parser.error("The output directory must be empty")
    os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    # Xcode can mount a read-only Metal toolchain under the build user's home.
    with (out / "build.log").open("xb") as log:
        subprocess.run([ROOT / "scripts/build-app.sh", "proofs", args.platform], stdout=log,
                       stderr=subprocess.STDOUT, timeout=900, check=True)
    with (out / "reference-install.log").open("xb") as log:
        subprocess.run(["bun", "install", "--cwd", "Fixtures/reference", "--frozen-lockfile"], stdout=log,
                       stderr=subprocess.STDOUT, timeout=120, check=True)
    with tempfile.TemporaryDirectory(prefix="thrush-live-") as scratch, ExitStack() as stack:
        endpoint, work, env = stack.enter_context(live_pty(Path(scratch), out, bash, codex, workflows, args.endpoint))
        with (app / ("Contents/Info.plist" if args.platform == "mac" else "Info.plist")).open("rb") as file:
            info = plistlib.load(file)
        app_executable = (app / "Contents/MacOS" if args.platform == "mac" else app) / info["CFBundleExecutable"]
        digest = hashlib.sha256(app_executable.read_bytes()).hexdigest()
        (out / "source.json").write_text(json.dumps(dict(commit=info["ThrushGitCommit"], dirty=info["ThrushWorktreeDirty"],
            toolchain=info["ThrushToolchain"], platform=args.platform, appearance=args.appearance, executableSHA256=digest), indent=2) + "\n")
        device = documents = None
        if args.platform == "simulator":
            device = stack.enter_context(simulator.disposable_phone(out))
            documents = simulator.prepare_workflow_phone(device, app, out)
        may_reboot = device is not None
        for name in workflows:
            print(f"Running live {name} in the packaged {args.platform} host", flush=True)
            output = out / name
            workflow_args = (name, endpoint, work, env, app_executable, output,
                             args.appearance, device, documents, args.trace_lifecycle_frames,
                             Path(scratch) / "shell" if args.endpoint else None)
            try:
                run_workflow(*workflow_args)
            except Exception as error:
                if not may_reboot or not stopped_before_attach(output, device):
                    raise
                may_reboot = False
                first = output.rename(out / f"{name}-attempt-1")
                retry = dict(workflow=name, device=device, stateBeforeBoot="Shutdown", nextAttempt=2,
                             firstAttemptDirectory=first.name, retryDirectory=output.name, rebootLog=f"{first.name}/reboot.log",
                             originalError=str(error))
                (out / "simulator-retry.json").write_text(json.dumps(retry, indent=2) + "\n")
                print(f"Rebooting the disposable simulator to retry {name}. First attempt in {first}", flush=True)
                with (first / "reboot.log").open("xb") as log:
                    subprocess.run(["xcrun", "simctl", "bootstatus", device, "-b"], stdout=log,
                                   stderr=subprocess.STDOUT, timeout=300, check=True)
                run_workflow(*workflow_args)
    print(out)


if __name__ == "__main__":
    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)
    signal.signal(signal.SIGTERM, interrupted)
    main()
