"""Verify a mounted cursor spinner against the peer's expected cell and the native framebuffer."""
import math
from pathlib import Path
import runpy

SCRIPTS = Path(__file__).resolve().parents[1]
Capture = runpy.run_path(str(SCRIPTS / "check-demo-capture.py"))["Capture"]
contrast = runpy.run_path(str(SCRIPTS / "check-spinner-contrast.py"))


def edges(frame):
    (x, y), (w, h) = frame
    return x, y, x + w, y + h


def grid_pixels(state, image):
    window = state.get("windowPoints", state.get("windowFrame"))
    (_, _), (width, height) = window
    # The Duo's display runs past the window, beside it in portrait and below it in landscape.
    scale = state.get("displayScale") or image.width / width
    if image.width + 1 < width * scale or image.height + 1 < height * scale:
        raise ValueError("The framebuffer does not cover the measured window.")
    grid = tuple(round(v * scale) for v in edges(state["gridFrame"]))
    x, y, r, b = grid
    if not 0 <= x < r <= image.width or not 0 <= y < b <= image.height:
        raise ValueError(f"Grid outside framebuffer: {grid}.")
    return scale, grid


def measure(image, state, appearance, row, column, expected_label, *, use_adjacent_canvas=False):
    label = state.get("cursorSpinnerLabel")
    if label != expected_label:
        raise ValueError(f"Expected native spinner label {expected_label!r}, observed {label!r}.")
    pixels = Capture(image, appearance)
    scale, grid = grid_pixels(state, pixels)
    spinner = state.get("cursorSpinner") or state.get("spinnerFrame")
    if not spinner or not state.get("cursorCellFrame") or not state.get("firstCellFrame"):
        raise ValueError("Missing native spinner, cursor cell or first-cell geometry.")
    (fx, fy), (cw, ch) = state["firstCellFrame"]
    (cx, cy), (w, h) = state["cursorCellFrame"]
    (sx, sy), (sw, sh) = spinner
    # Integer pixel boundaries may differ by a pixel as fractional cell advances accumulate.
    # firstCellFrame may already have rounded edges; use the aggregate grid's exact advances.
    if state.get("lastCellFrame"):
        _, _, right, bottom = edges(state["lastCellFrame"])
        cw, ch = (right - fx) / state["columns"], (bottom - fy) / state["rows"]
    elif state.get("cellGridPixels"):
        (_, _), (total_w, total_h) = state["cellGridPixels"]
        cw, ch = total_w / scale / state["columns"], total_h / scale / state["rows"]
    expected = (fx + (column + 0.5) * cw, fy + (row + 0.5) * ch)
    observed = (cx + w / 2, cy + h / 2)
    if max(abs(a-b) for a,b in zip(expected, observed)) > 1.5 / scale:
        raise ValueError(f"Native cursor {observed} differs from peer cell ({row}, {column}) at {expected}.")
    if (not 0 < sw <= min(w, h, 16) + 1 / scale or abs(sh-sw) > 1 / scale
            or max(abs(sx+sw/2-observed[0]), abs(sy+sh/2-observed[1])) > 1 / scale):
        raise ValueError(f"Spinner {spinner} is not centered inside one cursor cell {state['cursorCellFrame']}.")
    region = [math.floor(sx*scale)-1, math.floor(sy*scale)-1,
              math.ceil((sx+sw)*scale)-math.floor(sx*scale)+2, math.ceil((sy+sh)*scale)-math.floor(sy*scale)+2]
    # The native spinner replaces the block cursor on an empty cell in these scenes.
    # Its visible spokes must differ from the nearby Slate canvas, even in an inactive window.
    background_pixels = None
    if use_adjacent_canvas:
        # The reconnect-typing movie has an empty cell after the insertion point.
        # Sample its interior to avoid H.264 color bleed at the animated spoke edges.
        left, top = math.ceil((cx + 1.25 * w) * scale), math.ceil((cy + 0.25 * h) * scale)
        right, bottom = math.floor((cx + 1.75 * w) * scale), math.floor((cy + 0.75 * h) * scale)
        if not (grid[0] <= left < right < grid[2] and grid[1] <= top < bottom < grid[3]):
            raise ValueError("No adjacent canvas cell inside the terminal grid.")
        background_pixels = pixels.crop((left, top, right, bottom))
    ratio, point, ink, background = contrast["measure_pixels"](pixels, region, background_pixels=background_pixels)
    if ratio < 3:
        raise ValueError(f"Leading spoke contrast {ratio:.3f}:1 is below 3:1 at {point}.")
    return dict(accessibilityLabel=label, expectedCursorCell=[row, column], spinnerPoints=spinner, cellPoints=state["cursorCellFrame"],
                imagePixels=[pixels.width, pixels.height], region=region, spokePixel=point, contrast=ratio, ink=ink, background=background)


def compare(wait_image, waiting, live_image, live, appearance):
    if any(waiting.get(k) != live.get(k) for k in ("pid", "gridFrame", "rows", "columns", "firstCellFrame",
                                                    "cursorCellFrame", "keyboardHeight", "accessoryHeight")):
        raise ValueError("The cursor, terminal grid or keyboard layout changed during the handshake.")
    if live.get("cursorSpinner") or live.get("spinnerFrame") or live.get("cursorSpinnerLabel") is not None:
        raise ValueError("The reference frame still has a mounted cursor spinner.")
    a, b = Capture(wait_image, appearance), Capture(live_image, appearance)
    scale, (left, top, right, bottom) = grid_pixels(waiting, a)
    if (a.width, a.height) != (b.width, b.height):
        raise ValueError("The paired captures have different framebuffer sizes.")
    cx, cy, cr, cb = edges(waiting["cursorCellFrame"])
    cl, ct, cr, cb = math.floor(cx*scale)-1, math.floor(cy*scale)-1, math.ceil(cr*scale)+1, math.ceil(cb*scale)+1
    # Under a navigation bar, the Close button's glass shadow reaches the grid's top rows and can
    # shift a level between frames, so there the grid may differ by two levels at most.
    slack = 2 if waiting.get("toolbar") else 0

    def changed(x, z):
        return (x ^ z) & 0xffffff and max(abs(p - q) for p, q in zip(Capture.rgb(x), Capture.rgb(z))) > slack
    outside = inside = 0
    for y in range(top, bottom):
        start = y * a.width
        parts = [(left,right)] if not ct <= y < cb else [(left,max(left,cl)), (min(right,cr),right)]
        for x0,x1 in parts:
            aa, bb = a.pixels[start+x0:start+x1], b.pixels[start+x0:start+x1]
            if aa != bb:
                outside += sum(changed(x, z) for x,z in zip(aa,bb))
        if ct <= y < cb:
            inside += sum((x & 0xffffff) != (z & 0xffffff) for x,z in zip(
                a.pixels[start+max(cl,left):start+min(cr,right)], b.pixels[start+max(cl,left):start+min(cr,right)]))
    if outside or inside < 2:
        raise ValueError(f"Grid difference outside/inside the cursor cell: {outside}/{inside} pixels.")
    return dict(gridPixels=[left,top,right,bottom], changedPixelsOutsideCursor=outside, changedPixelsAtCursor=inside)
