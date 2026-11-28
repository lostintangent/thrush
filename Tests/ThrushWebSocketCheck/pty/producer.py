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
    (run / "armed").write_text(str(os.getpid()))
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

    end = b"\x1b[1;1HTHRUSH-END\x1b[K"
    out.write(end)
    out.flush()
    if scenario == "suspended":
        # The shell exits with this process while its reader is stopped. The server owes that reader the final screen.
        return
    # The server can skip the end fence during backpressure too. Repeat it until the host acknowledges.
    while not (select.select([sys.stdin], [], [], 0.25)[0] and sys.stdin.readline().strip() == "ack"):
        out.write(end)
        out.flush()
    out.write(b"\x1b[2;1HTHRUSH-FINAL\x1b[K")
    out.flush()


def paint():
    """Paints every row of the alternate screen at the PTY's grid on start and for each line the host sends.
    Like many simple programs, it ignores SIGWINCH."""
    out = sys.stdout.buffer
    out.write(b"\x1b[?1049h")
    frame = 0
    while True:
        columns, rows = os.get_terminal_size()
        out.write(b"".join(b"\x1b[%d;1H%d of %dx%d, frame %d\x1b[K" % (row, row, columns, rows, frame)
                           for row in range(1, rows + 1)))
        out.flush()
        if sys.stdin.readline().strip() == "done":
            return
        frame += 1


if __name__ == "__main__":
    paint() if sys.argv[1] == "paint" else produce(sys.argv[1])
