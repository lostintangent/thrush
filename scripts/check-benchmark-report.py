"""Verify Release counts against the fixture files independently of the Swift runner."""

import base64
import hashlib
import json
import math
import re
import subprocess
import sys
from bisect import bisect_right
from itertools import accumulate
from pathlib import Path


def styled_frames(fixture):
    """Resolve the reference's interned rows and cells, including the implicit blank tail."""
    result = {}
    for event in fixture["events"]:
        if event["name"] not in ("Styled Swift buffer", "Styled Swift portrait", "Styled Swift landscape"):
            continue
        checkpoint = event["checkpoint"]
        assert checkpoint["isAlternate"] and event["name"] not in result
        rows = []
        for line_id in checkpoint["visible"]:
            line = fixture["lines"][line_id]
            cells = []
            for count, cell_id in zip(line["runs"][::2], line["runs"][1::2]):
                cells.extend([fixture["cells"][cell_id]] * count)
            cells.extend([fixture["cells"][0]] * (checkpoint["columns"] - len(cells)))
            assert len(cells) == checkpoint["columns"]
            rows.append((line["text"], cells))
        assert len(rows) == checkpoint["rows"]
        result[event["name"]] = rows
    expected = {"Styled Swift buffer": (80, 24), "Styled Swift portrait": (45, 18),
                "Styled Swift landscape": (71, 11)}
    assert {name: (len(rows[0][1]), len(rows)) for name, rows in result.items()} == expected
    return result


def check_swift_theme(fixture, theme, foreground, background):
    assert fixture["vimBackground"] == theme
    events = fixture["events"]
    first_output = next(i for i, event in enumerate(events) if event.get("bytes"))
    palette = next(event["palette"] for event in events[:first_output + 1] if "palette" in event)
    assert palette["foreground"].lower() == foreground and palette["background"].lower() == background
    replies = b"".join(base64.b64decode(event.get("reply", "")) for event in events)
    for command, color in ((10, foreground), (11, background)):
        rgb = "/".join(color[i:i+2] * 2 for i in (1, 3, 5))
        assert f"\x1b]{command};rgb:{rgb}\x1b\\".encode() in replies, f"{theme} OSC {command}"
    return styled_frames(fixture)


def check_swift_pair(fixtures):
    dark = check_swift_theme(json.loads(fixtures["vim-swift-dark"]), "dark", "#e3eaf0", "#131d27")
    light = check_swift_theme(json.loads(fixtures["vim-swift-light"]), "light", "#233442", "#fbfdfe")
    for checkpoint in dark:
        assert [s for s, _ in dark[checkpoint]] == [s for s, _ in light[checkpoint]], checkpoint
    for theme, frames, gutter, comment, keyword, identifier, bold in (
        ("dark", dark, 11, 14, 81, 14, True), ("light", light, 130, 4, 5, 6, False)
    ):
        numbered = {}
        numbers = []
        for text, cells in frames["Styled Swift buffer"]:
            match = re.fullmatch(r" *([0-9]+) (.*)", text)
            if match:
                numbers.append(int(match[1]))
                assert cells[match.start(1)]["foreground"] == gutter, f"{theme} line number"
                numbered[match[2].strip()] = (text, cells)
        assert numbers == list(range(1, len(numbers) + 1)), f"{theme} sequential Swift line numbers"
        assert r'return "\(cwd) \(mark) "' in numbered and 'let mark = isRoot ? "#" : "$"' in numbered

        # These are syntax groups from the stock Vim runtime, sampled by token in its reference frame.
        for source, token, foreground in (("// Format the current shell prompt.", "//", comment),
                                          ("struct Prompt {", "struct", keyword),
                                          ("let width = 24", "width", identifier)):
            text, cells = numbered[source]
            start = text.index(token)
            span = cells[start:start + len(token)]
            assert "".join(c["text"] for c in span) == token
            assert all(c["foreground"] == foreground for c in span), f"{theme} {token} foreground"
            if token == "width":
                assert all(bool(c["flags"] & 1) == bold for c in span), f"{theme} Swift binding weight"

        for frame in frames.values():
            status_rows = [(s, row) for s, row in frame if re.fullmatch(r" *Prompt\.swift +\d+:\d+ *", s)]
            assert len(status_rows) == 1, f"{theme} Swift file status"
            status, cells = status_rows[0]
            start = status.index("Prompt.swift")
            assert all(c["flags"] & 32 for c in cells[start:start + len("Prompt.swift")]), f"{theme} status reverse"
        glyphs = [cell for frame in frames.values() for _, row in frame for cell in row if cell["text"].strip()]
        colors = {cell["foreground"] for cell in glyphs}
        assert any(0 <= color < 16 for color in colors), f"{theme} ANSI syntax colors"
        assert any(16 <= color < 256 for color in colors), f"{theme} extended indexed colors"
        assert any(cell["flags"] & 1 for cell in glyphs), f"{theme} bold glyphs"


root = Path(__file__).resolve().parents[1]
path = Path(sys.argv[1]) if len(sys.argv) == 2 else root / ".build/benchmarks/headless.json"
report = json.loads(path.read_bytes())
archived = path.resolve() == root / "Benchmarks/headless.json"
recordings = report["recordings"]
available = {p.stem: p.read_bytes() for p in (root / "Fixtures/recordings").glob("*.json")}
if archived:
    # Preserve the checked-in workload set in source archives and shallow checkouts.
    # A changed or removed fixture needs its original bytes from the measured commit.
    revision = report["environment"]["commit"]
    assert re.fullmatch(r"[0-9a-f]{40}", revision) and not report["environment"]["worktreeDirty"]
    fixtures = {}
    for recording in recordings:
        name = recording["name"]
        assert re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", name) and name not in fixtures
        data = available.get(name)
        if data is None or hashlib.sha256(data).hexdigest() != recording["fixtureSHA256"]:
            # Revisions before the rename kept the recordings in Fixtures/replays.
            for directory in ("recordings", "replays"):
                try:
                    data = subprocess.check_output(["git", "-C", str(root), "show",
                                                    f"{revision}:Fixtures/{directory}/{name}.json"], stderr=subprocess.PIPE)
                    break
                except (OSError, subprocess.CalledProcessError) as error:
                    failure = error
            else:
                sys.exit(f"Archived fixture {name} needs its original bytes from {revision}: {failure}")
        fixtures[name] = data
else:
    fixtures = available
assert len(recordings) == len(fixtures) and {r["name"] for r in recordings} == fixtures.keys()
# Check the styled Vim pair as checked in. An archived report's older bytes passed at their own commit.
check_swift_pair(available)

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

assert any(r["maximumQueuedSlots"] == r["queueSlotLimit"] for r in recordings)
assert any(r["maximumQueuedBytes"] == r["queueByteLimit"] for r in recordings)
assert {(b["grid"]["columns"], b["grid"]["rows"]) for b in report["bulk"]} == {(80, 24), (40, 32), (80, 14)}
bulk = ((b"abcdefghij" * 8)[:78] + b"\r\n") * 13_108
for sample in report["bulk"]:
    assert sample["inputSHA256"] == hashlib.sha256(bulk).hexdigest()
    assert sample["bytesPerPass"] == len(bulk) and sample["chunkBytes"] == 4096
    assert sample["receivedBytes"] == sample["appliedBytes"] == sample["measuredPasses"] * len(bulk)

if not archived:
    transitions = report["shellTransitions"]
    assert transitions["grid"] == {"columns": 80, "rows": 24} and transitions["measuredPasses"] == 25
    assert transitions["promptFixtureSHA256"] == hashlib.sha256(fixtures["shell-workflow"]).hexdigest()
    for name, before, after in [("startNewShell", 992, 1_000), ("prepareForReplay", 1_000, 992)]:
        sample = transitions[name]
        assert (sample["historyRowsBefore"], sample["historyRowsAfter"]) == (before, after), name
        assert 0 < sample["timing"]["p50Nanoseconds"] <= sample["timing"]["p95Nanoseconds"], name

print(f"Verified {len(recordings)} recording hashes and byte counts, both queue bounds, and all bulk grids.")
