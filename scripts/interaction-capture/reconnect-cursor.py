"""Decode the original simulator movie in software and check its confirmed insertion cell."""
from pathlib import Path
import gzip
import hashlib
import json
import platform
import re
import runpy
import shutil
import subprocess
import sys
import tempfile
from urllib.request import urlopen


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
    measure = runpy.run_path(str(Path(__file__).with_name("spinner.py")))["measure"]
    state = views["reconnecting"]
    start, end = views["spinnerIntervalSeconds"]
    if start < 0 or end - start < 0.8:
        raise ValueError("The movie must cover a sustained pre-replay outage.")
    ffmpeg = decoder(work)
    previous = start
    for n, fraction in enumerate((0.25, 0.5, 0.75)):
        frame = work / f"sample-{n}.png"
        actual = sample(ffmpeg, movie, start + fraction * (end - start), frame)
        if not previous < actual < end:
            raise ValueError(f"Movie timestamp {actual} is outside the measured outage interval.")
        previous = actual
        result = measure(frame, state, appearance, 8, len("~/thrush % git"))
        print(f"Movie frame {actual}s: cursor spinner at {result['region']}, contrast {result['contrast']:.2f}:1.", flush=True)
        if fraction == 0.5:
            shutil.copyfile(frame, still)


if __name__ == "__main__":
    movie, metadata, appearance, still = sys.argv[1:]
    with tempfile.TemporaryDirectory() as scratch:
        check(Path(movie), json.loads(Path(metadata).read_text()), appearance, Path(still), Path(scratch))
