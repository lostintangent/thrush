// Replay the recorded PTY output through the production WebSocket, keeping every read boundary.
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { ServerWebSocket } from "bun";

const [fixturePath, output, mode, deferred] = Bun.argv.slice(2);
type Read = { base64: string; elapsedMs: number };
type Capture = { beforeTyping: Read[]; typed: Read[]; returned: Read[] };
const capture: Capture = JSON.parse(readFileSync(fixturePath, "utf8"));
const frames: object[] = [];
let input = "";
let stage: "seed" | "typing" | "enter" | "done" = "seed";

async function play(socket: ServerWebSocket<unknown>, reads: Read[], section: string) {
    const start = performance.now();
    for (const read of reads) {
        const remaining = start + read.elapsedMs - performance.now();
        if (remaining > 0) await Bun.sleep(remaining);
        const bytes = Buffer.from(read.base64, "base64");
        const parts = mode === "split" && bytes.equals(Buffer.from("\x1b[3J\x1b[H\x1b[2J"))
            ? [bytes.subarray(0, 4), bytes.subarray(4, 7), bytes.subarray(7)] : [bytes];
        for (const part of parts) {
            socket.sendBinary(part);
            frames.push({ section, timeMs: performance.now(), hex: part.toString("hex") });
        }
    }
}

const server = Bun.serve({
    port: 0, hostname: "127.0.0.1",
    fetch(request, server) {
        const url = new URL(request.url);
        if (url.pathname === "/socket" && url.searchParams.get("service") === "terminal" && server.upgrade(request)) return;
        return new Response(null, { status: 404 });
    },
    websocket: {
        async open(socket) {
            socket.sendText(JSON.stringify({type: "ready", resumed: false}));
            writeFileSync(join(output, "attached"), "");
            if (deferred) {
                // Let WindowServer register the capture before the original numbered history
                // fills the native window. The clear and its prompt retain their recorded timing.
                const deadline = performance.now() + 60000;
                while (!existsSync(join(output, "recording-start.armed"))) {
                    if (performance.now() >= deadline) throw Error("No window recorder attached");
                    await Bun.sleep(15);
                }
            }
            await play(socket, capture.beforeTyping, "beforeTyping");
            stage = "typing";
            writeFileSync(join(output, "seeded"), "");
        },
        async message(socket, message) {
            if (typeof message === "string") return;
            const bytes = Buffer.from(message).toString();
            if (bytes === "\x1b[I" || bytes === "\x1b[O") return;
            if (stage === "typing") {
                input += bytes;
                if ("clear".startsWith(input) && input !== "clear") return;
                if (input === "clear") {
                    stage = "enter";
                    await play(socket, capture.typed, "typed");
                    writeFileSync(join(output, "echoed"), "");
                    return;
                }
            } else if (stage === "enter" && bytes === "\r") {
                stage = "done";
                await play(socket, capture.returned, "returned");
                writeFileSync(join(output, "wire.json"), JSON.stringify(frames));
                return;
            }
            writeFileSync(join(output, "peer-error.txt"), JSON.stringify({stage, input, bytes}));
        }
    }
});
console.log("http://127.0.0.1:" + server.port);
