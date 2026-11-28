#!/usr/bin/env python3
"""Sample ThrushCore on each comparison workload and rank its functions by self time.

Each workload runs at 80×24 in 4 KiB chunks while macOS `sample` records it for 3 seconds. Inlined
code counts toward the function it was inlined into. The Comparison profile workflow runs this on a
hosted Mac.

Usage: python3 scripts/comparison/profile.py [--output .build/benchmarks/comparison-profile.json]
"""

import argparse
import json
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

sys.dont_write_bytecode = True  # A clean checkout stays clean, so the report's revision is exact.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import workloads  # noqa: E402
from run import CHUNK, HISTORY, ROOT, environment, log  # noqa: E402

SECONDS = 3


def profile(binary, workload, out):
    process = subprocess.Popen([binary, "--workload", workload["path"], "80", "24", str(CHUNK), "1", "1000000",
                                str(HISTORY)], stdout=subprocess.DEVNULL)
    time.sleep(1)
    report = out / f"profile-{workload['name']}.txt"
    try:
        subprocess.run(["sample", str(process.pid), str(SECONDS), "1", "-mayDie", "-file", report],
                       check=True, capture_output=True)
    finally:
        process.kill()
        process.wait()
    return rank(report.read_text())


def rank(report):
    """Reads the self-time ranking from a sample report as each function's share of main-thread samples."""
    lines = report.splitlines()
    total = next(int(match.group(1)) for line in lines
                 if (match := re.match(r"\s*(\d+) Thread_\d+.*main-thread", line)))
    start = next(index for index, line in enumerate(lines) if line.startswith("Sort by top of stack"))
    functions = []
    for line in lines[start + 1:]:
        match = re.match(r"\s+(.+?)\s+\(in (.+?)\)\s+(\d+)$", line)
        if not match:
            break
        functions.append({"name": match.group(1), "image": match.group(2), "share": int(match.group(3)) / total})
    return {"samples": total, "functions": functions[:20]}


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--output", type=Path, default=ROOT / ".build" / "benchmarks" / "comparison-profile.json")
    options = parser.parse_args()

    log("Building ThrushBench in Release")
    subprocess.run(["swift", "build", "-c", "release", "--product", "ThrushBench"], cwd=ROOT, check=True,
                   stdout=subprocess.DEVNULL)
    out = ROOT / ".build" / "comparison"
    inputs = workloads.write(out / "workloads")
    report = {
        "schemaVersion": 1,
        "recordedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "environment": environment(),
        "method": {"columns": 80, "rows": 24, "chunkBytes": CHUNK, "historyRows": HISTORY, "seconds": SECONDS},
        "workloads": [{key: value for key, value in workload.items() if key != "path"} for workload in inputs],
        "profile": {},
    }
    for workload in inputs:
        ranking = report["profile"][workload["name"]] = profile(ROOT / ".build" / "release" / "ThrushBench",
                                                                workload, out)
        top = ", ".join(f"{function['name']} {function['share']:.0%}" for function in ranking["functions"][:3])
        print(f"{workload['name']} ({ranking['samples']} samples): {top}", flush=True)
    options.output.parent.mkdir(parents=True, exist_ok=True)
    options.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print(f"Report {options.output}")


if __name__ == "__main__":
    main()
