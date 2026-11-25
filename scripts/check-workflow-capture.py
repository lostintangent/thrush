#!/usr/bin/env python3
"""Compare a native terminal window's pixels with the independently verified checkpoint grid."""
import argparse
from collections import Counter
import json
import math
from pathlib import Path
import runpy
import subprocess
import tempfile

demo = runpy.run_path(str(Path(__file__).with_name("check-demo-capture.py")))
Capture = demo["Capture"]
keyboard = demo["keyboard"]


def require(value, message):
    if not value:
        raise ValueError(message)


def different(first, second):
    return any(abs((first >> shift & 255) - (second >> shift & 255)) >= 24 for shift in (0, 8, 16))


def verify_ended_notice(image, path, notice, sx, sy):
    require(notice["title"] == "Ended" and notice["action"] == "New Shell", "Missing the mounted final shell notice")
    (x, y), (w, h) = notice["frameInWindow"]
    require(all(math.isfinite(n) for n in (x, y, w, h)), "Invalid Ended geometry")
    left, top = round(x * sx), round(y * sy)
    right, bottom = round((x + w) * sx), round((y + h) * sy)
    require(0 <= left < right <= image.width and 0 <= top < bottom <= image.height, "Ended panel outside the window")
    # Only the measured opaque panel may cover terminal paper. Its labels must be visible inside that rectangle.
    with tempfile.TemporaryDirectory() as tmp:
        crop = Path(tmp) / "ended.png"
        subprocess.run(["/usr/bin/sips", "-c", str(bottom - top), str(right - left), "--cropOffset", str(top), str(left),
                        str(path), "--out", str(crop)], check=True, stdout=subprocess.DEVNULL)
        checker = Path(__file__).with_name("check-pane-capture.swift")
        subprocess.run(["xcrun", "swift", str(checker), str(crop), "Ended", "New Shell"], check=True)
    return left, top, right, bottom


def check(image, state, require_keyboard=False, path=None):
    phone = state.get("keyboard")
    if require_keyboard or (phone is not None and phone["keyboardHeight"] > 90):
        keyboard(image, phone)

    rows, columns = state["rows"], state["columns"]
    mask = state["inkMask"]
    require(rows > 0 and columns > 1 and len(mask) == rows and
            all(len(line) == columns and set(line) <= {"0", "1"} for line in mask),
            "Invalid expected ink mask")

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

    panel = None
    if notice := state.get("endedNotice"):
        require(phone is None or (phone["accessoryHeight"] == 0 and phone["keyboardHeight"] < 90),
                "The software keyboard is still on screen at exit")
        panel = verify_ended_notice(image, path, notice, sx, sy)

    selection = state.get("selection")
    require(state.get("copiedText") is None or selection is not None, "Missing native copy selection")
    selected_start = selected_end = -1
    if selection is not None:
        ar, ac, hr, hc = selection
        require(0 <= ar < rows and 0 <= hr < rows and 0 <= ac < columns and 0 <= hc < columns,
                "Selection extends outside the recorded grid")
        selected_start, selected_end = sorted((ar * columns + ac, hr * columns + hc))

    slate = image.matches("background", 6)
    highlight = image.matches("selection", 6)
    want = missing = extra = canvas = selection_missing = selection_extra = 0
    row_errors = []
    for row, expected in enumerate(mask):
        row_want = expected.count("1")
        row_missing = row_extra = 0
        for col in range(columns):
            left, right = xs[col], xs[col + 1]
            top, bottom = ys[row], ys[row + 1]
            # Keep the ink at the baseline. Rounding each cell separately matches snapped Metal vertices.
            inset_x, inset_y = (right - left) // 16, (bottom - top) // 16
            left, right, top, bottom = left + inset_x, right - inset_x, top + inset_y, bottom - inset_y
            colors = Counter()
            for py in range(top, bottom):
                start = py * image.width
                if panel and panel[1] <= py < panel[3] and panel[0] < right and left < panel[2]:
                    require(expected[col] == "0" and not selected_start <= row * columns + col <= selected_end,
                            f"Ended panel covers transcript ink or selection at row {row}, column {col}")
                    colors.update(image.pixels[start + left:start + max(left, panel[0])])
                    colors.update(image.pixels[start + min(right, panel[2]):start + right])
                else:
                    colors.update(image.pixels[start + left:start + right])
            if not colors:
                continue
            paper, _ = colors.most_common(1)[0]
            canvas += paper in slate
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

    require(canvas >= rows * columns * 0.20, "Expected Slate terminal background is absent from the grid")
    count = max(0, selected_end - selected_start + 1) if selection is not None else 0
    require(selection_missing <= max(1, count * 0.04) and selection_extra <= 1,
            f"Selection fill differs: {selection_missing} missing of {count} cells, {selection_extra} outside range")
    require(missing <= max(1, want * 0.10) and extra <= max(2, want * 0.10) and not row_errors,
            f"Glyph occupancy differs: {missing} missing, {extra} unexpected, {want} expected; " + "; ".join(row_errors[:4]))
    result = f"{want - missing}/{want} glyph cells, {extra} unexpected, {count - selection_missing}/{count} selected cells"
    return result + (", visible Ended and New Shell" if panel else "")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    parser.add_argument("checkpoint", type=Path)
    parser.add_argument("--require-keyboard", action="store_true",
                        help="require the iPhone software keyboard and accessory in the screenshot")
    args = parser.parse_args()
    state = json.loads(args.checkpoint.read_text())
    try:
        result = check(Capture(args.image, state["appearance"]), state, args.require_keyboard, args.image)
    except ValueError as error:
        parser.exit(1, f"{state['name']}: {error}\n")
    print(f"{state['name']}: {result}")


if __name__ == "__main__":
    main()
