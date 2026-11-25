#!/usr/bin/env python3
"""Ask the native macOS VoiceOver service to read a known row in the packaged terminal."""
import argparse
import os
from pathlib import Path
import plistlib
import sys
import tempfile

sys.dont_write_bytecode = True
import run as capture


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--build-only", action="store_true")
    mode.add_argument("--run-on-this-mac", action="store_true",
                        help="Temporarily enable VoiceOver and drive the sample terminal on this Mac.")
    args = parser.parse_args()
    os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="thrush-voiceover-mac-") as directory:
        work = Path(directory)
        name = "MacVoiceOverProof"
        plan = capture.build_test_runner(work, out, capture.HERE / (name + ".swift"), mac=True, name=name)
        if args.build_only:
            return
        capture.run_logged(["scripts/build-demo.sh", "mac"], out / "app-build.log", 360)
        with capture.load_helper("capture-simulator").peer(out) as endpoint:
            settings = plistlib.loads(plan.read_bytes())
            settings[name]["EnvironmentVariables"].update(
                THRUSH_VOICEOVER_APP=str(capture.ROOT / ".build/demo/mac/Thrush.app"),
                THRUSH_CAPTURE_ENDPOINT=endpoint)
            plan.write_bytes(plistlib.dumps(settings))
            capture.run_logged(["xcodebuild", "test-without-building", "-xctestrun", plan,
                                "-destination", "platform=macOS", "-parallel-testing-enabled", "NO",
                                "-resultBundlePath", work / "result.xcresult"], out / "voiceover.log", 600)


if __name__ == "__main__":
    main()
