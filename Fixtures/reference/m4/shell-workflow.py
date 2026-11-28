"""Record a real editable shell command and a browser-verified soft-wrap selection."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT.parent))
from capture import PROMPT, Session


def capture(bash):
    build = ROOT.parent / "m2/build-log.py"
    with tempfile.TemporaryDirectory(prefix="thrush-shell-workflow-") as work:
        directory = Path(work)
        shutil.copyfile(build, directory / "build")
        (directory / "build").chmod(0o755)
        (directory / "inputrc").write_text("set editing-mode emacs\nset enable-bracketed-paste on\n")
        session = Session.shell(directory, bash=bash, inputrc=directory / "inputrc")
        try:
            prompt = session.read("Shell prompt", PROMPT)
            assert prompt.endswith(PROMPT) and b"\x1b[?2004h" in prompt, "The shell must negotiate bracketed paste."
            session.checkpoint("Fresh prompt")
            session.resize(45, 18, checkpoint=True)
            assert b"./builx" in session.type("Type unfinished command", b"./builx", "text")
            session.checkpoint("Typed command")
            session.type("Correct typo", b"\x7f", "key", "backspace")
            session.checkpoint("Edited command")
            session.type("Paste build arguments", b"\x1b[200~d 126 130\x1b[201~", "paste", "d 126 130")
            session.checkpoint("Pasted build command")
            output = session.type("Run numbered compiler log", b"\r", "key", "enter", until=PROMPT)
            visits = re.findall(rb"\x1b\[32m(\d+)\x1b\[0m  compile ", output)
            assert [int(x) for x in visits] == list(range(126, 131)) and output.endswith(PROMPT)
            assert b"\x1b[?2004l" in output and b"\x1b[?2004h" in output
            assert (directory / "compile.o").stat().st_size > 0
            session.checkpoint("Numbered compiler log")
            recording = dict(name="shell-workflow", term="xterm-256color", shell="bash --noprofile --norc -i",
                             shellVersion=subprocess.check_output([bash, "--version"], text=True).splitlines()[0],
                             columns=80, rows=24, buildScriptSHA256=hashlib.sha256(build.read_bytes()).hexdigest(),
                             clangVersion=subprocess.check_output(["/usr/bin/clang","--version"], text=True).splitlines()[0])
            oracle = subprocess.run(
                ["bun", ROOT / "shell-selection.mjs"], check=True, capture_output=True, text=True,
                input=json.dumps({**recording, "events": session.events}))
            session.record("Copy soft-wrapped compiler path", copy=json.loads(oracle.stdout), checkpoint=True)
            session.save(ROOT / "shell-workflow.capture.json", recording)
        finally:
            session.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bash", type=Path, default=Path(shutil.which("bash") or "/bin/bash"),
                        help="Bash with Readline bracketed-paste support (Bash 5.3.9 for the checked-in capture)")
    args = parser.parse_args()
    capture(args.bash.resolve())
