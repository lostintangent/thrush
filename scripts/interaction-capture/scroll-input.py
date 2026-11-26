"""Run a program on its own terminal and log each read of its input with the time it arrived."""
import fcntl
import json
import os
import pty
import select
import signal
import sys
import termios
import time
import tty

log_path, *command = sys.argv[1:]
size = fcntl.ioctl(0, termios.TIOCGWINSZ, b"\0" * 8)
pid, program = pty.fork()
if pid == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, size)
    os.execvp(command[0], command)


def resize(*_):
    fcntl.ioctl(program, termios.TIOCSWINSZ, fcntl.ioctl(0, termios.TIOCGWINSZ, b"\0" * 8))


def write(fd, data):
    while data:
        data = data[os.write(fd, data):]


signal.signal(signal.SIGWINCH, resize)
saved = termios.tcgetattr(0)
tty.setraw(0)
with open(log_path, "a") as log:
    try:
        while True:
            ready, _, _ = select.select([0, program], [], [])
            if 0 in ready:
                data = os.read(0, 4096)
                if not data:
                    break
                log.write(json.dumps({"time": time.time(), "hex": data.hex()}) + "\n")
                log.flush()
                write(program, data)
            if program in ready:
                try:
                    data = os.read(program, 65536)
                except OSError:
                    break
                if not data:
                    break
                write(1, data)
    finally:
        termios.tcsetattr(0, termios.TCSANOW, saved)
        os.waitpid(pid, 0)
