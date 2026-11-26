#!/usr/bin/env python3
"""Record real iPhone terminal interactions from the packaged app on a disposable simulator."""
import argparse
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
RUNNER = "PhoneInteractionProof"
BUNDLE_ID = "app.thrush.review.interactions"
APPEARANCES = ("dark", "light")
PICS = ("shell-{}-portrait", "control-{}-armed", "control-{}-shift", "control-{}-option", "control-{}-landscape",
        "shell-{}-landscape", "keyboard-{}-hidden", "word-{}-menu", "line-{}-selected", "history-{}-latest",
        "line-{}-last")
CLIPS = ("control", "keyboard", "select", "history")
SWIPES = ("less", "vim", "history", "settings")
# An interrupted xcodebuild cancels its tests and still writes the result bundle, which keeps
# the screenshots and clips taken before a hang. Tearing down a hung test took 68 s on a Mac.
INTERRUPT_GRACE = 120


def load_helper(name):
    path = ROOT / "scripts" / (name + ".py")
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run_logged(args, log, timeout, observe=None):
    with log.open("w") as output, subprocess.Popen(args, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT) as result:
        deadline = time.monotonic() + timeout
        try:
            while result.poll() is None:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(args, timeout)
                if observe:
                    observe()
                try:
                    result.wait(timeout=min(remaining, 0.25) if observe else remaining)
                except subprocess.TimeoutExpired:
                    pass
        finally:
            if result.poll() is None:
                result.send_signal(signal.SIGINT)
                try:
                    result.wait(timeout=INTERRUPT_GRACE)
                except subprocess.TimeoutExpired:
                    result.kill()
    if result.returncode:
        raise RuntimeError(f"{args[0]} exited {result.returncode}. See {log.name}.\n" + log.read_text()[-2800:])


def build_test_runner(work, out, source=HERE / (RUNNER + ".swift"), *, mac=False, name=RUNNER):
    # XCUITest needs a UI-test bundle. Keep the product and its generated project inside
    # the disposable build directory; the real app is always the normal SwiftPM bundle.
    project = work / (name + ".xcodeproj")
    shared = project / "xcshareddata/xcschemes"
    shared.mkdir(parents=True)
    (work / (name + ".swift")).symlink_to(source)
    objects = {}

    def item(key, isa, **values):
        objects[key] = {"isa": isa, **values}

    item("PROJECT", "PBXProject", mainGroup="GROUP", productRefGroup="PRODUCTS", buildConfigurationList="CFG",
         targets=["TARGET"], projectDirPath="", projectRoot="", compatibilityVersion="Xcode 14.0",
         developmentRegion="en", knownRegions=["en", "Base"])
    item("GROUP", "PBXGroup", children=["SOURCE", "PRODUCTS"], sourceTree="<group>")
    item("PRODUCTS", "PBXGroup", children=["BUNDLE"], name="Products", sourceTree="<group>")
    item("SOURCE", "PBXFileReference", lastKnownFileType="sourcecode.swift", path=name + ".swift", sourceTree="<group>")
    item("BUNDLE", "PBXFileReference", explicitFileType="wrapper.cfbundle", path=name + ".xctest",
         sourceTree="BUILT_PRODUCTS_DIR")
    item("TARGET", "PBXNativeTarget", name=name, productName=name, productReference="BUNDLE",
         productType="com.apple.product-type.bundle.ui-testing", buildConfigurationList="TARGETCFG",
         buildPhases=["COMPILE", "LINK"], buildRules=[], dependencies=[])
    item("TEST", "PBXBuildFile", fileRef="SOURCE")
    for key, kind, files in [("COMPILE", "PBXSourcesBuildPhase", ["TEST"]), ("LINK", "PBXFrameworksBuildPhase", [])]:
        item(key, kind, buildActionMask="2147483647", files=files, runOnlyForDeploymentPostprocessing="0")
    platform = dict(SDKROOT="macosx", MACOSX_DEPLOYMENT_TARGET="27.0") if mac else dict(
        SDKROOT="iphoneos", IPHONEOS_DEPLOYMENT_TARGET="27.0", TARGETED_DEVICE_FAMILY="1")
    for key, debug, settings in [
        ("CFG", "DEBUG", dict(**platform, SWIFT_VERSION="5.0", CLANG_ENABLE_MODULES="YES")),
        ("TARGETCFG", "TARGETDEBUG", dict(PRODUCT_NAME=name, PRODUCT_BUNDLE_IDENTIFIER=BUNDLE_ID,
                                         GENERATE_INFOPLIST_FILE="YES", CODE_SIGN_IDENTITY="-")),
    ]:
        item(key, "XCConfigurationList", buildConfigurations=[debug], defaultConfigurationIsVisible="0",
             defaultConfigurationName="Debug")
        item(debug, "XCBuildConfiguration", name="Debug", buildSettings=settings)
    with (project / "project.pbxproj").open("wb") as file:
        plistlib.dump(dict(archiveVersion="1", objectVersion="56", classes={}, objects=objects, rootObject="PROJECT"), file)
    ref = (f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="TARGET" '
           f'BuildableName="{name}.xctest" BlueprintName="{name}" ReferencedContainer="container:{project.name}"/>')
    (shared / (name + ".xcscheme")).write_text(f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme version="1.7">
  <BuildAction parallelizeBuildables="NO" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{ref}</BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug"><Testables><TestableReference skipped="NO">{ref}</TestableReference></Testables></TestAction>
</Scheme>
""")
    derived = work / "DerivedData"
    run_logged(["xcodebuild", "-project", project, "-scheme", name, "-derivedDataPath", derived,
                "-destination", "platform=macOS" if mac else "generic/platform=iOS Simulator", "build-for-testing"], out / "runner-build.log", 300)
    return next((derived / "Build/Products").glob("*.xctestrun"))


def export_attachments(result, out, work, clips):
    """Saves the runner's screenshots and its clips' intervals, and returns every attachment's file and time."""
    # XCTest retains completed frames and motion intervals when a later gesture fails.
    exported = work / "attachments"
    run_logged(["xcrun", "xcresulttool", "export", "attachments", "--path", result,
                "--output-path", exported], out / "attachments.log", 90)
    attachments = {}
    for test in json.loads((exported / "manifest.json").read_text()):
        for attachment in test["attachments"]:
            match = re.search(r"thrush-proof__([a-z0-9-]+)__", attachment["suggestedHumanReadableName"])
            if not match:
                continue
            name, path = match[1], exported / Path(attachment["exportedFileName"]).name
            attachments[name] = path, attachment["timestamp"]
            if path.suffix == ".png" or name in clips:
                shutil.copyfile(path, out / (name + (".png" if path.suffix == ".png" else "-motion.json")))
    return attachments


def export_clip(name, video_start, out, work):
    interval = out / (name + "-motion.json")
    if not interval.exists():
        raise ValueError(f"Missing gesture interval {interval.name}.")
    if video_start is None:
        raise RuntimeError("Screen recording unavailable. See recording-error.log.")
    start, end = json.loads(interval.read_text())
    if not 0 < end - start <= 60 or start < video_start - 1:
        raise ValueError(f"Invalid capture interval for {name}: {start}, {end}")
    clip = work / (name + ".mp4")
    run_logged(["/usr/bin/avconvert", "--source", out / "appearance-switch.mov", "--output", clip,
                "--preset", "PresetHighestQuality", "--start", str(max(0, start - video_start - 0.25)),
                "--duration", str(end - start + 0.5)], out / (name + "-export.log"), 90)
    if not clip.stat().st_size:
        raise ValueError(f"Empty clip {clip.name}.")
    shutil.move(clip, out / clip.name)


def export_clips(names, video_start, out, work, attempt):
    for name in names:
        attempt(name + ".mp4", export_clip, name, video_start, out, work)
    if all((out / (name + ".mp4")).is_file() for name in names):
        (out / "appearance-switch.mov").unlink()


def run_gestures(phone, device, plan, result, out, attempt, observe):
    """Runs the native gestures while the simulator records its screen, and returns when the recording began."""
    # The runner timestamps just the gestures in the foreground app. Trim setup, launches
    # and XCTest's transitions out of the simulator's recording before handing it to design.
    # A simulator with no recording surface can still run UIKit gestures and return
    # XCTest screenshots. Collect those even when its video encoder is unavailable.
    recording = contextlib.ExitStack()
    video_start = None
    try:
        try:
            recording.enter_context(phone.record_switch())
            video_start = time.time()
        except (RuntimeError, TimeoutError, subprocess.SubprocessError) as error:
            (out / "recording-error.log").write_text(str(error) + "\n")
        attempt("native gestures", run_logged, ["xcodebuild", "test-without-building", "-xctestrun", plan,
                "-destination", f"platform=iOS Simulator,id={device}", "-parallel-testing-enabled", "NO",
                "-resultBundlePath", result], out / "ui-gestures.log", 720, observe)
    finally:
        attempt("finalize gesture recording", recording.close)
    return video_start


def save_shell_layouts(out, appearance, spans, frame_times):
    for orientation in ("portrait", "landscape"):
        when = frame_times[f"shell-{appearance}-{orientation}"]
        # A span ends at the first poll with a different geometry, an unqualified drawing or a different PID.
        span = next((span for span in reversed(spans) if span[0][0] <= when), None)
        if span is None or when > spans[-1][-1][0]:
            raise ValueError(f"{appearance} {orientation}: no observed layout at the XCTest checkpoint.")
        observed, state = next(sample for sample in reversed(span) if sample[0] <= when)
        if (state is None or state["appearance"] != appearance or state["orientation"] != orientation
                or span[-1][0] - span[0][0] < 0.7):
            measured = (state["pid"], state["appearance"], state["orientation"]) if state else None
            raise ValueError(f"{appearance} {orientation}: expected a stable completed layout at {when}; "
                             f"observed {measured} for {span[-1][0] - span[0][0]:.3f}s.")
        name = f"shell-{appearance}-{orientation}"
        evidence = dict(state, checkpointTime=when, observedAt=observed)
        (out / (name + "-layout.json")).write_text(json.dumps(evidence, indent=2) + "\n")
        print(f"{name}: PID {state['pid']}, {state['columns']} × {state['rows']} cells, "
              f"{state['keyboardHeight']:g} pt keyboard", flush=True)


def collect(phone, device, endpoint, plan, out, work, attempt):
    configuration = plistlib.loads(plan.read_bytes())
    configuration[RUNNER]["EnvironmentVariables"]["THRUSH_CAPTURE_ENDPOINT"] = endpoint
    plan.write_bytes(plistlib.dumps(configuration))
    result = work / "interactions.xcresult"
    spans = []
    previous = None

    def observe_layout():
        nonlocal previous
        state = phone.state()
        if (state.get("scene") != "shell" or not state.get("gpuCompleted") or not state.get("generation")
                or state.get("keyboardHeight", 0) <= 90 or state.get("accessoryHeight", 0) < 44):
            state = None
        geometry = None
        if state:
            geometry = tuple(state[k] for k in ("pid", "appearance", "orientation", "columns", "rows",
                                                "windowPoints", "gridFrame", "keyboardHeight", "accessoryHeight"))
        if not spans or geometry != previous:
            spans.append([])
            previous = geometry
        spans[-1].append((time.time(), state))

    video_start = run_gestures(phone, device, plan, result, out, attempt, observe_layout)
    names = [f"{gesture}-{appearance}" for appearance in APPEARANCES for gesture in CLIPS]
    if result.exists():
        frame_times = {}

        def export():
            frame_times.update((name, when) for name, (path, when) in export_attachments(result, out, work, names).items()
                               if path.suffix == ".png")
        attempt("gesture attachments", export)
        for appearance in APPEARANCES:
            attempt(f"{appearance} shell layouts", save_shell_layouts, out, appearance, spans, frame_times)
    export_clips(names, video_start, out, work, attempt)


def collect_swipes(phone, device, endpoint, plan, out, work, attempt):
    configuration = plistlib.loads(plan.read_bytes())
    configuration[RUNNER]["EnvironmentVariables"]["THRUSH_CAPTURE_ENDPOINT"] = endpoint
    plan.write_bytes(plistlib.dumps(configuration))
    result = work / "swipes.xcresult"
    previous = None

    with (out / "swipe-states.jsonl").open("w") as trace:
        def observe():
            nonlocal previous
            state = phone.state()
            if state and state != previous:
                trace.write(json.dumps(dict(state, observedAt=time.time())) + "\n")
                previous = state

        video_start = run_gestures(phone, device, plan, result, out, attempt, observe)
    names = [f"{clip}-{appearance}" for appearance in APPEARANCES for clip in SWIPES]
    if result.exists():
        attachments = export_attachments(result, out, work, names)
        gestures = {name: json.loads(path.read_text()) for name, (path, _) in attachments.items()
                    if path.suffix == ".json" and name not in names}
        (out / "swipe-gestures.json").write_text(json.dumps(gestures, indent=1) + "\n")
    export_clips(names, video_start, out, work, attempt)


def check_images(out):
    oracle = load_helper("check-demo-capture")
    for appearance in APPEARANCES:
        for orientation in ("portrait", "landscape"):
            if not (out / f"shell-{appearance}-{orientation}-layout.json").exists():
                raise ValueError(f"Missing settled keyboard and grid measurements for {appearance} {orientation}.")
        for template in PICS:
            path = out / (template.format(appearance) + ".png")
            capture = oracle.Capture(path, appearance)
            if capture.count("background") < capture.width * capture.height * 0.04:
                raise ValueError(f"{path.name} has insufficient Slate terminal background.")
            if template.startswith(("word-", "line-")) and capture.count("selection") < 100:
                raise ValueError(f"{path.name} lacks the Metal selection.")
            if template.endswith("-landscape") and capture.count("passed") < 16:
                raise ValueError(f"{path.name} lost the green shell checks above the prompt in landscape.")
            if template.startswith("control-"):
                check_armed(capture, path.name)
        run_logged([sys.executable, ROOT / "scripts/check-demo-capture.py", out / f"shell-{appearance}-portrait.png",
                    "shell", appearance], out / f"shell-{appearance}-pixels.log", 80)


def check_armed(capture, name):
    """The armed modifier key and its choice above the row fill with the selection under its own ink."""
    fill, ink = capture.matches("selection"), capture.matches("selected_ink")
    bands = []
    for y in range(capture.height):
        row = capture.pixels[y * capture.width:(y + 1) * capture.width]
        xs = [x for x, value in enumerate(row) if value in fill]
        if len(xs) < 60:
            continue
        # A title's crossbars can leave a few rows of a narrow chip with little fill showing.
        if bands and y - bands[-1][1] <= 12:
            bands[-1][1:] = [y, min(bands[-1][2], xs[0]), max(bands[-1][3], xs[-1])]
        else:
            bands.append([y, y, xs[0], xs[-1]])
    # A chip is at least 24 points tall, and its title is the selection's ink.
    chips = [band for band in bands if band[1] - band[0] >= 60]
    if len(chips) != 2:
        raise ValueError(f"{name} should fill the armed key and its choice, found {len(chips)} selection chips.")
    for top, bottom, left, right in chips:
        inked = sum(capture.pixels[y * capture.width + x] in ink
                    for y in range(top, bottom + 1) for x in range(left, right + 1))
        if inked < 40:
            raise ValueError(f"{name} has a selection chip without the selection's ink at rows {top} to {bottom}.")


def check_voiceover(phone, device, endpoint, plan, out, work):
    options = plistlib.loads(plan.read_bytes())
    options[RUNNER]["EnvironmentVariables"]["THRUSH_CAPTURE_ENDPOINT"] = endpoint
    plan.write_bytes(plistlib.dumps(options))
    result = work / "voiceover.xcresult"
    try:
        run_logged(["xcodebuild", "test-without-building", "-xctestrun", plan, "-destination",
                    f"platform=iOS Simulator,id={device}", "-parallel-testing-enabled", "NO",
                    "-resultBundlePath", result], out / "voiceover.log", 600)
    finally:
        observed = phone.state_path.parent / "accessibility-spinner-reconnecting.json"
        if observed.exists():
            shutil.copyfile(observed, out / observed.name)


def check_accessibility_settings(events):
    if not any(event["reduceMotion"] and event["reduceTransparency"]
               and event["contentSize"] == "UICTContentSizeCategoryAccessibilityXXXL" for event in events):
        raise ValueError("UIKit did not observe both reduced effects and the largest text size.")


def check_voiceover_focus(events):
    reconnect = next((i for i, event in enumerate(events) if event.get("cursorSpinnerLabel") == "Reconnecting"), None)
    if reconnect is None:
        raise ValueError("UIKit did not observe the reconnecting spinner.")
    # A reconnect announcement can change the last spoken phrase while the reading cursor stays on its row.
    before = [event for event in events[:reconnect] if event["voiceOverRunning"]]
    during = [event for event in events[reconnect:] if event["voiceOverRunning"]
              and event.get("cursorSpinnerLabel") == "Reconnecting"]
    if not before or before[-1].get("focusedLabel") != "Test run passed.":
        raise ValueError("VoiceOver did not focus the terminal line before the interruption.")
    if not during or any(event.get("focusedLabel") != "Test run passed." for event in during):
        raise ValueError("VoiceOver did not retain the terminal line during reconnect.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="A new or empty directory for captures and logs.")
    parser.add_argument("--build-runner-only", action="store_true", help="Compile the gesture runner without booting a simulator.")
    scope = parser.add_mutually_exclusive_group()
    scope.add_argument("--accessibility-only", action="store_true",
                       help="Exercise VoiceOver and accessible pane controls on a fresh iPhone at the largest text size.")
    scope.add_argument("--swipes-only", action="store_true",
                       help="Swipe through less, vim and the shell's history on a real shell in both appearances, and check "
                            "that a program glides as far as the history and stops under a resting or catching finger.")
    options = parser.parse_args()
    sys.dont_write_bytecode = True
    os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    out = options.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if any(out.iterdir()):
        parser.error("Use an empty output directory.")
    with tempfile.TemporaryDirectory(prefix="thrush-iphone-interactions-") as scratch:
        work = Path(scratch)
        source = HERE / ("PaneVoiceOverProof.swift" if options.accessibility_only else
                         "ScrollSwipeProof.swift" if options.swipes_only else RUNNER + ".swift")
        plan = build_test_runner(work, out, source=source)
        if options.build_runner_only:
            print("Compiled the native iPhone interaction runner.")
            return

        simulator = load_helper("capture-simulator")
        run_logged(["scripts/build-demo.sh", "simulator"], out / "app-build.log", 480)
        app = ROOT / ".build/demo/simulator/Thrush.app"
        info = plistlib.loads((app / "Info.plist").read_bytes())
        simulator.save_json(out / "source.json", dict(commit=info["ThrushGitCommit"], dirty=info["ThrushWorktreeDirty"],
                                                       toolchain=info["ThrushToolchain"]))
        os.environ["THRUSH_CAPTURE_GRID"] = "1"
        scroll = load_helper("interaction-capture/scroll")
        # Swipes scroll real programs, so they run on a shell rather than the scripted peer.
        peer = scroll.shell(work, out) if options.swipes_only else simulator.peer(out, cursor=options.accessibility_only)
        with peer as endpoint, simulator.disposable_phone(out) as device:
            phone = simulator.Phone(device, endpoint, app, out, work)
            failures = {}
            def attempt(name, action, *args):
                print(f"Running {name}", flush=True)
                try:
                    action(*args)
                except Exception as error:
                    failures[name] = str(error)
                    print(f"{name} failed: {error}", file=sys.stderr, flush=True)

            if options.accessibility_only:
                # simctl may return late after applying a setting. Record command failures,
                # then let UIKit report the effective values in the test process.
                try:
                    simulator.sim("ui", device, "content_size", "accessibility-extra-extra-extra-large")
                except (RuntimeError, subprocess.TimeoutExpired) as error:
                    print(f"Dynamic Type setting: {error}", file=sys.stderr, flush=True)
                for setting in ("ReduceMotionEnabled", "EnhancedBackgroundContrastEnabled"):
                    simulator.sim("spawn", device, "defaults", "write", "com.apple.Accessibility", setting, "-bool", "true")
                attempt("VoiceOver", check_voiceover, phone, device, endpoint, plan, out, work)
            else:
                # The simulator streams every log message live, and UIKit logs five render-factory
                # errors per key each time it lays out a keyboard. Turning that category off keeps
                # the gate from adding about 1,250 synchronous log sends to every keyboard turn.
                attempt("quiet keyboard render log", simulator.sim, "spawn", device, "log", "config", "--subsystem",
                        "com.apple.UIKit", "--category", "UIKBRenderingLog", "--mode", "level:off")
                attempt("pinned status bar", phone.pin_status_bar)
                attempt("keyboard warm-up", phone.warm_keyboard, "dark")
                if options.swipes_only:
                    attempt("swipe capture", collect_swipes, phone, device, endpoint, plan, out, work, attempt)
                    for appearance in APPEARANCES:
                        attempt(f"{appearance} swipes", scroll.check, out, appearance)
                else:
                    attempt("gesture capture", collect, phone, device, endpoint, plan, out, work, attempt)
                    attempt("interaction screenshots", check_images, out)
            attempt("UIKit tests", run_logged, ["scripts/check-ios-ui.sh", device], out / "uikit-tests.log", 720)
            if options.accessibility_only:
                report = out / "accessibility-spinner-reconnecting.json"
                if report.exists():
                    events = json.loads(report.read_text())["events"]
                    attempt("accessibility settings", check_accessibility_settings, events)
                    attempt("VoiceOver reading position", check_voiceover_focus, events)
                else:
                    failures["accessibility observations"] = "The mounted app did not record its accessibility state."
            simulator.save_json(out / "checks.json", {"failures": failures})
            if failures:
                raise RuntimeError("Failed interaction checks: " + ", ".join(failures))
    if options.accessibility_only:
        print("Verified VoiceOver, Dynamic Type, Reduce Motion and Reduce Transparency on the mounted iPhone pane.")
    elif options.swipes_only:
        print("Verified that swipes glide through less and vim as far as through the shell's history and stop under a finger.")
    else:
        print("Captured the iPhone terminal, selection, controls, scrolling and landscape in both Slate appearances.")


if __name__ == "__main__":
    main()
