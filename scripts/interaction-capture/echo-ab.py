"""Interleave independent native one-key echoes from two Release builds on one hosted machine."""
import argparse
import contextlib
import json
import math
from pathlib import Path
import platform
import re
import runpy
import statistics
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"
PLATFORMS = ("mac", "simulator")
PRODUCTS = ("Sources/Thrush", "Sources/ThrushCore")
METRICS = {
    "keyToAcceptance": ("keyAt", "acceptedAt"),
    "receiptToAcceptance": ("receivedAt", "acceptedAt"),
    "keyToSubmission": ("keyAt", "submittedAt"),
    "keyToPresentation": ("keyAt", "presentedAt"),
    "keyToFirstObservedGlyph": ("keyAt", "firstPixelAt"),
    "acceptanceToSubmission": ("acceptedAt", "submittedAt"),
}


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()


def save(path, value):
    path.write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")


def run_logged(command, log, cwd, seconds):
    with log.open("w") as handle:
        subprocess.run(command, cwd=cwd, stdout=handle, stderr=subprocess.STDOUT, timeout=seconds, check=True)


def distribution(samples):
    values = sorted(samples)
    if not values:
        return {"count": 0}
    def rank(p):
        return values[max(0, math.ceil(len(values) * p) - 1)]
    return {"count": len(values), "p50": statistics.median(values), "p95": rank(.95),
            "p99": rank(.99), "min": values[0], "max": values[-1]}


def times_for(report, endpoints):
    start, end = endpoints
    samples = report["samples"]
    if [s["marker"] for s in samples] != list("abcdefghijklmnopqrst"):
        raise ValueError("Single-key trial did not return all twenty native input markers")
    values = {}
    for sample in samples:
        if sample.get(end) is None or sample.get(start) is None:
            continue
        delta = 1000 * (sample[end] - sample[start])
        if not math.isfinite(delta):
            raise ValueError("Invalid timestamp for " + sample["marker"])
        values[sample["marker"]] = delta
    return values


def summarize(pairs):
    metrics = {}
    for name, endpoints in METRICS.items():
        totals = {side: [] for side in ("baseline", "candidate")}
        pair_data = []
        median_changes = []
        for pair in pairs:
            sides = {side: times_for(report, endpoints) for side, report in pair.items()}
            for side in totals:
                totals[side].extend(sides[side].values())
            a, b = sides["baseline"], sides["candidate"]
            shared = sorted(a.keys() & b.keys())
            item = {"baseline": distribution(a.values()), "candidate": distribution(b.values()),
                    "matchingKeyDelta": distribution(b[k] - a[k] for k in shared)}
            if shared:
                change = statistics.median(b[k] for k in shared) - statistics.median(a[k] for k in shared)
                item["differenceOfMatchedMedians"] = change
                median_changes.append(change)
            pair_data.append(item)
        metrics[name] = {side: distribution(values) for side, values in totals.items()}
        metrics[name].update(pairs=pair_data, pairedRunMedianDifferences=distribution(median_changes))
    return metrics


def compare(roots, product_parent, target, output):
    output.mkdir(parents=True)
    bundles = {}
    for side, repo in roots.items():
        run_logged([repo / "scripts/build-demo.sh", target], output / (side + "-build.log"), repo, 1000)
        bundles[side] = repo / ".build/demo" / target / "Thrush.app"
    capture = runpy.run_path(str(SCRIPTS / "capture-simulator.py"))
    reservation = capture["disposable_phone"](output) if target == "simulator" else contextlib.nullcontext(None)
    orders = [("baseline", "candidate"), ("candidate", "baseline"),
              ("candidate", "baseline"), ("baseline", "candidate")]
    pairs = []
    with reservation as device:
        def once(side, label):
            file = output / (label + "-" + side + ".json")
            command = ["bun", SCRIPTS / "interaction-peer.ts"]
            if device:
                command += ["--simulator", device]
            command += [bundles[side], file]
            print(target, label, side, flush=True)
            run_logged(command, file.with_suffix(".log"), ROOT, 190)
            report = json.loads(file.read_text())
            if len(times_for(report, METRICS["keyToAcceptance"])) != 20:
                raise RuntimeError("Missing content-verified native acceptance for one or more keys")
            return report

        for side in ("baseline", "candidate"):
            once(side, "warmup")
        for i, order in enumerate(orders):
            pair = {side: once(side, f"pair-{i+1}") for side in order}
            pairs.append(pair)
            save(output / "summary.json", {"platform": target, "simulator": device, "productParent": product_parent,
                 "checkoutCommits": {side: git(repo, "rev-parse", "HEAD") for side, repo in roots.items()},
                 "pairOrder": orders[:len(pairs)], "warmupsExcluded": 1, "units": "milliseconds",
                 "host": {"machine": platform.machine(), "macOS": platform.mac_ver()[0]},
                 "metrics": summarize(pairs)})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("product_parent")
    parser.add_argument("platform", choices=["both", *PLATFORMS])
    parser.add_argument("output", type=Path)
    parser.add_argument("--baseline", default="HEAD^", help="Clean capture commit with identical instrumentation")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.product_parent):
        raise ValueError("Pass the exact product-parent commit")
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="thrush-echo-pair-") as temporary:
        baseline = Path(temporary) / "baseline"
        baseline_sha = git(ROOT, "rev-parse", "--verify", args.baseline + "^{commit}")
        git(ROOT, "worktree", "add", "--detach", str(baseline), baseline_sha)
        try:
            git(baseline, "diff", "--exit-code", args.product_parent, "HEAD", "--", *PRODUCTS, "Package.swift")
            changes = git(ROOT, "diff", "--name-only", baseline_sha, "HEAD").splitlines()
            product_diff = [f for f in changes if not f.startswith("Tests/")]
            if not product_diff or any(not f.startswith(tuple(d + "/" for d in PRODUCTS)) for f in product_diff):
                raise ValueError("The two capture commits must differ only in measured product files")
            roots = {"baseline": baseline, "candidate": ROOT}
            save(root / "source.json", {"candidate": git(ROOT, "rev-parse", "HEAD"), "productParent": args.product_parent,
                "baseline": git(baseline, "rev-parse", "HEAD"), "onlySourceDifferences": product_diff,
                "peerBlob": git(ROOT, "rev-parse", "HEAD:scripts/interaction-peer.ts"),
                "probeBlob": git(ROOT, "rev-parse", "HEAD:Sources/ThrushDemo/InteractionBenchmark.swift")})
            failed = []
            for target in PLATFORMS if args.platform == "both" else [args.platform]:
                try:
                    compare(roots, args.product_parent, target, root / target)
                except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
                    save(root / (target + "-failure.json"), {"error": str(error)})
                    failed.append(target)
            if failed:
                raise RuntimeError("Incomplete native timing on " + ", ".join(failed))
        finally:
            git(ROOT, "worktree", "remove", "--force", str(baseline))


if __name__ == "__main__":
    main()
