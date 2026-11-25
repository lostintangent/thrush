"""Loopback Responses stream reconstructed from the published live Codex checkpoints."""
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import argparse
import json
from pathlib import Path
import re
import signal
from threading import Event, Thread
import time

QUESTION = "Name 12 songbirds on numbered lines. Start with Song thrush and end with European robin."
MODEL = "gpt-6.1-sol"

def published_answer():
    fixture = json.loads((Path(__file__).resolve().parents[2] / "replays/codex-session.json").read_text())
    entries = {}
    for event in fixture["events"]:
        if event["name"] not in ("Earlier transcript page", "Later transcript page") or "checkpoint" not in event:
            continue
        for row in event["checkpoint"]["visible"]:
            text = fixture["lines"][row]["text"].strip().removeprefix("• ")
            match = re.fullmatch(r"(\d+)\. ([\w -]+)", text)
            if match:
                n = int(match[1])
                if n in entries and entries[n] != text:
                    raise ValueError(f"Disagreeing published answer at item {n}")
                entries[n] = text
    if sorted(entries) != list(range(1, 13)):
        raise ValueError("The published transcript must contain all twelve songbirds")
    return "\n".join(entries[n] for n in sorted(entries))


@contextmanager
def local_responses(question, model, *, port=0, check_single_answer=True):
    answer = published_answer()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_POST(self):
            if self.path != "/v1/responses":
                self.send_error(404)
                return
            payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            user_text = [part["text"] for item in payload.get("input", []) if item.get("role") == "user"
                         for part in (item.get("content") or []) if part.get("type") == "input_text"]
            task = user_text[-1] if user_text else ""
            if task == question:
                self.server.answers += 1
                content = answer
            elif "title" in task.lower() and task.endswith("User prompt:\n" + question):
                # The original live session's footer contains this separately generated title.
                content = "List 12 songbirds"
            else:
                self.send_error(400, "Only the published songbird question and title are supported")
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            response = dict(id="resp_songbirds", object="response", model=model, status="in_progress", output=[])
            item = dict(id="msg_songbirds", type="message", role="assistant", status="in_progress", content=[])
            part = dict(type="output_text", text="", annotations=[])
            indexes = dict(item_id=item["id"], output_index=0, content_index=0)
            sequence = 0

            def send(kind, **fields):
                nonlocal sequence
                data = json.dumps(dict(type=kind, sequence_number=sequence, **fields))
                self.wfile.write(f"event: {kind}\ndata: {data}\n\n".encode())
                self.wfile.flush()
                sequence += 1

            send("response.created", response=response)
            if task == question:
                time.sleep(1)
            send("response.output_item.added", output_index=0, item=item)
            send("response.content_part.added", **indexes, part=part)
            for line in content.splitlines(keepends=True):
                send("response.output_text.delta", **indexes, delta=line)
                if task == question:
                    time.sleep(0.18)
            part["text"] = content
            send("response.output_text.done", **indexes, text=content)
            send("response.content_part.done", **indexes, part=part)
            item.update(content=[part], status="completed")
            send("response.output_item.done", output_index=0, item=item)
            response.update(status="completed", output=[item])
            send("response.completed", response=response)

    with ThreadingHTTPServer(("127.0.0.1", port), Handler) as server:
        server.answers = 0
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield f"http://127.0.0.1:{server.server_port}/v1"
            if check_single_answer and server.answers != 1:
                raise ValueError(f"Expected one local response, served {server.answers}")
        finally:
            server.shutdown()
            thread.join()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=0, help="loopback HTTP port (default: choose a free port)")
    args = parser.parse_args()
    stopped = Event()
    for signo in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signo, lambda *_: stopped.set())
    with local_responses(QUESTION, MODEL, port=args.port, check_single_answer=False) as endpoint:
        print(f"THRUSH_RESPONSES_URL={endpoint}", flush=True)
        stopped.wait()
