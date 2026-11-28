"""Serve a real shell for swipes through less, vim and its history, and measure the rows each gesture moves."""
from collections import Counter
import contextlib
import json
import math
from pathlib import Path
import re
import runpy
import shlex
import statistics
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
PROGRAMS = ("less", "vim")
GESTURES = ("slow", "slow-back", "flick", "fast", "catch", "return")
BIRDS = ("American robin", "Hermit thrush", "Wood thrush", "Song sparrow", "Cedar waxwing", "Barn swallow",
         "Black-capped chickadee", "Northern cardinal", "Eastern bluebird", "Carolina wren", "Blue jay",
         "Red-winged blackbird", "Tufted titmouse", "Mourning dove", "House finch", "Downy woodpecker")
# UIScrollView's normal deceleration keeps this fraction of a flick's velocity each millisecond.
DECELERATION = 0.998
# Every glide must move within this many rows of UIKit's own glide from the velocity it measured at the lift.
# Whole rows reach a program as the content passes them, so a glide can end most of a row short.
GLIDE_ROWS = 2
# A program's last row must arrive within this many seconds after UIKit's glide comes to rest.
GLIDE_LATE = 0.25
SGR = re.compile(rb"\x1b\[<(\d+);\d+;\d+([Mm])|\x1b[\[O]([AB])|.", re.S)


@contextlib.contextmanager
def shell(scratch, out):
    """Serves Bash from a local Thrush server, with a long file to read and logs of what programs read, and yields its endpoint."""
    launch = runpy.run_path(str(ROOT / "Tests/ThrushProofs/launch.py"))
    (scratch / "pty").mkdir()
    with launch["live_pty"](scratch / "pty", out, "/bin/bash", None, ()) as (endpoint, work, _):
        prepare(work.parent, out)
        yield endpoint


def prepare(home, out):
    """Puts a long file in the workspace and logs what less and vim read through their own terminals."""
    lines = (f"{n:03} {BIRDS[n % len(BIRDS)]}" for n in range(1, 401))
    (home / "workspace/birds").write_text("\n".join(lines) + "\n")
    (home / "scroll.vimrc").write_text(
        "set nocompatible nomodeline noswapfile nobackup noundofile viminfo=\n"
        "set noruler noshowcmd noshowmode laststatus=0 shortmess+=I belloff=all\n"
        "set ttimeout ttimeoutlen=10 mouse=a ttymouse=sgr\n"
        "nnoremap q :qa!<CR>\n")
    logger = [sys.executable, str(HERE / "scroll-input.py")]
    for program, command in (("less", ["/usr/bin/less"]),
                             ("vim", ["/usr/bin/vim", "-N", "-u", str(home / "scroll.vimrc"), "-i", "NONE", "-n"])):
        wrapper = home / "bin" / program
        wrapper.write_text("#!/bin/sh\nexec " + shlex.join([*logger, str(out / f"{program}-input.log"), *command])
                           + ' "$@"\n')
        wrapper.chmod(0o700)


def read_input(log):
    """Splits each read into arrows, wheel reports, clicks and other keys."""
    events = []
    for line in log.read_text().splitlines() if log.exists() else []:
        read = json.loads(line)
        for match in SGR.finditer(bytes.fromhex(read["hex"])):
            if match[1]:
                button = int(match[1]) & ~28  # Without Shift, Alt and Ctrl.
                kind = {64: "wheel-up", 65: "wheel-down"}.get(button, "click" if button < 3 and match[2] == b"M" else "mouse")
            elif match[3]:
                kind = "up" if match[3] == b"A" else "down"
            else:
                kind = "key"
            events.append((read["time"], kind))
    return events


def coast(velocity):
    return velocity / 1000 / -math.log(DECELERATION)


def history_events(offsets):
    """Turns each change in how far back the history view reads into rows toward earlier or later output."""
    events = []
    for (_, before), (when, after) in zip(offsets, offsets[1:]):
        events += [(when, "up" if after > before else "down")] * abs(after - before)
    return events


def releases(states):
    """UIKit's measure of each lift the app reported: when, the points moved under the finger and points per second."""
    return sorted({tuple(lift) for state in states for lift in state.get("scrollReleases", ())})


def measure(segment, appearance, gestures, events, row_height, lifts):
    earlier, later = ("wheel-up", "wheel-down") if segment == "vim" else ("up", "down")
    history = segment == "history"
    names = ("enter", "enter-2", *(name for name in GESTURES if name != "catch")) if history else GESTURES
    report, failures = {}, []
    for name in names:
        gesture = gestures.get(f"{segment}-{appearance}-{name}")
        if not gesture:
            failures.append(f"{segment} {name}: the gesture did not finish")
            continue
        window = [(when, kind) for when, kind in events if gesture["start"] <= when <= gesture["settled"]]
        counts = Counter(kind for _, kind in window)
        rows = counts[later] - counts[earlier]
        lift = next((lift for lift in lifts if gesture["start"] <= lift[0] <= gesture["settled"]), None)
        if not lift:
            failures.append(f"{segment} {name}: the app reported no lift")
            continue
        _, travel, velocity = lift
        expected = travel + coast(velocity)
        scrolls = [when for when, kind in window if kind in (earlier, later)]
        after = [kind for when, kind in window if when > gesture["returned"] and kind in (earlier, later)]
        entry = dict(rows=rows, events=dict(counts), fingerRows=round(travel / row_height, 1), velocity=round(velocity),
                     nativeRows=round(expected / row_height, 1),
                     rowsAfterRelease=(1 if gesture["travel"] > 0 else -1) * (after.count(later) - after.count(earlier)),
                     lastRowAfterRelease=round(scrolls[-1] - gesture["returned"], 3) if scrolls else None,
                     # XCUITest returns once UIScrollView comes to rest, so the history's glide ends there.
                     glide=round((gesture["returned"] if history else scrolls[-1] if scrolls else math.nan)
                                 - gesture["start"], 3),
                     keyboardAfter=gesture["keyboard"])
        if not history:  # The history view's offset is only sampled every quarter second.
            # The final gaps between rows show how the glide comes to rest.
            entry["tailGaps"] = [round((b - a) * 1000) for a, b in zip(scrolls[-4:], scrolls[-3:])]
        if gesture["caught"]:
            entry["lastRowAfterCatch"] = round(scrolls[-1] - gesture["caught"], 3) if scrolls else None
            entry["rowsAfterCatch"] = sum(1 for when in scrolls if when > gesture["caught"])
            # The finger's own rows can reach the program in one late read after the catch, so a caught flick fails
            # only when it went farther than the finger did.
            if abs(rows) > math.ceil(abs(gesture["travel"]) / row_height):
                failures.append(f"{segment} catch: moved {abs(rows)} rows for {abs(entry['fingerRows'])} rows of finger, "
                                f"{entry['rowsAfterCatch']} of them after the touch that caught it")
            if counts["click"] or gesture["keyboard"]:
                failures.append(f"{segment} catch: the touch that stopped the flick also clicked or focused input")
        # XCUITest may wait for the glide to rest before returning, so the rows are counted against the finger too.
        # A quarter-second sample can stamp the history's last row after the lift, so only the finger bounds it.
        moved_after_release = entry["rowsAfterRelease"] and not history
        if gesture["hold"] and (moved_after_release or abs(rows) > math.ceil(abs(gesture["travel"]) / row_height)):
            failures.append(f"{segment} {name}: moved {abs(rows)} rows for {abs(entry['fingerRows'])} rows of a finger "
                            f"that rested before lifting, {entry['rowsAfterRelease']} of them after it lifted")
        if not rows or (rows > 0) != (gesture["travel"] > 0):
            failures.append(f"{segment} {name}: moved {dict(counts)} for {gesture['travel']:.0f} points of finger travel")
        elif not gesture["caught"] and abs(rows - expected / row_height) > GLIDE_ROWS:
            failures.append(f"{segment} {name}: moved {abs(rows)} rows where UIKit's glide from {abs(velocity):.0f} points "
                            f"per second moves {abs(entry['nativeRows'])}")
        if not history and not gesture["caught"] and scrolls and entry["lastRowAfterRelease"] > GLIDE_LATE:
            failures.append(f"{segment} {name}: moved its last row {entry['lastRowAfterRelease']:.2f} s after UIKit's glide "
                            "came to rest")
        report[name] = entry
    return report, failures


def settings_travel(labels):
    """The median distance the rows that Settings showed before and after a gesture moved."""
    def unique(rows):
        counted = Counter(label for label, _ in rows)
        return {label: y for label, y in rows if counted[label] == 1}
    before, after = unique(labels["before"]), unique(labels["after"])
    moved = [before[label] - after[label] for label in before.keys() & after.keys()]
    return round(statistics.median(moved), 1) if moved else None


def check(out, appearance):
    """Measures one appearance's swipes, saves the report and raises for each glide or stop that differs."""
    gestures = json.loads((out / "swipe-gestures.json").read_text())
    states = [json.loads(line) for line in (out / "swipe-states.jsonl").read_text().splitlines()]
    drawn = [state for state in states if state.get("cellGridPixels") and state.get("rows")]
    if not drawn:
        raise ValueError("The terminal never reported a drawn grid.")
    # Prefer the taller grid the swipes ran over, with the keyboard hidden.
    layout = max(reversed(drawn), key=lambda state: state.get("accessoryHeight") == 0)
    row_height = layout["cellGridPixels"][1][1] / layout["rows"] / layout["displayScale"]
    report = dict(columns=layout["columns"], rows=layout["rows"], rowHeight=round(row_height, 2))
    offsets = []
    for state in states:
        if not offsets or offsets[-1][1] != state.get("historyOffset", 0):
            offsets.append((state["observedAt"], state.get("historyOffset", 0)))
    failures, lifts = [], releases(states)
    for segment in (*PROGRAMS, "history"):
        events = history_events(offsets) if segment == "history" else read_input(out / f"{segment}-input.log")
        report[segment], problems = measure(segment, appearance, gestures, events, row_height, lifts)
        failures += problems
    for program in PROGRAMS:
        tap, glide = gestures.get(f"{program}-{appearance}-tap"), gestures.get(f"{program}-{appearance}-return")
        last = report[program].get("return", {}).get("lastRowAfterRelease")
        if tap and glide and last is not None:
            quiet = tap["tapped"] - glide["returned"] - last
            report[program]["tap"] = dict(afterLastRow=round(quiet, 3), keyboard=tap["keyboard"])
            if not tap["keyboard"]:
                failures.append(f"{program}: a glide still coasting {quiet:.1f} s after its last row swallowed the tap "
                                "that should have brought the keyboard back")
    labels = gestures.get(f"settings-{appearance}-labels")
    if labels:
        report["settings"] = {}
        for name in ("slow", "slow-back", "flick"):
            gesture, travel = gestures.get(f"settings-{appearance}-{name}"), settings_travel(labels[name])
            report["settings"][name] = dict(
                travel=travel, rows=travel and round(travel / row_height, 1),
                fingerRows=gesture and round(gesture["travel"] / row_height, 1),
                nativeRows=gesture and round((gesture["travel"] + (0 if gesture["hold"] else coast(gesture["velocity"])))
                                             / row_height, 1))
    (out / f"swipes-{appearance}.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"{appearance} swipes: " + json.dumps({segment: {name: entry.get("rows") for name, entry in report[segment].items()}
                                                 for segment in (*PROGRAMS, "history")}), flush=True)
    if failures:
        raise ValueError("; ".join(failures))
