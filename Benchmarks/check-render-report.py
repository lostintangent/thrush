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
    assert columns >= 24 and rows >= 2 and report["schemaVersion"] == 6
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
    frames = [s["frame"] for s in samples]
    assert 0 < frames[0]["shaderCompileSeconds"] <= frames[0]["firstFrameSeconds"]
    assert all("shaderCompileSeconds" not in f and "firstFrameSeconds" not in f for f in frames[1:])
    assert frames[0]["glyphUploads"] > 0 and frames[0]["rowsPrepared"] == rows
    assert all(f["glyphUploads"] == 0 for f in frames[1:])
    assert all(s["frame"]["rowsPrepared"] <= 1 for s in samples if s["operation"] in ("oneRow", "cursor"))
    assert all(s["frame"]["rowsPrepared"] == rows for s in samples if s["operation"] == "full")
    assert all(a["generation"] < b["generation"] for a, b in zip(frames, frames[1:]))
    for frame in frames:
        check_frame(frame)
        assert "receivedAt" in frame
    for workload in report["workloads"]:
        matching = [s["frame"] for s in samples if s["operation"] == workload["operation"]]
        assert len(matching) == workload["frames"]
        presented = [f for f in matching if "presentedTime" in f]
        assert len(presented) + workload["unpresented"] == len(matching)
        if presented:
            latency = sorted((f["presentedTime"] - f["receivedAt"]) * 1000 for f in presented)
            p95 = latency[math.ceil(0.95 * len(latency)) - 1]
            assert math.isclose(p95, workload["receiptToPresentationP95Milliseconds"])
    switches = report["themeSwitches"]
    assert {s["theme"] for s in switches} == {"Light", "Dark", "Custom"}
    for switch in switches:
        check_frame(switch["frame"])
        assert switch["frame"]["generation"] == frames[-1]["generation"]
        assert switch["frame"]["rowsPrepared"] == 0 and switch["frame"]["glyphUploads"] == 0
    for state in ["foregroundIdle", "inactiveRenderer", "background"]:
        assert report[state]["seconds"] >= 1 and report[state]["additionalSubmissions"] == 0, state
    assert report["displayIntervalSeconds"] > 0
    check_synchronized_output(report["synchronizedOutput"])
    blink = report["textBlink"]
    check_text_blink(blink)
    drawn = sum("presentedTime" in f for f in frames)
    print(f'{environment["destination"]}, {columns} × {rows}, {drawn}/{len(samples)} confirmed presentations, '
          f'{blink["submissions"]} blink frames in {blink["seconds"]:.1f} s, '
          'zero settled, inactive and background submissions')


def check_frame(frame):
    assert frame["gpuCompleted"] and frame["cpuPreparationSeconds"] >= 0
    assert frame.get("receivedAt", frame["submittedAt"]) <= frame["submittedAt"] <= frame.get("presentedTime", math.inf)


def check_text_blink(blink):
    # Two full periods of 1.2 s, each fading out and back in for 0.4 s.
    assert blink["seconds"] >= 2.4
    assert 0 < blink["minimumSubmissions"] <= blink["submissions"] <= blink["maximumSubmissions"]
    assert blink["maximumSubmissions"] <= blink["seconds"] * 60
    assert blink["rowsPrepared"] == 0 and blink["glyphUploads"] == 0
    for state in ("reducedMotion", "steady"):
        assert blink[state]["seconds"] >= 1.2 and blink[state]["additionalSubmissions"] == 0, state


def check_synchronized_output(sync):
    begin, end, rewrite = "\x1b[?2026h", "\x1b[?2026l", "\x1b[1;1H\x1b[K"
    packets = [rewrite + "ready", begin + rewrite + "partial", rewrite + "replaced",
               begin + rewrite + "last partial", rewrite + "complete" + end,
               begin + rewrite + "unfinished", rewrite + "watchdog"]
    assert sync["workloadSHA256"] == hashlib.sha256("".join(packets).encode()).hexdigest()
    close, watchdog = sync["close"]["frame"], sync["watchdog"]["frame"]
    held = sync["heldGenerations"]
    assert len(held) == 3 and held[0] < held[1] < held[2] < close["generation"] < watchdog["generation"]
    assert 0.09 <= close["receivedAt"] - sync["holdOpenedAt"] < 1
    assert sync["submissionsDuringHold"] == 0
    for release in (sync["close"], sync["watchdog"]):
        assert release["submissions"] == 1 and release["frame"]["generation"] == release["expectedGeneration"]
        check_frame(release["frame"])
    assert close["submittedAt"] <= sync["truncatedOpenedAt"] < watchdog["receivedAt"]
    delay = watchdog["submittedAt"] - sync["truncatedOpenedAt"]
    assert delay >= 1 and math.isclose(delay, sync["watchdogToSubmissionSeconds"])
    assert sync["idle"]["seconds"] >= 1 and sync["idle"]["additionalSubmissions"] == 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: check-render-report.py REPORT.json")
    check(sys.argv[1])
