#!/usr/bin/env python3
"""Open the links scene's links with ⌘-clicks, tooltips and menus in the packaged Mac window, in both appearances."""
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
    parser.add_argument("--output", required=True, type=Path, help="A new or empty directory for captures and logs.")
    parser.add_argument("--build-only", action="store_true", help="Compile the runner without driving the proofs app.")
    args = parser.parse_args()
    os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if any(out.iterdir()):
        parser.error("Use an empty output directory.")
    with tempfile.TemporaryDirectory(prefix="thrush-links-mac-") as directory:
        work = Path(directory)
        name = "MacLinkProof"
        plan = capture.build_test_runner(work, out, capture.HERE / (name + ".swift"), mac=True, name=name)
        if args.build_only:
            return
        capture.run_logged(["scripts/build-app.sh", "proofs", "mac"], out / "app-build.log", 360)
        result = work / "result.xcresult"
        with capture.load_helper("capture-simulator").peer(out) as endpoint:
            settings = plistlib.loads(plan.read_bytes())
            settings[name]["EnvironmentVariables"].update(
                THRUSH_LINKS_APP=str(capture.ROOT / ".build/proofs/mac/Thrush.app"), THRUSH_CAPTURE_ENDPOINT=endpoint)
            plan.write_bytes(plistlib.dumps(settings))
            try:
                capture.run_logged(["xcodebuild", "test-without-building", "-xctestrun", plan,
                                    "-destination", "platform=macOS", "-parallel-testing-enabled", "NO",
                                    "-resultBundlePath", result], out / "links.log", 600)
            finally:
                if result.exists():
                    capture.export_attachments(result, out, work, ())
    print("Verified that Mac links open with a ⌘-click, show their menus and name their destinations.")


if __name__ == "__main__":
    main()
