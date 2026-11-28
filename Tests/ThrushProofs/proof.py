"""What the proof runners share: waiting and reports, the scene peer, the packaged Mac app and its window,
the UI test runner, ThrushServer, and captures read in sRGB and checked against the theme specifications."""
import collections
from contextlib import contextmanager
import functools
from itertools import groupby
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import struct
import subprocess
import tempfile
import time
from urllib.request import Request, urlopen

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
# An interrupted xcodebuild cancels its tests and still writes the result bundle, which keeps
# the screenshots and clips taken before a hang. Tearing down a hung test took 68 s on a Mac.
INTERRUPT_GRACE = 120
# Prints the window server's ID for a process's normal window, which screencapture takes.
WINDOW = """
import CoreGraphics
let pid = Int(CommandLine.arguments[1])
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
if let window = windows.first(where: {
    ($0[kCGWindowOwnerPID as String] as? Int) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
}), let id = window[kCGWindowNumber as String] as? Int { print(id) }
"""


def wait(description, condition, timeout=22, process=None):
    """Polls until `condition` returns something, failing early if `process` exits."""
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        value = condition()
        if value:
            return value
        if process is not None and process.poll() is not None:
            raise RuntimeError(f"{process.args[0]} exited with status {process.returncode} before {description}")
        time.sleep(0.1)
    raise TimeoutError(f"Timed out waiting for {description}")


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def edges(rect):
    (x, y), (w, h) = rect
    return x, y, x + w, y + h


@contextmanager
def peer(out):
    """Serves the scripted scenes in peers/demo-peer.ts on a loopback port and yields its address."""
    log = out / "peer.log"
    with log.open("w") as output:
        server = subprocess.Popen(["bun", "Tests/ThrushProofs/peers/demo-peer.ts"], stdout=output, stderr=subprocess.STDOUT,
                                  cwd=ROOT, env=dict(os.environ, THRUSH_HOST="127.0.0.1", THRUSH_PORT="0"))
        try:
            def endpoint():
                if server.poll() is not None:
                    raise RuntimeError("Demo peer exited: " + log.read_text())
                match = re.search(r"^Thrush demo peer listening at (http://127\.0\.0\.1:\d+)$", log.read_text(), re.M)
                return match.group(1) if match else None
            # Bun has taken 80 seconds to listen while a hosted runner pages the newly booted simulator in.
            address = wait("the loopback peer", endpoint, 180)
            print(f"Loopback peer ready at {address}", flush=True)
            yield address
        finally:
            server.terminate()
            try:
                server.wait(10)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()


def advance(endpoint, action):
    """Moves the peer's scene to its next step."""
    with urlopen(Request(endpoint + "/" + action, method="POST"), timeout=10) as response:
        if response.status != 204:
            raise RuntimeError(f"The demo peer rejected {action}.")


def mac_app(out, **source):
    """Packages the proofs app for the Mac and saves what it was built from."""
    subprocess.run([ROOT / "scripts/build-app.sh", "proofs", "mac"], cwd=ROOT, check=True)
    bundle = ROOT / ".build/proofs/mac/Thrush.app"
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    save(out / "source.json", dict(commit=info["ThrushGitCommit"], dirty=info["ThrushWorktreeDirty"],
                                   toolchain=info["ThrushToolchain"], **source,
                                   os=subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip()))
    return bundle


@contextmanager
def application(bundle, args, log):
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    binary = bundle / "Contents/MacOS" / info["CFBundleExecutable"]
    with log.open("w") as output, subprocess.Popen([binary, *args], stdout=output, stderr=subprocess.STDOUT) as process:
        try:
            yield process
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(5)
                except subprocess.TimeoutExpired:
                    process.kill()


def prepare_hosted_motion(out, reduced=False):
    # The disposable runner image can ship with Reduce Motion on. Query AppKit in
    # fresh processes before and after writing the user's macOS preference.
    if os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted":
        raise RuntimeError("Hosted motion preparation requires a disposable GitHub runner.")
    pref = ["com.apple.universalaccess", "reduceMotion"]
    probe = ["xcrun", "swift", "-e", "import AppKit; print(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)"]
    def effective():
        value = subprocess.check_output(probe, text=True, timeout=30).strip()
        if value not in ("true", "false"):
            raise ValueError("Unexpected AppKit motion response: " + value)
        return value == "true"
    def preference():
        result = subprocess.run(["defaults", "read", *pref], text=True, capture_output=True)
        return result.stdout.strip() if result.returncode == 0 else None

    report = dict(requested=reduced, before=effective(), previousPreference=preference())
    if report["before"] != reduced:
        write = subprocess.run(["defaults", "write", *pref, "-bool", str(reduced).lower()], text=True, capture_output=True)
        report.update(writeStatus=write.returncode, writeOutput=(write.stdout + write.stderr).strip())
    for _ in range(5):
        report["after"] = effective()
        if report["after"] == reduced:
            break
        time.sleep(.5)
    report["currentPreference"] = preference()
    save(out / ("motion-reduced.json" if reduced else "motion-settings.json"), report)
    if report["after"] != reduced:
        raise RuntimeError(f"AppKit reports Reduce Motion {report['after']} after setting the disposable host preference: {report}")


@functools.cache
def window_finder():
    """Compiles the window lookup once a run, since `xcrun swift` takes seconds to start."""
    finder = ROOT / ".build/proofs/find-window"
    finder.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["xcrun", "swiftc", "-", "-o", finder], input=WINDOW, text=True, check=True, timeout=300)
    return finder


def window_id(pid):
    return subprocess.run([window_finder(), str(pid)], text=True, capture_output=True, timeout=10).stdout.strip()


def window(process):
    """Waits for the app's window and returns its window server ID."""
    def found():
        if process.poll() is not None:
            raise RuntimeError(f"Application {process.pid} exited with status {process.returncode}")
        return window_id(process.pid)
    return wait("the terminal window", found)


def screenshot(window, path):
    subprocess.run(["/usr/sbin/screencapture", "-x", "-o", "-l", window, path], check=True, timeout=30)


def capture_window(pid, path):
    """Captures a process's window with its native chrome. A locked Mac lists no window on screen,
    and ScreenCaptureKit can still capture an obscured one there."""
    found = window_id(pid)
    if found and subprocess.run(["/usr/sbin/screencapture", "-x", "-o", "-l", found, path], timeout=30).returncode == 0:
        return
    subprocess.run(["xcrun", "swift", HERE / "capture-window.swift", str(pid), path], check=True, timeout=60)


def build_cover(scratch):
    """Builds a second app whose window can cover or take the focus from the terminal's."""
    cover = scratch / "Thrush Cover.app"
    contents = cover / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    with (contents / "Info.plist").open("wb") as f:
        plistlib.dump(dict(CFBundleIdentifier="app.thrush.lifecycle-cover", CFBundleName="Thrush Cover",
                           CFBundleExecutable="Cover", CFBundlePackageType="APPL"), f)
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", HERE / "cover-window.swift",
                    "-o", contents / "MacOS/Cover"], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", cover], check=True)
    return cover


def run_logged(args, log, timeout, observe=None):
    with log.open("w") as output, subprocess.Popen(args, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT) as result:
        deadline = time.monotonic() + timeout
        try:
            while result.poll() is None:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(args, timeout)
                if observe:
                    observe()
                try:
                    result.wait(timeout=min(remaining, 0.25) if observe else remaining)
                except subprocess.TimeoutExpired:
                    pass
        finally:
            if result.poll() is None:
                result.send_signal(signal.SIGINT)
                try:
                    result.wait(timeout=INTERRUPT_GRACE)
                except subprocess.TimeoutExpired:
                    result.kill()
    if result.returncode:
        raise RuntimeError(f"{args[0]} exited {result.returncode}. See {log.name}.\n" + log.read_text()[-2800:])


def build_test_runner(work, out, source, *, mac=False):
    """Builds a UI-test bundle of one XCTest source, named for it, and returns its test plan."""
    # XCUITest needs a UI-test bundle. Keep the product and its generated project inside
    # the disposable build directory; the real app is always the normal SwiftPM bundle.
    name = source.stem
    project = work / (name + ".xcodeproj")
    shared = project / "xcshareddata/xcschemes"
    shared.mkdir(parents=True)
    (work / (name + ".swift")).symlink_to(source)
    objects = {}

    def item(key, isa, **values):
        objects[key] = {"isa": isa, **values}

    item("PROJECT", "PBXProject", mainGroup="GROUP", productRefGroup="PRODUCTS", buildConfigurationList="CFG",
         targets=["TARGET"], projectDirPath="", projectRoot="", compatibilityVersion="Xcode 14.0",
         developmentRegion="en", knownRegions=["en", "Base"])
    item("GROUP", "PBXGroup", children=["SOURCE", "PRODUCTS"], sourceTree="<group>")
    item("PRODUCTS", "PBXGroup", children=["BUNDLE"], name="Products", sourceTree="<group>")
    item("SOURCE", "PBXFileReference", lastKnownFileType="sourcecode.swift", path=name + ".swift", sourceTree="<group>")
    item("BUNDLE", "PBXFileReference", explicitFileType="wrapper.cfbundle", path=name + ".xctest",
         sourceTree="BUILT_PRODUCTS_DIR")
    item("TARGET", "PBXNativeTarget", name=name, productName=name, productReference="BUNDLE",
         productType="com.apple.product-type.bundle.ui-testing", buildConfigurationList="TARGETCFG",
         buildPhases=["COMPILE", "LINK"], buildRules=[], dependencies=[])
    item("TEST", "PBXBuildFile", fileRef="SOURCE")
    for key, kind, files in [("COMPILE", "PBXSourcesBuildPhase", ["TEST"]), ("LINK", "PBXFrameworksBuildPhase", [])]:
        item(key, kind, buildActionMask="2147483647", files=files, runOnlyForDeploymentPostprocessing="0")
    platform = dict(SDKROOT="macosx", MACOSX_DEPLOYMENT_TARGET="27.0") if mac else dict(
        SDKROOT="iphoneos", IPHONEOS_DEPLOYMENT_TARGET="27.2", TARGETED_DEVICE_FAMILY="1")
    for key, debug, settings in [
        ("CFG", "DEBUG", dict(**platform, SWIFT_VERSION="5.0", CLANG_ENABLE_MODULES="YES")),
        ("TARGETCFG", "TARGETDEBUG", dict(PRODUCT_NAME=name, PRODUCT_BUNDLE_IDENTIFIER="app.thrush.review.interactions",
                                         GENERATE_INFOPLIST_FILE="YES", CODE_SIGN_IDENTITY="-")),
    ]:
        item(key, "XCConfigurationList", buildConfigurations=[debug], defaultConfigurationIsVisible="0",
             defaultConfigurationName="Debug")
        item(debug, "XCBuildConfiguration", name="Debug", buildSettings=settings)
    with (project / "project.pbxproj").open("wb") as file:
        plistlib.dump(dict(archiveVersion="1", objectVersion="56", classes={}, objects=objects, rootObject="PROJECT"), file)
    ref = (f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="TARGET" '
           f'BuildableName="{name}.xctest" BlueprintName="{name}" ReferencedContainer="container:{project.name}"/>')
    (shared / (name + ".xcscheme")).write_text(f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme version="1.7">
  <BuildAction parallelizeBuildables="NO" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{ref}</BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug"><Testables><TestableReference skipped="NO">{ref}</TestableReference></Testables></TestAction>
</Scheme>
""")
    derived = work / "DerivedData"
    run_logged(["xcodebuild", "-project", project, "-scheme", name, "-derivedDataPath", derived,
                "-destination", "platform=macOS" if mac else "generic/platform=iOS Simulator", "build-for-testing"], out / "runner-build.log", 300)
    return next((derived / "Build/Products").glob("*.xctestrun"))


def configure(plan, **environment):
    """Sets environment variables for the plan's one test target, which sits beside its metadata."""
    settings = plistlib.loads(plan.read_bytes())
    target, = (value for key, value in settings.items() if not key.startswith("__"))
    target["EnvironmentVariables"].update(environment)
    plan.write_bytes(plistlib.dumps(settings))


def export_attachments(result, out, work, clips):
    """Saves the runner's screenshots and its clips' intervals, and returns every attachment's file and time."""
    # XCTest retains completed frames and motion intervals when a later gesture fails.
    exported = work / "attachments"
    run_logged(["xcrun", "xcresulttool", "export", "attachments", "--path", result,
                "--output-path", exported], out / "attachments.log", 90)
    attachments = {}
    for test in json.loads((exported / "manifest.json").read_text()):
        for attachment in test["attachments"]:
            match = re.search(r"thrush-proof__([a-z0-9-]+)__", attachment["suggestedHumanReadableName"])
            if not match:
                continue
            name, path = match[1], exported / Path(attachment["exportedFileName"]).name
            attachments[name] = path, attachment["timestamp"]
            if path.suffix == ".png" or name in clips:
                shutil.copyfile(path, out / (name + (".png" if path.suffix == ".png" else "-motion.json")))
    return attachments


def build_server(out):
    """Builds ThrushServer for release and returns its executable."""
    build = ["swift", "build", "--package-path", str(ROOT), "-c", "release"]
    with (out / "server-build.log").open("xb") as log:
        subprocess.run([*build, "--product", "ThrushServer"], stdout=log, stderr=subprocess.STDOUT,
                       timeout=900, check=True)
        directory = subprocess.check_output([*build, "--show-bin-path"], stderr=log, text=True, timeout=60).strip()
    return Path(directory) / "ThrushServer"


@contextmanager
def server(executable, data, shell, log):
    """Runs ThrushServer with `shell` on a free loopback port and yields its address."""
    with log.open("w") as output, subprocess.Popen(
        [executable, "--port", "0", "--data-dir", data, "--shell", shell],
        cwd=ROOT, stdout=output, stderr=subprocess.STDOUT, start_new_session=True,
    ) as process:
        try:
            # Trust only the port bound by this process, read from its own output.
            listener = wait("ThrushServer's loopback listener", lambda: re.search(
                r"Listening on: (http://127\.0\.0\.1:\d+)/", log.read_text(errors="replace")), 30, process)
            yield listener[1]
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
            process.wait()


# Independent reference from the approved theme specifications and the Vim recording.
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



def luminance(rgb):
    """WCAG relative luminance of an sRGB color."""
    srgb = [value / 255 for value in rgb]
    linear = [v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4 for v in srgb]
    return sum(value * weight for value, weight in zip(linear, (0.2126, 0.7152, 0.0722)))

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
    """The reference checkpoint ends with the reverse status row, then a blank command row."""
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
    require(state is not None, "Keyboard verification requires the frame's geometry")
    (wx, wy), (width, height) = state["windowPoints"]
    (gx, gy), (gw, gh) = state["gridFrame"]
    scale = state["displayScale"]
    guide, accessory = state["keyboardHeight"], state["accessoryHeight"]
    require((image.width, image.height) == (round(width * scale), round(height * scale)),
            "Keyboard framebuffer is not upright at the submitted window size")
    require(guide > 90 and 44 <= accessory < guide and gy - wy + gh <= height - guide + 1,
            "The terminal viewport must clear the native keyboard and its accessory")
    left, right = round(gx - wx), round(gx - wx + gw)
    top = round(height - guide)
    require(0 <= left < right <= width and 0 <= top < height, "Keyboard is outside the window")

    def sample(x, y):
        r, g, b = image.rgb(image.pixels[int(y * scale) * image.width + int(x * scale)])
        return (54 * r + 183 * g + 19 * b) // 256

    def luma(x, y):
        return sample(x + 0.5, y + 0.5)

    # The key row floats as a capsule of eight equal controls, which the app reports in window points.
    keys = state.get("keys") or []
    require(len(keys) == 8, f"Expected the key row's eight controls, found {len(keys)}")
    widths = [w for _, (w, _) in keys]
    require(min(widths) >= 44 and max(widths) - min(widths) <= 0.5,
            f"Key row controls must share one width of at least 44 points, measured {widths}")
    for button, ((kx, ky), (kw, kh)) in enumerate(keys):
        x, y = kx - wx, ky - wy
        require(0 <= x and x + kw <= width and top <= y and y + kh <= top + accessory + 0.5,
                f"Keyboard accessory control {button + 1} lies outside the accessory")
        # Stay clear of the dividers at the edges. A label or arrow stands out from the glass behind it.
        samples = [sample(x + kw * (0.2 + 0.6 * i / 23), y + kh * (0.2 + 0.6 * j / 15))
                   for i in range(24) for j in range(16)]
        glass = sorted(samples)[len(samples) // 2]
        ink = sum(abs(v - glass) >= 70 for v in samples)
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
            "The expected terminal canvas is absent")
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



def check_scene(path, scene, theme, metadata=None, same_grid_as=None):
    """Checks a capture of a scene and describes what it found. Pass the frame's geometry for the
    Vim status row or the keyboard, and a glyph frame in the other appearance to compare its grid."""
    image = Capture(path, theme)
    found = check(image, scene, metadata)
    if same_grid_as:
        require(scene == "glyphs", "Comparing grids needs the glyph scene")
        other = Capture(same_grid_as, "dark" if theme == "light" else "light")
        require((image.width, image.height) == (other.width, other.height),
                "Device framebuffer size changed during the appearance switch")
        previous = check(other, "glyphs")
        require(found[:2] == previous[:2], "Selection or cursor moved during the live appearance change")
        # Integer sRGB conversion can round antialiased pixels differently. Opaque bird
        # colors appear in both frames at the same cell position.
        require(len(found[2] & previous[2]) >= 6, "Emoji colors changed during the appearance change")
    summary = f"{scene} / {theme}: {image.width} × {image.height}"
    if found:
        summary += f", selection {found[0]}, cursor {found[1]}, {len(found[2])} intrinsic bird colors"
    return summary
