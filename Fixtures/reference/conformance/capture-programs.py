"""Records real programs in disposable PTYs for the conformance harness.

Each scenario drives one program the way a person would, in a fresh home directory with an
xterm-256color terminal environment. The pinned reference reads every byte as it arrives and answers
the program's queries, so a recording follows the replies a terminal would send. Recordings land in
programs/<name>.capture.json, and harness.mjs replays them through the reference and ThrushCore.

    python3 Fixtures/reference/conformance/capture-programs.py [--only NAME ...]

Process monitors only list the recorder's own processes, the account name in their user columns gives
way to a stand-in of the same width, git uses a fixed identity and clock, and rg links to a fixed host
and folder, so nothing about the recording machine beyond its load and memory ends up in a capture.
"""
import argparse
import base64
import errno
import fcntl
import http.server
import json
import os
from pathlib import Path
import pty
import pwd
import select
import shutil
import signal
import struct
import subprocess
import tempfile
import termios
import threading
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
PROMPT = "❯".encode()
ZSHRC = r"""
PROMPT='%F{blue}%1~%f %F{green}❯%f '
RPROMPT='%F{8}main%f'
HISTFILE=~/.zsh_history HISTSIZE=100 SAVEHIST=100
autoload -Uz compinit && compinit -u -d ~/.zcompdump
zstyle ':completion:*' menu select
zstyle ':completion:*' list-colors ''
# Window and tab titles, the way popular zsh frameworks set them.
precmd() { print -Pn '\e]2;%~\a\e]1;%1~\a' }
preexec() { print -Pn '\e]2;'; print -rn -- "$1"; print -n '\a' }
"""
VIMRC = """set nocompatible nomodeline noswapfile nobackup noundofile viminfo=
set encoding=utf-8 belloff=all mouse= ttimeout ttimeoutlen=10 shortmess+=I
syntax on
set number cursorline laststatus=2 ruler showcmd
"""
TMUX = """set -g status-right "thrush"
set -g default-command "/bin/zsh"
set -g escape-time 10
set -g history-limit 200
"""
SCREENRC = """startup_message off
shell /bin/zsh
"""
LAZYGIT = """update:
  method: never
disableStartupPopups: true
gui:
  showRandomTip: false
"""
# rg links each file to its real path on its host, so the decorations project sits at a fixed path
# and rg asks a script for the host.
PROJECT = Path("/tmp/thrush-decorations")
RIPGREPRC = """--hyperlink-format=default
--hostname-bin={home}/.ripgrep-host
"""
# Vim leaves underline styles and colors off for xterm-256color, so configurations turn them on.
SPELL = r"""set spell spelllang=en_us
let &t_Cs = "\e[4:3m"
let &t_Ce = "\e[4:0m"
let &t_Us = "\e[4:2m"
let &t_ds = "\e[4:4m"
let &t_Ds = "\e[4:5m"
let &t_AU = "\e[58:5:%dm"
hi SpellBad cterm=undercurl ctermul=196
hi SpellCap cterm=underdouble ctermul=33
hi SpellRare cterm=underdotted ctermul=129
hi SpellLocal cterm=underdashed ctermul=34
"""
TRUE_COLOR_SPELL = r"""let &t_8u = "\e[58:2::%lu:%lu:%lum"
set termguicolors
hi SpellBad gui=undercurl guisp=#e5534b
hi SpellCap gui=underdouble guisp=#539bf5
hi SpellRare gui=underdotted guisp=#b083f0
hi SpellLocal gui=underdashed guisp=#57ab5a
"""
SPELLING = """# Spelling

A termnial draws a curly line under each mispelled word.
it marks a sentence that starts in lowercase, and the colour of a word from another region.
Wide text keeps its line: 界面 recieve ✓ 🙂 seperate.
"""


# Editors check a Swift file with sourcekit-lsp, and copy over the terminal the way remote sessions do.
SHAPES = """struct Circle {
    var radius: Double

    var area: Double {
        Double.pi * radius * radius
    }
}

let circle = Circle(radius: 2)
let label: Int = "Area \\(circle.area)"
print(circle.diameter)
"""
NEOVIM = """vim.o.swapfile = false
vim.o.shada = ''
vim.o.number = true
vim.o.cursorline = true
vim.o.signcolumn = 'yes'
vim.o.winborder = 'rounded'
vim.o.completeopt = 'menuone,noselect,popup'
vim.g.clipboard = 'osc52'
vim.diagnostic.config({ virtual_text = true })
vim.lsp.config('sourcekit', { cmd = { 'sourcekit-lsp' }, filetypes = { 'swift' }, root_markers = { 'Package.swift' } })
vim.lsp.enable('sourcekit')
vim.api.nvim_create_autocmd('LspAttach', {
  callback = function(event)
    vim.lsp.completion.enable(true, event.data.client_id, event.buf, { autotrigger = true })
  end,
})
"""
HELIX = """[editor]
clipboard-provider = "termcode"
end-of-line-diagnostics = "hint"

[editor.inline-diagnostics]
cursor-line = "warning"
"""
# btop names its CPU, leaves out temperatures, the GPU, disks and the battery, and its filter matches only
# its own command line.
BTOP = """update_ms = 1000
custom_cpu_name = "Thrush"
check_temp = False
show_gpu_info = "Off"
show_disks = False
show_battery = False
"""
# Agents work in a project at a fixed path and talk to a stand-in model, so a capture needs no account and
# their banners match on every Mac.
AGENT = Path("/tmp/thrush-agent")
API_KEY = "sk-ant-thrush-capture-0000"
MODEL = "claude-sonnet-4-5"
NOTES = "A terminal for macOS and iOS."
EDITED_NOTES = "A fast, faithful terminal for macOS and iOS."
SUMMARY = """## Updated the notes

The notes now say what Thrush is for:

- **Faithful**: every cell matches what the program meant
- *Fast*: the core outruns the reference
- `TerminalView` is the whole public API

| Platform | View |
| --- | --- |
| macOS | `TerminalView` |
| iOS | `TerminalView` |

```swift
let view = TerminalView(socket: socket)
```

Wide text stays aligned: 界面 ✓ 🙂
"""


def encoded(data):
    return base64.b64encode(data).decode("ascii")


def anonymous(events):
    """Swaps the account name, whole or cut short by a column, for a stand-in of the same width."""
    user = pwd.getpwuid(os.getuid()).pw_name.encode()
    stand_in = b"thrush".ljust(len(user))
    output = [event for event in events if "bytes" in event]
    stream = b"".join(base64.b64decode(event["bytes"]) for event in output)
    for length in range(len(user), 3, -1):
        stream = stream.replace(user[:length], stand_in[:length])
    for event in output:
        size = len(base64.b64decode(event["bytes"]))
        event["bytes"], stream = encoded(stream[:size]), stream[size:]


def window(fd, columns, rows):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))


class Session:
    """One program in a PTY, with every read, key and window change recorded in order."""

    def __init__(self, home, argv, env, columns=80, rows=24):
        self.events = []
        self.start = time.monotonic_ns()
        self.application_cursor_keys = False
        self.replies = subprocess.Popen(
            ["bun", HERE.parent / "replies.mjs"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.exchange({"resize": {"columns": columns, "rows": rows}})
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            window(0, columns, rows)
            os.chdir(home)
            os.execvpe(argv[0], argv, env)

    def exchange(self, event):
        self.replies.stdin.write(json.dumps(event) + "\n")
        self.replies.stdin.flush()
        response = self.replies.stdout.readline()
        if not response:
            raise RuntimeError("The reference exited during the capture")
        response = json.loads(response)
        self.application_cursor_keys = response["applicationCursorKeys"]
        return base64.b64decode(response["reply"], validate=True)

    def record(self, name, **fields):
        self.events.append(dict(name=name, offsetMicroseconds=(time.monotonic_ns() - self.start) // 1000, **fields))

    def send(self, data):
        remaining = memoryview(data)
        while remaining:
            remaining = remaining[os.write(self.fd, remaining):]

    def read(self, name, until=None, seconds=None, quiet=0.4, timeout=30):
        """Records output until `until` appears and output pauses, for `seconds`, or until output pauses."""
        output = b""
        begun = last = time.monotonic()
        while True:
            now = time.monotonic()
            if seconds is not None:
                if now - begun >= seconds: break
            elif (until is None or until in output) and now - last >= quiet:
                break
            if now - begun > timeout:
                if until is not None and until not in output:
                    raise TimeoutError(f"{name}: never saw {until!r} in {output[-400:]!r}")
                break
            if not select.select([self.fd], [], [], 0.05)[0]: continue
            try:
                data = os.read(self.fd, 65536)
            except OSError as error:
                if error.errno == errno.EIO: break
                raise
            if not data: break
            last = time.monotonic()
            self.record(name, bytes=encoded(data))
            reply = self.exchange({"bytes": encoded(data)})
            if reply:
                self.events[-1]["reply"] = encoded(reply)
                self.send(reply)
            output += data
        return output

    def type(self, name, data, **reading):
        """Sends keys and records what the program draws in response."""
        data = data.encode() if isinstance(data, str) else data
        self.record(name, input=encoded(data))
        self.send(data)
        return self.read(name, **reading)

    def key(self, name, key, count=1, **reading):
        """Sends a named key, using the cursor key mode the program has selected."""
        prefix = b"\x1bO" if self.application_cursor_keys else b"\x1b["
        arrows = dict(up=b"A", down=b"B", right=b"C", left=b"D", home=b"H", end=b"F")
        keys = dict(f1=b"\x1bOP", f2=b"\x1bOQ", f3=b"\x1bOR", f4=b"\x1bOS", f5=b"\x1b[15~", f6=b"\x1b[17~",
                    f10=b"\x1b[21~", pageup=b"\x1b[5~", pagedown=b"\x1b[6~", escape=b"\x1b", tab=b"\t",
                    enter=b"\r", backspace=b"\x7f", delete=b"\x1b[3~")
        data = prefix + arrows[key] if key in arrows else keys[key]
        return self.type(name, data * count, **reading)

    def resize(self, columns, rows, **reading):
        name = f"Resize to {columns}×{rows}"
        self.record(name, resize=dict(columns=columns, rows=rows))
        assert not self.exchange({"resize": {"columns": columns, "rows": rows}})
        window(self.fd, columns, rows)
        return self.read(name, **reading)

    def checkpoint(self, name):
        self.record(name, checkpoint=True)

    def close(self):
        os.close(self.fd)
        for sig in (signal.SIGHUP, signal.SIGKILL):
            # A group whose leader already exited refuses signals on macOS, which is as good as done.
            try:
                os.killpg(self.pid, sig)
            except (ProcessLookupError, PermissionError):
                pass
            for _ in range(50):
                if os.waitpid(self.pid, os.WNOHANG)[0]: break
                time.sleep(0.1)
            else:
                continue
            break
        self.replies.stdin.close()
        self.replies.wait()


class Model:
    """A stand-in for the Anthropic Messages API that streams one exchange the same way every time.

    Asked with tools, the agent reads the notes, edits them once the person approves, then sums up in Markdown.
    Requests without those tools, such as naming the session, get a short answer.
    """

    def __init__(self):
        model = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *arguments):
                pass

            def do_GET(self):
                listing = dict(type="model", id=MODEL, display_name="Claude Sonnet 4.5", created_at="2025-09-29T00:00:00Z")
                model.send(self, dict(data=[listing], has_more=False, first_id=MODEL, last_id=MODEL))

            def do_POST(self):
                request = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
                if self.path.startswith("/v1/messages/count_tokens"):
                    model.send(self, dict(input_tokens=2048))
                elif self.path.startswith("/v1/messages"):
                    model.answer(self, request)
                else:
                    self.send_error(404)

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"

    def close(self):
        self.server.shutdown()
        self.server.server_close()

    @staticmethod
    def send(handler, value):
        body = json.dumps(value).encode()
        handler.send_response(200)
        handler.send_header("Content-Type", "application/json")
        handler.send_header("Content-Length", str(len(body)))
        handler.end_headers()
        handler.wfile.write(body)

    @staticmethod
    def blocks(request):
        """The answer's content: text, or text then a tool call."""
        tools = {tool.get("name"): tool for tool in request.get("tools") or []}
        read = next((tools[name] for name in ("Read", "view") if name in tools), None)
        edit = next((tools[name] for name in ("Edit", "edit") if name in tools), None)
        if not (read and edit):
            return [dict(type="text", text="Tighten the notes")]
        results = sum(block.get("type") == "tool_result" for message in request.get("messages", [])
                      if isinstance(message.get("content"), list) for block in message["content"])

        def call(tool, **values):
            names = dict(path=("file_path", "path"), old=("old_string", "old_str"), new=("new_string", "new_str"))
            properties = tool.get("input_schema", {}).get("properties", {})
            arguments = {key: value for name, value in values.items() for key in names[name] if key in properties}
            return dict(type="tool_use", id=f"toolu_thrush_{results + 1}", name=tool["name"], input=arguments)

        notes = str(AGENT / "notes.md")
        if results == 0:
            return [dict(type="text", text="I'll read the notes first."), call(read, path=notes)]
        if results == 1:
            return [dict(type="text", text="Now I'll tighten the description."),
                    call(edit, path=notes, old=NOTES, new=EDITED_NOTES)]
        return [dict(type="text", text=SUMMARY)]

    def answer(self, handler, request):
        blocks = self.blocks(request)
        stop = "tool_use" if blocks[-1]["type"] == "tool_use" else "end_turn"
        message = dict(id="msg_thrush", type="message", role="assistant", model=request.get("model", MODEL),
                       stop_sequence=None, usage=dict(input_tokens=2048, output_tokens=96))
        if not request.get("stream"):
            return self.send(handler, dict(message, content=blocks, stop_reason=stop))
        handler.send_response(200)
        handler.send_header("Content-Type", "text/event-stream")
        handler.send_header("Cache-Control", "no-cache")
        handler.end_headers()

        def event(kind, **fields):
            handler.wfile.write(f"event: {kind}\ndata: {json.dumps(dict(type=kind, **fields))}\n\n".encode())
            handler.wfile.flush()

        event("message_start", message=dict(message, content=[], stop_reason=None))
        for index, block in enumerate(blocks):
            if block["type"] == "text":
                event("content_block_start", index=index, content_block=dict(type="text", text=""))
                words = block["text"].split(" ")
                for start in range(0, len(words), 4):
                    time.sleep(0.03)
                    piece = " ".join(words[start:start + 4]) + (" " if start + 4 < len(words) else "")
                    event("content_block_delta", index=index, delta=dict(type="text_delta", text=piece))
            else:
                event("content_block_start", index=index, content_block=dict(block, input={}))
                event("content_block_delta", index=index,
                      delta=dict(type="input_json_delta", partial_json=json.dumps(block["input"])))
            event("content_block_stop", index=index)
        event("message_delta", delta=dict(stop_reason=stop, stop_sequence=None), usage=dict(output_tokens=96))
        event("message_stop")


def environment(home):
    return {
        "HOME": str(home), "PATH": f"{home}/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "TERM": "xterm-256color", "COLORTERM": "truecolor", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
        "USER": "thrush", "LOGNAME": "thrush", "SHELL": "/bin/zsh", "ZDOTDIR": str(home),
        "XDG_CONFIG_HOME": str(home / ".config"), "TMUX_TMPDIR": str(home), "SCREENDIR": str(home / ".screen"),
        "SCREENRC": str(home / ".screenrc"), "GIT_CONFIG_GLOBAL": str(home / ".gitconfig"),
        "GIT_CONFIG_NOSYSTEM": "1", "HOMEBREW_NO_AUTO_UPDATE": "1", "PYTHON_HISTORY": str(home / ".python_history"),
    }


def prepare(home):
    """A small, fixed home: shell and program settings, a few files and a git repository with history."""
    (home / ".zshrc").write_text(ZSHRC)
    (home / ".vimrc").write_text(VIMRC)
    (home / ".tmux.conf").write_text(TMUX)
    (home / ".screenrc").write_text(SCREENRC)
    (home / ".screen").mkdir(mode=0o700)
    (home / ".config/lazygit").mkdir(parents=True)
    (home / ".config/lazygit/config.yml").write_text(LAZYGIT)
    (home / ".gitconfig").write_text("[user]\n\tname = Thrush\n\temail = thrush@example.com\n"
                                     "[init]\n\tdefaultBranch = main\n[color]\n\tui = auto\n")
    (home / "projects").mkdir()
    (home / "projects/Package.swift").write_text("// swift-tools-version: 6.2\n")
    (home / "notes.md").write_text("# Notes\n\nA terminal for macOS and iOS.\n")
    (home / "build.sh").write_text("#!/bin/sh\necho building\n")
    (home / "build.sh").chmod(0o755)
    (home / "notes link").symlink_to("notes.md")
    lines = []
    for number in range(1, 241):
        line = f"{number:3}  The quick brown fox jumps over the lazy dog."
        if number % 7 == 0: line += " " + "This line runs well past the width of the window. " * 3
        if number % 11 == 0: line = f"\x1b[1;34m{line}\x1b[0m"
        if number % 13 == 0: line += "\t界面 e\u0301 ✓"
        if number % 17 == 0: line += " needle"
        lines.append(line)
    (home / "story.txt").write_text("\n".join(lines) + "\n")
    shutil.copyfile(ROOT / "Sources/ThrushCore/Screen.swift", home / "Screen.swift")
    repository(home / "repo")


def repository(path):
    path.mkdir()
    clock = 1_790_000_000
    def git(*arguments):
        nonlocal clock
        clock += 3600
        stamp = f"@{clock} +0000"
        subprocess.run(["git", *arguments], cwd=path, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       env={**os.environ, "GIT_AUTHOR_NAME": "Thrush", "GIT_AUTHOR_EMAIL": "thrush@example.com",
                            "GIT_COMMITTER_NAME": "Thrush", "GIT_COMMITTER_EMAIL": "thrush@example.com",
                            "GIT_AUTHOR_DATE": stamp, "GIT_COMMITTER_DATE": stamp, "GIT_CONFIG_NOSYSTEM": "1",
                            "GIT_CONFIG_GLOBAL": "/dev/null"})
    git("init", "-q", "-b", "main")
    source = path / "Terminal.swift"
    body = ["struct Terminal {", "    var columns = 80", "    var rows = 24", "}"]
    for step in range(8):
        if step == 3:
            git("checkout", "-q", "-b", "wide-text")
        if step == 5:
            git("checkout", "-q", "main")
        if step in (3, 4):
            (path / "Wide.swift").write_text(f"let wide = \"界面\"  // Revision {step}\n")
        else:
            body.insert(-1, f"    var setting{step} = {step}  // Added in step {step}")
            source.write_text("\n".join(body) + "\n")
            (path / "README.md").write_text(f"# Terminal\n\nRevision {step}.\n")
        git("add", "-A")
        git("commit", "-q", "-m", f"Add setting {step}\n\nExplains why setting {step} exists.")
    git("merge", "-q", "--no-ff", "-m", "Merge wide text", "wide-text")
    source.write_text(source.read_text().replace("var rows = 24", "var rows = 40") + "// Uncommitted\n")


def shell(session, name="Shell prompt"):
    session.read(name, until=PROMPT)


def run(session, command, name=None, until=PROMPT, **reading):
    return session.type(name or f"Run {command}", command + "\r", until=until, **reading)


def zsh_clear(session, home):
    prompt = b"thrush$ "
    session.read("Shell prompt", until=prompt)
    session.checkpoint("Fresh prompt")
    for name, command, expected in [("System", "clear", b"\x1b[3J\x1b[H\x1b[2J"),
                                    ("Homebrew", "clear-alt", b"\x1b[H\x1b[2J\x1b[3J")]:
        history = session.type(f"Seed history before {name.lower()} clear", "seq 1 38\r", until=prompt)
        assert b"".join(f"{i}\r\n".encode() for i in range(1, 39)) in history
        session.checkpoint(name + " populated history")
        session.type("Type " + name.lower() + " clear", command)
        session.checkpoint(name + " clear edited command")
        start = len(session.events)
        output = session.type("Run " + name.lower() + " clear", "\r", until=prompt)
        if output.count(expected) != 1 or prompt not in output.split(expected)[1]:
            raise RuntimeError(f"{name} clear did not emit {expected.hex()} followed by the prompt")
        # Keep PTY reads intact, including when the CSI sequence spans several of them.
        clear_end = output.index(expected) + len(expected)
        read_end = 0
        for event in session.events[start:]:
            read_end += len(base64.b64decode(event.get("bytes", "")))
            if read_end == clear_end:
                event.update(name=name + " cleared screen", checkpoint=True)
                break
        else:
            raise RuntimeError(f"{name} clear and zsh's redraw shared a PTY read; "
                               "recapture to observe the cleared screen before the prompt")
        session.checkpoint(name + " cleared prompt")


def zsh(session, home):
    shell(session)
    session.checkpoint("Fresh prompt")
    session.type("Type a command", "echo hello wrld")
    session.key("Move left", "left", 3)
    session.type("Insert a letter", "o")
    session.type("Line start", "\x01")
    session.type("Line end", "\x05")
    session.key("Delete backward", "backspace")
    session.type("Retype", "d")
    run(session, "", "Run echo")
    run(session, "ls -G")
    run(session, "ls -lnG")
    session.checkpoint("Colored listings")
    session.type("Complete a directory", "cd pro\t")
    session.type("Clear the line", "\x15")
    session.type("List completions", "ls \t")
    session.type("Enter menu selection", "\t")
    session.type("Next match", "\t")
    session.checkpoint("Menu selection")
    session.type("Leave the menu", "\x03")
    session.type("Cancel", "\x03", until=PROMPT)
    session.type("Long line", "echo " + "a command line long enough to wrap across the window edge " * 2)
    session.type("Line start across the wrap", "\x01")
    session.type("Line end", "\x05")
    session.checkpoint("Wrapped command line")
    session.type("Cancel", "\x03", until=PROMPT)
    session.key("Previous command", "up")
    session.key("Older command", "up")
    session.type("Cancel", "\x03", until=PROMPT)
    session.type("Search history", "\x12hel")
    session.checkpoint("History search")
    session.type("Cancel search", "\x07")
    session.type("Cancel", "\x03", until=PROMPT)
    session.resize(60, 20)
    session.resize(80, 24)
    session.type("Clear the screen", "\x0c", until=PROMPT)
    session.checkpoint("Cleared")
    session.type("Exit", "exit\r")


def bash(session, home):
    shell(session)
    session.type("Type a command", "echo hello wrld")
    session.key("Move left", "left", 3)
    session.type("Insert a letter", "o")
    session.type("Line start", "\x01")
    session.key("Delete forward", "delete", 5)
    session.type("Reinsert", "echo ")
    session.type("Line end", "\x05")
    run(session, "", "Run echo")
    session.type("Complete a path", "ls /usr/\t\t")
    session.checkpoint("Completion list")
    session.type("Cancel", "\x03", until=PROMPT)
    session.type("Long line", "echo " + "a long command line that wraps past the edge of the window " * 2)
    session.type("Line start across the wrap", "\x01")
    session.type("Forward a word", "\x1bf\x1bf")
    session.type("Delete forward", "\x04\x04\x04")
    session.type("Kill to the end", "\x0b")
    session.checkpoint("Edited wrapped line")
    run(session, "", "Run the edit")
    session.key("Previous command", "up")
    session.type("Cancel", "\x03", until=PROMPT)
    run(session, "printf '\\e[1mbold\\e[0m \\e[3mitalic\\e[0m \\e[4munderline\\e[0m \\e[31mred\\e[0m\\n'")
    session.type("Clear the screen", "\x0c", until=PROMPT)
    session.type("Exit", "exit\r")


def pager(session, home):
    shell(session)
    session.type("Open less", "less -R story.txt\r", until=b"story.txt")
    session.checkpoint("First page")
    session.type("Next page", " ")
    session.type("Previous page", "b")
    session.type("Down three lines", "jjj")
    session.type("Up three lines", "kkk")
    session.checkpoint("Scrolled by line")
    session.type("Search", "/needle\r")
    session.type("Next match", "n")
    session.checkpoint("Search highlights")
    session.type("Chop long lines", "-S", until=b"Chop")
    session.type("Scroll right", "\x1b)")
    session.type("End", "G")
    session.resize(60, 18)
    session.type("Start", "g")
    session.resize(80, 24)
    session.type("Quit", "q", until=PROMPT)
    session.type("Open the manual", "man ls\r", until=b"NAME")
    session.checkpoint("Manual page")
    session.type("Next page", " ")
    session.type("Search", "/-l\r")
    session.type("Quit", "q", until=PROMPT)
    session.checkpoint("Back at the prompt")
    session.type("Exit", "exit\r")


def git(session, home):
    shell(session)
    run(session, "cd repo")
    run(session, "git status")
    session.type("Log graph", "git log --graph --decorate --stat\r")
    session.checkpoint("Log in the pager")
    session.type("Next page", " ")
    session.type("Quit", "q", until=PROMPT)
    session.type("Diff", "git diff\r", until=PROMPT)
    session.checkpoint("Colored diff")
    run(session, "git log --oneline --graph --all")
    run(session, "git clone --progress --no-local . ../copy")
    session.checkpoint("Clone progress")
    session.type("Exit", "exit\r")


def editor(session, home):
    shell(session)
    session.type("Open Vim", "vim Screen.swift\r", until=b"Screen.swift")
    session.checkpoint("Syntax colors")
    session.type("Page down", "\x06")
    session.type("Page up", "\x02")
    session.type("Half page down", "\x04")
    session.type("Scroll a line", "\x05\x05\x19")
    session.checkpoint("Scrolled")
    session.type("Vertical split", ":vsplit\r")
    session.type("Horizontal split", ":split\r")
    session.type("Next window", "\x17w")
    session.checkpoint("Split windows")
    session.type("Search", "/struct\r")
    session.type("Open a line", "oThe terminal 界 e\u0301\x1b")
    session.type("Undo", "u")
    session.resize(100, 30)
    session.checkpoint("Resized splits")
    session.type("Quit", ":qa!\r", until=PROMPT)
    session.type("Open pico", "nano notes.md\r", until=b"notes.md")
    session.type("Type", "\x0eA line typed in pico.")
    session.type("Cut a line", "\x0b")
    session.type("Paste it", "\x15")
    session.type("Search", "\x17terminal\r")
    session.checkpoint("Pico")
    session.type("Exit", "\x18")
    session.type("Discard", "n", until=PROMPT)
    session.type("Exit", "exit\r")


def monitors(session, home):
    shell(session)
    session.type("Open top", "top -s 1 -pid $$\r", until=b"PID")
    session.read("Top refreshes", seconds=2.5)
    session.checkpoint("top")
    session.resize(100, 30, seconds=1.5)
    session.type("Quit top", "q", until=PROMPT)
    session.type("Open htop", "htop -p $$\r", until=b"PID")
    session.read("htop refreshes", seconds=2.5)
    session.checkpoint("htop")
    session.key("Setup", "f2")
    session.checkpoint("htop setup")
    session.key("Back", "escape")
    session.type("Tree view", "t")
    session.key("Help", "f1")
    session.checkpoint("htop help")
    session.type("Back", "q")
    session.resize(80, 24, seconds=1.5)
    session.type("Quit htop", "q", until=PROMPT)
    session.type("Exit", "exit\r")


def multiplexers(session, home):
    shell(session)
    session.type("Open tmux", "tmux -L thrush -f ~/.tmux.conf new-session -s thrush\r", until=PROMPT)
    session.checkpoint("tmux")
    run(session, "ls -G")
    run(session, "seq 60")
    session.checkpoint("tmux scrolled")
    session.type("Split side by side", "\x02%", until=PROMPT)
    run(session, "seq 40")
    session.type("Split top and bottom", '\x02"', until=PROMPT)
    run(session, "echo 界面 e\u0301 ✓")
    session.checkpoint("tmux panes")
    session.type("Zoom", "\x02z")
    session.type("Unzoom", "\x02z")
    session.resize(100, 30)
    session.type("New window", "\x02c", until=PROMPT)
    session.type("Previous window", "\x02p")
    session.checkpoint("tmux after resize")
    session.type("Command prompt", "\x02:")
    session.type("Kill the server", "kill-server\r", until=PROMPT)
    session.resize(80, 24)
    session.type("Open screen", "screen -S thrush\r", until=PROMPT)
    run(session, "seq 40")
    session.type("Split", "\x01S")
    session.type("Focus the new region", "\x01\t")
    session.type("New window", "\x01c", until=PROMPT)
    run(session, "ls -G")
    session.checkpoint("screen regions")
    session.type("Command line", "\x01:")
    session.type("Quit screen", "quit\r", until=PROMPT)
    session.type("Exit", "exit\r")


def python(session, home):
    session.read("Python prompt", until=b">>> ")
    session.type("Define", "def greet(name):\r")
    session.type("Body", 'return f"hello {name}"\r')
    session.type("End the block", "\r", until=b">>> ")
    session.type("Call", 'greet("thrush")\r', until=b">>> ")
    session.type("Long result", "[n * n for n in range(40)]\r", until=b">>> ")
    session.type("Complete", "import o\t\t")
    session.checkpoint("Completions")
    session.type("Cancel", "\x03", until=b">>> ")
    session.key("Previous", "up")
    session.key("Older", "up")
    session.type("Cancel", "\x03", until=b">>> ")
    session.type("Error", "1 / 0\r", until=b">>> ")
    session.checkpoint("Traceback")
    session.type("Exit", "exit()\r")


def decorations(session, home):
    shell(session)
    run(session, f"cd {PROJECT}")
    run(session, "rg needle")
    session.checkpoint("Linked matches")
    run(session, "rg -i -m 2 terminal")
    session.checkpoint("Linked files")
    session.type("Open Vim with spell checking", "vim -S ~/spell.vim spelling.md\r", until=b"spelling.md")
    session.checkpoint("Spelling in 256 colors")
    session.type("True color", ":source ~/true-color-spell.vim\r")
    session.checkpoint("Spelling in true color")
    session.type("Quit", ":q\r", until=PROMPT)
    session.type("Exit", "exit\r")


def lazygit(session, home):
    session.read("Start", until=b"Commits", timeout=60)
    session.read("Settle", seconds=1)
    session.checkpoint("Status")
    session.type("Files", "2")
    session.type("Branches", "3")
    session.type("Commits", "4")
    session.key("Down", "down", 2)
    session.key("Open commit", "enter")
    session.checkpoint("Commit files")
    session.key("Back", "escape")
    session.type("Keybindings", "?")
    session.checkpoint("Keybindings")
    session.key("Close", "escape")
    session.resize(100, 30, seconds=1)
    session.type("Quit", "q")


def neovim(session, home):
    shell(session)
    run(session, "cd shapes")
    session.type("Open Neovim", "nvim Shapes.swift\r", until=b"Cannot convert", timeout=90)
    session.checkpoint("Diagnostics")
    session.type("Find the area", "/area\r")
    session.type("Hover", "K", until=b"Double")
    session.checkpoint("Hover")
    session.type("Close the hover", "jk")
    session.type("Last line", "G")
    session.type("Complete a member", "ocircle.", until=b"radius")
    session.checkpoint("Completion")
    session.type("Choose", "\x0e")
    session.key("Leave insert mode", "escape")
    session.type("Undo", "u")
    session.type("Next diagnostic", "gg]d")
    session.type("Show the diagnostic", "\x17d", until=b"Cannot")
    session.checkpoint("Diagnostic float")
    session.type("Close it", "jk")
    session.type("Copy two lines", 'ggVj"+y')
    session.checkpoint("Copied")
    session.resize(100, 30)
    session.checkpoint("Resized")
    session.type("Quit", ":qa!\r", until=PROMPT)
    session.type("Exit", "exit\r")


def helix(session, home):
    shell(session)
    run(session, "cd shapes")
    session.type("Open Helix", "hx Shapes.swift\r", until=b"Cannot convert", timeout=90)
    session.checkpoint("Diagnostics")
    session.type("Find the area", "/area\r")
    session.type("Hover", " k", until=b"Double")
    session.checkpoint("Hover")
    session.key("Close the hover", "escape")
    session.type("Next diagnostic", "]d")
    session.checkpoint("Inline diagnostic")
    session.type("Copy the line", "x y")
    session.checkpoint("Copied")
    session.type("Command palette", " ?")
    session.checkpoint("Command palette")
    session.key("Close", "escape")
    session.type("File picker", " f", until=b"Shapes.swift")
    session.type("Filter", "sha")
    session.checkpoint("File picker")
    session.key("Close", "escape")
    session.resize(100, 30)
    session.checkpoint("Resized")
    session.type("Quit", ":q!\r", until=PROMPT)
    session.type("Exit", "exit\r")


def fzf(session, home):
    shell(session)
    session.type("Inline finder", "seq 500 | fzf --height 40% --layout reverse --border rounded --prompt 'number> '\r",
                 until=b"number> ")
    session.checkpoint("Inline finder")
    session.type("Filter", "42")
    session.key("Down", "down", 2)
    session.checkpoint("Filtered")
    session.key("Choose", "enter", until=PROMPT)
    session.checkpoint("Chosen")
    session.type("Preview", "fzf --preview 'head -40 {}' --style full\r", until=b"story.txt")
    session.type("Filter", "story")
    session.checkpoint("Preview")
    session.key("Close", "escape", until=PROMPT)
    run(session, "source <(fzf --zsh)")
    session.type("History widget", "\x12")
    session.checkpoint("History")
    session.type("Filter", "seq")
    session.key("Choose", "enter")
    session.type("Cancel", "\x03", until=PROMPT)
    session.type("Exit", "exit\r")


def btop(session, home):
    shell(session)
    session.type("Open btop", "btop --filter thrush-btop\r", seconds=3)
    session.checkpoint("btop")
    session.key("Select the process", "down", seconds=1.5)
    session.checkpoint("Selected")
    session.key("Sort by the next column", "right", seconds=1.5)
    session.key("Menu", "escape", seconds=1)
    session.checkpoint("Menu")
    session.key("Close", "escape", seconds=1)
    session.resize(100, 30, seconds=2)
    session.checkpoint("Resized")
    session.type("Quit", "q", until=PROMPT)
    session.type("Exit", "exit\r")


def claude(session, home):
    shell(session)
    run(session, f"cd {AGENT}")
    # Claude Code moves to each word with CHA, so the scenario waits for single words.
    session.type("Open Claude Code", "claude\r", until=b"cancel", timeout=60)
    session.checkpoint("Folder trust")
    session.key("Choose trust", "down")
    session.key("Trust the folder", "enter", until=b"shortcuts", timeout=60)
    session.checkpoint("Ready")
    session.type("Ask", "Tighten the notes")
    session.key("Send", "enter", until=b"amend", timeout=60)
    session.checkpoint("Edit permission")
    session.type("Approve", "1", until=b"aligned", timeout=60)
    session.checkpoint("Answer")
    session.resize(100, 30)
    session.checkpoint("Resized")
    session.type("Commands", "/")
    session.checkpoint("Command menu")
    session.type("Quit", "exit\r", until=PROMPT)
    session.checkpoint("Back at the prompt")
    session.type("Exit", "exit\r")


def copilot(session, home):
    shell(session)
    run(session, f"cd {AGENT}")
    session.type("Open Copilot CLI", "copilot\r", until=b"cancel", timeout=60)
    session.checkpoint("Folder trust")
    session.key("Trust the folder", "enter", until=b"commands", timeout=60)
    session.checkpoint("Ready")
    session.type("Ask", "Tighten the notes")
    session.key("Send", "enter", until=b"navigate", timeout=60)
    session.checkpoint("Edit permission")
    session.type("Approve", "1", until=b"aligned", timeout=60)
    session.checkpoint("Answer")
    session.resize(100, 30)
    session.checkpoint("Resized")
    session.type("Commands", "/")
    session.checkpoint("Command menu")
    session.type("Quit", "exit\r", until=PROMPT)
    session.checkpoint("Back at the prompt")
    session.type("Exit", "exit\r")


SCENARIOS = {
    "zsh": (["/bin/zsh", "-i"], zsh, "zsh --version"),
    "zsh-clear": (["/bin/zsh", "-f", "-i"], zsh_clear,
                  "/bin/zsh --version; /usr/bin/infocmp -V; infocmp-alt -V"),
    "bash": (["/opt/homebrew/bin/bash", "--noprofile", "--norc", "-i"], bash, "/opt/homebrew/bin/bash --version"),
    "pager": (["/bin/zsh", "-i"], pager, "less --version"),
    "git": (["/bin/zsh", "-i"], git, "git --version"),
    "editors": (["/bin/zsh", "-i"], editor, "vim --version"),
    "monitors": (["/bin/zsh", "-i"], monitors, "htop --version"),
    "multiplexers": (["/bin/zsh", "-i"], multiplexers, "tmux -V; screen --version"),
    "python": (["python3.14", "-q"], python, "python3.14 --version"),
    "lazygit": (["lazygit", "-p", "repo"], lazygit, "lazygit --version"),
    "decorations": (["/bin/zsh", "-i"], decorations, "rg --version | head -1; vim --version | head -1"),
    "neovim": (["/bin/zsh", "-i"], neovim, "nvim --version | head -1; sourcekit-lsp --version"),
    "helix": (["/bin/zsh", "-i"], helix, "hx --version; sourcekit-lsp --version"),
    "fzf": (["/bin/zsh", "-i"], fzf, "fzf --version"),
    "btop": (["/bin/zsh", "-i"], btop, "btop --version | head -1"),
    "claude": (["/bin/zsh", "-i"], claude, "claude --version"),
    "copilot": (["/bin/zsh", "-i"], copilot, "copilot --version | head -1"),
}


def executable(name):
    """A program on the capturer's PATH, followed to the binary itself."""
    found = shutil.which(name)
    if found is None:
        raise FileNotFoundError(f"Recapturing needs {name} on the PATH")
    path = Path(found).resolve()
    # npm installs Copilot CLI as a Node loader beside its native binary.
    if name == "copilot" and path.suffix == ".js":
        path = path.parent.parent / f"copilot-darwin-{os.uname().machine}" / "copilot"
    return path


def setup(name, home, environ):
    """Gives one scenario its programs and settings. Returns what to clean up afterward."""
    commands = home / "bin"
    commands.mkdir(exist_ok=True)
    if name in ("neovim", "helix"):
        (home / "shapes").mkdir()
        (home / "shapes/Shapes.swift").write_text(SHAPES)
        server = subprocess.check_output(["xcrun", "--find", "sourcekit-lsp"], text=True).strip()
        (commands / "sourcekit-lsp").write_text(f'#!/bin/sh\nexec "{server}" "$@"\n')
        (commands / "sourcekit-lsp").chmod(0o755)
        (home / ".config/nvim").mkdir(parents=True)
        (home / ".config/nvim/init.lua").write_text(NEOVIM)
        (home / ".config/helix").mkdir(parents=True)
        (home / ".config/helix/config.toml").write_text(HELIX)
    if name == "btop":
        (home / ".config/btop").mkdir(parents=True)
        (home / ".config/btop/btop.conf").write_text(BTOP)
    if name not in ("claude", "copilot"):
        return lambda: None
    (commands / name).symlink_to(executable(name))
    shutil.rmtree(AGENT, ignore_errors=True)
    AGENT.mkdir()
    (AGENT / "notes.md").write_text(f"# Notes\n\n{NOTES}\n")
    shutil.copyfile(home / "Screen.swift", AGENT / "Screen.swift")
    model = Model()
    if name == "claude":
        state = dict(hasCompletedOnboarding=True, theme="dark", autoUpdates=False, numStartups=1,
                     customApiKeyResponses=dict(approved=[API_KEY[-20:]], rejected=[]))
        (home / ".claude").mkdir()
        (home / ".claude/.claude.json").write_text(json.dumps(state))
        environ.update(ANTHROPIC_BASE_URL=model.url, ANTHROPIC_API_KEY=API_KEY, ANTHROPIC_MODEL=MODEL,
                       ANTHROPIC_SMALL_FAST_MODEL=MODEL, CLAUDE_CONFIG_DIR=str(home / ".claude"),
                       CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1", DISABLE_AUTOUPDATER="1")
    else:
        environ.update(COPILOT_HOME=str(home / ".copilot"), COPILOT_OFFLINE="true", COPILOT_MODEL=MODEL,
                       COPILOT_PROVIDER_BASE_URL=model.url, COPILOT_PROVIDER_TYPE="anthropic",
                       COPILOT_PROVIDER_API_KEY=API_KEY,
                       COPILOT_PKG_CACHE_HOME=str(Path.home() / "Library/Caches/copilot"))

    def clean():
        model.close()
        shutil.rmtree(AGENT, ignore_errors=True)
    return clean


def capture(name, destination):
    argv, scenario, version = SCENARIOS[name]
    with tempfile.TemporaryDirectory(prefix="thrush-programs-", ignore_cleanup_errors=True) as work:
        home = Path(work).resolve()
        prepare(home)
        environ = environment(home)
        if name == "zsh-clear":
            commands = home / "bin"
            commands.mkdir(exist_ok=True)
            (commands / "clear").symlink_to("/usr/bin/clear")
            ncurses = Path(subprocess.check_output(["brew", "--prefix", "ncurses"], text=True).strip()) / "bin"
            for tool in ("clear", "infocmp"):
                binary = ncurses / tool
                if not binary.is_file():
                    raise FileNotFoundError(f"Recapturing zsh-clear requires Homebrew ncurses at {binary}")
                (commands / (tool + "-alt")).symlink_to(binary)
            environ.update(PS1="thrush$ ", PROMPT="thrush$ ", RPS1="")
        if name == "bash":
            environ.update(PS1=r"\[\e[1;32m\]\W\[\e[0m\] ❯ ", INPUTRC="/dev/null", HISTFILE="/dev/null")
        if name == "decorations":
            ripgrep = shutil.which("rg")
            if ripgrep is None:
                raise FileNotFoundError("Recapturing decorations requires ripgrep's rg on the PATH")
            commands = home / "bin"
            commands.mkdir(exist_ok=True)
            (commands / "rg").symlink_to(ripgrep)
            (home / ".ripgrep-host").write_text("#!/bin/sh\necho thrush\n")
            (home / ".ripgrep-host").chmod(0o755)
            (home / ".ripgreprc").write_text(RIPGREPRC.format(home=home))
            (home / "spell.vim").write_text(SPELL)
            (home / "true-color-spell.vim").write_text(TRUE_COLOR_SPELL)
            shutil.rmtree(PROJECT, ignore_errors=True)
            PROJECT.mkdir()
            for file in ("story.txt", "notes.md", "Screen.swift"):
                shutil.copyfile(home / file, PROJECT / file)
            (PROJECT / "spelling.md").write_text(SPELLING)
            environ.update(RIPGREP_CONFIG_PATH=str(home / ".ripgreprc"))
        clean = setup(name, home, environ)
        session = Session(home, argv, environ)
        try:
            scenario(session, home)
            session.read("Exit", timeout=5)
        finally:
            session.close()
            clean()
            if name == "decorations":
                shutil.rmtree(PROJECT, ignore_errors=True)
            if name == "multiplexers":
                subprocess.run(["tmux", "-L", "thrush", "kill-server"], env=environ, stderr=subprocess.DEVNULL)
                subprocess.run(["screen", "-wipe"], env=environ, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        anonymous(session.events)
        versions = subprocess.run(version, shell=True, env=environ, capture_output=True, text=True).stdout
        header = dict(name=name, command=" ".join(argv), versions=[line for line in versions.splitlines() if line][:3],
                      term="xterm-256color", columns=80, rows=24)
        compact = lambda value: json.dumps(value, ensure_ascii=False, separators=(",", ":"))
        content = compact(header)[:-1] + ',\n"events":[\n' + ",\n".join(map(compact, session.events)) + "\n]}\n"
        (destination / f"{name}.capture.json").write_text(content)
        print(f"Recorded {name}: {len(session.events)} events", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--only", action="append", choices=list(SCENARIOS))
    options = parser.parse_args()
    destination = HERE / "programs"
    destination.mkdir(exist_ok=True)
    failed = []
    for name in options.only or SCENARIOS:
        try:
            capture(name, destination)
        except Exception as error:
            print(f"Could not record {name}: {error}", flush=True)
            failed.append(name)
    raise SystemExit(f"Failed: {', '.join(failed)}" if failed else 0)
