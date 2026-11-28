#!/usr/bin/env python3
"""Measure blinking text in the packaged Mac renderer, then burst-capture the styles scene in both
appearances, first blinking and then under Reduce Motion. Runs only on a disposable GitHub
runner, because it changes the Reduce Motion preference."""
import argparse
import os
from pathlib import Path
import random
import subprocess
import tempfile
import time

import proof
from proof import ROOT, Capture, capture, wait
import text_blink


def benchmark(bundle, out):
    report = out / "render.json"
    result = subprocess.run([bundle / "Contents/MacOS/ThrushProofs", "--benchmark", report],
                            cwd=ROOT, text=True, capture_output=True, timeout=150)
    (out / "render.log").write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError("Mac render benchmark failed: " + (result.stdout + result.stderr)[-1800:])
    subprocess.run([ROOT / "Benchmarks/check-render-report.py", report], check=True, timeout=60)


def burst(pid, folder, appearance, count):
    folder.mkdir(parents=True)
    probe = folder / "probe.png"

    def drawn():
        capture(pid, probe)
        try:
            return text_blink.Grid(Capture(probe, appearance))
        except ValueError:
            return None
    wait(f"the styles scene in {appearance}", drawn)
    time.sleep(0.7)
    frames = []
    for index in range(count):
        path = folder / f"{index:02}.png"
        capture(pid, path)
        frames.append(path)
        time.sleep(random.uniform(0.03, 0.29))
    return frames


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    opts = parser.parse_args()
    os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    out = opts.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if any(out.iterdir()):
        parser.error("Use an empty output directory.")
    if os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted":
        parser.error("This capture changes Reduce Motion and runs only on a disposable GitHub runner.")
    bundle = proof.mac_app(out)
    proof.prepare_hosted_motion(out)
    benchmark(bundle, out)
    bursts = {}
    with tempfile.TemporaryDirectory(dir=out.parent, prefix="thrush-text-blink-") as scratch, proof.peer(out) as endpoint:
        for reduced in (False, True):
            proof.prepare_hosted_motion(out, reduced=reduced)
            for appearance in ("dark", "light"):
                label = "steady" if reduced else "blinking"
                args = ["--endpoint", endpoint, "--scene", "styles", "--appearance", appearance]
                with proof.application(bundle, args, out / f"{appearance}-{label}-host.log") as process:
                    proof.window(process)
                    subprocess.run(["open", "-a", bundle], check=True)
                    bursts[appearance, label] = burst(process.pid, Path(scratch) / f"{appearance}-{label}", appearance,
                                                      text_blink.STEADY_FRAMES if reduced else text_blink.BLINKING_FRAMES)
                    if process.poll() is not None:
                        raise RuntimeError(f"The styles scene exited during the {appearance} burst.")
        proof.prepare_hosted_motion(out)
        text_blink.check_bursts(bursts, out)


if __name__ == "__main__":
    main()
