"""Records programs in disposable PTYs for the reference.

A session runs one program in a PTY and records every read, key and window change in order, each with its
microsecond offset from the start. Each read goes to the pinned reference through replies.mjs as it arrives,
and the reference's reply goes back to the program, so a capture follows the replies a terminal would send.
The recorders in the folders below put this directory on their import path.
"""
import base64
import errno
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import termios
import time

HERE = Path(__file__).resolve().parent
PROMPT = b"thrush$ "
VIM = """#!/bin/sh
exec /usr/bin/vim -N -u "$HOME/vimrc" -i NONE -n "$@"
"""


def window(fd, columns, rows):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))


def encoded(data):
    return base64.b64encode(data).decode("ascii")


class Session:
    """One program in a PTY, with every read, key and window change recorded in order."""

    def __init__(self, directory, argv, env, columns=80, rows=24):
        self.events = []
        self.start = time.monotonic_ns()
        self.reference = subprocess.Popen(
            ["bun", HERE / "replies.mjs"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.exchange({"resize": {"columns": columns, "rows": rows}})
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            window(0, columns, rows)
            os.chdir(directory)
            os.execvpe(argv[0], argv, env)

    @classmethod
    def shell(cls, directory, columns=80, rows=24, *, home=None, bash="/bin/bash", inputrc="/dev/null"):
        """Interactive Bash at the `thrush$ ` prompt, without a profile, history or user settings. Programs
        in the home's bin folder come first."""
        home = home or directory
        env = dict(HOME=str(home), PATH=f"{home}/bin:/usr/bin:/bin", TERM="xterm-256color", LC_ALL="en_US.UTF-8",
                   PS1=PROMPT.decode(), HISTFILE="/dev/null", INPUTRC=str(inputrc), BASH_SILENCE_DEPRECATION_WARNING="1")
        return cls(directory, [str(bash), "--noprofile", "--norc", "-i"], env, columns, rows)

    def exchange(self, event):
        """Hands the reference an event and returns its reply. `response` keeps the rest, such as its modes."""
        self.reference.stdin.write(json.dumps(event) + "\n")
        self.reference.stdin.flush()
        response = self.reference.stdout.readline()
        if not response:
            raise RuntimeError("The reference exited during the capture")
        self.response = json.loads(response)
        return base64.b64decode(self.response["reply"], validate=True)

    def elapsed(self):
        return (time.monotonic_ns() - self.start) // 1000

    def record(self, name, **fields):
        self.events.append(dict(name=name, offsetMicroseconds=self.elapsed(), **fields))

    def send(self, data):
        remaining = memoryview(data)
        while remaining:
            remaining = remaining[os.write(self.fd, remaining):]

    def receive(self, name, timeout):
        """Records the program's next read, if one arrives within `timeout` seconds, and sends the reference's
        reply. Returns None without a read, and empty bytes once the program has closed the PTY."""
        if not select.select([self.fd], [], [], timeout)[0]:
            return None
        try:
            data = os.read(self.fd, 65536)
        except OSError as error:
            if error.errno == errno.EIO: return b""
            raise
        if data:
            self.record(name, bytes=encoded(data))
            reply = self.exchange({"bytes": encoded(data)})
            if reply:
                self.send(reply)
                self.events[-1].update(reply=encoded(reply), replyOffsetMicroseconds=self.elapsed())
        return data

    def read(self, name, until=None, seconds=None, quiet=0.4, timeout=30):
        """Records output until `until` appears and output pauses, for `seconds`, or until output pauses."""
        output = b""
        begun = last = time.monotonic()
        while True:
            now = time.monotonic()
            if seconds is not None:
                if now - begun >= seconds: break
            elif (until is None or until in output) and now - last >= quiet:
                break
            if now - begun > timeout:
                if until is not None and until not in output:
                    raise TimeoutError(f"{name}: never saw {until!r} in {output[-400:]!r}")
                break
            data = self.receive(name, 0.05)
            if data is None: continue
            if not data: break
            last = time.monotonic()
            output += data
        return output

    def input(self, name, data, kind=None, value=None, modifiers=()):
        """Records and sends keys. A `kind` such as text, key or paste records the action they encode, with
        its value, for a recording a native client replays."""
        data = data.encode() if isinstance(data, str) else data
        fields = dict(input=encoded(data))
        if kind:
            fields["action"] = dict(kind=kind, value=data.decode() if value is None else value)
            if modifiers:
                fields["action"]["modifiers"] = list(modifiers)
        self.record(name, **fields)
        self.send(data)

    def type(self, name, data, kind=None, value=None, modifiers=(), **reading):
        """Sends keys and records what the program draws in response."""
        self.input(name, data, kind, value, modifiers)
        return self.read(name, **reading)

    def key(self, name, key, count=1, **reading):
        """Sends a named key, using the cursor key mode the program has selected."""
        prefix = b"\x1bO" if self.response["applicationCursorKeys"] else b"\x1b["
        arrows = dict(up=b"A", down=b"B", right=b"C", left=b"D", home=b"H", end=b"F")
        keys = dict(f1=b"\x1bOP", f2=b"\x1bOQ", f3=b"\x1bOR", f4=b"\x1bOS", f5=b"\x1b[15~", f6=b"\x1b[17~",
                    f10=b"\x1b[21~", pageup=b"\x1b[5~", pagedown=b"\x1b[6~", escape=b"\x1b", tab=b"\t",
                    enter=b"\r", backspace=b"\x7f", delete=b"\x1b[3~")
        data = prefix + arrows[key] if key in arrows else keys[key]
        return self.type(name, data * count, **reading)

    def resize(self, columns, rows, checkpoint=False, **reading):
        """Changes the window and records the program's redraw. A checkpoint marks the screen the resize
        leaves before the program redraws."""
        self.record(f"Resize to {columns}×{rows}", resize=dict(columns=columns, rows=rows),
                    **({"checkpoint": True} if checkpoint else {}))
        assert not self.exchange({"resize": {"columns": columns, "rows": rows}})
        window(self.fd, columns, rows)
        return self.read("Redraw after resize", **reading)

    def checkpoint(self, name):
        self.record(name, checkpoint=True)

    def close(self):
        os.close(self.fd)
        for sig in (signal.SIGHUP, signal.SIGKILL):
            # A group whose leader already exited refuses signals on macOS, which is as good as done.
            try:
                os.killpg(self.pid, sig)
            except (ProcessLookupError, PermissionError):
                pass
            for _ in range(50):
                if os.waitpid(self.pid, os.WNOHANG)[0]: break
                time.sleep(0.1)
            else:
                continue
            break
        self.reference.stdin.close()
        self.reference.stdout.close()
        if self.reference.wait() != 0:
            raise RuntimeError("The reference exited unsuccessfully")

    def save(self, path, header):
        """Writes the capture: the header's fields, then one event per line."""
        compact = lambda value: json.dumps(value, ensure_ascii=False, separators=(",", ":"))
        Path(path).write_text(compact(header)[:-1] + ',\n"events":[\n' + ",\n".join(map(compact, self.events))
                              + "\n]}\n", encoding="utf-8")
