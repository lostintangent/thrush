#!/usr/bin/env python3
"""Check the native demo's shell, canonical Vim or six-column glyph frame in sRGB."""
import argparse
import collections
import struct
import subprocess
import tempfile
from pathlib import Path


# Independent reference from the approved Slate specifications and the Vim replay.
COLORS = {
    "dark": dict(background="131D27", ink="E3EAF0", cursor="FD9A01", cursor_ink="131D27",
                 selection="466B85", selected_ink="F8FBFE", stage="A9CFFF", passed="93CBA2",
                 syntax="9CE0E4", number="F2D69C"),
    "light": dict(background="FBFDFE", ink="233442", cursor="995500", cursor_ink="FFFFFF",
                  selection="7391A6", selected_ink="101C25", stage="16699E", passed="30683E",
                  syntax="276A70", number="AF5F00"),
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


class Capture:
    def __init__(self, path, theme):
        # Window captures can be tagged Display P3. ColorSync converts their samples to
        # the same sRGB coordinates as a simulator framebuffer.
        profile = "/System/Library/ColorSync/Profiles/sRGB Profile.icc"
        with tempfile.TemporaryDirectory() as directory:
            bitmap = Path(directory, "capture.bmp")
            subprocess.run(["/usr/bin/sips", "-m", profile, "-s", "format", "bmp",
                            str(path), "--out", str(bitmap)], check=True, stdout=subprocess.DEVNULL)
            data = bitmap.read_bytes()
        offset = struct.unpack_from("<I", data, 10)[0]
        _, width, signed_height, _, bits, compression = struct.unpack_from("<IiiHHI", data, 14)
        require(data[:2] == b"BM" and width > 0 and bits in (24, 32) and compression in (0, 3),
                "Unsupported ColorSync bitmap")
        self.width, self.height = width, abs(signed_height)
        stride = ((width * bits + 31) // 32) * 4
        # Normalize BMP's two scan directions and optional padding to top-down BGRX.
        packed = bytearray(self.width * self.height * 4)
        for y in range(self.height):
            i = y if signed_height < 0 else self.height - 1 - y
            src = memoryview(data)[offset + stride * i:offset + stride * i + width * (bits // 8)]
            dst = memoryview(packed)[4 * width * y:4 * width * (y + 1)]
            if bits == 32:
                dst[:] = src
            else:
                for channel in range(3):
                    dst[channel::4] = src[channel::3]
        # A little-endian BGRX pixel cast to an integer is 0xXXRRGGBB.
        self.pixels = memoryview(packed).cast("I")
        self.hist = collections.Counter(self.pixels)
        self.colors = {name: bytes.fromhex(value) for name, value in COLORS[theme].items()}

    @staticmethod
    def rgb(value):
        return (value >> 16 & 255, value >> 8 & 255, value & 255)

    def matches(self, name, tolerance=3):
        target = self.colors[name]
        return {v for v in self.hist if max(abs(a - b) for a, b in zip(self.rgb(v), target)) <= tolerance}

    def count(self, name):
        return sum(self.hist[v] for v in self.matches(name))

    def bounds(self, name):
        # Ignore isolated antialiased pixels of the same color in unrelated native chrome.
        matches = self.matches(name)
        groups = []
        for y in range(self.height):
            row = self.pixels[y * self.width:(y + 1) * self.width]
            xs = [x for x, value in enumerate(row) if value in matches]
            if len(xs) >= 3:
                # An opaque glyph stroke can cross the entire cursor fill on one scanline.
                if groups and y - groups[-1][-1][0] <= 4:
                    groups[-1].append((y, xs))
                else:
                    groups.append([(y, xs)])
        require(groups, f"No {name} fill")
        band = max(groups, key=lambda group: sum(len(xs) for _, xs in group))
        return min(min(xs) for _, xs in band), band[0][0], max(max(xs) for _, xs in band), band[-1][0]

    def crop(self, box):
        left, top, right, bottom = box
        return [self.rgb(self.pixels[y * self.width + x])
                for y in range(top, bottom + 1) for x in range(left, right + 1)]


def glyphs(image):
    selected, cursor = image.bounds("selection"), image.bounds("cursor")
    left, top, right, bottom = selected
    x, y, end, foot = cursor
    width, height = end - x + 1, foot - y + 1
    require((top, bottom) == (y, foot), "Cursor and selection are on different rows")
    require(width >= 5 and height >= width and
            abs(right - left + 1 - 2 * width) <= 2 and abs((x - right - 1) - 2 * width) <= 2,
            "Expected two selected CJK columns, two emoji columns, then a one-column cursor")
    for label, name, box in [("CJK glyph", "selected_ink", selected), ("Z under block", "cursor_ink", cursor)]:
        target = image.colors[name]
        ink = sum(max(abs(a - b) for a, b in zip(p, target)) <= 12 for p in image.crop(box))
        require(ink >= 3, f"Missing {label}")
    # An alpha mask tinted in the default ink produces colors along the background/ink
    # interpolation. Color emoji has independent pixels off that line in either theme.
    bird = image.crop((right + 1, top, x - 1, bottom))
    bg, fg = image.colors["background"], image.colors["ink"]
    channel = max(range(3), key=lambda n: abs(fg[n] - bg[n]))
    colors = set()
    for pixel in bird:
        coverage = (pixel[channel] - bg[channel]) / (fg[channel] - bg[channel])
        difference = max(abs(pixel[n] - (bg[n] + coverage * (fg[n] - bg[n]))) for n in range(3))
        if difference >= 8:
            colors.add(pixel)
    require(len(colors) >= 12, "The bird lacks independent color-glyph samples")
    return selected, cursor, colors


def prompt(image):
    left, top, right, bottom = image.bounds("cursor")
    width = right - left + 1
    require(width >= 5 and top < image.height * 0.28, "Missing the first-row block cursor")
    foreground = image.matches("ink", tolerance=22)
    xs = {x for y in range(top, bottom + 1)
          for x, value in enumerate(image.pixels[y * image.width:y * image.width + left])
          if value in foreground}
    # Eight cumulative advances precede the cursor. Fractional advances round to
    # different integer widths at each boundary. Fit the first seven cells with ink
    # and require a blank eighth cell for the trailing space in “thrush$ ”.
    for step in range(-20, 21):
        advance = width + step / 20
        start = left - 8 * advance
        max_inset = 14 if image.width > 1.8 * image.height else 2.25
        if not 0 <= start / advance <= max_inset:
            continue
        if not all(any(start + (i + 0.12) * advance <= x < start + (i + 0.88) * advance
                       for x in xs) for i in range(7)):
            continue
        if xs and min(xs) >= start - 2 and max(xs) <= left - advance + 2:
            return
    raise ValueError("Expected seven inked prompt cells and a trailing space before the column-8 cursor")


def check(image, scene):
    require(image.count("background") >= image.width * image.height * 0.12,
            "The expected Slate terminal canvas is absent")
    require(image.count("cursor") >= 8, "Missing the terminal cursor")
    if scene == "prompt":
        return prompt(image)
    if scene == "glyphs":
        return glyphs(image)
    if scene == "shell":
        require(image.count("stage") >= 16 and image.count("passed") >= 16 and image.count("ink") >= 50,
                "The blue compilation stages, green checks and shell text are incomplete")
    else:
        require(image.count("syntax") >= 12 and image.count("number") >= 8,
                "Missing canonical Vim syntax or line numbers")
        # The recorded Vim status line spans the grid with the default text color.
        solid = image.matches("ink")
        found = False
        for y in range(image.height):
            row = image.pixels[y * image.width:(y + 1) * image.width]
            if sum(v in solid for v in row) >= image.width * 0.70:
                found = True
                break
        require(found, "Missing Vim's reverse-video status line")
    return None


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path)
    parser.add_argument("scene", choices=["prompt", "shell", "editor", "glyphs"])
    parser.add_argument("theme", choices=COLORS)
    parser.add_argument("--same-grid-as", type=Path, help="Compare a glyph frame from the opposite appearance")
    args = parser.parse_args()
    try:
        image = Capture(args.path, args.theme)
        proof = check(image, args.scene)
        if args.same_grid_as:
            require(args.scene == "glyphs", "--same-grid-as needs the glyph scene")
            other_theme = "dark" if args.theme == "light" else "light"
            other = Capture(args.same_grid_as, other_theme)
            require((image.width, image.height) == (other.width, other.height),
                    "Device framebuffer size changed during the appearance switch")
            previous = check(other, "glyphs")
            require(proof[:2] == previous[:2], "Selection or cursor moved during the live appearance change")
            # Integer sRGB conversion can round antialiased pixels differently. Opaque bird
            # colors appear in both frames at the same cell position.
            require(len(proof[2] & previous[2]) >= 6, "Emoji colors changed during the appearance change")
        print(f"{args.scene} / {args.theme}: {image.width} × {image.height}", end="")
        if proof:
            print(f", selection {proof[0]}, cursor {proof[1]}, {len(proof[2])} intrinsic bird colors", end="")
        print()
    except (OSError, ValueError, subprocess.CalledProcessError, struct.error) as error:
        parser.exit(1, f"{args.path}: {error}\n")
