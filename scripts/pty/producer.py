"""Executed by the disposable fixture shell, with stdout attached to the real PTY."""
import json
import os
from pathlib import Path
import select
import sys
import time


def produce(scenario):
    assert os.isatty(0) and os.isatty(1)
    assert os.get_terminal_size() == (80, 24)
    run = Path(scenario)
    count = 8192 if scenario == "paced" else 131072
    (run / "armed").touch()
    while not (run / "go").exists():
        time.sleep(0.005)

    out = sys.stdout.buffer
    out.write(b"THRUSH-BEGIN\r\n")
    out.flush()
    writes = []
    start = time.monotonic()
    for first in range(1, count + 1, 128):
        batch = b"".join(b"THRUSH %06d " % number + b"." * 48 + b"\r\n"
                         for number in range(first, first + 128))
        out.write(batch)
        out.flush()
        writes.append((time.clock_gettime_ns(time.CLOCK_UPTIME_RAW), (first + 127) * 64))
        if scenario == "paced":
            # A 1 MiB/s stream. Do not count each batch's computation twice.
            deadline = start + (first + 127) * 64 / 1048576
            time.sleep(max(0, deadline - time.monotonic()))
    seconds = time.monotonic() - start
    (run / "writes.json").write_text(json.dumps(writes))
    (run / "produced.json").write_text(json.dumps({
        "markers": count, "payloadBytes": count * 64, "seconds": seconds,
    }))

    # The server can skip the end fence during backpressure too. Retry until the host sees it.
    while True:
        out.write(b"\x1b[1;1HTHRUSH-END\x1b[K")
        out.flush()
        if select.select([sys.stdin], [], [], 0.25)[0]:
            if sys.stdin.readline().strip() == "ack":
                break
    out.write(b"\x1b[2;1HTHRUSH-FINAL\x1b[K")
    out.flush()


if __name__ == "__main__":
    produce(sys.argv[1])
