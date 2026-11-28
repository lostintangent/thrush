#!/usr/bin/env python3
"""Compare a native terminal window's pixels with the independently verified checkpoint grid."""
import argparse
from collections import Counter
import json
import math
from pathlib import Path

from proof import Capture, keyboard, require


def different(first, second):
    return any(abs((first >> shift & 255) - (second >> shift & 255)) >= 24 for shift in (0, 8, 16))


def grid_edges(image, state):
    rows, columns = state["rows"], state["columns"]
    require(rows > 0 and columns > 1, "Invalid terminal grid size")
    x, y, w, h = state["gridInWindow"]
    window_w, window_h = state["windowSize"]
    require(all(math.isfinite(v) for v in (x, y, w, h, window_w, window_h))
            and min(window_w, window_h, w, h) > 0, "Invalid window or grid geometry")
    sx, sy = image.width / window_w, image.height / window_h
    require(abs(sx / sy - 1) < 0.025, "Window and screenshot aspect ratios differ")
    xs = [round((x + i * w / columns) * sx) for i in range(columns + 1)]
    ys = [round((y + j * h / rows) * sy) for j in range(rows + 1)]
    require(0 <= xs[0] < xs[-1] <= image.width and 0 <= ys[0] < ys[-1] <= image.height and
            w * sx / columns >= 4 and h * sy / rows >= 8, "Cell grid falls outside the screenshot or is too small")
    return xs, ys, sx, sy


def compare_grids(before, before_state, after, after_state, block_cursor=None):
    require(before_state["appearance"] == after_state["appearance"], "Terminal appearances differ")
    bx, by, _, _ = grid_edges(before, before_state)
    ax, ay, _, _ = grid_edges(after, after_state)
    for first, second in ((bx, ax), (by, ay)):
        require([n - first[0] for n in first] == [n - second[0] for n in second],
                "Terminal cell grid dimensions or pixel spacing differ")

    differences = {}
    width = bx[-1] - bx[0]
    for row in range(len(by) - 1):
        count = 0
        for y in range(by[row], by[row + 1]):
            left = y * before.width + bx[0]
            right = (ay[0] + y - by[0]) * after.width + ax[0]
            first = before.pixels[left:left + width]
            second = after.pixels[right:right + width]
            if first != second:
                # The decoder's fourth byte is BMP padding, outside the sRGB comparison.
                count += sum(bool((a ^ b) & 0xffffff) for a, b in zip(first, second))
        if count:
            differences[row] = count
    total = width * (by[-1] - by[0])
    errors = []
    if differences:
        errors.append(f"{sum(differences.values())} of {total} grid RGB pixels differ; "
                      f"counts by zero-based row {differences}")
    if block_cursor is not None:
        row, col = block_cursor
        require(0 <= row < len(by) - 1 and 0 <= col < len(bx) - 1, "Expected block cursor outside the grid")
        for label, image, xs, ys in (("before", before, bx, by), ("after", after, ax, ay)):
            cursor = image.matches("cursor")
            cell = [image.pixels[y * image.width + x] for y in range(ys[row], ys[row + 1])
                    for x in range(xs[col], xs[col + 1])]
            # The Vim caret covers the paper of its cell; accent and letter strokes cover the remaining pixels.
            fill = sum(pixel in cursor for pixel in cell)
            if fill * 2 <= len(cell):
                errors.append(f"{label}: expected visible block cursor at ({row}, {col}), "
                              f"got {fill}/{len(cell)} cursor-colored pixels")
    require(not errors, "; ".join(errors))
    return f"all {total} grid RGB pixels match" + (f", visible block cursor at {tuple(block_cursor)}" if block_cursor else "")


def check(image, state, require_keyboard=False):
    phone = state.get("keyboard")
    if require_keyboard or (phone is not None and phone["keyboardHeight"] > 90):
        keyboard(image, phone)

    xs, ys, sx, sy = grid_edges(image, state)
    rows, columns = state["rows"], state["columns"]
    # The pane's own controls, such as Latest while reading history, cover these cells.
    overlays = [(x * sx, y * sy, (x + w) * sx, (y + h) * sy) for x, y, w, h in state.get("overlays", [])]
    mask = state["inkMask"]
    require(len(mask) == rows and all(len(line) == columns and set(line) <= {"0", "1"} for line in mask),
            "Invalid expected ink mask")

    if state.get("ended"):
        require(phone is None or (phone["accessoryHeight"] == 0 and phone["keyboardHeight"] < 90),
                "The software keyboard is still on screen at exit")

    selection = state.get("selection")
    require(state.get("copiedText") is None or selection is not None, "Missing native copy selection")
    selected_start = selected_end = -1
    if selection is not None:
        ar, ac, hr, hc = selection
        require(0 <= ar < rows and 0 <= hr < rows and 0 <= ac < columns and 0 <= hc < columns,
                "Selection extends outside the recorded grid")
        selected_start, selected_end = sorted((ar * columns + ac, hr * columns + hc))

    background = image.matches("background", 6)
    highlight = image.matches("selection", 6)
    want = missing = extra = canvas = covered = selection_missing = selection_extra = 0
    row_errors = []
    for row, expected in enumerate(mask):
        row_want = row_missing = row_extra = 0
        for col in range(columns):
            left, right = xs[col], xs[col + 1]
            top, bottom = ys[row], ys[row + 1]
            if any(left < x2 and x1 < right and top < y2 and y1 < bottom for x1, y1, x2, y2 in overlays):
                covered += 1
                continue
            row_want += expected[col] == "1"
            # Keep the ink at the baseline. Rounding each cell separately matches snapped Metal vertices.
            inset_x, inset_y = (right - left) // 16, (bottom - top) // 16
            left, right, top, bottom = left + inset_x, right - inset_x, top + inset_y, bottom - inset_y
            colors = Counter()
            for py in range(top, bottom):
                start = py * image.width
                colors.update(image.pixels[start + left:start + right])
            if not colors:
                continue
            paper, _ = colors.most_common(1)[0]
            canvas += paper in background
            # The predominant color is the cell's local paper, including inverse video and selection.
            # A solid background or cursor block by itself does not count as a printed glyph.
            ink = sum(count for rgb, count in colors.items() if different(rgb, paper))
            visible = ink >= max(1, math.ceil((right - left) * (bottom - top) * 0.009))
            row_missing += expected[col] == "1" and not visible
            row_extra += expected[col] == "0" and visible
            selected = selected_start <= row * columns + col <= selected_end
            selection_missing += selected and paper not in highlight
            selection_extra += not selected and paper in highlight
        missing += row_missing
        extra += row_extra
        want += row_want
        # A single wide continuation, cursor edge or thin punctuation can differ on a native font.
        if row_missing > max(2, row_want * 0.23) or row_extra > max(2, row_want * 0.20):
            row_errors.append(f"row {row}: {row_missing} missing, {row_extra} unexpected of {row_want} expected")

    require(covered <= rows * columns * 0.10, f"Pane controls cover {covered} of {rows * columns} cells")
    require(canvas >= rows * columns * 0.20, "Expected terminal background is absent from the grid")
    count = max(0, selected_end - selected_start + 1) if selection is not None else 0
    require(selection_missing <= max(1, count * 0.04) and selection_extra <= 1,
            f"Selection fill differs: {selection_missing} missing of {count} cells, {selection_extra} outside range")
    require(missing <= max(1, want * 0.10) and extra <= max(2, want * 0.10) and not row_errors,
            f"Glyph occupancy differs: {missing} missing, {extra} unexpected, {want} expected; " + "; ".join(row_errors[:4]))
    result = f"{want - missing}/{want} glyph cells, {extra} unexpected, {count - selection_missing}/{count} selected cells"
    if covered:
        result += f", {covered} cells under pane controls"
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    parser.add_argument("checkpoint", type=Path)
    parser.add_argument("--require-keyboard", action="store_true",
                        help="require the iPhone software keyboard and accessory in the screenshot")
    parser.add_argument("--compare-grid", nargs=2, type=Path, metavar=("PNG", "CHECKPOINT"),
                        help="require every submitted grid RGB pixel to match a second capture")
    parser.add_argument("--block-cursor", nargs=2, type=int, metavar=("ROW", "COLUMN"),
                        help="also require the expected visible block cursor at this zero-based cell in both captures")
    args = parser.parse_args()
    if args.block_cursor is not None and args.compare_grid is None:
        parser.error("--block-cursor requires --compare-grid")
    state = json.loads(args.checkpoint.read_text())
    try:
        image = Capture(args.image, state["appearance"])
        if args.compare_grid:
            other_image, other_checkpoint = args.compare_grid
            other = json.loads(other_checkpoint.read_bytes())
            result = compare_grids(image, state, Capture(other_image, other["appearance"]), other, args.block_cursor)
        else:
            result = check(image, state, args.require_keyboard)
    except ValueError as error:
        parser.exit(1, f"{state['name']}: {error}\n")
    print(f"{state['name']}: {result}")


if __name__ == "__main__":
    main()
