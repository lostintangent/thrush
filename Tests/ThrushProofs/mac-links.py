#!/usr/bin/env python3
"""Open the links scene's links with ⌘-clicks, tooltips and menus in the packaged Mac window, in both appearances."""
import argparse
import os
from pathlib import Path
import tempfile

import proof


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
        plan = proof.build_test_runner(work, out, proof.HERE / "UITests" / (name + ".swift"), mac=True)
        if args.build_only:
            return
        proof.run_logged(["scripts/build-app.sh", "proofs", "mac"], out / "app-build.log", 360)
        result = work / "result.xcresult"
        with proof.peer(out) as endpoint:
            proof.configure(plan, THRUSH_LINKS_APP=str(proof.ROOT / ".build/proofs/mac/Thrush.app"),
                            THRUSH_CAPTURE_ENDPOINT=endpoint)
            try:
                proof.run_logged(["xcodebuild", "test-without-building", "-xctestrun", plan,
                                  "-destination", "platform=macOS", "-parallel-testing-enabled", "NO",
                                  "-resultBundlePath", result], out / "links.log", 600)
            finally:
                if result.exists():
                    proof.export_attachments(result, out, work, ())
    print("Verified that Mac links open with a ⌘-click, show their menus and name their destinations.")


if __name__ == "__main__":
    main()
