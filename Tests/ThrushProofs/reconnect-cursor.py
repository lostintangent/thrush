"""Decode the original simulator movie in software and check its confirmed insertion cell."""
from pathlib import Path
import gzip
import hashlib
import json
import math
import platform
import re
import shutil
import subprocess
import sys
import tempfile
from urllib.request import urlopen

from spinner import measure


def decoder(work):
    # Hosted Xcode VMs may have no working hardware video decoder. This tool is capture-only.
    pins = {"arm64": ("arm64", "8923876afa8db5585022d7860ec7e589af192f441c56793971276d450ed3bbfa"),
            "x86_64": ("x64", "929b375c1182d956c51f7ac25e0b2b0411fb01f6f407aa15c9758efeb4242106")}
    arch, digest = pins[platform.machine()]
    url = f"https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffmpeg-darwin-{arch}.gz"
    archive = work / "ffmpeg.gz"
    print(f"Downloading the pinned FFmpeg b6.1.1 software decoder for {arch}", flush=True)
    with urlopen(url, timeout=60) as response, archive.open("wb") as destination:
        shutil.copyfileobj(response, destination)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
        raise ValueError("The FFmpeg archive does not match its published SHA-256.")
    binary = work / "ffmpeg"
    with gzip.open(archive, "rb") as source, binary.open("wb") as destination:
        shutil.copyfileobj(source, destination)
    binary.chmod(0o700)
    return binary


def sample(ffmpeg, movie, time, image):
    # showinfo reports the source presentation timestamp after the filter selects a real frame.
    result = subprocess.run([ffmpeg, "-nostdin", "-hide_banner", "-hwaccel", "none", "-threads", "1",
                             "-i", movie, "-an", "-vf", f"select=gte(t\\,{time:.6f}),showinfo",
                             "-frames:v", "1", "-fps_mode", "passthrough", "-threads", "1", "-y", image],
                            capture_output=True, text=True, check=True, timeout=45)
    pts = re.search(r"\bn:\s*0\s+pts:\s*\d+\s+pts_time:([-+.\deE]+)", result.stderr)
    if not pts or not image.is_file():
        raise ValueError(f"No native movie frame at {time}s.")
    return float(pts.group(1))


def check(movie, views, appearance, still, work):
    state = views["reconnecting"]
    start, end = views["spinnerIntervalSeconds"]
    duration = end - start
    if start < 0 or duration < 0.8:
        raise ValueError("The movie must cover a sustained pre-replay outage.")
    ffmpeg = decoder(work)
    previous = start
    midpoint = (start + end) / 2
    # The adjacent midpoint samples avoid aliasing a periodic spinner with evenly spaced seeks.
    times = [start + duration / 4, midpoint, midpoint + min(0.2, duration / 8), end - duration / 4]
    leading = []
    for n, target in enumerate(times):
        frame = work / f"sample-{n}.png"
        actual = sample(ffmpeg, movie, target, frame)
        if not previous < actual < end:
            raise ValueError(f"Movie timestamp {actual} is outside the measured outage interval.")
        previous = actual
        result = measure(frame, state, appearance, 8, len("~/thrush % git"), "Reconnecting", use_adjacent_canvas=True)
        point = result["spokePixel"]
        leading.append(point)
        print(f"Movie frame {actual}s: leading spoke at {point}, contrast {result['contrast']:.3f}:1.", flush=True)
        if target == midpoint:
            shutil.copyfile(frame, still)
    # A frozen indicator can still have sufficient contrast. Require a change of leading spoke.
    if max(math.dist(a, b) for a in leading for b in leading) < min(result["region"][2:]) / 4:
        raise ValueError("The leading spoke stayed in the same position during the recorded outage.")


if __name__ == "__main__":
    movie, metadata, appearance, still = sys.argv[1:]
    with tempfile.TemporaryDirectory() as scratch:
        check(Path(movie), json.loads(Path(metadata).read_text()), appearance, Path(still), Path(scratch))
