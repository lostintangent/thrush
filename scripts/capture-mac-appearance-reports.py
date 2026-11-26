#!/usr/bin/env python3
"""Flip the packaged Mac window from the dark theme to the light theme to the custom Ember theme, which is also
dark, under programs on a real shell that set mode 2031. A printer logs every reply it receives, and each
flip must reach it exactly once. Choosing Dark again and a background the printer sets itself must not.
Neovim, when installed, then follows the same flips through its own OSC 11 query, and its 'background'
must change with each one. Screenshots show each program after each step."""
import argparse
import os
from pathlib import Path
import plistlib
import re
import runpy
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
spinners = runpy.run_path(str(SCRIPTS / "capture-mac-spinners.py"))
application, save, wait = (spinners[name] for name in ("application", "save", "wait"))
blink = runpy.run_path(str(SCRIPTS / "capture-mac-text-blink.py"))
WINDOW, window, screenshot = (blink[name] for name in ("WINDOW", "window", "screenshot"))
server = runpy.run_path(str(SCRIPTS / "pty/check.py"))["server"]
# The demo's --cycle-appearance chooses these Appearance menu items 4 s apart, beginning at its first output.
STEPS = ("dark", "light", "custom")
SETTLE = 2.5
# Asks whether mode 2031 is set, sets it, asks again and asks for the current appearance. Then it logs
# every reply. After the first report it sets its own background and restores it, which isn't a flip.
PRINTER = r'''
import os, re, sys, time, tty
log = open(sys.argv[1], "a", buffering=1)
tty.setraw(0)
meanings = {"?2031;1$y": "mode 2031 is set", "?2031;2$y": "mode 2031 is reset",
            "?997;1n": "dark", "?997;2n": "light"}
def show(line):
    log.write(line + "\n")
    os.write(1, (line + "\r\n").encode())
os.write(1, b"\x1b[?2031$p\x1b[?2031h\x1b[?2031$p\x1b[?996n")
show("Asked DECRQM ?2031, set mode 2031, asked again and sent DECDSR 996.")
pending, reports = b"", 0
while data := os.read(0, 1024):
    pending += data
    while match := re.search(rb"\x1b\[(\?[0-9;]+(?:\$y|n))", pending):
        pending = pending[match.end():]
        sequence = match[1].decode()
        show(f"received CSI {sequence}  {meanings.get(sequence, '')}")
        if sequence.startswith("?997"):
            reports += 1
            if reports == 2:
                os.write(1, b"\x1b]11;#101010\x07")
                time.sleep(1)
                os.write(1, b"\x1b]111\x07")
                show("set and restored the program's own background")
'''
# Each step's printer log after it settles.
EXPECTED = {
    "dark": ["?2031;2$y", "?2031;1$y", "?997;1n"],
    "light": ["?2031;2$y", "?2031;1$y", "?997;1n", "?997;2n"],
    "custom": ["?2031;2$y", "?2031;1$y", "?997;1n", "?997;2n", "?997;1n"],
}
NEOVIM = """set laststatus=2 noswapfile shortmess+=I
set statusline=\\ Neovim\\ background:\\ %{&background}
autocmd OptionSet background call writefile([v:option_new], '{log}', 'a')
"""


def received(log):
    return re.findall(r"received CSI (\S+)", log.read_text()) if log.exists() else []


def take(name, program, bundle, finder, server_binary, out, scratch, after_step):
    """Runs `program` as the shell, cycles the window's appearance and screenshots each settled step."""
    wrapper = scratch / f"{name}.sh"
    wrapper.write_text("#!/bin/sh\nexec " + shlex.join(map(str, program)) + "\n")
    wrapper.chmod(0o755)
    (scratch / name).mkdir()
    with server(scratch / name, wrapper, out / f"{name}-server.log", server_binary) as endpoint:
        host_log = out / f"{name}-host.log"
        args = ["--endpoint", endpoint, "--scene", "shell", "--cycle-appearance"]
        with application(bundle, args, host_log) as process:
            window_id = window(finder, process)
            subprocess.run(["open", "-a", bundle], check=True)
            for step in STEPS:
                wait(f"{name} appearance={step}", lambda: f"appearance={step}\n" in host_log.read_text())
                time.sleep(SETTLE)
                screenshot(window_id, out / f"{name}-{step}.png")
                after_step(step)
            if process.poll() is not None:
                raise RuntimeError(f"The {name} window exited during its take.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--neovim", type=Path, help="Neovim to run after the printer. Defaults to nvim on PATH.")
    opts = parser.parse_args()
    os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    out = opts.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if any(out.iterdir()):
        parser.error("Use an empty output directory.")
    neovim = opts.neovim or (Path(found) if (found := shutil.which("nvim")) else None)
    subprocess.run([SCRIPTS / "build-demo.sh", "mac"], cwd=ROOT, check=True)
    build = ["swift", "build", "--package-path", ROOT, "-c", "release"]
    subprocess.run([*build, "--product", "ThrushServer"], check=True)
    server_binary = Path(subprocess.check_output([*build, "--show-bin-path"], text=True).strip()) / "ThrushServer"
    bundle = ROOT / ".build/demo/mac/Thrush.app"
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    version = subprocess.check_output([neovim, "--version"], text=True).splitlines()[0] if neovim else None
    save(out / "source.json", dict(commit=info["ThrushGitCommit"], dirty=info["ThrushWorktreeDirty"],
                                 toolchain=info["ThrushToolchain"], neovim=version,
                                 os=subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip()))
    results, failures = {}, []
    with tempfile.TemporaryDirectory(dir=out.parent, prefix="thrush-appearance-") as scratch:
        scratch = Path(scratch)
        source, finder = scratch / "window.swift", scratch / "window"
        source.write_text(WINDOW)
        subprocess.run(["xcrun", "swiftc", source, "-o", finder], check=True, timeout=300)

        printer, printer_log = scratch / "printer.py", out / "printer.log"
        printer.write_text(PRINTER)

        def check_printer(step):
            replies = received(printer_log)
            results.setdefault("printer", {})[step] = replies
            if replies != EXPECTED[step]:
                failures.append(f"After {step}, the printer received {replies}, not {EXPECTED[step]}.")
        take("printer", [sys.executable, printer, printer_log], bundle, finder, server_binary, out, scratch, check_printer)

        if neovim:
            neovim_log = out / "neovim-background.log"
            script = scratch / "thrush.vim"
            script.write_text(NEOVIM.replace("{log}", str(neovim_log)))

            def check_neovim(step):
                values = neovim_log.read_text().split() if neovim_log.exists() else []
                results.setdefault("neovim", {})[step] = values
                expected = "light" if step == "light" else "dark"
                # Startup detection can set 'background' before the first flip, so only the latest value counts.
                if (values[-1:] or ["dark"]) != [expected]:
                    failures.append(f"After {step}, Neovim's 'background' history was {values}, not ending {expected}.")
            sample = ROOT / "Sources/ThrushCore/TerminalInput.swift"
            take("neovim", [neovim, "--clean", "--cmd", f"source {script}", sample],
                 bundle, finder, server_binary, out, scratch, check_neovim)
    save(out / "appearance-reports.json", dict(expected=EXPECTED, received=results, failures=failures))
    if failures:
        raise SystemExit("\n".join(failures))
    print("Each flip reached the printer once" + (" and changed Neovim's background." if neovim else "."))


if __name__ == "__main__":
    main()
