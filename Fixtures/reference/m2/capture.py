"""Record local PTY reads and writes. Regenerate reference checkpoints separately."""
import argparse
import base64
import errno
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import shutil
import signal
import struct
import subprocess
import tempfile
import termios
import time

ROOT = Path(__file__).resolve().parent
GRIDS = [(40, 32), (80, 14), (80, 24)]
PROMPT = b"thrush$ "
VIMRC = """set nocompatible
set nomodeline noswapfile nobackup noundofile viminfo=
set noruler noshowcmd noshowmode laststatus=0 shortmess+=I
set encoding=utf-8 nofoldenable mouse= belloff=all
set ttimeout ttimeoutlen=10
"""
VIM = """#!/bin/sh
exec /usr/bin/vim -N -u "$HOME/vimrc" -i NONE -n "$@"
"""
def window(fd, columns, rows):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))

def encoded(data):
    return base64.b64encode(data).decode("ascii")

class Session:
    def __init__(self, directory, checkout, columns=80, rows=24, *, bash="/bin/bash", inputrc="/dev/null"):
        self.events = []
        self.start = time.monotonic_ns()
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            window(0, columns, rows)
            os.chdir(directory)
            env = dict(HOME=str(directory), PATH=f"{directory}/bin:/usr/bin:/bin",
                       TERM="xterm-256color", LC_ALL="en_US.UTF-8", PS1=PROMPT.decode(),
                       HISTFILE="/dev/null", INPUTRC=str(inputrc), BASH_SILENCE_DEPRECATION_WARNING="1")
            os.execve(bash, ["bash", "--noprofile", "--norc", "-i"], env)

        self.reference = subprocess.Popen(
            ["bun", ROOT / "live-replies.mjs", checkout], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
            env={**os.environ, "NODE_PATH": str(checkout / "node_modules/@xterm/xterm/src")})

        self.exchange({"resize": {"columns": columns, "rows": rows}})

    def exchange(self, event):
        self.reference.stdin.write(json.dumps(event) + "\n")
        self.reference.stdin.flush()
        response = self.reference.stdout.readline()
        if not response:
            raise RuntimeError("The xterm reference process exited during capture")
        return base64.b64decode(json.loads(response)["reply"], validate=True)

    def write(self, data):
        remaining = memoryview(data)
        while remaining:
            remaining = remaining[os.write(self.fd, remaining):]

    def record(self, name, **fields):
        self.events.append(dict(name=name, offsetMicroseconds=(time.monotonic_ns() - self.start) // 1000, **fields))

    def read(self, name, until=None):
        chunks = []
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            poll = 0.2 if chunks or until is None else 1
            if not select.select([self.fd], [], [], poll)[0]:
                if until is None or until in b"".join(chunks): break
                continue
            try:
                data = os.read(self.fd, 8192)
            except OSError as error:
                if error.errno == errno.EIO: break
                raise
            if not data: break
            self.record(name, bytes=encoded(data))
            reply = self.exchange({"bytes": encoded(data)})
            if reply:
                self.write(reply)
                self.events[-1]["observedReply"] = encoded(reply)
                self.events[-1]["replyOffsetMicroseconds"] = (time.monotonic_ns() - self.start) // 1000
                print(f"{name}: xterm replied {reply!r}", flush=True)
            chunks.append(data)
        return b"".join(chunks)

    def input(self, name, data, semantic="text", value=None, until=None, *, modifiers=()):
        action = dict(kind=semantic, value=data.decode() if value is None else value)
        if modifiers:
            action["modifiers"] = list(modifiers)
        self.record(name, input=encoded(data), action=action)
        self.write(data)
        return self.read(name, until)

    def resize(self, columns, rows):
        name = f"Resize to {columns}x{rows}"
        self.record(name, resize=dict(columns=columns, rows=rows), checkpoint=True)
        assert not self.exchange({"resize": {"columns": columns, "rows": rows}})
        window(self.fd, columns, rows)
        self.read("Redraw after resize")

    def checkpoint(self, name):
        self.record(name, checkpoint=True)

    def close(self):
        # The interactive shell and its foreground job live in a private PTY session.
        os.close(self.fd)
        try: os.kill(self.pid, signal.SIGHUP)
        except ProcessLookupError: pass
        os.waitpid(self.pid, 0)
        self.reference.stdin.close()
        self.reference.stdout.close()
        if self.reference.wait() != 0:
            raise RuntimeError("The xterm reference process exited unsuccessfully")

def build_headers(session, directory, name, first, last):
    command = b"./build\r" if first == 1 else f"./build {first} {last}\r".encode()
    output = session.input(name, command, until=PROMPT)
    visits = re.findall(rb"\x1b\[32m(\d+)\x1b\[0m  compile ", output)
    assert [int(number) for number in visits] == list(range(first, last + 1))
    assert output.endswith(PROMPT) and b"The compiler did not" not in output
    assert (directory / "compile.o").stat().st_size > 0

def capture(name, checkout, destination=ROOT, columns=80, rows=24, grids=GRIDS):
    with tempfile.TemporaryDirectory(prefix="thrush-pty-") as work:
        directory = Path(work)
        (directory / "bin").mkdir()
        (directory / "vimrc").write_text(VIMRC)
        (directory / "scratch.txt").write_text("first line\nsecond line\n", encoding="utf8")
        shutil.copyfile(ROOT / "build-log.py", directory / "build")
        (directory / "build").chmod(0o755)
        (directory / "bin/vim").write_text(VIM, encoding="utf8")
        (directory / "bin/vim").chmod(0o755)
        session = Session(directory, checkout, columns, rows)
        try:
            output = session.read("Shell prompt", PROMPT)
            assert output.endswith(PROMPT), repr(output)
            session.checkpoint("Fresh prompt")
            if name == "shell-log":
                build_headers(session, directory, "Build numbered log", 1, 1030)
                session.checkpoint("Full normal history")
                session.resize(*GRIDS[0])
                session.resize(*GRIDS[1])
                build_headers(session, directory, "Refill landscape history", 1031, 1670)
                session.checkpoint("Full normal history before desktop resize")
                session.resize(*GRIDS[2])
                session.checkpoint("Restored normal grid")
                build_headers(session, directory, "Refill history before Vim", 1671, 1694)
                session.checkpoint("Full history before alternate screen")
            output = session.input("Open scratch file", b"vim scratch.txt\r", until=b"first line")
            assert b"\x1b[?1049h" in output and b"first line" in output, repr(output)
            session.checkpoint("Vim opens alternate screen")
            if name == "vim-edit":
                session.input("Enter insert mode", b"i")
                inserted = "note: 界 e\u0301"
                paste = b"\x1b[200~" + inserted.encode() + b"\x1b[201~"
                session.input("Paste scratch text", paste, "paste", inserted)
                session.input("Finish insertion", b"\x1b", "key", "escape")
                session.checkpoint("Edited scratch file")
            for grid in grids: session.resize(*grid)
            session.checkpoint("Restored alternate grid")
            output = session.input("Save and quit Vim", b":wq\r", until=PROMPT)
            assert output.endswith(PROMPT), repr(output)
            session.checkpoint("Returned to shell")
            expected = ("note: 界 e\u0301" if name == "vim-edit" else "") + "first line\nsecond line\n"
            assert (directory / "scratch.txt").read_text() == expected
            result = dict(name=name, term="xterm-256color", shell="/bin/bash --noprofile --norc -i",
                          vimVersion=subprocess.check_output(["/usr/bin/vim", "--version"], text=True).splitlines()[:3],
                          clangVersion=subprocess.check_output(["/usr/bin/clang","--version"], text=True).splitlines()[0],
                          columns=columns, rows=rows, events=session.events)
            events = result.pop("events")
            compact = lambda value: json.dumps(value, ensure_ascii=False, separators=(",", ":"))
            content = compact(result)[:-1] + ',\n"events":[\n' + ',\n'.join(map(compact, events)) + '\n]}\n'
            (destination / (name + ".capture.json")).write_text(content)
        finally:
            session.close()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkout", nargs="?", type=Path, default=Path("../toy-box"))
    parser.add_argument("--only", choices=["shell-log", "vim-edit"])
    parser.add_argument("--columns", type=int, default=80)
    parser.add_argument("--rows", type=int, default=24)
    parser.add_argument("--resize", action="append", metavar="COLSxROWS", help="Vim resize sequence, in order")
    parser.add_argument("--destination", type=Path, default=ROOT, help="directory for the source recording")
    options = parser.parse_args()
    grids = GRIDS if options.resize is None else [tuple(map(int, size.split("x"))) for size in options.resize]
    if any(len(grid) != 2 or grid[0] < 2 or grid[1] < 1 for grid in [(options.columns, options.rows), *grids]):
        parser.error("Use positive heights and widths of at least two columns")
    if ((options.columns, options.rows) != (80, 24) or grids != GRIDS) and (
            options.only != "vim-edit" or options.destination.resolve() == ROOT):
        parser.error("Provide --only vim-edit and a separate --destination for another native geometry")
    for name in [options.only] if options.only else ["shell-log", "vim-edit"]:
        capture(name, options.checkout.resolve(), options.destination, options.columns, options.rows, grids)
