"""WindowServer pixel measurement for the native echo peer. Invoked only by THRUSH_ECHO_PIXELS=1."""
import argparse
import gzip
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import sys

import numpy as np

HERE = Path(__file__).resolve().parent
PEER = HERE.parent / "interaction-peer.ts"
MARKERS = "abcdefghijklmnopqrst"
# The terminal prompt is ASCII, and the committed character occupies two columns.
PREFIX_WIDTH = len("~/thrush % ") + 2 + len(" " + "a soft wrap " * 8 + "ends here.")


def read(path):
    return json.loads(path.read_text())


def write(path, data):
    path.write_text(json.dumps(data, indent=2, allow_nan=False) + "\n")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def distribution(values):
    values = sorted(values)
    if not values:
        return {"count": 0}
    return {"count": len(values), "min": values[0], "median": statistics.median(values),
            "p95": values[math.ceil(.95 * len(values)) - 1], "max": values[-1]}


class Recording:
    def __init__(self, directory, report):
        self.meta = read(directory / "frames.json")
        self.frames = self.meta["frames"]
        self.times = np.array([f["displayAt"] for f in self.frames])
        self.width, self.height = self.meta["width"], self.meta["height"]
        require(len(self.times) >= 2 and np.all(np.diff(self.times) > 0), "Missing ordered WindowServer displayTime")
        shape = (len(self.frames), self.height, self.width)
        raw = directory / "window.gray"
        require(raw.stat().st_size == math.prod(shape), "Raw pixel extent disagrees with source-frame index")
        self.gray = np.memmap(raw, "uint8", mode="r", shape=shape)
        self.report = report
        self.samples = report["samples"]
        require("".join(s["marker"] for s in self.samples) == MARKERS, "Unexpected echo sequence")
        ticks = read(directory / "wire-ticks.json")
        scale = self.meta["timebaseNumerator"] / self.meta["timebaseDenominator"] / 1e9
        self.echo_times = [int(t) * scale for t in ticks]
        require(len(self.echo_times) == 20, "Missing independent host echo clocks")
        require(self.meta["hostClockErrorSeconds"] < .001, "Mach ticks and host CACurrentMediaTime diverged")
        for s, t in zip(self.samples, self.echo_times):
            require(s["keyAt"] <= t <= s["receivedAt"] <= s["acceptedAt"],
                    f"App clock does not bracket the independent host echo for {s['marker']}")
        require(self.times[0] < self.samples[0]["keyAt"] <= self.times[-1], "Source clock does not cover the keys")

    def latest(self, before):
        return int(np.searchsorted(self.times, before, side="left")) - 1


def references(rec):
    # Only the separate calibration process pauses each key's wire echo. A stable frame can
    # precede the next keyAt (the app may issue that key before its network echo is sent).
    refs = []
    for k in range(21):
        limit = rec.echo_times[k] - .030 if k < 20 else rec.times[-1] + .000001
        idx = rec.latest(limit)
        if k == 20:
            # Mac exits after its final report. Never allow a cleared window to become a template.
            valid = np.where((rec.times >= rec.samples[-1]["acceptedAt"]) & (rec.times <= limit))[0]
            require(len(valid) > 0, "No source frame for last calibration marker")
            # The source can deliver the previous compositor image after native acceptance.
            # Keep the newest localized repaint relative to marker 19, excluding a closed
            # window, a transient system surface and an unchanged preceding image.
            preceding = rec.gray[refs[-1]].astype(np.int16)
            candidates = []
            for index in valid:
                changed = np.abs(rec.gray[index].astype(np.int16) - preceding) >= 32
                if 3 <= changed.sum() <= max(50, changed.size * .04):
                    candidates.append(int(index))
            require(candidates, "No visible final calibration repaint")
            idx = candidates[-1]
        require(idx >= 0 and (k == 0 or rec.times[idx] >= rec.samples[k - 1]["acceptedAt"]),
                f"No isolated rendered calibration state {k}")
        refs.append(idx)
    require(len(set(refs)) == 21, "Calibration skipped one or more displayed states")
    return refs


def longest_band(count):
    ends = np.flatnonzero(np.diff(np.r_[False, count, False].astype(int)))
    require(len(ends) > 0, "No stationary terminal glyph band in calibration")
    return max(zip(ends[::2], ends[1::2]), key=lambda pair: pair[1] - pair[0])


def learn(rec, out):
    cols = rec.report["columns"]
    ref = references(rec)
    columns = [(PREFIX_WIDTH + i) % cols for i in range(20)]
    # A key at the left margin can scroll all numbered rows. Its glyph still appears in
    # the same bottom row, but its whole-window change should not influence registration.
    stationary = [i for i, col in enumerate(columns) if 0 < col < cols - 1]
    require(len(stationary) >= 12, "Too few independent non-wrapping keys")
    def delta(i):
        return np.abs(rec.gray[ref[i + 1]].astype(np.int16) - rec.gray[ref[i]]) >= 32
    votes = np.sum([delta(i).sum(axis=1) >= 2 for i in stationary], axis=0)
    y0, y1 = map(int, longest_band(votes >= math.ceil(len(stationary) * .65)))
    require(4 <= y1 - y0 <= rec.height // 8, "Unusable inferred terminal glyph band")
    xs = []
    for i in stationary:
        c = np.nonzero(delta(i)[y0:y1].sum(axis=0) >= 2)[0]
        if len(c):
            # Keyboard and window chrome lie outside the stationary terminal band.
            xs.append((columns[i], int(c[0])))
    slopes = [(xb - xa) / (b - a) for a, xa in xs for b, xb in xs if b - a >= 4]
    require(slopes, "Missing separated native glyph columns")
    pitch = float(np.median(slopes))
    require(3 <= pitch <= 60, "Unplausible captured native cell width")
    origin = float(np.median([x - col * pitch for col, x in xs]))
    fit = [abs(x - (origin + col * pitch)) for col, x in xs]
    require(np.median(fit) <= max(1.8, pitch * .18), "Changing pixels do not follow the expected terminal columns")
    models, locations = {}, []
    for i, col in enumerate(columns):
        x0 = round(origin + col * pitch)
        x1 = round(origin + (col + 1) * pitch)
        require(0 <= x0 < x1 <= rec.width, "Predicted glyph is outside the window")
        box = [x0, y0, x1, y1]
        glyph = np.array(rec.gray[ref[i + 1], y0:y1, x0:x1])
        prior = np.array(rec.gray[ref[i], y0:y1, x0:x1])
        # The positive template must contain varied glyph ink. A blank/solid cursor fails.
        ink = glyph.astype(float) > .5 * (int(glyph.max()) + int(glyph.min()))
        require(np.ptp(glyph) >= 48 and .02 < ink.mean() < .72,
                f"Calibration did not resolve actual glyph ink for {MARKERS[i]}")
        difference = float(np.abs(glyph.astype(float) - prior).mean())
        require(difference >= 7, f"Glyph {MARKERS[i]} was indistinguishable from its previous cell")
        # A blank cell and an inverse block are both independently rejected.
        bg = float(np.percentile(glyph, 12))
        blank = np.mean(np.abs(glyph.astype(float) - bg))
        solid = np.mean(np.abs(glyph.astype(float) - int(glyph.max())))
        threshold = max(0.8, min(12., difference * .26, blank * .32, solid * .26))
        models[MARKERS[i]] = glyph
        locations.append(dict(marker=MARKERS[i], column=col, box=box, meanAbsoluteErrorLimit=threshold))
    np.savez_compressed(out / "glyphs.npz", **models)
    result = {"columns": cols, "rows": rec.report["rows"], "width": rec.width, "height": rec.height,
              "referenceFrames": ref, "locations": locations, "originX": origin, "pitchX": pitch,
              "rowBand": [y0,y1], "medianOriginResidualPixels": float(np.median(fit))}
    write(out / "model.json", result)
    return result


def measure(rec, model_dir):
    model, glyphs = read(model_dir / "model.json"), np.load(model_dir / "glyphs.npz")
    require((rec.width, rec.height, rec.report["columns"], rec.report["rows"]) ==
            tuple(model[k] for k in ("width","height","columns","rows")), "Calibration and target geometry differ")
    results = []
    for i,(s, loc) in enumerate(zip(rec.samples, model["locations"])):
        key, marker = s["keyAt"], s["marker"]
        before = rec.latest(key)
        require(before >= 0, "No source frame before key")
        # Require a measured frame while this keystroke was isolated. Later characters
        # can move or wrap old glyphs; those samples do not prove this transition.
        end = rec.samples[i+1]["keyAt"] if i + 1 < len(rec.samples) else rec.times[-1] + .000001
        x0,y0,x1,y1 = loc["box"]
        target = glyphs[marker].astype(float)
        def error(k):
            return float(np.abs(rec.gray[k,y0:y1,x0:x1].astype(float) - target).mean())
        limit = loc["meanAbsoluteErrorLimit"]
        item = dict(marker=marker, keyAt=key, hostSocketEchoAt=rec.echo_times[i], box=loc["box"],
                    lastPreKeyFrame=before, errorLimit=limit, preKeyError=error(before))
        if item["preKeyError"] <= limit:
            item["unresolved"] = "same glyph patch already present before key"
        else:
            for k in range(before + 1, rec.latest(end) + 1):
                score = error(k)
                if score <= limit:
                    earliest = max(rec.echo_times[i], s["acceptedAt"], s.get("submittedAt") or 0)
                    if rec.times[k] < earliest:
                        item["unresolved"] = "glyph preceded its matching native acceptance or submission"
                        break
                    item.update(firstVisibleAt=float(rec.times[k]), firstVisibleFrame=k,
                        previousSourceAt=float(rec.times[k-1]), previousSourceFrame=k-1, matchError=score,
                        observedKeyToPixelMilliseconds=float(1000 * (rec.times[k] - key)),
                        sourceGapMilliseconds=float(1000 * (rec.times[k] - rec.times[k-1])))
                    break
            if "firstVisibleAt" not in item and "unresolved" not in item:
                item["unresolved"] = "no isolated observed glyph before the following key"
        results.append(item)
    observed = [s for s in results if "firstVisibleAt" in s]
    require(observed, "No independently observed echo glyphs")
    return {"clock": "SCStreamFrameInfo.displayTime (WindowServer mach_absolute_time), converted to CACurrentMediaTime seconds",
            "window": rec.meta["window"], "width": rec.width, "height": rec.height,
            "displayedFrames": len(rec.frames), "hostClockErrorSeconds": rec.meta["hostClockErrorSeconds"],
            "sourceIntervalsMilliseconds": distribution(np.diff(rec.times)*1000),
            "observedKeyToPixelMilliseconds": distribution(s["observedKeyToPixelMilliseconds"] for s in observed),
            "firstVisibleSourceGapsMilliseconds": distribution(s["sourceGapMilliseconds"] for s in observed),
            "samples": results, "all20Observed": len(observed) == 20}


def archive(path):
    if path.exists():
        with path.open("rb") as source, gzip.open(str(path) + ".gz", "wb", compresslevel=1) as output:
            shutil.copyfileobj(source,output,1024*1024)
        path.unlink()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator")
    parser.add_argument("app",type=Path)
    parser.add_argument("output",type=Path)
    args=parser.parse_args()
    app, output = args.app.resolve(), args.output.resolve()
    output.parent.mkdir(parents=True,exist_ok=True)
    recorder = output.parent / "echo-pixels-recorder"
    if not recorder.exists():
        subprocess.run(["xcrun","swiftc","-O",HERE/"echo-pixels.swift","-o",recorder],check=True)
    if args.simulator:
        developer = os.environ.get("DEVELOPER_DIR") or subprocess.check_output(["xcode-select","-p"],text=True).strip()
        subprocess.run(["open","-a",str(Path(developer)/"Applications/Simulator.app"),"--args","-CurrentDeviceUDID",args.simulator],check=True)
    binary = app / ("ThrushDemo" if args.simulator else "Contents/MacOS/ThrushDemo")
    build = hashlib.sha256(binary.read_bytes()).hexdigest()[:16]
    calibration = output.parent / ("echo-pixel-calibration-" + build)
    def capture(directory, report_path, phase):
        directory.mkdir()
        child_env = dict(os.environ,THRUSH_ECHO_PIXEL_DIR=str(directory),THRUSH_ECHO_PIXEL_RECORDER=str(recorder),
                         THRUSH_ECHO_PIXEL_CALIBRATION="1" if phase=="calibration" else "0")
        cmd = ["bun",PEER] + (["--simulator",args.simulator] if args.simulator else []) + [app,report_path]
        subprocess.run(cmd,check=True,env=child_env,timeout=145)
        return Recording(directory,read(report_path))
    calibration_error = None
    if not (calibration / "model.json").exists():
        error_file = calibration / "registration-error.json"
        if error_file.exists():
            calibration_error = read(error_file)["reason"]
        else:
            try:
                cal = capture(calibration,calibration / "native.json","calibration")
                learn(cal,calibration)
            except ValueError as error:
                calibration_error = str(error)
                write(error_file, {"reason": calibration_error})
            finally:
                archive(calibration/"window.gray")
    directory = output.with_suffix(".pixels")
    try:
        rec = capture(directory,output,"measured")
        # Preserve a genuinely timed native run and source pixels even when offline
        # registration fails. A nonzero exit surfaces incomplete evidence to the caller.
        if calibration_error:
            write(directory/"result.json", {"status":"inconclusive", "reason":calibration_error,
                  "calibration":calibration.name, "all20Observed":False})
            raise ValueError("Captured native pixels; calibration needs review: " + calibration_error)
        pixels = measure(rec,calibration)
        pixels["calibration"] = calibration.name
        pixels["windowStreamEnded"] = rec.meta.get("windowStreamEnded")
        write(directory/"result.json",pixels)
        for s, p in zip(rec.report["samples"],pixels["samples"]):
            if "firstVisibleAt" in p:
                s["firstPixelAt"]=p["firstVisibleAt"]
                s["previousPixelSampleAt"]=p["previousSourceAt"]
        rec.report["pixelEvidence"]=directory.name+"/result.json"
        write(output,rec.report)
        print("Independently observed",pixels["observedKeyToPixelMilliseconds"]["count"],"of 20 echo glyphs",flush=True)
    finally:
        archive(directory/"window.gray")


if __name__ == "__main__":
    try: main()
    except (OSError, ValueError, subprocess.SubprocessError) as e:
        sys.exit(str(e))
