#!/usr/bin/env python3
"""Verify the native window workload against its input bytes and frame counters."""
import hashlib
import json
import math
import sys
from pathlib import Path


def check(path):
    report = json.loads(Path(path).read_bytes())
    columns, rows = report["columns"], report["rows"]
    version = report["schemaVersion"]
    assert columns >= 24 and rows >= 2 and version in (1, 2)
    environment = report["environment"]
    assert environment["commit"] != "unknown" and environment["toolchain"] != "unknown"
    assert environment["hardwareModel"] != "unknown"
    assert len(environment["loadAverage"]) == 3
    assert environment["contended"] == (environment["loadAverage"][0] > environment["coreCount"])
    line = "\x1b[36mA翼🐦Z\x1b[0m 0123456789"
    full = "".join(f"\x1b[{row};1H{line}" for row in range(1, rows + 1)) + "\x1b[1;1H"
    tape = "\x1b[?12l" + full + ("\x1b[1;6H\x1b[1;9H89" + f"\x1b[{rows};1H\r\n" + line + full) * 10
    assert report["workloadSHA256"] == hashlib.sha256(tape.encode()).hexdigest()
    samples = report["samples"]
    assert [s["operation"] for s in samples] == ["cold"] + ["cursor", "oneRow", "scroll", "full"] * 10
    if version == 2:
        assert 0 < samples[0]["shaderCompileSeconds"] <= samples[0]["firstFrameSeconds"]
        assert all("shaderCompileSeconds" not in s and "firstFrameSeconds" not in s for s in samples[1:])
    assert samples[0]["glyphUploads"] > 0 and samples[0]["rowsPrepared"] == rows
    assert all(s["glyphUploads"] == 0 for s in samples[1:])
    assert all(s["rowsPrepared"] <= 1 for s in samples if s["operation"] in ("oneRow", "cursor"))
    assert all(s["rowsPrepared"] == rows for s in samples if s["operation"] == "full")
    assert all(a["generation"] < b["generation"] for a, b in zip(samples, samples[1:]))
    for sample in samples:
        assert sample["receivedAt"] <= sample["submittedAt"]
        assert sample["cpuPreparationSeconds"] >= 0
        if "presentedTime" in sample:
            assert sample["presentedTime"] >= sample["submittedAt"]
    for workload in report["workloads"]:
        frames = [s for s in samples if s["operation"] == workload["operation"]]
        assert len(frames) == workload["frames"]
        presented = [s for s in frames if "presentedTime" in s]
        assert len(presented) + workload["unpresented"] == len(frames)
        if presented:
            latency = sorted((s["presentedTime"] - s["receivedAt"]) * 1000 for s in presented)
            p95 = latency[math.ceil(0.95 * len(latency)) - 1]
            assert math.isclose(p95, workload["receiptToPresentationP95Milliseconds"])
    switches = report["themeSwitches"]
    assert {s["theme"] for s in switches} == {"Slate Light", "Slate Dark", "Custom"}
    assert all(s["generation"] == samples[-1]["generation"] and s["rowsPrepared"] == 0
               and s["glyphUploads"] == 0 for s in switches)
    for state in ["foregroundIdle", "inactiveRenderer", "background"]:
        assert report[state]["seconds"] >= 1 and report[state]["additionalSubmissions"] == 0, state
    assert report["displayIntervalSeconds"] > 0
    drawn = sum("presentedTime" in s for s in samples)
    print(f'{environment["destination"]}, {columns} × {rows}, {drawn}/{len(samples)} '
          'confirmed presentations, zero settled, inactive and background submissions')


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: check-render-report.py REPORT.json")
    check(sys.argv[1])
