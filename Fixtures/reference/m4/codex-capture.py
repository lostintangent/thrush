"""Record the real Codex TUI with a live provider or the published offline response."""
import argparse
import base64
import errno
import json
import os
from pathlib import Path
import pty
import re
import select
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT.parent / "m2"))
sys.dont_write_bytecode = True
from capture import PROMPT, Session, encoded, window

from songbird_stream import MODEL, QUESTION, local_responses

COLUMNS, ROWS = 80, 16
VERSION = "codex-cli 0.166.0"
SAMPLE_THREAD_ID = b"00000000-0000-4000-8000-000000000000"
UUID_PATTERN = rb"[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}"


def replace_resume_id(events):
    """Remove the live thread ID, even when it straddles two consecutive PTY reads."""
    reads = [(event, base64.b64decode(event["bytes"], validate=True)) for event in events if "bytes" in event]
    stream = b"".join(data for _, data in reads)
    sanitized, count = re.subn(rb"(?<=codex resume )" + UUID_PATTERN, SAMPLE_THREAD_ID, stream)
    if count != 1 or re.findall(UUID_PATTERN, sanitized) != [SAMPLE_THREAD_ID]:
        raise ValueError("Expected exactly one thread identifier, in the exit resume command")
    offset = 0
    for event, data in reads:
        event["bytes"] = encoded(sanitized[offset:offset + len(data)])
        offset += len(data)
    return {"field":"exit resume command thread ID", "replacement":SAMPLE_THREAD_ID.decode(), "count":count}


def mark_split_paint(events, columns, rows):
    """Ask the independent parser which real read first leaves a repaint pending."""
    reads = [e for e in events if "bytes" in e]
    requests = [{"resize":{"columns":columns, "rows":rows}}] + [{"bytes":e["bytes"]} for e in reads]
    result = subprocess.run(
        ["bun", ROOT / "codex-reference.mjs"], text=True, capture_output=True, check=True,
        input="".join(json.dumps(r) + "\n" for r in requests), env={"PATH":os.environ["PATH"]})
    states = [json.loads(line) for line in result.stdout.splitlines()][1:]
    if len(states) != len(reads):
        raise ValueError("Missing reference responses during checkpoint verification")
    pending = False
    marked = False
    for event, state in zip(reads, states):
        if state["reply"] != event.get("observedReply", ""):
            raise ValueError("The live terminal reply disagrees with the replay")
        if marked or state["synchronizedOutput"] == pending:
            continue
        if event.get("checkpoint") and not event["name"].startswith("Synchronized Codex repaint "):
            raise ValueError("The first split repaint overlaps another named checkpoint")
        pending = state["synchronizedOutput"]
        event.update(name="Synchronized Codex repaint " + ("pending" if pending else "complete"), checkpoint=True)
        marked = not pending
    if not marked:
        raise ValueError("The live capture did not include a repaint split across reads")

class CodexSession(Session):
    """Capture the real interactive shell while feeding its PTY reads to the pinned reference."""
    def __init__(self, home, workspace, columns, rows):
        self.start = time.monotonic_ns()
        self.events = []
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            window(0, columns, rows)
            os.chdir(workspace)
            env = dict(HOME=str(home), PATH=f"{home}/bin:/usr/bin:/bin", TERM="xterm-256color",
                       LC_ALL="en_US.UTF-8", PS1=PROMPT.decode(), HISTFILE="/dev/null",
                       INPUTRC="/dev/null", BASH_SILENCE_DEPRECATION_WARNING="1")
            os.execve("/bin/bash", ["bash", "--noprofile", "--norc", "-i"], env)
        self.reference = subprocess.Popen(
            ["bun", ROOT / "codex-reference.mjs"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
            env={"PATH":os.environ["PATH"], "HOME":str(home)})
        self.exchange({"resize":{"columns":columns, "rows":rows}})

    def state(self):
        self.reference.stdin.write('{"inspect":true}\n')
        self.reference.stdin.flush()
        return json.loads(self.reference.stdout.readline())

    def inspect(self):
        return self.state()["visible"]

    def read_one(self, name, timeout):
        if not select.select([self.fd], [], [], timeout)[0]:
            return False
        try:
            data = os.read(self.fd, 8192)
        except OSError as error:
            if error.errno == errno.EIO:
                raise RuntimeError("The PTY closed before the last checkpoint") from error
            raise
        if not data:
            raise RuntimeError("Early end of Codex PTY")
        self.record(name, bytes=encoded(data))
        reply = self.exchange({"bytes":encoded(data)})
        if reply:
            self.write(reply)
            self.events[-1]["observedReply"] = encoded(reply)
            self.events[-1]["replyOffsetMicroseconds"] = (time.monotonic_ns() - self.start) // 1000
        return True

    def key(self, name, value, data, modifiers=()):
        action = {"kind":"key", "value":value}
        if modifiers:
            action["modifiers"] = list(modifiers)
        self.record(name, input=encoded(data), action=action)
        self.write(data)

    def text(self, name, value):
        data = value.encode()
        self.record(name, input=encoded(data), action={"kind":"text", "value":value})
        self.write(data)

    def observe(self, checkpoint, condition, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.read_one("Codex paints", 0.12)
            state = self.state()
            if not state["synchronizedOutput"] and condition(state["visible"]):
                self.checkpoint(checkpoint)
                return
        raise RuntimeError(f"Timed out waiting for {checkpoint!r}; the previous capture is preserved")

    def answer(self, published=False):
        """Mark real completed display updates as the answer streams, preserving every read."""
        deadline = time.monotonic() + 150
        working = False
        first_lines = False
        while time.monotonic() < deadline:
            if not self.read_one("Codex paints", 0.2):
                continue
            event = self.events[-1]
            # The CLI brackets paints with DEC synchronized updates. Only mark a finished paint.
            if not base64.b64decode(event["bytes"]).endswith(b"\x1b[?2026l"):
                continue
            rows = self.inspect()
            text = "\n".join(rows).casefold()
            if not working and "esc to interrupt" in text:
                event.update(name="Codex working", checkpoint=True)
                working = True
            third = "3. eurasian blue tit" in text if published else re.search(r"\b3[.)]\s+", text)
            if (working and not first_lines and not event.get("checkpoint") and third
                    and re.search(r"\b1[.)]\s+song thrush", text)):
                event.update(name="First three songbirds streamed", checkpoint=True)
                first_lines = True
            # The working label can disappear while content is still streaming. Codex paints
            # its elapsed-time summary after consuming response.completed.
            if re.search(r"\b12[.)]\s+european robin", text) and "worked for " in text:
                if not (working and first_lines):
                    raise ValueError("Missing working indicator or incremental answer before the completed response")
                self.checkpoint("Received Codex answer")
                return
        raise RuntimeError("No complete answer; keep the checked-in capture")

def capture(binary, login, columns=COLUMNS, rows=ROWS, local_url=None):
    version = subprocess.check_output([binary, "--version"], text=True).strip()
    if version != VERSION:
        raise ValueError(f"Expected {VERSION}, found {version}")
    if local_url is None and not login.is_file():
        raise ValueError("The live recorder requires an existing authorized Codex ChatGPT login")
    with tempfile.TemporaryDirectory(prefix="thrush-codex-", dir=Path("/tmp").resolve()) as tmp:
        home = Path(tmp) / "home"
        workspace = home / "workspace"
        workspace.mkdir(parents=True)
        subprocess.run(["git", "init", "-q", workspace], check=True)
        (home / "bin").mkdir()
        (home / "bin/codex-real").symlink_to(binary)
        executable = home / "bin/codex"
        command = 'codex-real --no-daemon -s read-only -a never "$@"'
        if local_url:
            # The CLI starts a local worktree helper on a second ephemeral port.
            policy = '(version 1) (allow default) (deny network-outbound) (allow network-outbound (remote tcp "localhost:*"))'
            command = f"/usr/bin/sandbox-exec -p '{policy}' " + command
        executable.write_text("#!/bin/sh\nexec " + command + "\n")
        executable.chmod(0o755)
        state = home / ".codex"
        state.mkdir()
        provider = ""
        if local_url:
            provider = ('model_provider = "thrush"\n[model_providers.thrush]\nname = "Thrush local fixture"\n'
                        f'base_url = "{local_url}"\nwire_api = "responses"\nrequires_openai_auth = false\n')
        (state / "config.toml").write_text(
            f'model = "{MODEL}"\ncheck_for_update_on_startup = false\nweb_search = "disabled"\n'
            f'{provider}[projects.{json.dumps(str(workspace))}]\ntrust_level = "trusted"\n[analytics]\nenabled = false\n')
        # Only the official CLI opens the existing login. No credentials are serialized by the recorder.
        if local_url is None:
            (state / "auth.json").symlink_to(login)
        session = CodexSession(home, workspace, columns, rows)
        try:
            session.observe("Shell prompt", lambda rows: PROMPT.decode() in rows)
            session.text("Launch Codex", "codex\r")
            session.observe("Codex ready", lambda rows: any("GPT-6.1-Sol" in r for r in rows)
                            and any("Ask Codex" in r for r in rows) and any("OpenAI Codex" in r for r in rows))
            session.text("Enter prompt", QUESTION)
            session.observe("Entered Codex prompt", lambda rows: QUESTION in " ".join(" ".join(rows).split()))
            session.key("Submit", "enter", b"\r")
            session.answer(published=local_url is not None)
            session.key("Codex transcript shortcut", "t", b"\x14", ["control"])
            session.key("Earlier transcript page", "pageUp", b"\x1b[5~")
            session.observe("Earlier transcript page", lambda rows: any("1. Song thrush" in r for r in rows)
                            and any("Back to bottom" in r for r in rows))
            session.key("Later transcript page", "pageDown", b"\x1b[6~")
            session.observe("Later transcript page", lambda rows: any("12. European robin" in r for r in rows)
                            and not any("Back to bottom" in r for r in rows))
            session.text("Enter quit command", "/quit")
            # Let the slash-command menu handle its normal keystrokes before Enter.
            deadline = time.monotonic() + 5
            while not any("/quit" in r for r in session.inspect()):
                if time.monotonic() > deadline:
                    raise RuntimeError("Codex did not display the quit command")
                session.read_one("Codex paints", 0.1)
            session.key("Submit", "enter", b"\r")
            session.observe("Returned to shell", lambda rows: PROMPT.decode() in rows)
        finally:
            session.close()
        sanitization = replace_resume_id(session.events)
        mark_split_paint(session.events, columns, rows)
        stream = b"".join(base64.b64decode(e.get("bytes", "")) for e in session.events)
        private_patterns = [b"/Users/", b"/private/", b"/tmp/thrush", rb"[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}",
                            rb"sk-[\w-]{12,}|Bearer |refresh_token|access_token|id_token"]
        if local_url:
            private_patterns += [rb"127\.0\.0\.1:[0-9]+", b"MCP startup incomplete"]
        if any(re.search(pattern, stream) for pattern in private_patterns):
            raise ValueError("The output includes private identifiers; keep the previous public recording")
        metadata = dict(name="codex-session", term="xterm-256color", shell="/bin/bash --noprofile --norc -i",
                        application=version, provider=dict(kind="live", name="OpenAI",
                        access="ChatGPT login through the Codex CLI", model=MODEL),
                        prompt=QUESTION, columns=columns, rows=rows, sanitization=sanitization)
        if local_url:
            metadata["provider"] = dict(kind="local-recorded-response", source="Fixtures/replays/codex-session.json",
                                        model=MODEL, transport="loopback Responses SSE", authentication="none")
        compact = lambda obj: json.dumps(obj, ensure_ascii=False, separators=(",",":"))
        text = compact(metadata)[:-1] + ',\n"events":[\n' + ',\n'.join(map(compact, session.events)) + '\n]}\n'
        return text

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex-bin", required=True, type=Path, help="native 0.166.0 Codex executable")
    parser.add_argument("--login-file", default=Path.home()/".codex/auth.json", type=Path)
    parser.add_argument("--output", default=ROOT/"codex-session.capture.json", type=Path)
    parser.add_argument("--columns", default=COLUMNS, type=int)
    parser.add_argument("--rows", default=ROWS, type=int)
    parser.add_argument("--local-response", action="store_true", help="stream the published answer using a loopback-only local provider")
    args = parser.parse_args()
    if (args.local_response or (args.columns, args.rows) != (COLUMNS, ROWS)) and args.output.resolve() == (ROOT / "codex-session.capture.json"):
        parser.error("Give a separate --output for a local response or a different PTY size")
    if args.local_response:
        with local_responses(QUESTION, MODEL) as url:
            text = capture(args.codex_bin.resolve(), None, args.columns, args.rows, url)
    else:
        text = capture(args.codex_bin.resolve(), args.login_file.resolve(), args.columns, args.rows)
    args.output.write_text(text)
