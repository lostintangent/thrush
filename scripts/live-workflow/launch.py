#!/usr/bin/env python3
"""Run a packaged Thrush host against real processes on an isolated Toy Box PTY."""
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
import subprocess
import sys
import tempfile
import time
from urllib.request import urlopen

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ("shell", "vim", "codex", "lifecycle")
ORIGIN = re.compile(r"http://127\.0\.0\.1:[0-9]+")
CODEX_VERSION = "codex-cli 0.166.0"


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
    vim = load(ROOT / "Fixtures/reference/m2/capture.py")
    executable(bin_dir / "vim", vim.VIM)
    (home / "vimrc").write_text(vim.VIMRC)
    (work / "scratch.txt").write_text("first line\nsecond line\n")
    shutil.copyfile(ROOT / "Fixtures/reference/m2/build-log.py", work / "build")
    (work / "build").chmod(0o700)
    subprocess.run(["/usr/bin/git", "init", "-q", work], env=env, check=True)
    if responses:
        # Run the installed CLI itself and keep its profile, model traffic and tools local.
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
        )


@contextmanager
def live_pty(root, output, toy_box, bash, codex, workflows, working_tree=False, public_web=False):
    """Yield the production endpoint, PTY cwd, pinned xterm modules and isolated tool environment."""
    # Codex keys workspace trust by the canonical path of its PTY's current directory.
    root = root.resolve()
    env = private_environment(root)
    bash = Path(bash).absolute()
    bash_version = subprocess.check_output([bash, "--version"], env=env, text=True).splitlines()[0]
    if not bash_version.startswith("GNU bash, version "):
        raise ValueError("Pass --bash pointing to GNU Bash with Readline bracketed paste")
    shell = root / "shell"
    executable(shell, '#!/bin/sh\ncd "$HOME/workspace" || exit 1\nexport PATH="$HOME/bin:/usr/bin:/bin" INPUTRC="$HOME/inputrc" HISTFILE=/dev/null\n'
               f"export PS1='thrush$ ' SHELL={shlex.quote(str(bash))}\nexec {shlex.quote(str(bash))} --noprofile --norc -i\n")
    log = output / "toy-box.log"
    overlay = None
    if public_web:
        # Keep the caller's checkout intact. The report fingerprints the modified tree and the original pin.
        scratch_source = root / "public-server-source"
        revision = load(ROOT / "scripts/serve-pty.py").REVISION
        subprocess.run(["git", "clone", "-q", "--shared", "--no-checkout", toy_box, scratch_source], env=env, check=True)
        subprocess.run(["git", "-C", scratch_source, "switch", "-q", "--detach", revision], env=env, check=True)
        overlay_file = output / "server-build.json"
        with (output / "public-dependencies.log").open("xb") as build_log:
            subprocess.run(["bun", ROOT / "scripts/live-workflow/ci-web.ts", scratch_source, revision, overlay_file],
                           env=env, check=True, stdout=build_log, stderr=subprocess.STDOUT)
        overlay = json.loads(overlay_file.read_bytes())
        toy_box = scratch_source
    args = [sys.executable, "-B", ROOT / "scripts/serve-pty.py", "--toy-box", toy_box, "--data-dir", root / "data", "--shell", shell]
    if working_tree or public_web:
        args.append("--working-tree")
    with ExitStack() as stack:
        responses = None
        if "codex" in workflows:
            provider = load(ROOT / "Fixtures/reference/m4/songbird_stream.py")
            responses = stack.enter_context(provider.local_responses(provider.QUESTION, provider.MODEL))
        process = stack.enter_context(service(args, log, env))
        listener = wait_for(process, log, lambda: re.search(r"Listening on: (http://127\.0\.0\.1:\d+)/",
                                                            log.read_text(errors="replace")), 900)
        home = root / "data/home"
        # Keep the Codex header and footer at ~/workspace on every machine.
        work = home / "workspace"
        work.mkdir(mode=0o700)
        configure_workspace(work, home, env, codex, responses)
        if "recovery" in workflows:
            shutil.copyfile(Path(__file__).with_name("recovery-producer.py"), work / "recovery-producer.py")
        source = json.loads((root / "data/source.json").read_text())
        bun = subprocess.check_output(["bun", "--version"], env=env, text=True).strip()
        key = source["toyBoxRevision"]
        if "toyBoxWorktreeSHA256" in source:
            key += "-worktree-" + source["toyBoxWorktreeSHA256"]
        modules = ROOT / ".build/pty-server" / f"{key}-bun-{bun}" / "node_modules"
        for name, version in {"@xterm/headless": "6.0.0", "@xterm/addon-unicode11": "0.9.0"}.items():
            if json.loads((modules / name / "package.json").read_text())["version"] != version:
                raise ValueError(f"The controller requires {name} {version}")
        metadata = dict(source, bun=bun, bash=bash_version, workflows=list(workflows))
        if overlay:
            metadata["webAnimationSubstitution"] = overlay
        if responses:
            metadata.update(codex=CODEX_VERSION, responses="local published songbird stream")
        (output / "server.json").write_text(json.dumps(metadata, indent=2) + "\n")
        yield listener[1], work, modules, env


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


def run_workflow(name, upstream, work, modules, env, app_executable, output, appearance, device, documents, pane, trace_lifecycle_frames=False):
    output.mkdir()
    log = output / "controller.log"
    controller = ["bun", ROOT / "scripts/live-workflow/controller.ts", "--workflow", name,
                  "--upstream", upstream, "--work", work, "--report", output / "controller-report.json"]
    trace = ["--trace-lifecycle-frames"] if trace_lifecycle_frames and name == "lifecycle" else []
    with service([*controller, *trace], log, dict(env, THRUSH_XTERM_MODULES=str(modules))) as proxy:
        endpoint, control = wait_for(proxy, log, lambda: controller_origins(log), 30)
        driver = Path(tempfile.mkdtemp(prefix="thrush-live-", dir=documents)) if device else output
        try:
            options = ["--endpoint", endpoint, "--workflow-driver", control, "--workflow-output", str(driver),
                       "--appearance", appearance, *trace,
                       "--keyboard" if device else "--hide-keyboard"]
            if device:
                command = ["xcrun", "simctl", "launch", "--console", device, pane.BUNDLE_ID]
            else:
                command = [app_executable, "-NSAppSleepDisabled", "YES"]
            with pane.running([*command, *options], output / "app.log", **({} if device else {"env": env})) as host:
                try:
                    if name == "recovery":
                        stall_upstream(proxy, host, log, work, output, device)
                    pane.await_report("live-" + name if name in ("lifecycle", "recovery") else name, host, proxy,
                                      driver, output, "simulator" if device else "mac", device or str(host.pid),
                                      verify_fixture=False)
                    verify_controller(name, output, driver)
                except Exception:
                    # The controller can still be waiting for the native acknowledgement that failed.
                    try:
                        with urlopen(control + "/observations?clientId=thrush-native-workflow", timeout=5) as response:
                            observations = json.load(response)
                        (output / "controller-at-failure.json").write_text(json.dumps(observations, indent=2) + "\n")
                    except (OSError, ValueError) as error:
                        print(f"Could not retain controller observations: {error}", file=sys.stderr)
                    raise
                finally:
                    if device and host.poll() is None:
                        # simctl --console is the console reader. Explicitly release our app
                        # before the next workflow uses this reserved device.
                        already_failed = sys.exc_info()[0] is not None
                        try:
                            subprocess.run(["xcrun", "simctl", "terminate", device, pane.BUNDLE_ID],
                                           timeout=20, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                        except subprocess.TimeoutExpired as error:
                            if not already_failed:
                                raise
                            print(f"Simulator termination: {error}", file=sys.stderr)
        finally:
            if device:
                shutil.copytree(driver, output, dirs_exist_ok=True)
                shutil.rmtree(driver)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", required=True, choices=("mac", "simulator"))
    parser.add_argument("--appearance", choices=("dark", "light"), default="dark", help="Native terminal appearance (default: dark)")
    parser.add_argument("--output", type=Path, required=True, help="New or empty native evidence directory")
    parser.add_argument("--toy-box", type=Path, default=ROOT.parent / "toy-box", help="Local checkout containing the pinned revision")
    parser.add_argument("--public-web-build", action="store_true", help="Use the documented CI substitute for Toy Box’s web animation components in a disposable copy of the pin")
    parser.add_argument("--working-tree", action="store_true", help="Build the current Toy Box files instead of the pinned revision")
    parser.add_argument("--workflow", action="append", choices=(*WORKFLOWS, "recovery"), help="Select workflows. Defaults to shell, vim, codex and lifecycle. Use recovery with --working-tree.")
    parser.add_argument("--trace-lifecycle-frames", action="store_true", help="Record bounded relay and native WebSocket frames for the disposable lifecycle workflow")
    parser.add_argument("--device", help="Reserved booted iPhone UDID. By default create and remove a disposable simulator.")
    parser.add_argument("--app", type=Path, help="Prebuilt Thrush.app; by default build the current checkout")
    parser.add_argument("--bash", default=shutil.which("bash"), help="GNU Bash with Readline bracketed paste")
    parser.add_argument("--codex-bin", default=shutil.which("codex"), help="Installed native Codex 0.166.0 executable")
    args = parser.parse_args()
    if args.public_web_build and args.working_tree:
        parser.error("The public web build uses the pinned server revision; select one source mode")
    workflows = args.workflow or list(WORKFLOWS)
    if args.trace_lifecycle_frames and "lifecycle" not in workflows:
        parser.error("--trace-lifecycle-frames requires the lifecycle workflow")
    if "recovery" in workflows and not args.working_tree:
        parser.error("The recovery workflow needs the candidate's in-band repair. Pass --working-tree with its Toy Box checkout.")
    if len(set(workflows)) != len(workflows) or (args.device and args.platform != "simulator"):
        parser.error("Choose each workflow once and use --device only with --platform simulator")
    if args.bash is None:
        parser.error("Pass --bash pointing to GNU Bash with Readline bracketed paste")
    out = args.output.resolve()
    toy_box = args.toy_box.resolve()
    app = args.app.resolve() if args.app else ROOT / ".build/demo" / args.platform / "Thrush.app"
    bash = Path(args.bash).absolute()
    codex = Path(args.codex_bin).absolute() if args.codex_bin else None
    os.chdir(ROOT)
    out.mkdir(parents=True, exist_ok=True)
    if any(out.iterdir()):
        parser.error("The output directory must be empty")
    os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    if not args.app:
        # Xcode can mount a read-only Metal toolchain under the build user's home.
        with (out / "build.log").open("xb") as log:
            subprocess.run([ROOT / "scripts/build-demo.sh", args.platform], stdout=log,
                           stderr=subprocess.STDOUT, timeout=900, check=True)
    pane = load(ROOT / "scripts/check-pane-workflows.py")
    with tempfile.TemporaryDirectory(prefix="thrush-live-") as scratch, ExitStack() as stack:
        endpoint, work, modules, env = stack.enter_context(live_pty(
            Path(scratch), out, toy_box, bash, codex, workflows, args.working_tree, args.public_web_build))
        with (app / ("Contents/Info.plist" if args.platform == "mac" else "Info.plist")).open("rb") as file:
            info = plistlib.load(file)
        app_executable = (app / "Contents/MacOS" if args.platform == "mac" else app) / info["CFBundleExecutable"]
        digest = hashlib.sha256(app_executable.read_bytes()).hexdigest()
        (out / "source.json").write_text(json.dumps(dict(commit=info["ThrushGitCommit"], dirty=info["ThrushWorktreeDirty"],
            toolchain=info["ThrushToolchain"], platform=args.platform, appearance=args.appearance, executableSHA256=digest), indent=2) + "\n")
        device = documents = None
        if args.platform == "simulator":
            simulator = load(ROOT / "scripts/capture-simulator.py")
            if args.device:
                device = stack.enter_context(pane.reserve_phone(args.device))
                pane.ensure_demo_idle(device)
            else:
                device = stack.enter_context(simulator.disposable_phone(out))
            documents = simulator.prepare_workflow_phone(device, app, out)
        for name in workflows:
            print(f"Running live {name} in the packaged {args.platform} host", flush=True)
            run_workflow(name, endpoint, work, modules, env, app_executable, out / name, args.appearance, device, documents, pane, args.trace_lifecycle_frames)
    print(out)


if __name__ == "__main__":
    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)
    signal.signal(signal.SIGTERM, interrupted)
    main()
