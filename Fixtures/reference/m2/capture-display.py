"""Record Bash Readline character edits and printf output on a 16-column PTY."""
import argparse
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT.parent))
from capture import PROMPT, Session


def capture_display(session):
    for edit in ("delete", "insert"):
        typed = session.type("Type abcdef", b"abcdef", "text")
        assert typed == b"abcdef"
        for _ in range(3):
            moved = session.type("Move left one character", b"\x02", "key", "b", ["control"])
            assert moved == b"\x08"
        if edit == "delete":
            deleted = session.type("Delete at cursor", b"\x04", "key", "d", ["control"])
            assert deleted == b"\x1b[1P"
            session.checkpoint("Deleted middle character")
        else:
            inserted = session.type("Insert at cursor", b"X", "text")
            assert inserted == b"\x1b[1@X"
            session.checkpoint("Inserted middle character")
        cancelled = session.type("Cancel edited command", b"\x03", "key", "c", ["control"], until=PROMPT)
        assert cancelled.endswith(PROMPT)

    for name, command, expected in (
        ("Literal tab stop", rb"printf 'name\tvalue'", b"name\tvalue"),
        ("Erased progress line", rb"printf 'progress...\r\033[2KDone'", b"progress...\r\x1b[2KDone"),
    ):
        # Wait for one unechoed byte so the next prompt does not overwrite the measured cursor.
        session.type("Type printf command", command + rb"; read -rsn1; printf '\n'", "text")
        output = session.type("Run printf command", b"\r", "key", "enter", until=expected)
        assert output.endswith(expected), (name, output)
        session.checkpoint(name)
        prompt = session.type("Return to prompt", b" ", "text", until=PROMPT)
        assert prompt.endswith(PROMPT)


def record(bash):
    columns, rows = 16, 25
    with tempfile.TemporaryDirectory(prefix="thrush-display-") as scratch:
        directory = Path(scratch)
        inputrc = directory / "inputrc"
        inputrc.write_text("set editing-mode emacs\nset enable-bracketed-paste on\n")
        session = Session.shell(directory, columns, rows, bash=bash, inputrc=inputrc)
        try:
            prompt = session.read("Bash display prompt", PROMPT)
            assert prompt.endswith(PROMPT)
            capture_display(session)
        finally:
            session.close()
    session.save(ROOT / "bash-display.capture.json", dict(
        name="bash-display", term="xterm-256color", shell="bash --noprofile --norc -i",
        shellVersion=subprocess.check_output([bash, "--version"], text=True).splitlines()[0],
        columns=columns, rows=rows))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bash", type=Path, default=Path("/opt/homebrew/bin/bash"))
    args = parser.parse_args()
    record(args.bash.resolve())
