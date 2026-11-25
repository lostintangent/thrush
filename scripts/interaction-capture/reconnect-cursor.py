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
    capture = runpy.run_path(str(Path(__file__).resolve().parents[1] / "check-demo-capture.py"))["Capture"]
    state = views["reconnecting"]
    start, end = views["noticeIntervalSeconds"]
    if start < 0 or end - start < 2:
        raise ValueError("The mounted notice did not overlap a sustained pre-replay outage.")
    (wx, wy), (window_w, window_h) = state["windowPoints"]
    (gx, gy), _ = state["gridFrame"]
    (cx, cy), (grid_w, grid_h) = state["cellGridPixels"]
    scale = state["displayScale"]
    cell_w, cell_h = grid_w / state["columns"], grid_h / state["rows"]
    # The peer emits eight complete rows, then “~/thrush % git”. The held suffix stays invisible.
    left = (gx - wx) * scale + cx + len("~/thrush % git") * cell_w
    top = (gy - wy) * scale + cy + 8 * cell_h
    ffmpeg = decoder(work)
    previous = start
    for n, fraction in enumerate((0.25, 0.5, 0.75)):
        frame = work / f"sample-{n}.png"
        actual = sample(ffmpeg, movie, start + fraction * (end - start), frame)
        pixels = capture(frame, appearance)
        if not previous < actual < end or (pixels.width, pixels.height) != (round(window_w * scale), round(window_h * scale)):
            raise ValueError(f"Frame at {actual}s does not match the native window and outage interval.")
        previous = actual
        # H.264 chroma subsampling can ring at the color boundary. Check the cell's interior.
        cursor = pixels.matches("cursor", tolerance=30)
        interior = [pixels.pixels[y * pixels.width + x] in cursor
                    for y in range(round(top + 0.2 * cell_h), round(top + 0.8 * cell_h))
                    for x in range(round(left + 0.2 * cell_w), round(left + 0.8 * cell_w))]
        coverage = sum(interior) / len(interior)
        if coverage < 0.90:
            raise ValueError(f"Cursor fill at the confirmed git cell was {coverage:.1%} at {actual}s.")
        print(f"Native frame {actual}s, confirmed cell at ({left:.1f}, {top:.1f}), cursor fill {coverage:.1%}.", flush=True)
        if fraction == 0.5:
            shutil.copyfile(frame, still)


if __name__ == "__main__":
    movie, metadata, appearance, still = sys.argv[1:]
    with tempfile.TemporaryDirectory() as scratch:
        check(Path(movie), json.loads(Path(metadata).read_text()), appearance, Path(still), Path(scratch))
