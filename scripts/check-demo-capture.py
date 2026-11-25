#!/usr/bin/env python3
"""Check the native demo's terminal scenes and iPhone keyboard in sRGB."""
import argparse
import collections
import json
from itertools import groupby
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


def check_status_row(image, state):
    """The xterm checkpoint ends with the reverse status row, then a blank command row."""
    (wx, wy), (window_width, window_height) = state["windowPoints"]
    (view_x, view_y), _ = state["gridFrame"]
    (cell_x, cell_y), (pixel_width, pixel_height) = state["cellGridPixels"]
    scale = state["displayScale"]
    columns, rows = state["columns"], state["rows"]
    require(state["gpuCompleted"] and rows >= 2 and columns > 18, "Missing the completed terminal grid")
    require((image.width, image.height) == (round(window_width * scale), round(window_height * scale)),
            "Image size or orientation differs from the submitted window")
    left = round((view_x - wx) * scale + cell_x)
    grid_top = round((view_y - wy) * scale + cell_y)
    width = round(pixel_width)
    row_height = round(pixel_height / rows)
    top = grid_top + (rows - 2) * row_height
    require(row_height > 0 and abs(row_height * rows - pixel_height) < 1 and
            0 <= left < left + width <= image.width and 0 <= grid_top < top + 2 * row_height <= image.height,
            "Submitted grid falls outside the captured framebuffer")
    paper, ink = image.matches("ink"), image.matches("background", tolerance=12)

    def scan(y):
        start = y * image.width + left
        return image.pixels[start:start + width]

    # All columns are reverse-video, including the space after the ruler. The scan
    # lines outside the glyph ink should cross the complete physical width of the grid.
    for y in (top + 1, top + row_height - 2):
        require(sum(v in paper for v in scan(y)) >= width - 2,
                f"Vim's status fill does not span grid row {rows - 1} of {rows} at y={y}")
    require(all(v in ink for v in scan(top + row_height + 1)), "Vim's last command row should be blank")

    # Both recorded themes say “ Prompt.swift … 5:18 ”. Check ink in every letter
    # and ruler column so a clipped, padded or horizontally wrapped replay cannot pass.
    for col in [*range(1, 13), *range(columns - 5, columns - 1)]:
        x0, x1 = round(col * width / columns), round((col + 1) * width / columns)
        require(any(v in ink for y in range(top + 2, top + row_height - 2) for v in scan(y)[x0:x1]),
                f"Missing Vim status text in column {col + 1} of {columns}")


def keyboard(image, state):
    require(state is not None, "Keyboard verification requires --metadata")
    (wx, wy), (width, height) = state["windowPoints"]
    (gx, gy), (gw, gh) = state["gridFrame"]
    scale = state["displayScale"]
    guide, accessory = state["keyboardHeight"], state["accessoryHeight"]
    require((image.width, image.height) == (round(width * scale), round(height * scale)),
            "Keyboard framebuffer is not upright at the submitted window size")
    require(guide > 90 and 44 <= accessory < guide and abs(gy - wy + gh - (height - guide)) <= 1,
            "The keyboard guide and attached accessory must meet the terminal viewport")
    left, right = round(gx - wx), round(gx - wx + gw)
    top = round(height - guide)
    require(0 <= left < right <= width and 0 <= top < height, "Keyboard is outside the window")

    # Sample point centres. The safe-area width also sets the widths of the seven
    # equal accessory buttons, including when the home indicator moves in landscape.
    def luma(x, y):
        px = int((x + 0.5) * scale)
        py = int((y + 0.5) * scale)
        r, g, b = image.rgb(image.pixels[py * image.width + px])
        return (54 * r + 183 * g + 19 * b) // 256

    for button in range(7):
        x0 = round(left + (button + 0.20) * (right - left) / 7)
        x1 = round(left + (button + 0.80) * (right - left) / 7)
        ink = sum(abs(luma(x, y) - luma(x, top + 3)) >= 70 for x in range(x0, x1)
                  for y in range(top + 11, top + 33))
        require(ink >= 10, f"Keyboard accessory control {button + 1} has no visible label or arrow")

    # Native keycaps are brighter than the gutters in both system appearances.
    # Look for the repeated key-width fills, independently on each scanline. This
    # follows the actual system keyboard without assuming QWERTY row coordinates.
    def letter_row(y):
        samples = [luma(x, y) for x in range(left, right)]
        ranked = sorted(samples)
        gutter, cap = ranked[len(ranked) // 25], ranked[len(ranked) * 2 // 3]
        if cap - gutter < 15:
            return False
        threshold = (gutter + cap) / 2
        widths = [sum(1 for _ in run) for filled, run in groupby(samples, lambda v: v >= threshold) if filled]
        keys = [w for w in widths if len(samples) * 0.026 <= w <= len(samples) * 0.16]
        return len(keys) >= 6 and sum(keys) >= len(samples) * 0.42

    # Require sustained keycaps in three vertically separate bands. Spacing scales
    # with the available keyboard height on a compact landscape keyboard.
    body = round(top + accessory)
    bands = []
    for filled, lines in groupby(range(body, int(height)), key=letter_row):
        if filled:
            lines = list(lines)
            if len(lines) >= 4:
                center = (lines[0] + lines[-1]) / 2
                if not bands or center - bands[-1] >= (height - body) * 0.09:
                    bands.append(center)
    require(len(bands) >= 3, f"Expected three native letter-key rows below the accessory, found {len(bands)}")


def check(image, scene, metadata=None):
    if scene == "keyboard":
        return keyboard(image, metadata)
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
        if metadata is not None:
            check_status_row(image, metadata)
            return None
        # Original Mac window captures may have no geometry sidecar.
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
    parser.add_argument("scene", choices=["prompt", "shell", "editor", "glyphs", "keyboard"])
    parser.add_argument("theme", choices=COLORS)
    parser.add_argument("--metadata", type=Path, help="Phone frame geometry for Vim status or keyboard checks")
    parser.add_argument("--same-grid-as", type=Path, help="Compare a glyph frame from the opposite appearance")
    args = parser.parse_args()
    try:
        image = Capture(args.path, args.theme)
        state = json.loads(args.metadata.read_text()) if args.metadata else None
        proof = check(image, args.scene, state)
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
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError, struct.error) as error:
        parser.exit(1, f"{args.path}: {error}\n")
