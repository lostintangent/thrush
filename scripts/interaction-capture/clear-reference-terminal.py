"""Run inside the captured native terminal. Record the bytes this terminal actually receives."""
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import sys
import termios
import time
import traceback
import tty


def write_all(fd, data):
    while data:
        data = data[os.write(fd, data):]


def wait_file(path, timeout):
    deadline = time.monotonic() + timeout
    while not path.exists():
        if time.monotonic() > deadline:
            raise TimeoutError(str(path))
        time.sleep(0.02)


def native_pid(app):
    pid = os.getpid()
    while pid > 1:
        parent, name = subprocess.check_output(
            ["ps", "-p", str(pid), "-o", "ppid=,comm="], text=True).strip().split(None, 1)
        if name.endswith(f"/{app}.app/Contents/MacOS/{'ghostty' if app == 'Ghostty' else app}"):
            return pid
        pid = int(parent)
    raise RuntimeError(f"the capture worker has no {app} ancestor")


def replay(fixture, record):
    digest = hashlib.sha256()
    for phase in ["beforeTyping", "typed", "returned"]:
        if phase != "beforeTyping":
            # Hold the populated viewport and the typed command long enough to see both.
            time.sleep(0.7)
        start = time.monotonic()
        for read in fixture[phase]:
            due = start + read["elapsedMs"] / 1000
            time.sleep(max(0, due - time.monotonic()))
            data = base64.b64decode(read["base64"], validate=True)
            write_all(1, data)
            digest.update(data)
            record(phase, "output", data)
    return {"outputSHA256": digest.hexdigest(), "sourceTERM": fixture["term"]}


def live(fixture, record, size):
    # Let zsh, its line editor, and the system clear command generate all visible bytes.
    # Feed the keys on the child PTY and relay real terminal-generated answers back to zsh.
    pid, master = pty.fork()
    if pid == 0:
        fcntl.ioctl(1, termios.TIOCSWINSZ, struct.pack("HHHH", size.lines, size.columns, 0, 0))
        os.environ.update(PATH="/usr/bin:/bin:/usr/sbin:/sbin", PS1="thrush$ ", RPS1="")
        os.execv("/bin/zsh", ["zsh", "-dfi"])
    screen = bytearray()

    def read_until(phase, ready, timeout):
        deadline = time.monotonic() + timeout
        while not ready():
            left = deadline - time.monotonic()
            if left <= 0:
                raise TimeoutError(f"zsh {phase}: {screen[-400:]!r}")
            readable, _, _ = select.select([master, 0], [], [], min(left, 0.01))
            for fd in readable:
                chunk = os.read(fd, 65536)
                if not chunk:
                    raise RuntimeError(f"unexpected EOF during {phase}")
                if fd == master:
                    record(phase, "output", chunk)
                    screen.extend(chunk)
                    write_all(1, chunk)
                else:
                    record(phase, "terminalReply", chunk)
                    write_all(master, chunk)

    def send(phase, keys):
        record(phase, "input", keys)
        write_all(master, keys)

    def settle(phase, seconds):
        end = time.monotonic() + seconds
        read_until(phase, lambda: time.monotonic() >= end, seconds + 0.3)

    try:
        read_until("initial", lambda: b"thrush$ " in screen, 8)
        screen.clear()
        send("beforeTyping", fixture["seedCommand"].encode() + b"\r")
        last = str(fixture["historyLines"]).encode() + b"\r\n"
        read_until("beforeTyping", lambda: last in screen and b"thrush$ " in screen.split(last, 1)[1], 12)
        settle("beforeTyping", 0.7)
        for key in b"clear":
            send("typed", bytes([key]))
            settle("typed", 0.08)
        settle("typed", 0.55)
        screen.clear()
        send("returned", b"\r")
        read_until("returned", lambda: b"\x1b[2J" in screen and b"thrush$ " in screen.split(b"\x1b[2J", 1)[1], 8)
        settle("returned", 0.1)
        return {"shell": "/bin/zsh -dfi", "command": "/usr/bin/clear", "seed": fixture["seedCommand"],
                "terminalTERM": os.environ["TERM"], "prompt": "thrush$ ", "observedClearAndNewPrompt": True}
    finally:
        os.close(master)
        try:
            os.kill(pid, signal.SIGHUP)
        except ProcessLookupError:
            pass
        os.waitpid(pid, 0)


def main():
    out, app, mode, source = sys.argv[1:]
    out = Path(out)
    fixture = json.loads(Path(source).read_bytes())
    size = os.get_terminal_size(1)
    info = {"appPID": native_pid(app), "workerPID": os.getpid(), "app": app, "mode": mode,
            "columns": size.columns, "rows": size.lines, "TERM": os.environ["TERM"]}
    original = termios.tcgetattr(0)
    try:
        tty.setraw(0)
        write_all(1, b"\x1b]0;Thrush Clear Reference\x07\x1b[3J\x1b[H\x1b[2J")
        (out / "terminal.json").write_text(json.dumps(info, indent=2))
        wait_file(out / "go", 60)
        ticks = time.monotonic_ns()
        with (out / "pty.jsonl").open("w", buffering=1) as log:
            def record(phase, direction, chunk):
                log.write(json.dumps({"phase": phase, "direction": direction,
                                      "elapsedUs": (time.monotonic_ns() - ticks) // 1000,
                                      "base64": base64.b64encode(chunk).decode()}) + "\n")

            result = replay(fixture, record) if mode == "recorded-oshen" else live(fixture, record, size)
        (out / "result.json").write_text(json.dumps(dict(info, **result), indent=2))
        wait_file(out / "release", 35)
    finally:
        termios.tcsetattr(0, termios.TCSANOW, original)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        (Path(sys.argv[1]) / "worker-error.txt").write_text(traceback.format_exc())
        raise
