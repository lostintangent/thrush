#!/usr/bin/env python3
"""Measure a native Mac spinner in an original window PNG, in top-left physical pixels.

Pass the spinner's native frame plus 2 pt of padding on each side. The outermost
pixel ring supplies the local background. Within the spoke ring, use the strongest
adjacent pair's lower WCAG contrast to avoid counting a single antialiased outlier.
"""
import argparse
from collections import Counter
from pathlib import Path
import runpy


def luminance(rgb):
    srgb = [value / 255 for value in rgb]
    linear = [v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4 for v in srgb]
    return sum(value * weight for value, weight in zip(linear, (0.2126, 0.7152, 0.0722)))


def measure(frame, region):
    # Reuse the capture checker's ColorSync conversion for both Slate appearances.
    capture = runpy.run_path(str(Path(__file__).with_name("check-demo-capture.py")))["Capture"](frame, "dark")
    return measure_pixels(capture, region)


def measure_pixels(capture, region, *, background_pixels=None):
    x, y, width, height = region
    if min(x, y) < 0 or min(width, height) < 5 or x + width > capture.width or y + height > capture.height:
        raise ValueError(f"Spinner region {region} falls outside the {capture.width}×{capture.height} frame or is too small.")
    pixels = capture.crop((x, y, x + width - 1, y + height - 1))
    if background_pixels is None:
        background_pixels = [pixel for index, pixel in enumerate(pixels)
                             if index % width in (0, width - 1) or index // width in (0, height - 1)]
    background, _ = Counter(background_pixels).most_common(1)[0]
    if any(max(abs(a - b) for a, b in zip(pixel, background)) > 2 for pixel in background_pixels):
        raise ValueError("The spinner needs uniform local background pixels for its contrast measurement.")
    center_x, center_y = (width - 1) / 2, (height - 1) / 2
    bg_luminance = luminance(background)
    ratios = {}
    for index, pixel in enumerate(pixels):
        col, row = index % width, index // width
        radius = ((col - center_x) ** 2 + (row - center_y) ** 2) ** 0.5 / min(width, height)
        if 0.15 <= radius <= 0.48:
            low, high = sorted((bg_luminance, luminance(pixel)))
            ratios[col, row] = (high + 0.05) / (low + 0.05)
    best = 0
    for (col, row), ratio in ratios.items():
        for neighbor in ((col + 1, row), (col, row + 1)):
            if neighbor in ratios and min(ratio, ratios[neighbor]) > best:
                sample = (col, row) if ratio <= ratios[neighbor] else neighbor
                best = ratios[sample]
    if best == 0:
        raise ValueError("No adjacent spinner spoke pixels were found.")
    col, row = sample
    return best, (x + col, y + row), pixels[row * width + col], background


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("frame", type=Path)
    parser.add_argument("--region", required=True, metavar="X,Y,WIDTH,HEIGHT")
    args = parser.parse_args()
    try:
        region = tuple(map(int, args.region.split(",")))
        ratio, point, spoke, background = measure(args.frame, region)
    except ValueError as error:
        parser.error(str(error))
    print(f"{args.frame.name} {args.region}: spoke #{bytes(spoke).hex().upper()} at {point}, "
          f"local background #{bytes(background).hex().upper()}, contrast {ratio:.4f}:1 (minimum 3:1)")
    return 0 if ratio >= 3 else 1


if __name__ == "__main__":
    raise SystemExit(main())
