"""Verify Release counts against the fixture files independently of the Swift runner."""

import base64
import hashlib
import json
import math
import sys
from bisect import bisect_right
from itertools import accumulate
from pathlib import Path

root = Path(__file__).resolve().parents[1]
path = Path(sys.argv[1]) if len(sys.argv) == 2 else root / ".build/benchmarks/headless.json"
report = json.loads(path.read_bytes())
recordings = report["recordings"]
fixtures = {p.stem: p.read_bytes() for p in (root / "Fixtures/recordings").glob("*.json")}
assert len(recordings) == len(fixtures) and {r["name"] for r in recordings} == fixtures.keys()

for recording in recordings:
    data = fixtures[recording["name"]]
    fixture = json.loads(data)
    events = fixture["events"]
    passes = recording["measuredReplays"]
    assert passes > 0 and hashlib.sha256(data).hexdigest() == recording["fixtureSHA256"], recording["name"]

    def sizes(field):
        return [len(base64.b64decode(event.get(field, ""))) for event in events]

    output = sizes("bytes")
    assert recording["receivedBytes"] == recording["appliedBytes"] == passes * sum(output), recording["name"]
    assert recording["replyBytes"] == passes * sum(sizes("reply")), recording["name"]
    semantic = sum(n for event, n in zip(events, sizes("input")) if "action" in event)
    assert recording["encodedInputBytes"] == passes * semantic, recording["name"]
    assert recording["referenceCheckpointsPerReplay"] == sum("checkpoint" in e for e in events), recording["name"]
    palette_changes = sum("palette" in e for e in events)
    assert recording["paletteChangesPerReplay"] == palette_changes
    assert (recording.get("paletteChangeTime") is not None) == (palette_changes > 0)
    assert recording["queuedBytesAfterDrain"] == 0, recording["name"]
    assert 0 < recording["maximumQueuedBytes"] <= min(recording["queueByteLimit"], sum(output)), recording["name"]
    assert 0 < recording["maximumQueuedSlots"] <= recording["queueSlotLimit"], recording["name"]

    times = [e["offsetMicroseconds"] for e in events]
    assert times == sorted(times), recording["name"]
    prefix = [0, *accumulate(output)]
    peak = max(prefix[i + 1] - prefix[bisect_right(times, t - 1_000_000)] for i, t in enumerate(times))
    assert recording["fixturePeakBytesInOneSecond"] == peak, recording["name"]
    multiple = recording["receiveMiBPerSecond"] * 1_048_576 / peak
    assert math.isclose(recording["fixturePeakMultiple"], multiple), recording["name"]
    assert recording["meetsTwiceRecordedPeak"] == (multiple >= 2), recording["name"]
    # Each receive-rate sample applies at least 8 KiB, so no timed span is close to a clock tick.
    assert recording["receiveSamples"] > 0, recording["name"]
    assert recording["receiveReplaysPerSample"] == -(-8192 // sum(output)), recording["name"]
    expected = [e for e in events if "resize" in e]
    assert len(recording["resizes"]) == len(expected), recording["name"]
    for resize, event in zip(recording["resizes"], expected):
        checkpoint = event["checkpoint"]
        assert resize["requested"] == event["resize"], event["name"]
        assert resize["to"] == {k: checkpoint[k] for k in ("columns", "rows")}, event["name"]
        assert resize["alternate"] == checkpoint["isAlternate"], event["name"]
        assert resize["historyRowsBefore"] == event["historyRowsBefore"], event["name"]
        assert resize["normalHistoryRowsBefore"] == event["normalHistoryRowsBefore"], event["name"]

    if recording["name"] == "shell-log":
        normal = [r for r in recording["resizes"] if not r["alternate"]]
        assert len(normal) == 3 and all(r["normalHistoryRowsBefore"] == r["historyRowsBefore"] == 1_000
                                        for r in normal), "All three normal resizes must start with 1,000 rows"
        first_alternate = next(r for r in recording["resizes"] if r["alternate"])
        assert first_alternate["historyRowsBefore"] == 0 and first_alternate["normalHistoryRowsBefore"] == 1_000

assert any(r["maximumQueuedSlots"] == r["queueSlotLimit"] for r in recordings)
assert any(r["maximumQueuedBytes"] == r["queueByteLimit"] for r in recordings)
assert {(b["grid"]["columns"], b["grid"]["rows"]) for b in report["bulk"]} == {(80, 24), (40, 32), (80, 14)}
bulk = ((b"abcdefghij" * 8)[:78] + b"\r\n") * 13_108
for sample in report["bulk"]:
    assert sample["inputSHA256"] == hashlib.sha256(bulk).hexdigest()
    assert sample["bytesPerPass"] == len(bulk) and sample["chunkBytes"] == 4096
    assert sample["receivedBytes"] == sample["appliedBytes"] == sample["measuredPasses"] * len(bulk)

transitions = report["shellTransitions"]
assert transitions["grid"] == {"columns": 80, "rows": 24} and transitions["measuredPasses"] == 25
assert transitions["promptFixtureSHA256"] == hashlib.sha256(fixtures["shell-workflow"]).hexdigest()
for name, before, after in [("startNewShell", 992, 1_000), ("prepareForReplay", 1_000, 992)]:
    sample = transitions[name]
    assert (sample["historyRowsBefore"], sample["historyRowsAfter"]) == (before, after), name
    assert 0 < sample["timing"]["p50Nanoseconds"] <= sample["timing"]["p95Nanoseconds"], name

print(f"Verified {len(recordings)} recording hashes and byte counts, both queue bounds, and all bulk grids.")
