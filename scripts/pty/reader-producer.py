"""Emit only the paced 8 MiB numbered payload. No prompt, echo, or in-band counting fences."""
import json
import os
from pathlib import Path
import sys
import time


def main():
    assert os.isatty(1) and os.get_terminal_size() == (80, 24)
    if Path("producer-ready").exists():
        Path("replacement-pid").write_text(str(os.getppid()))
        sys.stdin.readline()
        return
    Path("producer-ready").write_text(str(os.getppid()))
    while not Path("go").exists():
        time.sleep(0.005)
    batch_bytes = 8192
    rate = None if Path("unpaced").exists() else 16 * 1048576
    stamps = []
    out = sys.stdout.buffer
    start = time.monotonic()
    for first in range(1, 131073, 128):
        # Same producer as the M5a 8 MiB workload. Generate each 128-record batch immediately before writing.
        batch = b"".join(b"THRUSH %06d " % i + b"." * 48 + b"\r\n" for i in range(first, first + 128))
        out.write(batch)
        out.flush()
        stamps.append(time.clock_gettime_ns(time.CLOCK_UPTIME_RAW))
        if rate:
            time.sleep(max(0, start + (first + 127) * 64 / rate - time.monotonic()))
    seconds = time.monotonic() - start
    left = peak = 0
    for right, stamp in enumerate(stamps):
        while stamps[left] <= stamp - 50_000_000:
            left += 1
        peak = max(peak, right - left + 1)
    Path("production.json").write_text(json.dumps({
        "bytes": len(stamps) * batch_bytes, "seconds": seconds,
        "peak50msMiBPerSecond": peak * batch_bytes / 1048576 / 0.05,
    }))
    if not Path("exit-now").exists():
        while not Path("allow-exit").exists():
            time.sleep(0.01)


if __name__ == "__main__":
    main()
