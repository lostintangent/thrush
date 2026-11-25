import { existsSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const [base, id, directory, mode] = Bun.argv.slice(2);
const url = new URL("/socket", base);
if (url.hostname !== "127.0.0.1" || url.protocol !== "http:" || !["count", "exit"].includes(mode)) {
  throw new Error("Run scripts/check-pty.sh --readers");
}
url.protocol = "ws:";
url.search = new URLSearchParams({ service: "terminal", clientId: id, cols: "80", rows: "24" }).toString();
const socket = new WebSocket(url);
socket.binaryType = "arraybuffer";
let receivedBytes = 0, binaryFrames = 0, exitSeen = false, attached = false;
let tail = Buffer.alloc(0);
let awaitingReplay = false, replayFrames = 0, replayBytes = 0, finalInReplay = false;
let closeCode: number | null = null, exitBeforeClose = false;
// Only the exit probe retains the last complete serialization and the live bytes following it.
let finalScreenFrames: Buffer[] | null = null;
socket.onclose = event => {
  closeCode = event.code;
  exitBeforeClose = exitSeen;
};
const final = Buffer.from("THRUSH-SHELL-EXIT\r\n");

function report(extra = {}) {
  writeFileSync(join(directory, "client.json"), JSON.stringify({ reader: "bun", receivedBytes, binaryFrames, replayBytes, replayFrames, ...extra }));
}

socket.onmessage = ({data}) => {
  if (typeof data !== "string") {
    if (!attached || exitSeen) throw new Error("Binary message outside the active shell");
    receivedBytes += data.byteLength;
    if (awaitingReplay) {
      awaitingReplay = false;
      replayFrames++;
      replayBytes += data.byteLength;
      if (mode === "exit") {
        const snapshot = Buffer.from(data);
        finalInReplay = snapshot.includes("THRUSH-SHELL-EXIT");
        finalScreenFrames = [snapshot];
      }
      return;
    }
    binaryFrames++;
    // The matched reader only counts bytes. For the exit probe retain a bounded suffix.
    if (mode === "exit") {
      const frame = Buffer.from(data);
      tail = Buffer.concat([tail, frame.subarray(-final.length)]).subarray(-final.length);
      finalScreenFrames?.push(frame);
    }
    return;
  }
  const control = JSON.parse(data);
  if (control.type === "ready" && !attached && !control.resumed) {
    attached = true;
    writeFileSync(join(directory, "reader-ready"), "");
  } else if (control.type === "ready" && attached && control.resumed && !awaitingReplay && !exitSeen) {
    awaitingReplay = true;
  } else if (control.type === "exit" && attached && !awaitingReplay && !exitSeen) {
    exitSeen = true;
    if (mode === "count") {
      report();
      socket.close();
    }
  } else {
    throw new Error("Unexpected control " + data);
  }
};

if (mode === "exit") {
  // Python has observed the real shell PID disappear and given the reader three seconds to drain.
  while (!existsSync(join(directory, "probe"))) await Bun.sleep(25);
  const openAfterExit = socket.readyState === WebSocket.OPEN;
  const nonce = crypto.randomUUID();
  let pong = false;
  socket.addEventListener("pong", ({data}) => {
    if (Buffer.from(data).toString() === nonce) pong = true;
  });
  if (openAfterExit) socket.ping(nonce);
  const deadline = performance.now() + 2000;
  while (openAfterExit && !pong && closeCode === null && performance.now() < deadline) await Bun.sleep(10);

  // A same-ID attachment proves whether Toy Box can still replay the former PTY.
  const next = new WebSocket(url);
  const resumed = await new Promise<boolean>((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error("Missing same-ID ready")), 3000);
    next.onmessage = ({data}) => {
      if (typeof data !== "string") return;
      const control = JSON.parse(data);
      if (control.type === "ready") {
        clearTimeout(timeout);
        resolve(control.resumed);
      }
    };
  });
  if (finalScreenFrames !== null) {
    writeFileSync(join(directory, "final-screen.bin"), Buffer.concat(finalScreenFrames));
  }
  report({ exitSeen, finalMarkerSeen: tail.equals(final), finalInReplay, openAfterExit, pongAfterExit: pong,
           exitBeforeClose, closeCode, resumed });
  // Allow Python to independently identify the replacement shell by PID before closing it.
  const limit = performance.now() + 3000;
  while (!existsSync(join(directory, "replacement-pid")) && performance.now() < limit) await Bun.sleep(10);
  next.send(JSON.stringify({type: "close"}));
  next.close();
  socket.close();
}
