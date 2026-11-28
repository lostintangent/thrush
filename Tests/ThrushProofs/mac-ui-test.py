#!/usr/bin/env python3
"""Run one Mac UI test against the packaged proofs app. `links` opens the links scene's links with
⌘-clicks, tooltips and menus in both appearances. `voiceover` has VoiceOver read a known row, turning it
on for the test. Both drive this Mac's pointer and keyboard."""
import argparse
import os
from pathlib import Path
import tempfile

import proof

TESTS = {"links": "MacLinkProof", "voiceover": "MacVoiceOverProof"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("test", choices=TESTS)
    parser.add_argument("--output", required=True, type=Path, help="A new or empty directory for captures and logs.")
    parser.add_argument("--build-only", action="store_true", help="Compile the test without driving the proofs app.")
    args = parser.parse_args()
    os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if any(out.iterdir()):
        parser.error("Use an empty output directory.")
    with tempfile.TemporaryDirectory(prefix="thrush-mac-ui-test-") as directory:
        work = Path(directory)
        plan = proof.build_test_runner(work, out, proof.HERE / "UITests" / (TESTS[args.test] + ".swift"), mac=True)
        if args.build_only:
            return
        bundle = proof.mac_app(out)
        result = work / "result.xcresult"
        with proof.peer(out) as endpoint:
            proof.configure(plan, THRUSH_PROOFS_APP=str(bundle), THRUSH_CAPTURE_ENDPOINT=endpoint)
            try:
                proof.run_logged(["xcodebuild", "test-without-building", "-xctestrun", plan,
                                  "-destination", "platform=macOS", "-parallel-testing-enabled", "NO",
                                  "-resultBundlePath", result], out / (args.test + ".log"), 600)
            finally:
                if result.exists():
                    proof.export_attachments(result, out, work, ())
    print(f"{TESTS[args.test]} passed.")


if __name__ == "__main__":
    main()
