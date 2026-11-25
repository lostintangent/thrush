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
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
RUNNER = "PhoneInteractionProof"
BUNDLE_ID = "app.thrush.review.interactions"
APPEARANCES = ("dark", "light")
PICS = ("shell-{}-portrait", "control-{}-armed", "shell-{}-landscape", "word-{}-menu",
        "line-{}-selected", "history-{}-latest")
CLIPS = ("control", "rotate", "select", "history")


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


def export_attachments(result, out, work):
    # XCTest retains completed frames and motion intervals when a later gesture fails.
    exported = work / "attachments"
    run_logged(["xcrun", "xcresulttool", "export", "attachments", "--path", result,
                "--output-path", exported], out / "attachments.log", 90)
    for test in json.loads((exported / "manifest.json").read_text()):
        for attachment in test["attachments"]:
            match = re.search(r"thrush-proof__([a-z-]+)__", attachment["suggestedHumanReadableName"])
            if not match:
                continue
            name = match.group(1)
            is_frame = any(name == template.format(style) for template in PICS for style in APPEARANCES)
            is_clip = any(name == f"{clip}-{style}" for clip in CLIPS for style in APPEARANCES)
            if is_frame or is_clip:
                src = exported / Path(attachment["exportedFileName"]).name
                shutil.copyfile(src, out / (name + (".png" if is_frame else "-motion.json")))


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


def collect(phone, device, endpoint, plan, out, work, attempt, rotation_only=False):
    configuration = plistlib.loads(plan.read_bytes())
    environment = configuration[RUNNER]["EnvironmentVariables"]
    environment["THRUSH_CAPTURE_ENDPOINT"] = endpoint
    environment["THRUSH_CAPTURE_ROTATION_ONLY"] = "1" if rotation_only else "0"
    plan.write_bytes(plistlib.dumps(configuration))
    result = work / "interactions.xcresult"
    previous = None
    saved = None
    since = time.monotonic()

    def observe_layout():
        nonlocal previous, saved, since
        state = phone.state()
        if (state.get("scene") != "shell" or not state.get("gpuCompleted") or not state.get("generation")
                or state.get("keyboardHeight", 0) <= 90 or state.get("accessoryHeight", 0) < 44):
            previous = None
            return
        geometry = tuple(state[k] for k in ("pid", "appearance", "orientation", "columns", "rows",
                                             "windowPoints", "gridFrame", "keyboardHeight", "accessoryHeight"))
        if geometry != previous:
            previous, since = geometry, time.monotonic()
        elif geometry != saved and time.monotonic() - since >= 0.7:
            name = f"shell-{state['appearance']}-{state['orientation']}"
            (out / (name + "-layout.json")).write_text(json.dumps(state, indent=2) + "\n")
            print(f"{name}: {state['columns']} × {state['rows']} cells, "
                  f"{state['keyboardHeight']:g} pt keyboard, {state['accessoryHeight']:g} pt accessory", flush=True)
            saved = geometry

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
                "-resultBundlePath", result], out / "ui-gestures.log", 720, observe_layout)
    finally:
        attempt("finalize gesture recording", recording.close)

    if result.exists():
        attempt("gesture attachments", export_attachments, result, out, work)
    gestures = ("rotate",) if rotation_only else CLIPS
    names = [f"{gesture}-{appearance}" for appearance in APPEARANCES for gesture in gestures]
    for name in names:
        attempt(name + ".mp4", export_clip, name, video_start, out, work)
    if all((out / (name + ".mp4")).is_file() for name in names):
        (out / "appearance-switch.mov").unlink()


def check_rotation_sizes(out, appearance):
    start, end = json.loads((out / f"rotate-{appearance}-motion.json").read_text())
    expected = []
    for orientation in ("landscape", "portrait"):
        layout = json.loads((out / f"shell-{appearance}-{orientation}-layout.json").read_text())
        expected.append((layout["columns"], layout["rows"]))
    actual = []
    for line in (out / "peer.log").read_text().splitlines():
        if not line.startswith("{"):
            continue
        event = json.loads(line)
        if (event.get("scene") == "shell" and event["event"] == "resize"
                and start <= event["time"] / 1000 <= end):
            actual.append((event["cols"], event["rows"]))
    if actual != expected:
        raise ValueError(f"{appearance} rotation sent {actual} to the shell; expected the settled grids {expected}.")


def check_images(out, appearances=APPEARANCES, pictures=PICS):
    oracle = load_helper("check-demo-capture")
    for appearance in appearances:
        for orientation in ("portrait", "landscape"):
            if not (out / f"shell-{appearance}-{orientation}-layout.json").exists():
                raise ValueError(f"Missing settled keyboard and grid measurements for {appearance} {orientation}.")
        check_rotation_sizes(out, appearance)
        for template in pictures:
            path = out / (template.format(appearance) + ".png")
            capture = oracle.Capture(path, appearance)
            if capture.count("background") < capture.width * capture.height * 0.04:
                raise ValueError(f"{path.name} has insufficient Slate terminal background.")
            if template.startswith(("word-", "line-")) and capture.count("selection") < 100:
                raise ValueError(f"{path.name} lacks the Metal selection.")
            if template.endswith("-landscape") and capture.count("passed") < 16:
                raise ValueError(f"{path.name} lost the green shell checks above the prompt during rotation.")
        run_logged([sys.executable, ROOT / "scripts/check-demo-capture.py", out / f"shell-{appearance}-portrait.png",
                    "shell", appearance], out / f"shell-{appearance}-pixels.log", 80)


def check_voiceover(phone, device, endpoint, plan, out, work):
    options = plistlib.loads(plan.read_bytes())
    options[RUNNER]["EnvironmentVariables"]["THRUSH_CAPTURE_ENDPOINT"] = endpoint
    plan.write_bytes(plistlib.dumps(options))
    result = work / "voiceover.xcresult"
    candidate = work / "large-type.png"
    captured = False

    def observe():
        nonlocal captured
        state = phone.state()
        if (captured or state.get("scene") != "notice-displaced" or not state.get("gpuCompleted")
                or not state.get("generation") or (state.get("notice") or {}).get("title") != "Open in another window"):
            return
        try:
            subprocess.run(["xcrun", "simctl", "io", device, "screenshot", "--mask=black", candidate],
                           capture_output=True, timeout=20, check=True)
        except (OSError, subprocess.SubprocessError) as error:
            captured = True
            (out / "large-type-framebuffer-error.log").write_text(str(error) + "\n")
            return
        if phone.state() == state:
            captured = True
            shutil.copyfile(candidate, out / "large-type-takeover.png")
            (out / "large-type-takeover-layout.json").write_text(json.dumps(state, indent=2) + "\n")

    try:
        run_logged(["xcodebuild", "test-without-building", "-xctestrun", plan, "-destination",
                    f"platform=iOS Simulator,id={device}", "-parallel-testing-enabled", "NO",
                    "-resultBundlePath", result], out / "voiceover.log", 600, observe)
    finally:
        for report in phone.state_path.parent.glob("accessibility-notice-*.json"):
            shutil.copyfile(report, out / report.name)
    for scene in ("ended", "displaced", "reconnecting"):
        report = json.loads((out / f"accessibility-notice-{scene}.json").read_text())
        if not any(event["voiceOverRunning"] for event in report["events"]):
            raise ValueError(f"UIKit did not observe VoiceOver running during {scene}.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="A new or empty directory for captures and logs.")
    parser.add_argument("--build-runner-only", action="store_true", help="Compile the gesture runner without booting a simulator.")
    scope = parser.add_mutually_exclusive_group()
    scope.add_argument("--accessibility-only", action="store_true",
                       help="Exercise VoiceOver and accessible pane controls on a fresh iPhone at the largest text size.")
    scope.add_argument("--rotation-only", action="store_true",
                       help="Capture keyboard-open rotation in both appearances and check the shell resize sequence.")
    options = parser.parse_args()
    sys.dont_write_bytecode = True
    os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    out = options.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if any(out.iterdir()):
        parser.error("Use an empty output directory.")
    with tempfile.TemporaryDirectory(prefix="thrush-iphone-interactions-") as scratch:
        work = Path(scratch)
        source = HERE / ("PaneVoiceOverProof.swift" if options.accessibility_only else RUNNER + ".swift")
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
        with simulator.peer(out, notices=options.accessibility_only) as endpoint, simulator.disposable_phone(out) as device:
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
                attempt("keyboard warm-up", phone.warm_keyboard, "dark")
                attempt("gesture capture", collect, phone, device, endpoint, plan, out, work, attempt, options.rotation_only)
                if options.rotation_only:
                    for appearance in APPEARANCES:
                        attempt(f"{appearance} rotation", check_images, out, (appearance,),
                                ("shell-{}-portrait", "shell-{}-landscape"))
                else:
                    attempt("interaction screenshots", check_images, out)
            if not options.rotation_only:
                attempt("UIKit tests", run_logged, ["scripts/check-ios-ui.sh", device], out / "uikit-tests.log", 720)
            if options.accessibility_only:
                log = (out / "uikit-tests.log").read_text()
                if "Reduce Motion=true Reduce Transparency=true System size=UICTContentSizeCategoryAccessibilityXXXL" not in log:
                    failures["accessibility settings"] = "UIKit did not observe both reduced effects and the largest text size."
            simulator.save_json(out / "checks.json", {"failures": failures})
            if failures:
                raise RuntimeError("Failed interaction checks: " + ", ".join(failures))
    if options.accessibility_only:
        print("Verified VoiceOver, Dynamic Type, Reduce Motion and Reduce Transparency on the mounted iPhone pane.")
    elif options.rotation_only:
        print("Verified keyboard-open iPhone rotation and shell resizes in both Slate appearances.")
    else:
        print("Captured the iPhone terminal, selection, controls, scrolling and rotation in both Slate appearances.")


if __name__ == "__main__":
    main()
