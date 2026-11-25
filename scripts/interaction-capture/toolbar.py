"""Check the packaged terminal under an inline NavigationStack toolbar in original simulator pixels."""
import json
from pathlib import Path
import runpy
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def edges(rect):
    (x, y), (w, h) = rect
    return x, y, x + w, y + h


def check_copy(image, rect, state, checker, scratch, labels):
    # Crop only the checked geometry so a transcript line cannot masquerade as a toolbar title.
    scale = state["displayScale"]
    window_x, window_y, _, _ = edges(state["windowPoints"])
    left, top, right, bottom = edges(rect)
    x, y = round((left - window_x) * scale), round((top - window_y) * scale)
    width, height = round((right - left) * scale), round((bottom - top) * scale)
    crop = scratch / "toolbar-region.png"
    subprocess.run(["/usr/bin/sips", "--cropToHeightWidth", str(height), str(width),
                    "--cropOffset", str(y), str(x), image, "--out", crop],
                   check=True, stdout=subprocess.DEVNULL, timeout=25)
    subprocess.run([checker, crop, *labels], check=True, timeout=60)


def check(image, state, appearance, scene, scratch):
    toolbar = state.get("toolbar")
    if not toolbar:
        raise ValueError("Missing mounted navigation bar or pane geometry.")
    scale = state["displayScale"]
    epsilon = 1 / scale
    pane = edges(toolbar["paneFrame"])
    safe = edges(toolbar["safeAreaFrame"])
    bar = edges(toolbar["navigationBarFrame"])
    grid = edges(state["gridFrame"])
    window = edges(state["windowPoints"])
    first = edges(toolbar["firstCellFrame"])
    notice = edges(state["notice"]["frameInWindow"])
    if not (window[0] <= bar[0] < bar[2] <= window[2] and window[1] <= bar[1] < bar[3] <= window[3]):
        raise ValueError(f"Invalid native navigation bar: {bar}, {window}")
    if abs(pane[1] - window[1]) > epsilon:
        raise ValueError(f"The canvas does not reach the physical top of the window: {pane}, {window}")
    if state["orientation"] == "portrait" and abs(grid[1] - bar[3]) > epsilon:
        raise ValueError(f"The terminal grid does not begin at the inline bar’s bottom: {grid}, {bar}")
    if (first[1] + epsilon < max(bar[3], safe[1]) or first[0] + epsilon < grid[0] or
            first[3] <= first[1] or first[2] <= first[0]):
        raise ValueError(f"Row one overlaps toolbar chrome or falls outside the grid: {first}, {bar}, {grid}")
    checker = scratch / "check-pane-capture"
    check_copy(image, toolbar["navigationBarFrame"], state, checker, scratch, ["Terminal", "Close"])
    labels = ["Connecting"] if scene == "notice-connecting" else ["Open in another window", "Use Here"]
    check_copy(image, state["notice"]["frameInWindow"], state, checker, scratch, labels)
    pixels = runpy.run_path(str(ROOT / "scripts/check-demo-capture.py"))["Capture"](image, appearance)
    if (pixels.width, pixels.height) != (round((window[2] - window[0]) * scale),
                                        round((window[3] - window[1]) * scale)):
        raise ValueError("Simulator framebuffer does not match the mounted window.")
    # The inline title sits in the center, with Close on the trailing edge. Sample the
    # unobstructed bar to the leading side of both, where the pane canvas must show through.
    bar_width = bar[2] - bar[0]
    left = round((bar[0] - window[0] + 0.14 * bar_width) * scale)
    right = round((bar[0] - window[0] + 0.28 * bar_width) * scale)
    middle = round(((bar[1] + bar[3]) / 2 - window[1]) * scale)
    slate = pixels.matches("background", tolerance=8)
    for y in range(middle - 1, middle + 2):
        sample = pixels.pixels[y * pixels.width + left:y * pixels.width + right]
        if not sample or sum(value in slate for value in sample) < 0.95 * len(sample):
            raise ValueError(f"Slate canvas is missing beneath the unoccupied bar at x={left}…{right}, y={y}.")
    if scene == "notice-connecting":
        if any(abs((notice[i] + notice[i + 2] - grid[i] - grid[i + 2]) / 2) > epsilon for i in (0, 1)):
            raise ValueError(f"Connecting is not centered in the usable terminal: {notice}, {grid}")
        return

    # First row from the wire peer ends in “swift test”. Only that row may satisfy this check.
    row = ((grid[0], first[1]), (grid[2] - grid[0], first[3] - first[1]))
    check_copy(image, row, state, checker, scratch, ["swift test"])
    if any(abs(span[i] - window[i]) > epsilon for span in (pane, notice) for i in (0, 2)):
        raise ValueError(f"Status backing does not span the physical window: {notice}, {pane}, {window}")
    # Below the separator and above the padded text, the full scan line is opaque host backing.
    expected = bytes.fromhex("1D2934" if appearance == "dark" else "E8EEF1")
    y = round((notice[1] - window[1] + 3) * scale)
    scan = pixels.pixels[y * pixels.width:(y + 1) * pixels.width]
    def backing(pixel):
        return max(abs(a - b) for a, b in zip(pixels.rgb(pixel), expected)) <= 8
    if not scan or not backing(scan[0]) or not backing(scan[-1]) or sum(map(backing, scan)) < 0.99 * pixels.width:
        raise ValueError(f"The full-width status backing is missing in framebuffer row {y}.")


def capture(phone, options, sim):
    frames = []
    failures = {}
    for scene in ("notice-connecting", "notice-displaced"):
        name = f"{scene}-{options.appearance}-{options.orientation}"
        prefix = "toolbar-" + name.removeprefix("notice-")
        try:
            pid = phone.launch(scene, options.appearance, options.orientation, "hidden", extra_arguments=("--toolbar-proof",))
            state = phone.frame(scene, options.appearance, options.orientation, "hidden", pid, None, layout_only=True)
            # Collect both untouched simulator framebuffers before compiling the independent pixel checker.
            raw = phone.out / (prefix + "-framebuffer.png")
            sim("io", phone.device, "screenshot", "--mask=black", str(raw), timeout=90)
            upright = phone.oriented_image(raw, options.orientation)
            image = phone.out / (prefix + ".png")
            if upright == raw:
                raw.replace(image)
            else:
                shutil.copyfile(upright, image)
            metadata = dict(state, framebufferRotationDegrees=90 if upright != raw else 0)
            (phone.out / (prefix + ".json")).write_text(json.dumps(metadata, indent=2) + "\n")
            if state != phone.state():
                raise ValueError("Native geometry changed during the framebuffer capture.")
            frames.append((scene, image, state))
        except (KeyError, ValueError, OSError, RuntimeError, subprocess.SubprocessError) as error:
            failures[scene] = str(error)
            (phone.out / (prefix + "-last-state.json")).write_text(json.dumps(phone.state(), indent=2) + "\n")
            print(f"{prefix}: {error}", flush=True)

    if frames:
        subprocess.run(["xcrun", "swiftc", ROOT / "scripts/check-pane-capture.swift",
                        "-o", phone.scratch / "check-pane-capture"], check=True, timeout=300)
    for scene, image, state in frames:
        try:
            check(image, state, options.appearance, scene, phone.scratch)
            print(f"Verified navigation chrome and terminal geometry in {image.name}", flush=True)
        except (KeyError, ValueError, OSError, RuntimeError, subprocess.SubprocessError) as error:
            failures[scene] = str(error)
            print(f"{image.name}: {error}", flush=True)
    if failures:
        raise RuntimeError(f"Toolbar proof failed: {failures}")
