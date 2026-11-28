#!/usr/bin/env python3
"""Measure ThrushCore against libghostty-vt and @xterm/headless on identical workloads.

Every core receives the same bytes at the same grid size and history limit. Rounds interleave
the cores in a shuffled order so load on a shared machine lands on all of them alike. Each run
reports its final screen, and the report lists every core whose visible text, cursor, active
screen or history differs from @xterm/headless under Node.

Usage: python3 scripts/comparison/run.py [--rounds 5]
"""

import argparse
import hashlib
import json
import os
import platform
import random
import shutil
import statistics
import subprocess
import sys
import tarfile
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

sys.dont_write_bytecode = True  # A clean checkout stays clean, so the report's revision is exact.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import workloads  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
HISTORY = 1000
GRIDS = [(80, 24), (240, 60)]
CHUNK = 4096
WARMUPS = 3
PASSES = 3
CORES = ["thrush", "ghostty", "xterm-node", "xterm-bun"]
REFERENCE = ROOT / "Fixtures" / "reference"

ZIG = ("0.17.1", "zig-aarch64-macos-0.17.1.tar.xz",
       "75f1bc7a1e9852f17ec9a0c1895f767c4ec56d46bc8a834920eece1d0359dd8d",
       ["https://ziglang.org/download/0.17.1/", "https://pkg.machengine.org/zig/"])
GHOSTTY = ("1.0.2", "https://release.files.ghostty.org/libghostty-vt/1.0.2/", {
    "libghostty-vt-1.0.2.tar.gz": "1dcafa8a3357f3a6bbf4f2696e61de611400c5469518716793dfffd35f008b3e",
    "libghostty-vt-1.0.2-deps.tar.gz": "c56156dbea82fdf71f13bf0d704cdf4393b6a04208d7f9691e0d7f60c7f9ca4d",
})


def log(message):
    print(message, file=sys.stderr, flush=True)


def fetch(urls, path, sha256):
    if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() == sha256:
        return
    for url in urls:
        try:
            log(f"Downloading {url}")
            # The Ghostty release host rejects Python's default User-Agent.
            request = urllib.request.Request(url, headers={"User-Agent": "thrush-comparison"})
            with urllib.request.urlopen(request, timeout=600) as response:
                data = response.read()
        except OSError as error:
            log(f"  {error}")
            continue
        if hashlib.sha256(data).hexdigest() == sha256:
            path.write_bytes(data)
            return
        log("  checksum mismatch")
    raise SystemExit(f"could not download {path.name} with SHA-256 {sha256}")


def build_ghostty(tools):
    """Builds the pinned libghostty-vt release with ReleaseFast from its verified source tarballs."""
    version, base, tarballs = GHOSTTY
    prefix = tools / f"ghostty-{version}"
    if (prefix / "lib" / "libghostty-vt.a").exists():
        return prefix
    zig_version, zig_name, zig_sha, mirrors = ZIG
    fetch([mirror + zig_name for mirror in mirrors], tools / zig_name, zig_sha)
    for name, sha in tarballs.items():
        fetch([base + name], tools / name, sha)
    for name in [zig_name, *tarballs]:
        with tarfile.open(tools / name) as archive:
            archive.extractall(tools, filter="data")
    cache = tools / "zig-cache"
    shutil.rmtree(cache, ignore_errors=True)
    log(f"Building libghostty-vt {version} with Zig {zig_version}")
    subprocess.run([tools / zig_name.removesuffix(".tar.xz") / "zig", "build", "--prefix", prefix,
                    "--system", tools / f"libghostty-vt-{version}-deps", "-Doptimize=ReleaseFast"],
                   cwd=tools / f"libghostty-vt-{version}", env={**os.environ, "ZIG_GLOBAL_CACHE_DIR": str(cache)},
                   check=True)
    return prefix


def find_node():
    """Returns a Node.js executable, skipping Bun's node shim."""
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        candidate = Path(directory) / "node"
        if not os.access(candidate, os.X_OK):
            continue
        probe = subprocess.run([candidate, "-e", "process.stdout.write(typeof Bun)"],
                               capture_output=True, text=True)
        if probe.returncode == 0 and probe.stdout == "undefined":
            return str(candidate)
    raise SystemExit("Node.js is required, and only Bun's node shim was found on PATH")


def build(tools):
    out = ROOT / ".build" / "comparison"
    out.mkdir(parents=True, exist_ok=True)
    log("Building ThrushBench in Release")
    subprocess.run(["swift", "build", "-c", "release", "--product", "ThrushBench"], cwd=ROOT, check=True,
                   stdout=subprocess.DEVNULL)
    ghostty = build_ghostty(tools)
    subprocess.run(["cc", "-O2", "-std=c11", "-DGHOSTTY_STATIC", f"-I{ghostty / 'include'}", HERE / "ghostty.c",
                    ghostty / "lib" / "libghostty-vt.a", "-o", out / "ghostty"], check=True)
    subprocess.run(["cc", "-O2", "-dynamiclib", HERE / "allocations.c", "-o", out / "allocations.dylib"], check=True)
    node, bun = find_node(), shutil.which("bun")
    if not bun:
        raise SystemExit("Bun is required")
    subprocess.run([bun, "install", "--cwd", REFERENCE, "--frozen-lockfile", "--silent"], check=True)
    xterm = [str(HERE / "xterm.mjs")]
    commands = {
        "thrush": [str(ROOT / ".build" / "release" / "ThrushBench"), "--workload"],
        "ghostty": [str(out / "ghostty")],
        "xterm-node": [node, *xterm],
        "xterm-bun": [bun, *xterm],
    }
    return commands, out


def run_core(command, workload, grid, warmups, passes, allocations=None):
    arguments = [*command, workload, str(grid[0]), str(grid[1]), str(CHUNK), str(warmups), str(passes), str(HISTORY)]
    env = {**os.environ, "DYLD_INSERT_LIBRARIES": str(allocations)} if allocations else None
    result = subprocess.run(arguments, capture_output=True, text=True, env=env)
    if result.returncode != 0:
        raise SystemExit(f"{' '.join(arguments)} failed:\n{result.stderr}")
    return json.loads(result.stdout)


def normalized(state, columns):
    """Trailing blanks and a cursor waiting to wrap are spelled differently by each core."""
    row, column = state["cursor"]
    return {"rows": [text.rstrip(" ") for text in state["rows"]], "cursor": [row, min(column, columns - 1)],
            "alternate": state["alternate"], "history": state["history"]}


def compare(states, columns):
    """Checks every core's final state against the Node xterm run and returns the differences."""
    reference = normalized(states["xterm-node"], columns)
    differences = {}
    for core, state in states.items():
        state = normalized(state, columns)
        found = []
        rows = [index for index, (a, b) in enumerate(zip(state["rows"], reference["rows"])) if a != b]
        if rows:
            found.append({"field": "rows", "count": len(rows), "first": rows[0],
                          "expected": reference["rows"][rows[0]], "actual": state["rows"][rows[0]]})
        for field in ("cursor", "alternate"):
            if state[field] != reference[field]:
                found.append({"field": field, "expected": reference[field], "actual": state[field]})
        # libghostty-vt prunes history in whole pages, so its depth lands near the limit rather than on it.
        if core != "ghostty" and state["history"] != reference["history"]:
            found.append({"field": "history", "expected": reference["history"], "actual": state["history"]})
        if found:
            differences[core] = found
    return differences


def environment():
    def output(*command):
        try:
            return subprocess.run(command, capture_output=True, text=True, cwd=ROOT).stdout.strip()
        except OSError:
            return None
    load = os.getloadavg()
    return {
        "commit": output("git", "rev-parse", "HEAD"),
        "worktreeDirty": bool(output("git", "status", "--porcelain")),
        "processor": output("sysctl", "-n", "machdep.cpu.brand_string"),
        "coreCount": os.cpu_count(),
        "os": platform.mac_ver()[0],
        "loadAverage": {"oneMinute": load[0], "fiveMinutes": load[1], "fifteenMinutes": load[2]},
        "swift": output("swift", "--version").splitlines()[0] if output("swift", "--version") else None,
    }


def measure(commands, inputs, rounds):
    """Runs every core once per workload and grid in each round, in a freshly shuffled order."""
    samples, states, runtimes = {}, {}, {}
    order = random.Random(1)
    for round_index in range(rounds):
        started = time.monotonic()
        for workload in inputs:
            for grid in GRIDS:
                key = (workload["name"], grid)
                cores = CORES[:]
                order.shuffle(cores)
                for core in cores:
                    result = run_core(commands[core], workload["path"], grid, WARMUPS, PASSES)
                    samples.setdefault(key, {}).setdefault(core, []).append(result["passes"])
                    states.setdefault(key, {})[core] = result["state"]
                    if "runtime" in result:
                        runtimes[core] = result["runtime"]
        log(f"Round {round_index + 1}/{rounds} took {time.monotonic() - started:.0f} s, "
            f"load {os.getloadavg()[0]:.0f}")
    return samples, states, runtimes


def count_allocations(commands, inputs, library):
    counts = {}
    for workload in inputs:
        for grid in GRIDS:
            for core in ("thrush", "ghostty"):
                result = run_core(commands[core], workload["path"], grid, 1, 1, library)
                counts[(workload["name"], grid, core)] = result["passes"][0]["allocations"]
    return counts


def summarize(inputs, samples, states, allocations):
    results = []
    for workload in inputs:
        for grid in GRIDS:
            key = (workload["name"], grid)
            cores, rounds = {}, {}
            for core, runs in samples[key].items():
                wall = [sample["wall"] for passes in runs for sample in passes]
                median = statistics.median(wall)
                rounds[core] = [statistics.median(sample["wall"] for sample in passes) for passes in runs]
                cores[core] = {"medianWallNanoseconds": round(median),
                               "roundMedianWallNanoseconds": [round(value) for value in rounds[core]],
                               "samples": len(wall), "mibPerSecond": workload["bytes"] / (1 << 20) / (median / 1e9),
                               "history": states[key][core]["history"]}
                if (*key, core) in allocations:
                    cores[core]["allocations"] = allocations[(*key, core)]
            xterm = min(("xterm-node", "xterm-bun"), key=lambda core: cores[core]["medianWallNanoseconds"])

            def speedup(core):
                # Each round runs the cores back to back, so pairing within a round cancels that round's load.
                paired = [other / mine for other, mine in zip(rounds[core], rounds["thrush"])]
                return {"median": statistics.median(paired), "roundRange": [min(paired), max(paired)]}

            results.append({
                "workload": workload["name"], "columns": grid[0], "rows": grid[1],
                "cores": cores, "fastestXterm": xterm,
                "speedup": {"ghostty": speedup("ghostty"), "xterm": speedup(xterm)},
                "differences": compare(states[key], grid[0]),
            })
    return results


def table(results):
    lines = ["| Workload | Grid | Thrush MiB/s | libghostty-vt MiB/s | xterm MiB/s | vs libghostty-vt | vs xterm | Screens |",
             "| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |"]
    for result in results:
        cores = result["cores"]
        xterm = result["fastestXterm"].removeprefix("xterm-")
        screens = "match" if not result["differences"] else "differ: " + ", ".join(sorted(result["differences"]))
        lines.append(f"| {result['workload']} | {result['columns']}×{result['rows']} "
                     f"| {cores['thrush']['mibPerSecond']:.0f} | {cores['ghostty']['mibPerSecond']:.0f} "
                     f"| {cores[result['fastestXterm']]['mibPerSecond']:.0f} ({xterm}) "
                     f"| {result['speedup']['ghostty']['median']:.2f}× | {result['speedup']['xterm']['median']:.2f}× | {screens} |")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--workloads", help="comma-separated subset of workloads")
    parser.add_argument("--output", type=Path, default=ROOT / ".build" / "benchmarks" / "comparison.json")
    options = parser.parse_args()

    tools = ROOT / ".build" / "comparison" / "tools"
    tools.mkdir(parents=True, exist_ok=True)
    commands, out = build(tools)
    inputs = workloads.write(out / "workloads")
    if options.workloads:
        selected = options.workloads.split(",")
        inputs = [workload for workload in inputs if workload["name"] in selected]
    before = environment()
    samples, states, runtimes = measure(commands, inputs, options.rounds)
    log("Counting allocations")
    allocations = count_allocations(commands, inputs, out / "allocations.dylib")
    results = summarize(inputs, samples, states, allocations)
    report = {
        "schemaVersion": 1,
        "recordedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "environment": before,
        "environmentAfter": environment(),
        "method": {"rounds": options.rounds, "warmupsPerRun": WARMUPS, "passesPerRun": PASSES,
                   "chunkBytes": CHUNK, "historyRows": HISTORY,
                   "timing": "rates use the median wall time of all measured passes, "
                             "and ratios use the median of each round's paired ratio"},
        "cores": {
            "thrush": {"build": "swift build -c release"},
            "ghostty": {"version": GHOSTTY[0], "zig": ZIG[0], "build": "zig build -Doptimize=ReleaseFast",
                        "sources": GHOSTTY[2]},
            "xterm": {"packages": {name: version for name, version in json.loads(
                          (REFERENCE / "package.json").read_text())["dependencies"].items() if name != "@xterm/xterm"},
                      "runtimes": runtimes, "unicode": "11"},
        },
        "workloads": [{key: value for key, value in workload.items() if key != "path"} for workload in inputs],
        "results": results,
    }
    options.output.parent.mkdir(parents=True, exist_ok=True)
    options.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print(table(results))
    for result in results:
        for core, found in result["differences"].items():
            print(f"{result['workload']} {result['columns']}×{result['rows']} {core}: {found[0]}")
    print(f"Report {options.output}")


if __name__ == "__main__":
    main()
