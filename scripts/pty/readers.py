"""Compare real PTY readers at a matched source rate and test exit with a full socket buffer."""
import argparse
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

sys.dont_write_bytecode = True
from check import fixture_environment, local_endpoint, read_json, report_path, server, wait_for


HERE = Path(__file__).resolve().parent
FINAL = b"THRUSH-SHELL-EXIT\r\n"


def dead(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    return False


def exercise(binary, endpoint, work, name, reader, env, profile="paced16", probe=False, suspend=False):
    run = work / name
    run.mkdir()
    (work / "current-run").write_text(name)
    if profile == "unpaced":
        (run / "unpaced").touch()
    if probe:
        (run / "exit-now").touch()
    shell_id = str(uuid.uuid4())
    if env["THRUSH_PTY_CHECK_BOOTSTRAP"]:
        (run / "reader-id").write_text(shell_id)
    if reader == "silent":
        (run / "gap-nonce").write_text(shell_id)
    if reader == "bun":
        command = ["bun", HERE / "count-reader.ts", endpoint, shell_id, run, "exit" if probe else "count"]
    else:
        command = [binary, "reader", reader, endpoint, shell_id, run]
    with subprocess.Popen(command, env=env) as client:
        try:
            wait_for("fresh reader", (run / "reader-ready").exists, client)
            wait_for("real PTY producer", (run / "producer-ready").exists, client)
            pid = int((run / "producer-ready").read_text())
            if suspend:
                client.send_signal(signal.SIGSTOP)
                _, status = os.waitpid(client.pid, os.WUNTRACED)
                if not os.WIFSTOPPED(status):
                    raise RuntimeError("Reader failed to suspend")
            (run / "go").touch()
            wait_for("all producer writes", (run / "production.json").exists, client)
            if reader == "silent":
                # The server can process every PTY write while the receiving process remains stopped.
                time.sleep(1)
                (run / "send-gap-input").touch()
                client.send_signal(signal.SIGCONT)
                wait_for("gap input reached the silent producer", (run / "gap-input-received").exists, client)
            elif probe:
                wait_for("real shell process death", lambda: dead(pid), client, 10)
                if not (run / "shell-exit-issued").exists():
                    raise RuntimeError("Real shell did not write its final marker")
                if suspend:
                    # Keep the window full while the server drains its serializer's exit callback.
                    time.sleep(1)
                    client.send_signal(signal.SIGCONT)
                time.sleep(3)
                (run / "probe").touch()
            else:
                # Keep exit separate from payload loss in the matched-reader series.
                time.sleep(1)
                (run / "allow-exit").touch()
            if client.wait(timeout=15):
                raise RuntimeError(f"Reader {name} failed")
        finally:
            if client.poll() is None:
                client.kill()

    produced = read_json(run / "production.json")
    result = read_json(run / "client.json")
    if result.get("appliedBytes", result["receivedBytes"]) != result["receivedBytes"]:
        raise RuntimeError("Thrush applied-byte count diverged")
    if probe:
        if result["replayFrames"]:
            screen = subprocess.run([binary, "check-exit-screen", run / "final-screen.bin"], capture_output=True, timeout=10)
            result["finalScreenMatchesExpected"] = screen.returncode == 0
        new_pid = int((run / "replacement-pid").read_text())
        result.update({"shellFinalWriteSucceeded": True, "shellPIDDead": True,
                       "replacementShellHasNewPID": new_pid != pid, "afterDeathReadWindowSeconds": 3})
    expected_wire = produced["bytes"] + (len(FINAL) if probe else 0)
    live_bytes = result["receivedBytes"] - result.get("replayBytes", 0)
    if reader == "silent":
        result["gapInputReceivedByPTY"] = (run / "gap-input-received").exists()
        # Exclude the live echo after the repair from the original numbered-stream comparison.
        live_bytes = result["liveNumberedBytes"]
    result.update({"name": name, "profile": profile, "peak50msMiBPerSecond": produced["peak50msMiBPerSecond"],
                   "producerBytes": produced["bytes"], "producerSeconds": produced["seconds"],
                   "producerMiBPerSecond": round(produced["bytes"] / 1048576 / produced["seconds"], 3),
                   "expectedBinaryBytes": expected_wire, "missingBinaryBytes": expected_wire - live_bytes})
    if result["missingBinaryBytes"] < 0:
        raise RuntimeError("Unexpected prompt, echo, or extra binary output")
    print(json.dumps(result), flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--endpoint", type=local_endpoint, help="Use a disposable local PTY server sharing this filesystem")
    parser.add_argument("--server-binary", type=Path, help="Release ThrushServer executable beside the check client")
    parser.add_argument("--recovery", action="store_true", help="Run the silent repair and exit-order acceptance checks")
    args = parser.parse_args()
    binary = args.binary.resolve()

    def terminate(signum, frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, terminate)
    with tempfile.TemporaryDirectory(prefix="thrush-readers-") as temp:
        root = Path(temp)
        work = root / "data" / "work"
        shell = root / "shell"
        shell.write_text(
            f'#!/bin/sh\nset -eu\ncd {shlex.quote(str(work))}\nstty -echo -onlcr\ncd "$(cat current-run)"\n'
            'if test -f reader-id; then printf "\\r\\nTHRUSH-SETUP-%s\\r\\n" "$(cat reader-id)"; fi\n'
            '/usr/bin/python3 ../reader-producer.py\n'
            'if test -f exit-now && ! test -f replacement-pid; then\n'
            "  printf 'THRUSH-SHELL-EXIT\\r\\n' && touch shell-exit-issued\nfi\nexit 0\n"
        )
        shell.chmod(0o700)
        env = fixture_environment(args.endpoint, shell)
        log = root / "server.log"
        try:
            with server(root, shell, log, args.server_binary or binary.with_name("ThrushServer"), args.endpoint) as endpoint:
                shutil.copyfile(HERE / "reader-producer.py", work / "reader-producer.py")
                readers = ["bun", "thrush", "urlsession"]
                results = []
                for iteration in range(0 if args.recovery else 3):
                    for profile in ("paced16", "unpaced"):
                        for reader in readers[iteration:] + readers[:iteration]:
                            name = f"{profile}-{iteration+1}-{reader}"
                            results.append(exercise(binary, endpoint, work, name, reader, env, profile=profile))
                exits = [exercise(binary, endpoint, work, "exit-live", "bun", env, probe=True),
                         exercise(binary, endpoint, work, "exit-suspended", "bun", env, probe=True, suspend=True)]
                silent = exercise(binary, endpoint, work, "silent", "silent", env, profile="unpaced", suspend=True) if args.recovery else None
                source = read_json(root / "data" / "source.json")
        except BaseException:
            if log.exists():
                print(log.read_text()[-2000:], file=sys.stderr)
            raise
    report = {**source, "thrushHead": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
              "thrushWorktreeDirty": bool(subprocess.check_output(["git", "status", "--porcelain"])),
              "bun": subprocess.check_output(["bun", "--version"], text=True).strip(), "macOS": platform.mac_ver()[0],
              "grid": [80, 24], "sourceTargetMiBPerSecond": 16, "comparisons": results, "exits": exits}
    kind = "pty-recovery" if args.recovery else "pty-readers"
    if args.recovery:
        report["silent"] = silent
    path = report_path(kind, args.endpoint)
    path.write_text(json.dumps(report, indent=2) + "\n")
    if not all(e["shellPIDDead"] and e["replacementShellHasNewPID"] and not e["resumed"] for e in exits):
        raise RuntimeError(f"Could not establish natural exit and fresh attachment. See {path}")
    if args.recovery and not all(e["exitBeforeClose"] and e["closeCode"] == 1000 for e in exits):
        raise RuntimeError(f"Expected exit followed by a server close with code 1000. See {path}")
    if args.recovery and not exits[1].get("finalScreenMatchesExpected", False):
        raise RuntimeError(f"Saturated exit must replay the complete final screen before exit. See {path}")
    if args.recovery and not (exits[1]["missingBinaryBytes"] > 0 and not exits[1]["openAfterExit"]):
        raise RuntimeError(f"The exit case must exercise actual backpressure. See {path}")
    print(path)


if __name__ == "__main__":
    main()
