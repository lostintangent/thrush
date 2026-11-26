// Paint the grid in three WebSocket messages per burst, top third first, with controlled gaps.
// Each burst flips every third between ink and blank, so a frame with mixed thirds shows part of a burst.
import { dlopen, FFIType } from "bun:ffi";
import { existsSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const [output, countText = "24"] = Bun.argv.slice(2);
const perGap = Number(countText);
// Gaps in milliseconds between the three messages. 20 ms spans a 60 Hz refresh and
// checks that the recorder sees a partial that is certainly displayed.
const gaps = [0, 0.1, 0.25, 0.5, 1, 2, 4, 20];
let seed = 0x7468;
function random() {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), seed | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}
const schedule = gaps.flatMap(gap => Array(perGap).fill(gap));
for (let i = schedule.length - 1; i > 0; i--) {
    const j = Math.floor(random() * (i + 1));
    [schedule[i], schedule[j]] = [schedule[j], schedule[i]];
}
let size = { cols: 0, rows: 0 };
// The host's media clock, which the app and the window recorder also use, in seconds.
const system = dlopen("/usr/lib/libSystem.B.dylib", { clock_gettime_nsec_np: { args: [FFIType.u32], returns: FFIType.u64 } });
const CLOCK_UPTIME_RAW = 8;
function mediaTime() {
    return Number(system.symbols.clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9;
}

function spin(until: number) {
    while (Bun.nanoseconds() < until) {}
}

function thirds(ink: boolean) {
    const fill = "\x1b[97;107m" + "█".repeat(size.cols) + "\x1b[0m";
    const bounds = [0, Math.floor(size.rows / 3), Math.floor(2 * size.rows / 3), size.rows];
    return [0, 1, 2].map(third => {
        let text = "";
        for (let row = bounds[third]; row < bounds[third + 1]; row++)
            text += `\x1b[${row + 1};1H` + (ink ? fill : "\x1b[0m\x1b[2K");
        return Buffer.from(text);
    });
}

const server = Bun.serve({
    port: 0, hostname: "127.0.0.1",
    fetch(request, server) {
        const url = new URL(request.url);
        size = { cols: Number(url.searchParams.get("cols")), rows: Number(url.searchParams.get("rows")) };
        if (url.pathname === "/socket" && url.searchParams.get("service") === "terminal" && server.upgrade(request)) return;
        return new Response(null, { status: 404 });
    },
    websocket: {
        async open(socket) {
            socket.sendText(JSON.stringify({ type: "ready", resumed: false }));
            writeFileSync(join(output, "attached"), "");
            const deadline = performance.now() + 120000;
            while (!existsSync(join(output, "start"))) {
                if (performance.now() >= deadline) throw Error("The driver never started the bursts");
                await Bun.sleep(15);
            }
            socket.sendBinary(Buffer.from("\x1b[?25l\x1b[?7l\x1b[0m\x1b[2J\x1b[H"));
            await Bun.sleep(400);
            const bursts = [];
            for (const [index, gap] of schedule.entries()) {
                // A random pause between bursts spreads their arrival across the refresh.
                await Bun.sleep(70 + 60 * random());
                const parts = thirds(index % 2 === 0);
                const sent = [];
                const sentAt = mediaTime();
                const start = Bun.nanoseconds();
                for (const [n, part] of parts.entries()) {
                    spin(start + n * gap * 1e6);
                    socket.sendBinary(part);
                    sent.push((Bun.nanoseconds() - start) / 1e6);
                }
                bursts.push({ index, gap, ink: index % 2 === 0, sentAt, sentMs: sent, cols: size.cols, rows: size.rows });
            }
            await Bun.sleep(400);
            writeFileSync(join(output, "wire.json"), JSON.stringify({ gaps, perGap, bursts }));
        },
        message(_socket, message) {
            if (typeof message !== "string") return;
            const control = JSON.parse(message);
            if (control.type === "resize") size = { cols: control.cols, rows: control.rows };
        }
    }
});
console.log("http://127.0.0.1:" + server.port);
