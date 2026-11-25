#!/usr/bin/env python3
"""Collect five consecutive quiet Release runs of the M1 first-bytes fixture."""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
from statistics import median
import subprocess
import tempfile
import time


WORKLOAD_SHA256 = "9bc23bc2916fc72d27c5f86d27e9fae0099efe168c1dc5688df802d121372ec2"
COUNTS = {"receivedBytes": 150_000, "appliedBytes": 150_000, "replyBytes": 36_000,
          "keyBytes": 18_000, "queuedBytesAfterDrain": 0}


def measured_fixture_sha256(path):
    """Pin the M1 workload and return the exact file digest that ThrushBench must report."""
    contents = path.read_bytes()
    fixture = json.loads(contents)
    if not isinstance(fixture, dict):
        raise ValueError("expected an M1 first-bytes fixture object")
    fixture.pop("reference", None)  # The recording's provenance can change independently.
    workload = json.dumps(fixture, sort_keys=True, separators=(",", ":")).encode()
    if hashlib.sha256(workload).hexdigest() != WORKLOAD_SHA256:
        raise ValueError("SOURCE does not contain the M1 first-bytes workload")
    return hashlib.sha256(contents).hexdigest()


def validate(report, revision, fixture_sha256):
    env, replay = report["environment"], report["replay"]
    if env["commit"] != revision or env["worktreeDirty"] is not False:
        raise ValueError(f"report did not measure the clean source revision {revision}")
    if (report["buildConfiguration"] != "release" or report["fixture"] != "first-bytes.json"
            or report["fixtureSHA256"] != fixture_sha256):
        raise ValueError("report does not match the Release build and M1 fixture")
    for key, expected in COUNTS.items():
        if replay[key] != expected:
            raise ValueError(f"{key}: expected {expected}, got {replay[key]}")
    load, cores = env["loadAverage"]["oneMinute"], env["coreCount"]
    if (not math.isfinite(load) or load < 0 or type(cores) is not int or cores < 1
            or env["contended"] is not (load > cores)):
        raise ValueError(f"inconsistent contention sample: {load} load, {cores} active CPUs, {env['contended']=}")
    return not env["contended"]


def collect(binary, source, stage, revision, fixture_sha256, cores):
    deadline = time.monotonic() + 15 * 60
    reports = []
    candidate = stage / "candidate.json"
    while len(reports) < 5:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("did not obtain five consecutive quiet runs within 15 minutes")
        load = os.getloadavg()[0]
        if load > cores:
            print(f"Waiting for load {load:.2f} to settle to {cores} active CPUs; restarting series.", flush=True)
            reports.clear()
            time.sleep(min(15, remaining))
            continue

        subprocess.run([binary, "--output", candidate], cwd=source, check=True, timeout=remaining,
                       stdout=subprocess.DEVNULL)
        report = json.loads(candidate.read_bytes())
        quiet = validate(report, revision, fixture_sha256)
        env = report["environment"]
        print(f"Load {env['loadAverage']['oneMinute']:.2f}/{env['coreCount']}, thermal {env['thermalState']}: "
              + (f"quiet run {len(reports) + 1}/5" if quiet else "contended; restarting series"), flush=True)
        if quiet:
            reports.append(report)
            candidate.replace(stage / f"run-{len(reports)}.json")
        else:
            candidate.unlink()
            reports.clear()
    return reports


def summarize(reports):
    metrics = {}
    for report in reports:
        replay = report["replay"]
        ops = {op["name"]: op["timing"] for op in replay["operations"]}
        for name, value in (("Receive (MiB/s)", replay["receiveMiBPerSecond"]),
                            ("Shell prompt p95 (ns)", ops["Shell prompt"]["p95Nanoseconds"]),
                            ("Complete cursor query p95 (ns)", ops["Complete cursor query"]["p95Nanoseconds"]),
                            ("Burst drain p95 (ns)", replay["burstDrain"]["p95Nanoseconds"])):
            if not math.isfinite(value) or value < 0:
                raise ValueError(f"invalid {name}: {value}")
            metrics.setdefault(name, []).append(value)
    for name, samples in metrics.items():
        low, high, middle = min(samples), max(samples), median(samples)
        span = high - low
        percent = f"{100 * span / middle:.2f}% of median" if middle else "percentage undefined for zero median"
        print(f"{name}: median {middle:g}, min–max {low:g}–{high:g}, range {span:g} ({percent})")
    throughputs = metrics["Receive (MiB/s)"]
    print(f"Median-throughput report: run-{throughputs.index(median(throughputs)) + 1}.json")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="clean checkout of the revision to measure")
    parser.add_argument("output", type=Path, help="new or empty directory outside that checkout")
    args = parser.parse_args()
    source, output = args.source.resolve(), args.output.resolve()
    git = ["git", "--no-optional-locks", "-C", source]
    if Path(subprocess.check_output([*git, "rev-parse", "--show-toplevel"], text=True).strip()).resolve() != source:
        parser.error("SOURCE must be the root of the measured checkout")
    if subprocess.check_output([*git, "status", "--porcelain"]):
        parser.error("SOURCE must be clean")
    if output == source or source in output.parents:
        parser.error("OUTPUT must be outside SOURCE")
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        parser.error("OUTPUT must be a new or empty directory")
    try:
        fixture_sha256 = measured_fixture_sha256(source / "Fixtures/first-bytes.json")
    except (OSError, ValueError) as error:
        parser.error(str(error))
    revision = subprocess.check_output([*git, "rev-parse", "HEAD"], text=True).strip()
    cores = int(subprocess.check_output(["/usr/sbin/sysctl", "-n", "hw.activecpu"], text=True))
    if cores <= 0:
        parser.error("could not determine a positive active CPU count")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent, prefix=".first-bytes-") as scratch:
        stage = Path(scratch)
        build = ["swift", "build", "--package-path", source, "--scratch-path", stage / "build", "-c", "release"]
        subprocess.run([*build, "--product", "ThrushBench"], check=True)
        binary = Path(subprocess.check_output([*build, "--show-bin-path"], text=True).strip()) / "ThrushBench"
        reports = collect(binary, source, stage, revision, fixture_sha256, cores)
        summarize(reports)
        accepted = stage / "accepted"
        accepted.mkdir()
        for i in range(1, len(reports) + 1):
            name = f"run-{i}.json"
            (stage / name).replace(accepted / name)
        accepted.replace(output)


if __name__ == "__main__":
    main()
