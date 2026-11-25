// Query the packaged Mac pane after each native Appearance menu action on the same socket.
import assert from "node:assert/strict";
import { join, resolve } from "node:path";
import { createInterface } from "node:readline";
import { Readable } from "node:stream";

const app = resolve(process.argv[2] ?? ".build/demo/mac/Thrush.app");
const executable = join(app, "Contents/MacOS/ThrushDemo");
if (!(await Bun.file(executable).exists())) throw Error("Build the app with scripts/build-demo.sh mac");

// Independent sRGB expectations from the Slate and Ember palettes in docs/design/README.md.
const palettes = [
    { name: "dark", foreground: "e3eaf0", background: "131d27" },
    { name: "light", foreground: "233442", background: "fbfdfe" },
    { name: "custom", foreground: "eee4d6", background: "1c1a18" },
];
const osc = "\x1b]";
const st = "\x1b\\";
function reply(command: number, hex: string): string {
    const rgb = hex.match(/../g)!.map(byte => byte + byte).join("/");
    return osc + command + ";rgb:" + rgb + st;
}
const expected = palettes.map(({ foreground, background }) => reply(10, foreground) + reply(11, background));
const query = Buffer.from(osc + "10;?" + st + osc + "11;?" + st);
const failure = Promise.withResolvers<never>();
let sendQuery: (() => void) | undefined;
let pending: ReturnType<typeof Promise.withResolvers<string>> | undefined;
let bytes = "";
let connections = 0;

const peer = Bun.serve({
    hostname: "127.0.0.1", port: 0,
    fetch(request, server) {
        const url = new URL(request.url);
        if (url.pathname === "/socket" && url.searchParams.get("service") === "terminal" &&
            Number(url.searchParams.get("cols")) > 0 && Number(url.searchParams.get("rows")) > 0 &&
            server.upgrade(request)) return;
        failure.reject(Error("Expected a measured terminal WebSocket attachment"));
        return new Response("Expected a terminal WebSocket", { status: 400 });
    },
    websocket: {
        open(socket) {
            if (++connections !== 1) {
                failure.reject(Error("Changing appearance opened a second terminal connection"));
                return;
            }
            sendQuery = () => socket.sendBinary(query);
            socket.sendText(JSON.stringify({ type: "ready", resumed: false }));
            socket.sendBinary(Buffer.from("Palette check\r\n% "));
        },
        message(_socket, message) {
            if (typeof message === "string") {
                if (JSON.parse(message).type !== "resize") failure.reject(Error("Unexpected control frame: " + message));
                return;
            }
            if (!pending) return failure.reject(Error("Received terminal input without an outstanding palette query"));
            bytes += message.toString("latin1");
            if (bytes.length >= expected[0].length) {
                pending.resolve(bytes);
                pending = undefined;
            }
        },
        close() { failure.reject(Error("Terminal connection closed during appearance cycle")); },
    },
});

const child = Bun.spawn([executable, "--endpoint", peer.url.origin, "--cycle-appearance"],
                        { stdout: "pipe", stderr: "inherit" });
let phase = "initial connection";
const deadline = setTimeout(() => failure.reject(Error("Timed out waiting for " + phase)), 60_000);
async function verify() {
    let index = 0;
    const lines = createInterface({ input: Readable.fromWeb(child.stdout), crlfDelay: Infinity });
    for await (const line of lines) {
        if (!line.startsWith("appearance=")) continue;
        const palette = palettes[index];
        phase = palette.name;
        assert.equal(line, "appearance=" + phase, "Unexpected native menu action");
        assert.ok(sendQuery, "Menu cycled before the first terminal output");
        // The native menu action can precede the SwiftUI environment update by one run-loop turn.
        const until = Date.now() + 3_000;
        for (;;) {
            bytes = "";
            pending = Promise.withResolvers<string>();
            const result = pending.promise;
            sendQuery();
            const actual = await result;
            if (actual === expected[index]) break;
            assert.ok(expected.includes(actual), "Malformed or unknown palette reply: " + JSON.stringify(actual));
            assert.ok(Date.now() < until, "Palette did not update for " + phase + ": " + JSON.stringify(actual));
            await Bun.sleep(50);
        }
        console.log(phase + " OSC 10 #" + palette.foreground + ", OSC 11 #" + palette.background);
        if (++index === palettes.length) return;
    }
    throw Error("Native app exited before completing the appearance cycle");
}
try {
    await Promise.race([verify(), failure.promise]);
    console.log("Verified all six color replies over one terminal connection.");
} finally {
    clearTimeout(deadline);
    child.kill();
    peer.stop(true);
}
