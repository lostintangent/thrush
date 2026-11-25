"""The byte streams every emulator core in the comparison receives.

Each workload is about 1 MiB and is written once, so all cores parse identical bytes.
Synthetic workloads use a fixed-seed generator and only control functions every
measured core implements, so no core is credited for skipping work. Recorded
workloads repeat the program output captured in Fixtures/replays, without resizes.
"""

import base64
import hashlib
import json
from pathlib import Path

TARGET_BYTES = 1 << 20
ESC = "\x1b"


class Random:
    """A small xorshift generator, so the bytes never depend on the Python version."""

    def __init__(self, seed):
        self.state = seed or 1

    def next(self):
        x = self.state
        x ^= (x << 13) & 0xFFFFFFFFFFFFFFFF
        x ^= x >> 7
        x ^= (x << 17) & 0xFFFFFFFFFFFFFFFF
        self.state = x
        return x

    def below(self, bound):
        return self.next() % bound

    def between(self, low, high):
        return low + self.below(high - low + 1)

    def choice(self, items):
        return items[self.below(len(items))]


WORDS = ("build test swift terminal render cursor scroll buffer history parser screen "
         "glyph cell style color input output stream bytes frame grid row column wide "
         "emoji region margin erase line prompt shell vim codex commit branch merge").split()


def repeat_units(make_unit):
    """Concatenates whole units until the stream reaches the target size."""
    parts, size = [], 0
    while size < TARGET_BYTES:
        unit = make_unit().encode()
        parts.append(unit)
        size += len(unit)
    return b"".join(parts)


def dense_ascii():
    rng = Random(0xA5C11)

    def line():
        words, length, limit = [], 0, rng.between(8, 200)
        while length < limit:
            word = rng.choice(WORDS)
            words.append(word)
            length += len(word) + 1
        return " ".join(words) + "\r\n"

    return repeat_units(line)


def styled_cells():
    rng = Random(0x56E)

    def style():
        kind = rng.below(10)
        if kind == 0:
            return f"38;5;{rng.below(256)}"
        if kind == 1:
            return f"48;5;{rng.below(256)}"
        if kind == 2:
            return f"38;2;{rng.below(256)};{rng.below(256)};{rng.below(256)}"
        if kind == 3:
            return f"48;2;{rng.below(256)};{rng.below(256)};{rng.below(256)}"
        if kind == 4:
            return rng.choice(("1", "2", "7", "22", "27"))
        if kind == 5:
            return f"{rng.choice((30, 90))+rng.below(8)};{rng.choice((40, 100))+rng.below(8)}"
        if kind == 6:
            return rng.choice(("39", "49", "39;49"))
        if kind == 7:
            return f"1;38;5;{rng.below(256)}"
        if kind == 8:
            return f"0;{30 + rng.below(8)}"
        return "0"

    def line():
        cells = "".join(f"{ESC}[{style()}m{chr(rng.between(0x21, 0x7E))}" for _ in range(80))
        return cells + f"{ESC}[0m\r\n"

    return repeat_units(line)


def wide_text():
    rng = Random(0xC1C)

    def piece():
        kind = rng.below(3)
        if kind == 0:
            return "".join(chr(rng.between(0x4E00, 0x9FFF)) for _ in range(rng.between(2, 12)))
        if kind == 1:
            return "".join(chr(rng.between(0x1F600, 0x1F64F)) for _ in range(rng.between(1, 4)))
        return rng.choice(WORDS)

    def line():
        pieces, length, limit = [], 0, rng.between(10, 120)
        while length < limit:
            text = piece()
            pieces.append(text)
            length += sum(1 if ord(c) < 0x80 else 2 for c in text) + 1
        return " ".join(pieces) + "\r\n"

    return repeat_units(line)


def cursor_addressing():
    rng = Random(0xC0A)

    def frame():
        parts = [f"{ESC}[H{ESC}[2J"]
        for _ in range(120):
            row, column = rng.between(1, 24), rng.between(1, 70)
            parts.append(f"{ESC}[{row};{column}H{rng.choice(WORDS)}")
            if rng.below(8) == 0:
                parts.append(f"{ESC}[K")
            if rng.below(16) == 0:
                parts.append(f"{ESC}[J")
        return "".join(parts)

    return repeat_units(frame)


def scrolling_history():
    counter = iter(range(1 << 30))
    return repeat_units(lambda: f"{next(counter):08} {WORDS[next(counter) % len(WORDS)]}\r\n")


def scroll_region():
    rng = Random(0x5C0)
    block = iter(range(1 << 30))

    def unit():
        index = next(block)
        lines = "".join(f"{rng.choice(WORDS)} {rng.choice(WORDS)} {index:06}\n\r" for _ in range(64))
        status = f"{ESC}[24;1H{ESC}[7m status {index:06} {ESC}[0m{ESC}[K"
        return f"{ESC}[2;20r{ESC}[20;1H{lines}{ESC}[r{status}"

    return repeat_units(unit)


def recorded(names):
    replays = Path(__file__).resolve().parents[2] / "Fixtures" / "replays"
    output = b""
    for name in names:
        events = json.loads((replays / f"{name}.json").read_text())["events"]
        output += b"".join(base64.b64decode(event["bytes"]) for event in events if "bytes" in event)
    repeats = -(-TARGET_BYTES // len(output))
    return output * repeats


WORKLOADS = {
    "shell": ("Recorded shell log", lambda: recorded(["shell-log"])),
    "vim": ("Recorded Vim sessions", lambda: recorded(["vim-edit", "vim-resume", "vim-swift-dark", "vim-swift-light"])),
    "codex": ("Recorded Codex session", lambda: recorded(["codex-session"])),
    "ascii": ("Dense ASCII", dense_ascii),
    "sgr": ("SGR on every cell", styled_cells),
    "wide": ("Wide CJK and emoji", wide_text),
    "cursor": ("Cursor addressing", cursor_addressing),
    "scroll": ("Scrolling into history", scrolling_history),
    "region": ("Scroll region", scroll_region),
}


def write(directory):
    """Writes every workload and returns its name, title, path, size and SHA-256."""
    directory.mkdir(parents=True, exist_ok=True)
    written = []
    for name, (title, make) in WORKLOADS.items():
        data = make()
        path = directory / f"{name}.bin"
        path.write_bytes(data)
        written.append({"name": name, "title": title, "path": str(path), "bytes": len(data),
                        "sha256": hashlib.sha256(data).hexdigest()})
    return written


if __name__ == "__main__":
    import sys
    for workload in write(Path(sys.argv[1] if len(sys.argv) > 1 else ".build/comparison/workloads")):
        print(f"{workload['name']:8} {workload['bytes']:>9} {workload['sha256'][:16]}")
