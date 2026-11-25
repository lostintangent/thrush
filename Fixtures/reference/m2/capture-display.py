"""Record Bash Readline character edits and printf output on a 16-column PTY."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from capture import PROMPT, ROOT, Session


def capture_display(session):
    for edit in ("delete", "insert"):
        typed = session.input("Type abcdef", b"abcdef")
        assert typed == b"abcdef"
        for _ in range(3):
            moved = session.input("Move left one character", b"\x02", "key", "b", modifiers=["control"])
            assert moved == b"\x08"
        if edit == "delete":
            deleted = session.input("Delete at cursor", b"\x04", "key", "d", modifiers=["control"])
            assert deleted == b"\x1b[1P"
            session.checkpoint("Deleted middle character")
        else:
            inserted = session.input("Insert at cursor", b"X")
            assert inserted == b"\x1b[1@X"
            session.checkpoint("Inserted middle character")
        cancelled = session.input("Cancel edited command", b"\x03", "key", "c", until=PROMPT, modifiers=["control"])
        assert cancelled.endswith(PROMPT)

    for name, command, expected in (
        ("Literal tab stop", rb"printf 'name\tvalue'", b"name\tvalue"),
        ("Erased progress line", rb"printf 'progress...\r\033[2KDone'", b"progress...\r\x1b[2KDone"),
    ):
        # Wait for one unechoed byte so the next prompt does not overwrite the measured cursor.
        session.input("Type printf command", command + rb"; read -rsn1; printf '\n'")
        output = session.input("Run printf command", b"\r", "key", "enter", until=expected)
        assert output.endswith(expected), (name, output)
        session.checkpoint(name)
        prompt = session.input("Return to prompt", b" ", until=PROMPT)
        assert prompt.endswith(PROMPT)


def record(checkout, bash):
    columns, rows = 16, 25
    with tempfile.TemporaryDirectory(prefix="thrush-display-") as scratch:
        directory = Path(scratch)
        inputrc = directory / "inputrc"
        inputrc.write_text("set editing-mode emacs\nset enable-bracketed-paste on\n")
        session = Session(directory, checkout, columns, rows, bash=bash, inputrc=inputrc)
        try:
            prompt = session.read("Bash display prompt", PROMPT)
            assert prompt.endswith(PROMPT)
            capture_display(session)
        finally:
            session.close()
    recording = dict(name="bash-display", term="xterm-256color", shell="bash --noprofile --norc -i",
                     shellVersion=subprocess.check_output([bash, "--version"], text=True).splitlines()[0],
                     columns=columns, rows=rows)
    compact = lambda value: json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    document = compact(recording)[:-1] + ',\n"events":[\n' + ',\n'.join(map(compact, session.events)) + '\n]}\n'
    (ROOT / "bash-display.capture.json").write_text(document, encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkout", type=Path, help="pinned Toy Box checkout")
    parser.add_argument("--bash", type=Path, default=Path("/opt/homebrew/bin/bash"))
    args = parser.parse_args()
    record(args.checkout.resolve(), args.bash.resolve())
