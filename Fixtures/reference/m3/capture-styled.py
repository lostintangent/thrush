"""Capture the same Swift editor session twice with the dark and light palettes."""
from hashlib import sha256
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent
M2 = ROOT.parent / "m2"
sys.path.insert(0, str(M2))
sys.dont_write_bytecode = True
from capture import PROMPT, Session, VIM

DESIGN = ROOT.parents[2] / "docs/design/README.md"

def theme_palette(appearance):
    design = DESIGN.read_text()
    section = design.split("## " + appearance.title() + "\n", 1)[1].split("\n## ", 1)[0]
    defaults = next(line for line in section.splitlines() if line.startswith("| Default foreground / background"))
    colors = lambda line: [v.lower() for v in re.findall(r"#(?:[a-fA-F0-9]{6})\b", line)]
    fg, bg = colors(defaults)
    table = section if appearance == "light" else design.split("## Dark and Ember ANSI colors", 1)[1]
    normal, bright = [], []
    for name in ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]:
        row = next(line for line in table.splitlines() if line.startswith(f"| {name} |"))
        value, intense = colors(row)[:2]
        normal.append(value)
        bright.append(intense)
    return dict(foreground=fg, background=bg, ansi=normal + bright)

def capture_styled(appearance):
    name = "vim-swift-" + appearance
    palette = theme_palette(appearance)
    with tempfile.TemporaryDirectory(prefix="thrush-styled-") as work:
        directory = Path(work)
        (directory / "bin").mkdir()
        (directory / "bin/vim").write_text(VIM)
        (directory / "bin/vim").chmod(0o755)
        shutil.copyfile(ROOT / "styled.vim", directory / "vimrc")
        shutil.copyfile(ROOT / "Prompt.swift", directory / "Prompt.swift")
        session = Session(directory)
        try:
            session.record("Apply host palette", palette=palette)
            assert not session.exchange({"palette": palette})
            assert session.read("Shell prompt", PROMPT).endswith(PROMPT)
            session.checkpoint("Shell prompt")
            output = session.input("Open Swift file", b"vim Prompt.swift\r", until=b"Format the current shell prompt.")
            assert b"\x1b[?1049h" in output
            session.input("Measure Vim background", b":Frame\r")
            proof = (directory / "vim-proof.txt").read_text().splitlines()
            assert proof == [appearance, "swift", "swift", "256"], (name, proof)
            session.input("Paint Swift buffer", b"\x0c")
            session.checkpoint("Styled Swift buffer")
            for (columns, rows), checkpoint in [((45,18), "Styled Swift portrait"), ((71,11), "Styled Swift landscape")]:
                session.resize(columns, rows)
                session.checkpoint(checkpoint)
            assert session.input("Quit to shell", b":q\r", until=PROMPT).endswith(PROMPT)
            session.checkpoint("Returned to shell")
            assert (directory / "Prompt.swift").read_bytes() == (ROOT / "Prompt.swift").read_bytes()
            metadata = dict(name=name, term="xterm-256color", shell="/bin/bash --noprofile --norc -i",
                            vimVersion=subprocess.check_output(["/usr/bin/vim", "--version"], text=True).splitlines()[:3],
                            vimBackground=proof[0], vimFiletype=proof[1], vimSyntax=proof[2], vimColorCount=int(proof[3]),
                            sourceSHA256=sha256((ROOT / "Prompt.swift").read_bytes()).hexdigest(),
                            vimrcSHA256=sha256((ROOT / "styled.vim").read_bytes()).hexdigest(), columns=80, rows=24)
            compact = lambda value: json.dumps(value, ensure_ascii=False, separators=(",",":"))
            data = compact(metadata)[:-1] + ',\n"events":[\n' + ',\n'.join(map(compact, session.events)) + '\n]}\n'
            (ROOT / (name + ".capture.json")).write_text(data)
        finally:
            session.close()

if __name__ == "__main__":
    for appearance in ["dark", "light"]:
        capture_styled(appearance)
