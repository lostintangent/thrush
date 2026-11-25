#!/usr/bin/env python3
"""Record real iPhone terminal interactions from the packaged app on a disposable simulator."""
import argparse
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


def run_logged(args, log, timeout, **kwargs):
    with log.open("w") as output:
        result = subprocess.run(args, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT, timeout=timeout, **kwargs)
    if result.returncode:
        raise RuntimeError(f"{args[0]} exited {result.returncode}. See {log.name}.\n" + log.read_text()[-2800:])


def build_test_runner(work, out):
    # XCUITest needs a UI-test bundle. Keep the product and its generated project inside
    # the disposable build directory; the real app is always the normal SwiftPM bundle.
    project = work / (RUNNER + ".xcodeproj")
    shared = project / "xcshareddata/xcschemes"
    shared.mkdir(parents=True)
    (work / (RUNNER + ".swift")).symlink_to(HERE / (RUNNER + ".swift"))
    objects = {}

    def item(key, isa, **values):
        objects[key] = {"isa": isa, **values}

    item("PROJECT", "PBXProject", mainGroup="GROUP", productRefGroup="PRODUCTS", buildConfigurationList="CFG",
         targets=["TARGET"], projectDirPath="", projectRoot="", compatibilityVersion="Xcode 14.0",
         developmentRegion="en", knownRegions=["en", "Base"])
    item("GROUP", "PBXGroup", children=["SOURCE", "PRODUCTS"], sourceTree="<group>")
    item("PRODUCTS", "PBXGroup", children=["BUNDLE"], name="Products", sourceTree="<group>")
    item("SOURCE", "PBXFileReference", lastKnownFileType="sourcecode.swift", path=RUNNER + ".swift", sourceTree="<group>")
    item("BUNDLE", "PBXFileReference", explicitFileType="wrapper.cfbundle", path=RUNNER + ".xctest",
         sourceTree="BUILT_PRODUCTS_DIR")
    item("TARGET", "PBXNativeTarget", name=RUNNER, productName=RUNNER, productReference="BUNDLE",
         productType="com.apple.product-type.bundle.ui-testing", buildConfigurationList="TARGETCFG",
         buildPhases=["COMPILE", "LINK"], buildRules=[], dependencies=[])
    item("TEST", "PBXBuildFile", fileRef="SOURCE")
    for key, kind, files in [("COMPILE", "PBXSourcesBuildPhase", ["TEST"]), ("LINK", "PBXFrameworksBuildPhase", [])]:
        item(key, kind, buildActionMask="2147483647", files=files, runOnlyForDeploymentPostprocessing="0")
    for key, debug, settings in [
        ("CFG", "DEBUG", dict(SDKROOT="iphoneos", IPHONEOS_DEPLOYMENT_TARGET="27.0", SWIFT_VERSION="5.0",
                             CLANG_ENABLE_MODULES="YES", TARGETED_DEVICE_FAMILY="1")),
        ("TARGETCFG", "TARGETDEBUG", dict(PRODUCT_NAME=RUNNER, PRODUCT_BUNDLE_IDENTIFIER=BUNDLE_ID,
                                         GENERATE_INFOPLIST_FILE="YES", CODE_SIGN_IDENTITY="-")),
    ]:
        item(key, "XCConfigurationList", buildConfigurations=[debug], defaultConfigurationIsVisible="0",
             defaultConfigurationName="Debug")
        item(debug, "XCBuildConfiguration", name="Debug", buildSettings=settings)
    with (project / "project.pbxproj").open("wb") as file:
        plistlib.dump(dict(archiveVersion="1", objectVersion="56", classes={}, objects=objects, rootObject="PROJECT"), file)
    ref = (f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="TARGET" '
           f'BuildableName="{RUNNER}.xctest" BlueprintName="{RUNNER}" ReferencedContainer="container:{project.name}"/>')
    (shared / (RUNNER + ".xcscheme")).write_text(f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme version="1.7">
  <BuildAction parallelizeBuildables="NO" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{ref}</BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug"><Testables><TestableReference skipped="NO">{ref}</TestableReference></Testables></TestAction>
</Scheme>
""")
    derived = work / "DerivedData"
    run_logged(["xcodebuild", "-project", project, "-scheme", RUNNER, "-derivedDataPath", derived,
                "-destination", "generic/platform=iOS Simulator", "build-for-testing"], out / "runner-build.log", 300)
    return next((derived / "Build/Products").glob("*.xctestrun"))


def collect(phone, device, endpoint, plan, out, work):
    configuration = plistlib.loads(plan.read_bytes())
    configuration[RUNNER]["EnvironmentVariables"]["THRUSH_CAPTURE_ENDPOINT"] = endpoint
    plan.write_bytes(plistlib.dumps(configuration))
    result = work / "interactions.xcresult"

    # The runner timestamps just the gestures in the foreground app. Trim setup, launches
    # and XCTest's transitions out of the simulator's recording before handing it to design.
    with phone.record_switch():
        video_start = time.time()
        try:
            run_logged(["xcodebuild", "test-without-building", "-xctestrun", plan, "-destination",
                        f"platform=iOS Simulator,id={device}", "-parallel-testing-enabled", "NO",
                        "-resultBundlePath", result], out / "ui-gestures.log", 360)
        finally:
            if result.exists():
                # XCTest retains accepted frames even when a subsequent gesture fails. Read
                # the manifest instead of depending on Xcode's opaque exported filenames.
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

    movie = out / "appearance-switch.mov"
    for appearance in APPEARANCES:
        for clip in CLIPS:
            name = clip + "-" + appearance
            start, end = json.loads((out / (name + "-motion.json")).read_text())
            if not 0 < end - start <= 60 or start < video_start - 1:
                raise ValueError(f"Invalid capture interval for {name}: {start}, {end}")
            run_logged(["/usr/bin/avconvert", "--source", movie, "--output", out / (name + ".mp4"),
                        "--preset", "PresetHighestQuality", "--start", str(max(0, start - video_start - 0.25)),
                        "--duration", str(end - start + 0.5)], work / (name + ".log"), 90)
    movie.unlink()


def check_images(out):
    oracle = load_helper("check-demo-capture")
    for appearance in APPEARANCES:
        for template in PICS:
            path = out / (template.format(appearance) + ".png")
            capture = oracle.Capture(path, appearance)
            if capture.count("background") < capture.width * capture.height * 0.04:
                raise ValueError(f"{path.name} has insufficient Slate terminal background.")
            if template.startswith(("word-", "line-")) and capture.count("selection") < 100:
                raise ValueError(f"{path.name} lacks the Metal selection.")
        run_logged([sys.executable, ROOT / "scripts/check-demo-capture.py", out / f"shell-{appearance}-portrait.png",
                    "shell", appearance], out / f"shell-{appearance}-pixels.log", 80)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="A new or empty directory for captures and logs.")
    parser.add_argument("--build-runner-only", action="store_true", help="Compile the gesture runner without booting a simulator.")
    options = parser.parse_args()
    sys.dont_write_bytecode = True
    os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    out = options.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if any(out.iterdir()):
        parser.error("Use an empty output directory.")
    with tempfile.TemporaryDirectory(prefix="thrush-iphone-interactions-") as scratch:
        work = Path(scratch)
        plan = build_test_runner(work, out)
        if options.build_runner_only:
            print("Compiled the native iPhone interaction runner.")
            return

        simulator = load_helper("capture-simulator")
        run_logged(["scripts/build-demo.sh", "simulator"], out / "app-build.log", 480)
        app = ROOT / ".build/demo/simulator/Thrush.app"
        info = plistlib.loads((app / "Info.plist").read_bytes())
        simulator.save_json(out / "source.json", dict(commit=info["ThrushGitCommit"], dirty=info["ThrushWorktreeDirty"],
                                                       toolchain=info["ThrushToolchain"]))
        with simulator.disposable_phone(out) as device, simulator.peer(out) as endpoint:
            run_logged(["scripts/check-ios-ui.sh", device], out / "uikit-tests.log", 360)
            phone = simulator.Phone(device, endpoint, app, out, work)
            try:
                collect(phone, device, endpoint, plan, out, work)
                check_images(out)
            except Exception:
                simulator.sim("io", device, "screenshot", "--mask=black", str(out / "failure.png"),
                              timeout=20, check=False)
                raise
    print("Captured the iPhone terminal, selection, controls, scrolling and rotation in both Slate appearances.")


if __name__ == "__main__":
    main()
