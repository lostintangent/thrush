"""Write a finite burst through the real PTY, then stay silent until the user types."""
import json
import os
from pathlib import Path
import sys
import termios
import time

assert os.isatty(0) and os.isatty(1)
settings = termios.tcgetattr(0)
settings[3] &= ~termios.ECHO
termios.tcsetattr(0, termios.TCSANOW, settings)
out = sys.stdout.buffer
out.write(b"\x1b[?1049h\x1b[2J\x1b[HWaiting for the terminal output burst")
out.flush()
while not Path("recovery-go").exists():
    time.sleep(0.005)

# Fixed-width PTY progress writes avoid accumulating synthetic history in the replay.
block = (b"Compiling " + b"." * 53 + b"\r") * 128
for _ in range(1024):
    out.write(block)
out.write(b"\x1b[2J\x1b[HBuild complete\x1b[3;1H131072 compilation updates processed"
          b"\x1b[5;1HResult: all checks passed\x1b[7;1HReady for input\x1b[8;1H")
out.flush()
Path("recovery-produced.json").write_text(json.dumps(dict(payloadBytes=len(block)*1024, pid=os.getpid())))
line = sys.stdin.readline().rstrip("\r\n")
Path("recovery-input").write_text(line)
out.write(("\x1b[8;1HConfirmed: " + line + "\x1b[9;1H").encode())
out.flush()
# Keep exactly this screen visible until the native app explicitly closes the PTY.
sys.stdin.readline()
