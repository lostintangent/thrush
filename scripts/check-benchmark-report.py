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
fixtures = {p.stem: p for p in (root / "Fixtures/replays").glob("*.json")}
replays = report["recordings"]
assert len(replays) == len(fixtures) and {r["name"] for r in replays} == fixtures.keys()

for replay in replays:
    data = fixtures[replay["name"]].read_bytes()
    fixture = json.loads(data)
    events = fixture["events"]
    passes = replay["measuredReplays"]
    assert passes > 0 and hashlib.sha256(data).hexdigest() == replay["fixtureSHA256"], replay["name"]

    def sizes(field):
        return [len(base64.b64decode(event.get(field, ""))) for event in events]

    output = sizes("bytes")
    assert replay["receivedBytes"] == replay["appliedBytes"] == passes * sum(output), replay["name"]
    assert replay["replyBytes"] == passes * sum(sizes("reply")), replay["name"]
    semantic = sum(n for event, n in zip(events, sizes("input")) if "action" in event)
    assert replay["encodedInputBytes"] == passes * semantic, replay["name"]
    assert replay["referenceCheckpointsPerReplay"] == sum("checkpoint" in e for e in events), replay["name"]
    assert replay["queuedBytesAfterDrain"] == 0, replay["name"]
    assert 0 < replay["maximumQueuedBytes"] <= min(replay["queueByteLimit"], sum(output)), replay["name"]
    assert 0 < replay["maximumQueuedSlots"] <= replay["queueSlotLimit"], replay["name"]

    times = [e["offsetMicroseconds"] for e in events]
    assert times == sorted(times), replay["name"]
    prefix = [0, *accumulate(output)]
    peak = max(prefix[i + 1] - prefix[bisect_right(times, t - 1_000_000)] for i, t in enumerate(times))
    assert replay["fixturePeakBytesInOneSecond"] == peak, replay["name"]
    multiple = replay["receiveMiBPerSecond"] * 1_048_576 / peak
    assert math.isclose(replay["fixturePeakMultiple"], multiple), replay["name"]
    assert replay["meetsTwiceRecordedPeak"] == (multiple >= 2), replay["name"]
    expected = [e for e in events if "resize" in e]
    assert len(replay["resizes"]) == len(expected), replay["name"]
    for resize, event in zip(replay["resizes"], expected):
        checkpoint = event["checkpoint"]
        assert resize["requested"] == event["resize"], event["name"]
        assert resize["to"] == {k: checkpoint[k] for k in ("columns", "rows")}, event["name"]
        assert resize["alternate"] == checkpoint["isAlternate"], event["name"]
        assert resize["historyRowsBefore"] == event["historyRowsBefore"], event["name"]
        assert resize["normalHistoryRowsBefore"] == event["normalHistoryRowsBefore"], event["name"]

    if replay["name"] == "shell-log":
        full = [e for e in events if "full" in e["name"].lower() and "history" in e["name"].lower()
                and "checkpoint" in e]
        assert full and all(not e["checkpoint"]["isAlternate"] and len(e["checkpoint"]["history"]) == 1_000
                            for e in full), "The named full-history shell checkpoints must contain 1,000 rows"
        assert any("alternate" in e["name"].lower() or "vim" in e["name"].lower() for e in full)
        normal = [e for e in expected if not e["checkpoint"]["isAlternate"]]
        assert len(normal) == 3 and all(e["normalHistoryRowsBefore"] == e["historyRowsBefore"] == 1_000
                                        for e in normal), "All three normal resizes must start with 1,000 rows"
        first_alternate = next(e for e in expected if e["checkpoint"]["isAlternate"])
        assert first_alternate["historyRowsBefore"] == 0 and first_alternate["normalHistoryRowsBefore"] == 1_000

assert any(r["maximumQueuedSlots"] == r["queueSlotLimit"] for r in replays)
assert any(r["maximumQueuedBytes"] == r["queueByteLimit"] for r in replays)
assert {(b["grid"]["columns"], b["grid"]["rows"]) for b in report["bulk"]} == {(80, 24), (40, 32), (80, 14)}
bulk = ((b"abcdefghij" * 8)[:78] + b"\r\n") * 13_108
for sample in report["bulk"]:
    assert sample["inputSHA256"] == hashlib.sha256(bulk).hexdigest()
    assert sample["bytesPerPass"] == len(bulk) and sample["chunkBytes"] == 4096
    assert sample["receivedBytes"] == sample["appliedBytes"] == sample["measuredPasses"] * len(bulk)

print(f"Verified {len(replays)} recording hashes and byte counts, both queue bounds, and all bulk grids.")
