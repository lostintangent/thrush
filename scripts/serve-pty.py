#!/usr/bin/env python3
"""Serve the plan's pinned Toy Box on loopback with a private home and empty working directory."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


THRUSH = Path(__file__).resolve().parent.parent
REVISION = "b9d0eca3c5f4e9036e58327ba633eff52474bb92"


def copy_worktree(repo, build):
    # Git lists tracked files and nonignored additions, including files a developer has not staged.
    # Hash the copied bytes, path, link target and executable bit to identify this exact build.
    names = subprocess.check_output(["git", "-C", repo, "ls-files", "-co", "--exclude-standard", "-z"])
    fingerprint = hashlib.sha256()
    for name in sorted(set(names.split(b"\0")) - {b""}):
        relative = os.fsdecode(name)
        source = repo / relative
        target = build / relative
        if not source.is_symlink() and not source.exists():
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        if source.is_symlink():
            link = os.readlink(source)
            target.symlink_to(link)
            kind, payload = b"link", os.fsencode(link)
        elif source.is_file():
            data = source.read_bytes()
            target.write_bytes(data)
            executable = source.stat().st_mode & 0o111
            target.chmod(0o755 if executable else 0o644)
            kind, payload = b"executable" if executable else b"file", data
        else:
            raise ValueError(f"Unsupported source entry {relative}")
        fingerprint.update(name + b"\0" + kind + b"\0" + hashlib.sha256(payload).digest())
    return fingerprint.hexdigest()


def prepare(repo, bun, working_tree):
    revision = subprocess.check_output(["git", "-C", repo, "rev-parse", "--verify", ("HEAD" if working_tree else REVISION) + "^{commit}"],
                                       text=True).strip()
    version = subprocess.check_output([bun, "--version"], text=True).strip()
    cache = THRUSH / ".build" / "pty-server"
    cache.mkdir(parents=True, exist_ok=True)
    with (cache / "build.lock").open("a") as lock, tempfile.TemporaryDirectory(dir=cache) as temp:
        fcntl.flock(lock, fcntl.LOCK_EX)
        build = Path(temp) / "build"
        build.mkdir()
        source = {"toyBoxRevision": revision}
        key = revision
        if working_tree:
            digest = copy_worktree(repo, build)
            source["toyBoxWorktreeSHA256"] = digest
            key = f"{revision}-worktree-{digest}"

        target = cache / f"{key}-bun-{version}"
        entry = target / ".output" / "server" / "index.mjs"
        if not entry.is_file():
            if not working_tree:
                archive = Path(temp) / "source.tar"
                subprocess.run(["git", "-C", repo, "archive", revision, "-o", archive], check=True)
                subprocess.run(["tar", "xf", archive, "-C", build], check=True)
            subprocess.run([bun, "install", "--frozen-lockfile", "--ignore-scripts"], cwd=build, check=True)
            subprocess.run([bun, "run", "build"], cwd=build, check=True)
            build.rename(target)
    return entry, source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--toy-box", type=Path, default=THRUSH.parent / "toy-box",
                        help="Toy Box git checkout containing the pinned revision")
    parser.add_argument("--working-tree", action="store_true",
                        help="Build the checkout's current files, including nonignored unstaged additions")
    parser.add_argument("--port", default=0, type=int, help="Loopback port, or 0 for an available port")
    parser.add_argument("--data-dir", required=True, type=Path,
                        help="New or empty directory. Its work, home, and tmp directories survive shutdown.")
    parser.add_argument("--shell", type=Path, default=Path("/bin/zsh"), help="Executable for new PTYs")
    args = parser.parse_args()
    if not (0 <= args.port <= 65535):
        parser.error("port must be between 0 and 65535")
    shell = args.shell.resolve()
    if not shell.is_file() or not os.access(shell, os.X_OK):
        parser.error("shell must be an executable file")
    bun = shutil.which("bun")
    if not bun:
        parser.error("Bun is required to build and run Toy Box")
    data = args.data_dir.resolve()
    data.mkdir(parents=True, exist_ok=True)
    if any(data.iterdir()):
        parser.error("data directory must be new or empty")
    entry, source = prepare(args.toy_box.resolve(), bun, args.working_tree)
    (data / "source.json").write_text(json.dumps(source, indent=2) + "\n")
    home, work, temp = (data / name for name in ("home", "work", "tmp"))
    for directory in (home, work, temp):
        directory.mkdir(mode=0o700)
    # Bun, provider helpers and PTYs all inherit this private environment. The build above can
    # use the developer's package cache and dependency registry; the running server cannot.
    env = {"HOME": str(home), "CFFIXED_USER_HOME": str(home), "TMPDIR": str(temp),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": str(shell),
           "NITRO_HOST": "127.0.0.1", "NITRO_PORT": str(args.port), "NODE_ENV": "production",
           "LC_ALL": "en_US.UTF-8"}
    os.chdir(work)
    print(f"Toy Box {source['toyBoxRevision']} · {data}", flush=True)
    os.execve(bun, [bun, str(entry)], env)


if __name__ == "__main__":
    main()
