#!/usr/bin/env python3
"""Ask the native macOS VoiceOver service to read a known row in the packaged terminal."""
import argparse
import os
from pathlib import Path
import tempfile

import proof


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
        plan = proof.build_test_runner(work, out, proof.HERE / "UITests" / (name + ".swift"), mac=True)
        if args.build_only:
            return
        proof.run_logged(["scripts/build-app.sh", "proofs", "mac"], out / "app-build.log", 360)
        with proof.peer(out) as endpoint:
            proof.configure(plan, THRUSH_VOICEOVER_APP=str(proof.ROOT / ".build/proofs/mac/Thrush.app"),
                            THRUSH_CAPTURE_ENDPOINT=endpoint)
            proof.run_logged(["xcodebuild", "test-without-building", "-xctestrun", plan,
                              "-destination", "platform=macOS", "-parallel-testing-enabled", "NO",
                              "-resultBundlePath", work / "result.xcresult"], out / "voiceover.log", 600)


if __name__ == "__main__":
    main()
