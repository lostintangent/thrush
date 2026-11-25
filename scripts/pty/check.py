"""Start a private production Toy Box, exercise its PTYs, and check the independent numbered log."""
import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid


def wait_for(description, check, process, seconds=45):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        if process.poll() is not None:
            raise RuntimeError(f"{description}: process exited with {process.returncode}")
        time.sleep(0.025)
    raise TimeoutError(description)


@contextmanager
def server(repo, root, shell, log, working_tree=False):
    launcher = Path(__file__).resolve().parents[1] / "serve-pty.py"
    with log.open("w") as output, subprocess.Popen(
        [sys.executable, launcher, "--toy-box", repo, "--data-dir", root / "data", "--shell", shell,
         *(["--working-tree"] if working_tree else [])],
        stdout=output, stderr=subprocess.STDOUT,
        start_new_session=True,
    ) as process:
        try:
            # Trust only the port bound by this process, read from its own stdout.
            address = wait_for("Toy Box loopback listener",
                               lambda: re.search(r"Listening on: (http://127\.0\.0\.1:\d+)/", log.read_text()),
                               process, seconds=900)
            yield address[1]
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
            process.wait()


def read_json(path):
    return json.loads(path.read_text())


def timing(run, payload_offset, payload_length):
    frames = read_json(run / "frames.json")
    writes = read_json(run / "writes.json")
    # Both clocks use macOS mach_absolute_time. Compare bytes accepted by the PTY in 8 KiB batches
    # with bytes applied from each binary frame, excluding the shell prompt and protocol fences.
    if not frames[0]["uptimeNanoseconds"] <= writes[0][0] <= writes[-1][0] <= frames[-1]["uptimeNanoseconds"]:
        raise RuntimeError("Producer and client timestamps do not share the expected uptime interval")
    events = [(stamp, written, None) for stamp, written in writes]
    delivered = []
    largest = previous = previous_wire = 0
    for frame in frames:
        stamp = frame["uptimeNanoseconds"]
        wire = frame["cumulativeBytes"]
        applied = min(payload_length, max(0, wire - payload_offset))
        largest = max(largest, wire - previous_wire)
        if applied > previous:
            delivered.append(stamp)
            events.append((stamp, None, applied))
        previous, previous_wire = applied, wire
    produced = applied = peak = 0
    for _, written, read in sorted(events, key=lambda item: item[0]):
        if written is not None:
            produced = written
        if read is not None:
            applied = read
        peak = max(peak, produced - applied)
    # A skipped tail can end the timed live interval early. Permanent loss also contributes to peak.
    return {"peakProducedMinusAppliedBytes": peak, "largestReceivedFrameBytes": largest,
            "liveFrames": len(frames), "firstToLastAppliedMiBPerSecond":
            round(payload_length / 1048576 / ((delivered[-1] - delivered[0]) / 1e9), 3) if len(delivered) > 1 else None}


def check_log(run, scenario):
    producer = read_json(run / "produced.json")
    client = read_json(run / "client.json")
    wire = (run / "wire.bin").read_bytes()
    if not (len(wire) + client.get("replayBytes", 0) == client["receivedBytes"] == client["appliedBytes"]):
        raise RuntimeError("Adapter byte counts disagree with the independent stream capture")
    before, start, remainder = wire.partition(b"THRUSH-BEGIN\r\n")
    payload, end, _ = remainder.partition(b"\x1b[1;1HTHRUSH-END\x1b[K")
    if not (start and end):
        raise RuntimeError(f"Missing PTY boundary in {scenario} ({len(wire)} bytes)")

    count = 8192 if scenario == "paced" else 131072
    expected = b"".join(("THRUSH " + str(i).zfill(6) + " " + "." * 48 + "\r\n").encode()
                        for i in range(1, count + 1))
    if producer["markers"] != count or producer["payloadBytes"] != len(expected):
        raise RuntimeError("Producer workload differs from the oracle")
    markers = [int(match[1]) for match in re.finditer(rb"THRUSH (\d{6}) \.{48}\r\n", payload)]
    unique = set(markers)
    if markers != sorted(unique) or not unique.issubset(range(1, count + 1)):
        raise RuntimeError("Duplicate, out-of-range, or reordered complete marker")
    missing = count - len(unique)
    first_missing = next((i for i in range(1, count + 1) if i not in unique), None)
    expected_rows = ["THRUSH-END"] + [f"THRUSH {i:06d} " + "." * 48 for i in range(count - 21, count + 1)] + [""]
    live_rows, replay_rows = client.pop("liveRows"), client.pop("replayRows")

    def last_marker(rows):
        return max((int(match[1]) for row in rows if (match := re.fullmatch(r"THRUSH (\d{6}) \.{48}", row))),
                   default=None)

    # Keep evidence when a direct run fails too, including corruptions with the same byte count.
    return {
        **client, **timing(run, len(before) + len(start), len(payload)), "scenario": scenario,
        "liveLastVisibleMarker": last_marker(live_rows), "replayLastVisibleMarker": last_marker(replay_rows),
        "liveScreenMatchesExpected": live_rows == expected_rows, "replayScreenMatchesExpected": replay_rows == expected_rows,
        "markersExpected": count, "markersIntact": len(unique),
        "missingOrPartialMarkers": missing, "firstMissingOrPartialMarker": first_missing,
        "expectedPayloadBytes": len(expected), "receivedPayloadBytes": len(payload),
        "missingPayloadBytes": len(expected) - len(payload), "payloadMatches": expected == payload,
        "producerSeconds": producer["seconds"],
        "producerMiBPerSecond": round(len(expected) / 1048576 / producer["seconds"], 3),
        "receivedPayloadMiBPerSecondToExit": round(len(payload) / 1048576 / (client["commandToExitMs"] / 1000), 3),
    }


def exercise(binary, endpoint, token, work, scenario, limit=None):
    run = work / scenario
    run.mkdir()
    command = [binary, endpoint, token, scenario, run]
    if limit:
        command.append(str(limit * 1048576))
    with subprocess.Popen(command) as process:
        try:
            wait_for("Real shell started its numbered log", (run / "armed").exists, process)
            if scenario == "suspended":
                # Suspend the whole client, including the URLSession receive loop and socket reads.
                process.send_signal(signal.SIGSTOP)
                _, status = os.waitpid(process.pid, os.WUNTRACED)
                if not os.WIFSTOPPED(status):
                    raise RuntimeError("Swift client did not enter the suspended state")
            (run / "go").touch()
            wait_for("Real PTY finished writing the log", (run / "produced.json").exists, process)
            if scenario == "suspended":
                # Let the server parse and enqueue the last PTY chunks before the client resumes.
                time.sleep(1)
                process.send_signal(signal.SIGCONT)
            if process.wait(timeout=60):
                raise RuntimeError(f"Swift client failed in {scenario}")
        finally:
            if process.poll() is None:
                process.kill()
    return {**check_log(run, scenario), "readerLimitMiBPerSecond": limit}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--toy-box", type=Path, default=Path("../toy-box"))
    parser.add_argument("--working-tree", action="store_true", help="Test the current Toy Box checkout")
    args = parser.parse_args()

    def terminate(signum, frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, terminate)
    binary = args.binary.resolve()
    report_path = Path(".build/benchmarks") / ("pty-smoke-candidate.json" if args.working_tree else "pty-smoke.json")
    report_path.parent.mkdir(parents=True, exist_ok=True)
    token = str(uuid.uuid4())
    with tempfile.TemporaryDirectory(prefix="thrush-pty-") as temp:
        root = Path(temp)
        # A fresh nonce identifies exactly this server to the client before it sends shell input.
        shell = root / "shell"
        shell.write_text(f"#!/bin/sh\nprintf 'THRUSH-{token}\\n'\nexec /bin/sh -i\n")
        shell.chmod(0o700)
        log = root / "server.log"
        try:
            with server(args.toy_box, root, shell, log, working_tree=args.working_tree) as endpoint:
                work = root / "data" / "work"
                shutil.copyfile(Path(__file__).with_name("producer.py"), work / "producer.py")
                source = read_json(root / "data" / "source.json")
                runs = []
                baseline = next(row["receiveMiBPerSecond"] for row in read_json(Path("Benchmarks/headless.json"))["bulk"]
                                if row["grid"] == {"columns": 80, "rows": 24})
                for scenario in ("paced", "live", "limited", "suspended"):
                    result = exercise(binary, endpoint, token, work, scenario, baseline / 4 if scenario == "limited" else None)
                    print(json.dumps(result), flush=True)
                    runs.append(result)
                subprocess.run([binary, endpoint, token, "lifecycle", root], timeout=75, check=True)
        except BaseException:
            if log.exists():
                print(log.read_text()[-4000:], file=sys.stderr)
            raise

    report = {**source, "bun": subprocess.check_output(["bun", "--version"], text=True).strip(),
              "thrushHead": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
              "thrushWorktreeDirty": bool(subprocess.check_output(["git", "status", "--porcelain"])),
              "macOS": platform.mac_ver()[0], "hardware": subprocess.check_output(
                  ["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
              "grid": [80, 24], "runs": runs}
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    if not runs[0]["payloadMatches"]:
        raise RuntimeError(f"Paced live output differs from the reference. See {report_path}")
    if not all(run["replayScreenMatchesExpected"] for run in runs):
        raise RuntimeError(f"Server replay did not restore the expected visible rows. See {report_path}")
    if any(run["missingPayloadBytes"] < 0 for run in runs):
        raise RuntimeError("Live output contains extra payload bytes")
    print(report_path)


if __name__ == "__main__":
    main()
