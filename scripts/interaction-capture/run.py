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
# The capture turns to landscape and back twice, since a stalled main thread can miss a turn's frames.
ROUND_TRIPS = 2
DISPLAY_FRAME = 1 / 60


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


def export_attachments(result, out, work, frame_times):
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
            if is_frame:
                frame_times[name] = attachment["timestamp"]
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


def save_rotation_layouts(out, appearance, spans, frame_times):
    start, end = json.loads((out / f"rotate-{appearance}-motion.json").read_text())
    portrait = frame_times[f"shell-{appearance}-portrait"]
    landscape = frame_times[f"shell-{appearance}-landscape"]
    if not portrait <= start < landscape < end:
        raise ValueError(f"{appearance}: screenshot times do not bracket the two orientation changes.")

    pid = None
    for stage, when in (("portrait", portrait), ("landscape", landscape), ("portrait-return", end)):
        # A span ends at the first poll with a different geometry, an unqualified drawing or a different PID.
        span = next((span for span in reversed(spans) if span[0][0] <= when), None)
        if span is None or when > spans[-1][-1][0]:
            raise ValueError(f"{appearance} {stage}: no observed layout at the XCTest checkpoint.")
        observed, state = next(sample for sample in reversed(span) if sample[0] <= when)
        orientation = "portrait" if stage == "portrait-return" else stage
        if (state is None or state["appearance"] != appearance or state["orientation"] != orientation
                or span[-1][0] - span[0][0] < 0.7 or (pid is not None and state["pid"] != pid)):
            measured = (state["pid"], state["appearance"], state["orientation"]) if state else None
            raise ValueError(f"{appearance} {stage}: expected a stable completed layout at {when}; "
                             f"observed {measured} for {span[-1][0] - span[0][0]:.3f}s, shell PID {pid}.")
        pid = state["pid"]
        name = f"shell-{appearance}-{stage}"
        evidence = dict(state, checkpointTime=when, observedAt=observed)
        (out / (name + "-layout.json")).write_text(json.dumps(evidence, indent=2) + "\n")
        print(f"{name}: PID {pid}, {state['columns']} × {state['rows']} cells, "
              f"{state['keyboardHeight']:g} pt keyboard", flush=True)


def collect(phone, device, endpoint, plan, out, work, attempt, rotation_only=False, trace_layout=False):
    configuration = plistlib.loads(plan.read_bytes())
    environment = configuration[RUNNER]["EnvironmentVariables"]
    environment["THRUSH_CAPTURE_ENDPOINT"] = endpoint
    environment["THRUSH_CAPTURE_ROTATION_ONLY"] = "1" if rotation_only else "0"
    environment["THRUSH_TRACE_ROTATION_LAYOUT"] = "1" if trace_layout else "0"
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
        frame_times = {}
        attempt("gesture attachments", export_attachments, result, out, work, frame_times)
        for appearance in APPEARANCES:
            attempt(f"{appearance} rotation layouts", save_rotation_layouts, out, appearance, spans, frame_times)
    gestures = ("rotate",) if rotation_only else CLIPS
    names = [f"{gesture}-{appearance}" for appearance in APPEARANCES for gesture in gestures]
    for name in names:
        attempt(name + ".mp4", export_clip, name, video_start, out, work)
    if all((out / (name + ".mp4")).is_file() for name in names):
        (out / "appearance-switch.mov").unlink()


def collect_layout_traces(phone, out):
    traces = list(phone.state_path.parent.glob("rotation-layout-*.jsonl"))
    for trace in traces:
        shutil.copyfile(trace, out / trace.name)
    if not traces or any(trace.stat().st_size == 0 for trace in traces):
        raise ValueError("The shell did not save a populated rotation layout trace for each traced process.")


def check_keyboard_release(out, appearance):
    start, end = json.loads((out / f"rotate-{appearance}-motion.json").read_text())
    landscape = json.loads((out / f"shell-{appearance}-landscape-layout.json").read_text())
    trace = out / f"rotation-layout-{landscape['pid']}.jsonl"
    events = [json.loads(line) for line in trace.read_text().splitlines()]
    for orientation, stage in (("landscape", "landscape"), ("portrait", "portrait-return")):
        settled = json.loads((out / f"shell-{appearance}-{stage}-layout.json").read_text())
        expected = (settled["columns"], settled["rows"])
        # The proof's full-screen window starts at the screen origin. The docked keyboard
        # fills its width and ends at its bottom edge in each settled orientation.
        _, (width, height) = settled["windowPoints"]
        keyboard = settled["keyboardHeight"]
        box = ((0, height - keyboard), (width, keyboard))
        pixel = 1 / settled["displayScale"]

        def matches(rect):
            return rect and all(abs(value - target) <= pixel for pair, expected_pair in zip(rect, box)
                                for value, target in zip(pair, expected_pair))

        for event in events:
            layout = event.get("layout") or {}
            if (start <= event["time"] <= end and event["source"] in
                    ("UIKeyboardWillChangeFrameNotification", "UIKeyboardDidChangeFrameNotification")
                    and layout.get("appearance") == appearance and layout.get("orientation", "").startswith(orientation)
                    and matches(event.get("keyboardEndFrameInScreen")) and matches(layout.get("keyboardGuideInWindow"))):
                break
        else:
            raise ValueError(f"{appearance} {orientation}: no destination keyboard frame matched the settled guide.")
        delivered = next((sample for sample in events if sample.get("afterNotificationAt") == event["time"]), None)
        if not delivered:
            raise ValueError(f"{appearance} {orientation}: missing post-delivery sample for {event['source']}.")
        grid = delivered.get("layout") or {}
        actual = (grid.get("columns"), grid.get("rows"))
        if actual != expected:
            raise ValueError(f"{appearance} {orientation}: grid was {actual} immediately after the first matching "
                             f"keyboard frame; expected {expected}.")
        # The motion starts in portrait; only the subsequent return belongs to the second check.
        start = event["time"]


def begun(animation):
    """Whether an animation has begun in its layer's own time.

    UIKit can hold the turn's transaction until the keyboard lays out for the new orientation, leaving
    each begin time at 0, and it can begin the turn later in the layer's time. Until then the screen
    keeps the previous frame, and the app's presentation layers describe nothing that was drawn.
    """
    return animation["beginTime"] != 0 and animation["layerTime"] >= animation["beginTime"]


def finished(animation):
    return begun(animation) and animation["layerTime"] >= animation["beginTime"] + animation["duration"]


def check_anchored_row(out, appearance):
    """Every displayed frame keeps the reader's row visible and never jumps it against its viewport.

    UIKit animates the viewport's edges with the rotation and the keyboard on separate curves, so a row
    gliding between its source and destination places can lead or trail both edges by a few points. A
    frame fails when the row moves further than either edge carried it and also shifts more than half a
    row against each edge for every display frame since the previous sample, which no eased glide does.

    Samples taken before the window's turn begins are skipped, because the screen still shows the previous
    frame. UIKit can hold the turn until the keyboard lays out, and after a stall the main thread can read
    a turn further along than the one the screen then begins, so a sample further from where its turn
    settles than a later one is skipped too. So is one sample per turn whose row doesn't span its viewport.
    Every commit lays out the whole tree, so it caught the main thread between layout passes, in a state the
    screen never shows. Each direction must be sampled while it turns, and each turn's last sample is its
    settled frame and is never skipped. The system animates the accessory on its own, so the row is held
    above the accessory only once those animations finish.
    """
    start, end = json.loads((out / f"rotate-{appearance}-motion.json").read_text())
    landscape = json.loads((out / f"shell-{appearance}-landscape-layout.json").read_text())
    trace = out / f"rotation-layout-{landscape['pid']}.jsonl"
    frames = []
    for line in trace.read_text().splitlines():
        event = json.loads(line)
        if (event["source"] == "accessory.display" and event.get("anchor") and start <= event["time"] <= end
                and (event.get("layout") or {}).get("appearance") == appearance):
            frames.append(event)

    def width(event):
        return event["anchor"]["viewportInWindow"][1][0]

    def held(event):
        return event.get("ahead") or not all(map(begun, event["animations"]["window"]))

    def mid_layout(event):
        (_, (row_width, _)), (_, (viewport_width, _)) = (event["anchor"]["rowInWindow"],
                                                         event["anchor"]["viewportInWindow"])
        return abs(row_width - viewport_width) > 1

    # A turn runs from the first sample with the window's turn animations through its settled samples.
    turns = []
    for event in frames:
        if not turns or (event["animations"]["window"] and not turns[-1][-1]["animations"]["window"]):
            turns.append([])
        turns[-1].append(event)
    for turn in turns:
        settled = width(turn[-1])
        for index, event in enumerate(turn):
            event["ahead"] = any(abs(width(later) - settled) > abs(width(event) - settled) + 1
                                 for later in turn[index + 1:])
        when = f"{appearance} turn settling at {turn[-1]['time'] - start:.3f}s"
        if held(turn[-1]) or mid_layout(turn[-1]):
            raise ValueError(f"{when} ended on a sample the screen never showed.")
        if sum(map(mid_layout, turn)) > 1:
            raise ValueError(f"{when} had more than one sample read between layout passes.")
    turned = [turn for turn in turns if any(event["animations"]["window"] for event in turn)]
    directions = {(turn[-1]["anchor"]["columns"], turn[-1]["anchor"]["rows"]) for turn in turned}
    if len(directions) != 2:
        raise ValueError(f"{appearance}: the trace sampled {len(turned)} of the capture's {2 * ROUND_TRIPS} turns "
                         f"while they turned, settling only in {sorted(directions)}.")
    skipped = sum(map(held, frames))
    partial = sum(1 for event in frames if not held(event) and mid_layout(event))
    frames = [event for event in frames if not held(event) and not mid_layout(event)]
    if len(frames) < 30:
        raise ValueError(f"{appearance}: only {len(frames)} displayed frames recorded the anchored row.")
    reference = frames[0]["anchor"]
    if reference["kind"] != "prompt" or not reference["text"]:
        raise ValueError(f"{appearance}: the turn began anchored to {reference['kind']} row {reference['text']!r}.")

    def span(rect):
        (_, y), (_, height) = rect
        return y, y + height

    previous = None
    for event in frames:
        anchor = event["anchor"]
        top, bottom = span(anchor["rowInWindow"])
        visible_top, visible_bottom = span(anchor["viewportInWindow"])
        when = f"{appearance} frame at {event['time'] - start:.3f}s ({anchor['columns']} × {anchor['rows']})"
        if (anchor["kind"], anchor["text"]) != (reference["kind"], reference["text"]):
            raise ValueError(f"{when} anchored {anchor['kind']} row {anchor['row']} {anchor['text']!r} "
                             f"instead of {reference['text']!r}.")
        settled = all(map(finished, event["animations"]["accessory"]))
        accessory = anchor.get("accessoryTopInWindow") if settled else None
        if top < visible_top - 1 or bottom > visible_bottom + 1 or (accessory is not None and bottom > accessory + 1):
            raise ValueError(f"{when} drew {reference['text']!r} at {top:g}–{bottom:g} pt, outside the viewport "
                             f"{visible_top:g}–{visible_bottom:g} pt above the accessory at {accessory}.")
        if previous:
            moved = abs(top - previous[0])
            carried = max(abs(visible_top - previous[1]), abs(visible_bottom - previous[2]))
            shifted = min(abs(top - visible_top - previous[0] + previous[1]),
                          abs(top - visible_bottom - previous[0] + previous[2]))
            elapsed = max(1, round((event["time"] - previous[3]) / DISPLAY_FRAME))
            if moved > carried + 1 and shifted > (bottom - top) / 2 * elapsed:
                raise ValueError(f"{when} moved {reference['text']!r} {moved:g} pt while its viewport moved {carried:g} pt, "
                                 f"shifting it {shifted:g} pt against both of the viewport's edges "
                                 f"in {elapsed} display frames.")
        previous = (top, visible_top, visible_bottom, event["time"])
    print(f"{appearance} anchored row: {len(frames)} displayed frames across {len(turned)} turns kept "
          f"{reference['text']!r} in view and never jumped it against the viewport, skipping {skipped} "
          f"before the turn began and {partial} read between layout passes.", flush=True)


def check_rotation_sizes(out, appearance):
    start, end = json.loads((out / f"rotate-{appearance}-motion.json").read_text())
    expected = []
    for stage in ("landscape", "portrait-return"):
        layout = json.loads((out / f"shell-{appearance}-{stage}-layout.json").read_text())
        expected.append((layout["columns"], layout["rows"]))
    expected *= ROUND_TRIPS
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
    parser.add_argument("--trace-rotation-layout", action="store_true",
                        help="Record UIKit geometry, keyboard notifications and the anchored row of each displayed frame "
                             "during the shell gestures, and check them through rotation.")
    scope = parser.add_mutually_exclusive_group()
    scope.add_argument("--accessibility-only", action="store_true",
                       help="Exercise VoiceOver and accessible pane controls on a fresh iPhone at the largest text size.")
    scope.add_argument("--rotation-only", action="store_true",
                       help="Capture keyboard-open rotation in both appearances and check the shell resize sequence.")
    options = parser.parse_args()
    if options.accessibility_only and options.trace_rotation_layout:
        parser.error("--trace-rotation-layout applies to shell gestures.")
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
        with simulator.peer(out, cursor=options.accessibility_only) as endpoint, simulator.disposable_phone(out) as device:
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
                attempt("keyboard warm-up", phone.warm_keyboard, "dark")
                attempt("gesture capture", collect, phone, device, endpoint, plan, out, work, attempt,
                        options.rotation_only, options.trace_rotation_layout)
                if options.trace_rotation_layout:
                    attempt("rotation layout traces", collect_layout_traces, phone, out)
                    for appearance in APPEARANCES:
                        attempt(f"{appearance} keyboard release", check_keyboard_release, out, appearance)
                        attempt(f"{appearance} anchored row", check_anchored_row, out, appearance)
                if options.rotation_only:
                    for appearance in APPEARANCES:
                        attempt(f"{appearance} rotation", check_images, out, (appearance,),
                                ("shell-{}-portrait", "shell-{}-landscape"))
                else:
                    attempt("interaction screenshots", check_images, out)
            if not options.rotation_only:
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
    elif options.rotation_only:
        print("Verified keyboard-open iPhone rotation and shell resizes in both Slate appearances.")
    else:
        print("Captured the iPhone terminal, selection, controls, scrolling and rotation in both Slate appearances.")


if __name__ == "__main__":
    main()
