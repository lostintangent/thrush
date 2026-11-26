"""Count partial bursts that two Release builds submit, and those that reach the screen.

Each burst repaints the grid's three thirds in three WebSocket messages. A submitted frame or
a recorded window frame whose thirds disagree shows part of a burst. HEAD^ is the baseline
and HEAD the candidate. They must differ only in measured product files.
"""
import argparse
import contextlib
import json
import os
from pathlib import Path
import runpy
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"
HERE = Path(__file__).resolve().parent
PRODUCTS = ("Sources/Thrush", "Sources/ThrushCore")
APP_ID = "app.thrush.demo"
ORDER = ("baseline", "candidate", "candidate", "baseline")
capture = runpy.run_path(str(SCRIPTS / "capture-simulator.py"))
panes = runpy.run_path(str(SCRIPTS / "check-pane-workflows.py"))


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()


def until(what, predicate, deadline=100):
    end = time.monotonic() + deadline
    while time.monotonic() < end:
        value = predicate()
        if value:
            return value
        time.sleep(.05)
    raise RuntimeError("Timed out waiting for " + what)


@contextlib.contextmanager
def record_mac(out, pid, window_id, tool):
    stop = out / "recording-stop"
    with panes["running"]([tool, "record", str(pid), str(window_id), str(out), str(stop)], out / "recorder.log") as recorder:
        def started():
            if recorder.poll() is not None:
                raise RuntimeError("Window recorder exited: " + (out / "recorder.log").read_text())
            return (out / "recording-start").exists()
        until("the first window frame", started)
        try:
            yield
        finally:
            stop.touch()
            if recorder.wait(30) != 0:
                raise RuntimeError("The window recorder failed: " + (out / "recorder.log").read_text())


def take(out, bundle, device, docs, tool, per_gap):
    out.mkdir()
    driver = Path(tempfile.mkdtemp(prefix="burst-", dir=docs)) if device else out
    pid = None
    try:
        with panes["running"](["bun", HERE / "burst-peer.ts", out, str(per_gap)], out / "peer.log") as peer:
            def endpoint():
                panes["check_alive"](peer, "peer", out / "peer.log")
                line = (out / "peer.log").read_text().strip()
                return line if line.startswith("http://127.0.0.1:") else None
            url = until("the burst peer", endpoint)
            args = ["--endpoint", url, "--scene", "prompt", "--burst-capture", str(driver), "--appearance", "dark"]
            if device:
                launch = ["xcrun", "simctl", "launch", "--console", "--terminate-running-process", device, APP_ID,
                          *args, "--hide-keyboard"]
            else:
                launch = ["open", "-n", "-W", "-F", "-a", bundle, "--stdout", out / "host.stdout.log",
                          "--stderr", out / "host.stderr.log", "--args", "-NSAppSleepDisabled", "YES", *args]
            with panes["running"](launch, out / "app.log") as app:
                def received(path):
                    if (driver / "error.txt").exists():
                        raise RuntimeError((driver / "error.txt").read_text())
                    panes["check_alive"](peer, "peer", out / "peer.log")
                    panes["check_alive"](app, "demo", out / "app.log")
                    return path.exists()
                until("native window and socket", lambda: received(driver / "ready") and received(out / "attached"))
                if device:
                    recorder = capture["record_simulator"](device, out, "burst")
                else:
                    window = json.loads((driver / "ready").read_text())
                    pid = window["pid"]
                    subprocess.run(["open", "-a", bundle], check=True)
                    recorder = record_mac(out, pid, window["windowID"], tool)
                time.sleep(1)
                with recorder:
                    (out / "start").touch()
                    until("every burst", lambda: received(out / "wire.json"), 8 * per_gap * 0.6 + 120)
                    time.sleep(.5)
                    (driver / "finish").touch()
                    until("the submitted frame report", lambda: received(driver / "frames.json"))
    finally:
        if pid:
            with contextlib.suppress(ProcessLookupError):
                os.kill(pid, signal.SIGTERM)
        if device and driver.is_dir():
            shutil.copytree(driver, out, dirs_exist_ok=True)
            shutil.rmtree(driver)
    if device:
        with (out / "decode.log").open("w") as log:
            subprocess.run([tool, "movie", out / "burst.mov", out], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=600)
    result = analyze(out)
    (out / "summary.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def text_thirds(frame):
    rows, columns = frame["rows"], frame["columns"]
    bounds = [0, rows // 3, 2 * rows // 3, rows]
    thirds = []
    for k in range(3):
        texts = [t.strip() for t in frame["text"][bounds[k]:bounds[k + 1]]]
        if all(t == "█" * columns for t in texts):
            thirds.append("ink")
        elif not any(texts):
            thirds.append("blank")
        else:
            thirds.append(None)
    return thirds


def pixel_thirds(out, layout):
    meta = json.loads((out / "window.json").read_text())
    data = (out / "window.gray").read_bytes()
    width, height, size = meta["width"], meta["height"], meta["width"] * meta["height"]
    if len(data) != size * len(meta["frames"]):
        raise RuntimeError("Gray frame archive does not match its index")
    scale = meta["sourceWidth"] / layout["window"][0] / meta["factor"]
    gx, gy, gw, gh = (v * scale for v in layout["grid"])
    rows = layout["rows"]
    bounds = [0, rows // 3, 2 * rows // 3, rows]
    boxes = []
    for k in range(3):
        top, bottom = gy + gh * bounds[k] / rows, gy + gh * bounds[k + 1] / rows
        inset = (bottom - top) * .2
        boxes.append((int(gx + .1 * gw), int(gx + .9 * gw), int(top + inset), int(bottom - inset)))
    if any(x1 <= x0 or y1 <= y0 or x1 > width or y1 > height for x0, x1, y0, y1 in boxes):
        raise RuntimeError(f"Grid {layout['grid']} does not fit the {width}×{height} frames")
    means = []
    for n in range(len(meta["frames"])):
        frame = data[n * size:(n + 1) * size]
        band = []
        for x0, x1, y0, y1 in boxes:
            total = sum(sum(frame[y * width + x0:y * width + x1]) for y in range(y0, y1))
            band.append(total / ((x1 - x0) * (y1 - y0)))
        means.append(band)
    values = sorted(v for band in means for v in band)
    lo, hi = values[len(values) // 50], values[-1 - len(values) // 50]
    if hi - lo < 80:
        raise RuntimeError(f"The recording never showed both ink and blank thirds ({lo:.0f} to {hi:.0f})")
    def classify(v):
        return "ink" if v > lo + .7 * (hi - lo) else "blank" if v < lo + .3 * (hi - lo) else None
    times = [f["displayAt"] if f.get("displayAt") is not None else f["time"] for f in meta["frames"]]
    return [[classify(v) for v in band] for band in means], times, {"blank": lo, "ink": hi}


def attribute(thirds, bursts):
    """Assign each frame whose thirds disagree to the burst in progress, by counting completed bursts.
    Also find the first frame that shows any part of each burst."""
    done, current = 0, "blank"
    partial = {}
    first = {}
    unknown = []
    for n, bands in enumerate(thirds):
        if None in bands:
            unknown.append(n)
        elif len(set(bands)) == 1:
            if bands[0] != current:
                first.setdefault(done, n)
                current = bands[0]
                done += 1
        else:
            new = "blank" if current == "ink" else "ink"
            if done < bursts and bands in ([new, current, current], [new, new, current]):
                first.setdefault(done, n)
                partial.setdefault(done, []).append(n)
            else:
                unknown.append(n)
    return partial, done, unknown, first


def analyze(out):
    wire = json.loads((out / "wire.json").read_text())
    bursts = wire["bursts"]
    frames = json.loads((out / "frames.json").read_text())
    shapes = {(b["rows"], b["cols"]) for b in bursts}
    if len(shapes) != 1:
        raise RuntimeError(f"The grid changed size during the bursts: {shapes}")
    rows, columns = shapes.pop()
    sized = [f for f in frames if (f["rows"], f["columns"]) == (rows, columns)]
    submitted, submitted_done, submitted_unknown, _ = attribute([text_thirds(f) for f in sized], len(bursts))
    shown_thirds, times, levels = pixel_thirds(out, sized[-1])
    shown, shown_done, shown_unknown, first = attribute(shown_thirds, len(bursts))
    # Simulator movie times have no host anchor, so only a Mac recording measures latency.
    anchored = all(f.get("displayAt") is not None for f in json.loads((out / "window.json").read_text())["frames"])
    def latency(b):
        n = first.get(b["index"])
        if not anchored or n is None or b.get("sentAt") is None:
            return None
        return round(1000 * (times[n] - b["sentAt"]), 2)
    def held(n):
        return 1000 * (times[n + 1] - times[n]) if n + 1 < len(times) else None
    per_burst = [{"index": b["index"], "gap": b["gap"], "sentMs": b["sentMs"],
                  "submittedPartials": len(submitted.get(b["index"], [])), "firstShownMs": latency(b),
                  "shownPartials": [round(held(n), 2) for n in shown.get(b["index"], [])]} for b in bursts]
    return {"bursts": len(bursts), "grid": [rows, columns], "levels": levels,
            "completedBursts": {"submitted": submitted_done, "shown": shown_done},
            "unclassifiedFrames": {"submitted": len(submitted_unknown), "shown": shown_unknown[:40]},
            "submittedFrames": len(sized), "shownFrames": len(times), "perBurst": per_burst}


def tally(results):
    table = {}
    for result in results:
        if result["completedBursts"] != {"submitted": result["bursts"], "shown": result["bursts"]}:
            continue
        for burst in result["perBurst"]:
            row = table.setdefault(str(burst["gap"]), {"bursts": 0, "submittedPartial": 0, "shownPartial": 0, "shownMs": 0,
                                                       "firstShownMs": []})
            row["bursts"] += 1
            row["submittedPartial"] += burst["submittedPartials"] > 0
            row["shownPartial"] += bool(burst["shownPartials"])
            row["shownMs"] = round(row["shownMs"] + sum(burst["shownPartials"]), 2)
            if burst.get("firstShownMs") is not None:
                row["firstShownMs"].append(burst["firstShownMs"])
    for row in table.values():
        latencies = sorted(row.pop("firstShownMs"))
        if latencies:
            row["firstShownMs"] = {q: latencies[min(len(latencies) - 1, int(p * len(latencies)))]
                                   for q, p in (("p10", .1), ("p50", .5), ("p90", .9))}
    return dict(sorted(table.items(), key=lambda item: float(item[0])))


def compare(platform, roots, output, per_gap):
    output.mkdir(parents=True)
    bundles = {}
    for side, repo in roots.items():
        with (output / (side + "-build.log")).open("w") as log:
            subprocess.run([repo / "scripts/build-demo.sh", platform], cwd=repo, stdout=log, stderr=subprocess.STDOUT,
                           check=True, timeout=1000)
        bundles[side] = repo / ".build/demo" / platform / "Thrush.app"
    tool = output / "burst-frames"
    subprocess.run(["xcrun", "swiftc", "-O", HERE / "burst-frames.swift", "-o", tool], check=True)
    reservation = capture["disposable_phone"](output) if platform == "simulator" else contextlib.nullcontext(None)
    results = {"baseline": [], "candidate": []}
    damaged = {}
    with reservation as device:
        for n, side in enumerate(ORDER):
            docs = capture["install_and_locate_app"](device, bundles[side]) if device else None
            name = f"{n + 1}-{side}"
            print(platform, n + 1, side, flush=True)
            try:
                results[side].append(take(output / name, bundles[side], device, docs, tool, per_gap))
            except subprocess.CalledProcessError as error:
                # The simulator occasionally writes a movie that can't be decoded. Name the take and skip it.
                if error.cmd[:2] != [tool, "movie"]:
                    raise
                damaged[name] = (output / name / "decode.log").read_text()[-400:]
                print(f"{name}: the recording could not be decoded", flush=True)
            summary = {"platform": platform, "order": ORDER[:n + 1],
                       "commits": {s: git(repo, "rev-parse", "HEAD") for s, repo in roots.items()},
                       "damagedTakes": damaged,
                       "byGap": {s: tally(r) for s, r in results.items()},
                       "completedBursts": {s: [r["completedBursts"] for r in rs] for s, rs in results.items()}}
            (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary["byGap"], indent=2), flush=True)
    if sum(map(len, results.values())) < 3 or not all(results.values()):
        raise RuntimeError(f"Too few judged takes: {', '.join(damaged)} could not be decoded")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("platform", choices=["mac", "simulator"])
    parser.add_argument("output", type=Path)
    parser.add_argument("--per-gap", type=int, default=24)
    args = parser.parse_args()
    out = args.output.resolve()
    with tempfile.TemporaryDirectory(prefix="thrush-burst-pair-") as temporary:
        baseline = Path(temporary) / "baseline"
        git(ROOT, "worktree", "add", "--detach", str(baseline), "HEAD^")
        try:
            changes = git(ROOT, "diff", "--name-only", "HEAD^", "HEAD").splitlines()
            product = [f for f in changes if not f.startswith("Tests/")]
            if not product or any(not f.startswith(tuple(d + "/" for d in PRODUCTS)) for f in product):
                raise ValueError("HEAD^ and HEAD must differ only in measured product files")
            compare(args.platform, {"baseline": baseline, "candidate": ROOT}, out, args.per_gap)
        finally:
            git(ROOT, "worktree", "remove", "--force", str(baseline))


if __name__ == "__main__":
    main()
