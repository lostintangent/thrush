"""Records the shell-log and vim-edit sessions in Bash. Regenerate the references separately."""
import argparse
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT.parent))
from capture import PROMPT, Session, VIM

GRIDS = [(40, 32), (80, 14), (80, 24)]
VIMRC = """set nocompatible
set nomodeline noswapfile nobackup noundofile viminfo=
set noruler noshowcmd noshowmode laststatus=0 shortmess+=I
set encoding=utf-8 nofoldenable mouse= belloff=all
set ttimeout ttimeoutlen=10
"""

def build_headers(session, directory, name, first, last):
    command = b"./build\r" if first == 1 else f"./build {first} {last}\r".encode()
    output = session.type(name, command, "text", until=PROMPT)
    visits = re.findall(rb"\x1b\[32m(\d+)\x1b\[0m  compile ", output)
    assert [int(number) for number in visits] == list(range(first, last + 1))
    assert output.endswith(PROMPT) and b"The compiler did not" not in output
    assert (directory / "compile.o").stat().st_size > 0

def capture(name, destination=ROOT, columns=80, rows=24, grids=GRIDS):
    with tempfile.TemporaryDirectory(prefix="thrush-pty-") as work:
        directory = Path(work)
        (directory / "bin").mkdir()
        (directory / "vimrc").write_text(VIMRC)
        (directory / "scratch.txt").write_text("first line\nsecond line\n", encoding="utf8")
        shutil.copyfile(ROOT / "build-log.py", directory / "build")
        (directory / "build").chmod(0o755)
        (directory / "bin/vim").write_text(VIM, encoding="utf8")
        (directory / "bin/vim").chmod(0o755)
        session = Session.shell(directory, columns, rows)
        try:
            output = session.read("Shell prompt", PROMPT)
            assert output.endswith(PROMPT), repr(output)
            session.checkpoint("Fresh prompt")
            if name == "shell-log":
                build_headers(session, directory, "Build numbered log", 1, 1030)
                session.checkpoint("Full normal history")
                session.resize(*GRIDS[0], checkpoint=True)
                session.resize(*GRIDS[1], checkpoint=True)
                build_headers(session, directory, "Refill landscape history", 1031, 1670)
                session.checkpoint("Full normal history before desktop resize")
                session.resize(*GRIDS[2], checkpoint=True)
                session.checkpoint("Restored normal grid")
                build_headers(session, directory, "Refill history before Vim", 1671, 1694)
                session.checkpoint("Full history before alternate screen")
            output = session.type("Open scratch file", b"vim scratch.txt\r", "text", until=b"first line")
            assert b"\x1b[?1049h" in output and b"first line" in output, repr(output)
            session.checkpoint("Vim opens alternate screen")
            if name == "vim-edit":
                session.type("Enter insert mode", b"i", "text")
                inserted = "note: 界 e\u0301"
                paste = b"\x1b[200~" + inserted.encode() + b"\x1b[201~"
                session.type("Paste scratch text", paste, "paste", inserted)
                session.type("Finish insertion", b"\x1b", "key", "escape")
                session.checkpoint("Edited scratch file")
            for grid in grids: session.resize(*grid, checkpoint=True)
            session.checkpoint("Restored alternate grid")
            output = session.type("Save and quit Vim", b":wq\r", "text", until=PROMPT)
            assert output.endswith(PROMPT), repr(output)
            session.checkpoint("Returned to shell")
            expected = ("note: 界 e\u0301" if name == "vim-edit" else "") + "first line\nsecond line\n"
            assert (directory / "scratch.txt").read_text() == expected
            session.save(destination / (name + ".capture.json"), dict(
                name=name, term="xterm-256color", shell="/bin/bash --noprofile --norc -i",
                vimVersion=subprocess.check_output(["/usr/bin/vim", "--version"], text=True).splitlines()[:3],
                clangVersion=subprocess.check_output(["/usr/bin/clang","--version"], text=True).splitlines()[0],
                columns=columns, rows=rows))
        finally:
            session.close()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
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
        capture(name, options.destination, options.columns, options.rows, grids)
