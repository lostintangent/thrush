// scripts/check-loopback.sh runs the platform client against this loopback-only R4 peer.
import assert from "node:assert/strict";
import type { ServerWebSocket } from "bun";

const observe = process.argv[3] === "--observe";
if (process.argv.length !== (observe ? 4 : 3)) {
    throw new Error("Usage: bun scripts/lifecycle-peer.ts PATH_TO_CHECK_EXECUTABLE [--observe]");
}

type Control = { type: "resize"; cols: number; rows: number } | { type: "close" };
type Exchange = { input: string | Control; observation: string; output?: string[] };
type Attachment = {
    name: string;
    resumed: boolean;
    output: string[];
    inBandReady?: boolean[];
    exchanges: Exchange[];
    end: "detach" | "takeover" | "close" | "exit" | "lost" | "protocol error";
};

// While detached the shell clears its normal screen, prints four lines on a three-row grid,
// enters 1049 alternate screen, homes, and prints "alt". Its application cursor mode is set.
// The serializer restores that mode after both buffers. Each later replay includes prior echoes.
function replay(altLine: string) {
    return "history\r\none\r\ntwo\r\nshell$\x1b[?1049h\x1b[H" + altLine + "\x1b[?1h";
}

const attachments: Attachment[] = [
    {
        name: "fresh", resumed: false, output: ["old-only\r\nold", "\x1b[?1h"],
        exchanges: [{ input: { type: "resize", cols: 18, rows: 3 }, output: ["."], observation: "Fresh ready to resize" }], end: "detach",
    },
    {
        name: "foreground", resumed: true, output: [replay("alt"), "!"],
        exchanges: [{ input: "\x1bOA", output: ["A"], observation: "Foreground ready and replay to Up" }], end: "takeover",
    },
    {
        name: "second owner", resumed: true, output: [replay("alt!A"), "!"],
        exchanges: [{ input: "\x1bOA", output: ["B"], observation: "Takeover ready and replay to Up" }], end: "takeover",
    },
    {
        name: "reclaimed", resumed: true, output: [replay("alt!A!B")],
        exchanges: [
            { input: { type: "resize", cols: 17, rows: 3 }, observation: "Reclaimed replay to deferred resize" },
            { input: "r", output: ["R", "\x1b[?1049l"], observation: "Deferred resize to reclaim key" },
        ],
        end: "detach",
    },
    {
        name: "after expiry", resumed: false, output: ["new$ "],
        exchanges: [
            { input: "\x1b[A", output: ["N"], observation: "Post-expiry fresh ready to Up" },
            { input: { type: "close" }, observation: "Replacement repair to explicit close" },
        ], end: "close",
    },
    {
        name: "after explicit close", resumed: false, output: ["last ", "bytes"], exchanges: [], end: "exit",
    },
    {
        name: "before outage", resumed: false, output: [],
        exchanges: [{ input: "once", output: ["seen"], observation: "Ready to last write before loss" }], end: "lost",
    },
    {
        name: "automatic resume", resumed: true, output: ["\x1b]2;Original shell\x07\x1b[?1h\x1b[?2004hsaved-main\x1b[?1049h\x1b[H"],
        exchanges: [
            { input: "\x1bOA", observation: "Recovery ready and replay to held Up" },
            { input: "\x1b[200~a\rb\x1b[201~", observation: "Held Up to bracketed paste" },
            { input: "\x1bOD", output: ["ok"], observation: "Held paste to replay-time Left" },
            { input: "again", observation: "Drained input echo to next outage" },
        ], end: "lost",
    },
    {
        name: "automatic replacement", resumed: false, output: ["new$ "],
        exchanges: [{ input: "clean", output: ["clean"], observation: "Replacement ready to fresh input" }], end: "exit",
    },
    {
        name: "user restart", resumed: false, output: [],
        exchanges: [{ input: "pause", observation: "New session ready to input" }], end: "lost",
    },
    {
        name: "visible again", resumed: true, output: ["$ "],
        exchanges: [{ input: "back", observation: "Visible replay to new input" }], end: "exit",
    },
    {
        name: "slow reader", resumed: false, output: ["gone\r\nold 1\r\nold 2\r\nold 3\x1b[?1h\x1b]0;partial"], inBandReady: [true],
        exchanges: [
            { input: "\x1bOA", observation: "In-band ready to active Up" },
            { input: { type: "resize", cols: 17, rows: 3 }, observation: "In-band replay to deferred resize" },
            { input: "\x1b[A", observation: "Deferred resize to restored Up" },
            { input: "\x1b[200~a\rb\x1b[201~", output: ["\r\nbye"], observation: "Restored Up to bracketed paste" },
        ], end: "exit",
    },
    { name: "unexpected fresh marker", resumed: false, output: ["kept"], inBandReady: [false], exchanges: [], end: "protocol error" },
    { name: "duplicate replay marker", resumed: false, output: ["kept"], inBandReady: [true, true], exchanges: [], end: "protocol error" },
];

type State = { script: Attachment; received: number; acceptsInput: boolean; start: number };
type Socket = ServerWebSocket<State>;
type Shell = { owner?: Socket; orphanedAt?: number };
const encoder = new TextEncoder();
const clientID = "thrush lifecycle";
const orphanLifetime = 30_000;
let now = 0;
let shell: Shell | undefined;
let attachmentCount = 0;
let takeovers = 0;
let freshShells = 0;
const detached = Promise.withResolvers<void>();
const foreground = Promise.withResolvers<void>();
const leftAfterReclaim = Promise.withResolvers<void>();
const explicitlyClosed = Promise.withResolvers<void>();
const allowFreshReady = Promise.withResolvers<void>();
const originalLifecycleEnded = Promise.withResolvers<void>();
const interruptedSocketClosed = Promise.withResolvers<void>();
const inputDuringStall = Promise.withResolvers<void>();
const finished = Promise.withResolvers<void>();
const checkpoints = new Set<string>();
const closedSockets = new Set<string>();
const observations: { name: string; nanoseconds: number }[] = [];

function startInterval(socket: Socket) {
    if (observe) socket.data.start = Bun.nanoseconds();
}

function recordInterval(socket: Socket, name: string) {
    if (observe) observations.push({ name, nanoseconds: Bun.nanoseconds() - socket.data.start });
}

function advanceClock(milliseconds: number) {
    now += milliseconds;
    if (shell?.orphanedAt !== undefined && now - shell.orphanedAt >= orphanLifetime) shell = undefined;
}

// Test-driver barriers use HTTP so synchronization adds no terminal frames. The first socket's
// FIN and its successor's handshake may arrive in either order, including while a read is pending.
async function checkpoint(path: string) {
    assert(!checkpoints.has(path), "Repeated checkpoint " + path);
    checkpoints.add(path);
    switch (path) {
    case "/check/detached":
        await detached.promise;
        advanceClock(1_000);
        assert(shell && !shell.owner, "Brief detach should retain the shell");
        foreground.resolve();
        break;
    case "/check/owner-b":
        assert.equal(shell?.owner?.data.script.name, "second owner");
        assert.equal(shell.owner.data.received, 1, "Second owner must still receive its input echo");
        break;
    case "/check/replay": {
        const socket = shell?.owner;
        assert.equal(socket?.data.script.name, "reclaimed");
        startInterval(socket);
        output(socket, socket.data.script.output);
        socket.data.acceptsInput = true;
        break;
    }
    case "/check/expire":
        await leftAfterReclaim.promise;
        advanceClock(orphanLifetime - 1);
        assert(shell && !shell.owner, "Orphan should still exist before its deadline");
        advanceClock(1);
        assert.equal(shell, undefined, "Orphan should expire at its deadline");
        break;
    case "/check/ready":
        assert(checkpoints.has("/check/expire"), "Expiry must precede the fresh handshake");
        allowFreshReady.resolve();
        break;
    case "/check/replacement-replay": {
        const socket = shell?.owner;
        assert.equal(socket?.data.script.name, "after expiry");
        assert.equal(socket.data.received, 1, "Only the fresh Up may reach the replacement");
        startInterval(socket);
        assert(socket.sendText(JSON.stringify({ type: "ready", resumed: true })) > 0);
        output(socket, ["new$ N"]);
        break;
    }
    case "/check/closed":
        await explicitlyClosed.promise;
        assert.equal(shell, undefined, "Explicit close must release the shell");
        break;
    case "/check/interrupted":
        await interruptedSocketClosed.promise;
        break;
    case "/check/live-replay": {
        await inputDuringStall.promise;
        const socket = shell?.owner;
        assert.equal(socket?.data.script.name, "slow reader");
        assert.equal(socket.data.received, 1, "Input must stay active and resize must wait for the replay");
        // The repaint restores five lines of output and re-enables bracketed paste.
        // Queue the next live write immediately. No fresh socket or extra control separates them.
        startInterval(socket);
        output(socket, ["oldest\r\nnewer\r\none\r\ntwo\r\nthree\x1b[?2004h", "!"]);
        break;
    }
    default:
        assert.fail("Unknown checkpoint " + path);
    }
}

function output(socket: Socket, frames: string[]) {
    for (const text of frames) assert(socket.sendBinary(encoder.encode(text)) > 0, "Failed to send binary output");
}

function shellExited(socket: Socket) {
    shell = undefined;
    assert(socket.sendText(JSON.stringify({ type: "exit" })) > 0);
    if (socket.data.script.name === "slow reader") socket.close(1000);
}

function ready(socket: Socket) {
    const { script } = socket.data;
    assert.equal(shell?.owner, socket);
    startInterval(socket);
    assert(socket.sendText(JSON.stringify({ type: "ready", resumed: script.resumed })) > 0);
    if (script.name === "reclaimed") return; // The host resizes while awaiting this replay.
    output(socket, script.output);
    socket.data.acceptsInput = true;
    for (const resumed of script.inBandReady ?? []) {
        startInterval(socket);
        assert(socket.sendText(JSON.stringify({ type: "ready", resumed })) > 0);
    }
    if (script.end === "protocol error") shell = undefined;
    if (script.end === "exit" && script.exchanges.length === 0) shellExited(socket);
}

const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request, server) {
        try {
            const { pathname, searchParams } = new URL(request.url);
            assert.equal(request.method, "GET");
            if (pathname.startsWith("/check/")) {
                await checkpoint(pathname);
                return new Response(null, { status: 204 });
            }
            assert.equal(pathname, "/socket");
            assert.deepEqual([...searchParams.keys()].sort(), ["clientId", "cols", "rows", "service"]);
            assert.equal(searchParams.get("service"), "terminal");
            assert.equal(searchParams.get("clientId"), clientID);
            assert.equal(searchParams.get("cols"), "16");
            assert.equal(searchParams.get("rows"), "3");
            const script = attachments[attachmentCount++];
            assert(script, "Unexpected additional attachment");
            if (script.name === "foreground") await foreground.promise;
            if (script.name === "reclaimed") assert(checkpoints.has("/check/owner-b"), "Displaced owner reconnected before user input");
            if (script.name === "after explicit close") assert(checkpoints.has("/check/closed"));
            if (script.name === "before outage") await originalLifecycleEnded.promise;
            if (script.name === "automatic resume") await interruptedSocketClosed.promise;
            assert(server.upgrade(request, { data: { script, received: 0, acceptsInput: false, start: 0 } }), "Expected a WebSocket upgrade");
        } catch (error) {
            finished.reject(error);
            return new Response("Unexpected lifecycle request", { status: 400 });
        }
    },
    websocket: {
        data: {} as State,
        open(socket) {
            try {
                const { script } = socket.data;
                assert.equal(shell !== undefined, script.resumed, script.name + " shell lifetime");
                if (!shell) freshShells++;
                const displaced = shell?.owner;
                shell = { owner: socket };
                if (displaced) {
                    assert.equal(displaced.data.script.end, "takeover");
                    assert.equal(displaced.data.received, displaced.data.script.exchanges.length);
                    takeovers++;
                    displaced.close(4000, "replaced");
                }
                if (script.name === "after expiry") {
                    void allowFreshReady.promise.then(() => ready(socket)).catch(finished.reject);
                } else {
                    ready(socket);
                }
            } catch (error) {
                finished.reject(error);
            }
        },
        message(socket, message) {
            try {
                const state = socket.data;
                assert.equal(shell?.owner, socket, "Received a write from a displaced socket");
                assert(state.acceptsInput, "Received a write before ready and replay");
                const exchange = state.script.exchanges[state.received++];
                assert(exchange, "Unexpected frame on " + state.script.name);
                recordInterval(socket, exchange.observation);
                if (typeof exchange.input === "string") {
                    assert(typeof message !== "string", "Expected binary stdin");
                    assert.deepEqual([...message], [...encoder.encode(exchange.input)], state.script.name + " stdin");
                } else {
                    assert(typeof message === "string", "Expected a JSON control");
                    assert.deepEqual(JSON.parse(message), exchange.input);
                }
                startInterval(socket);
                if (exchange.output) output(socket, exchange.output);
                if (state.script.name === "slow reader" && state.received === 1) inputDuringStall.resolve();
                if (typeof exchange.input !== "string" && exchange.input.type === "close") {
                    shell = undefined;
                    socket.close(1000);
                    explicitlyClosed.resolve();
                }
                if (state.received === state.script.exchanges.length) {
                    if (state.script.end === "exit") shellExited(socket);
                    if (state.script.name === "automatic resume" || state.script.name === "user restart") {
                        shell = state.script.name === "automatic resume" ? undefined : { orphanedAt: now };
                        socket.close(1011, "connection lost");
                    }
                }
            } catch (error) {
                finished.reject(error);
            }
        },
        close(socket) {
            try {
                const { script, received } = socket.data;
                assert.equal(received, script.exchanges.length, script.name + " disconnected before its last expected frame");
                closedSockets.add(script.name);
                if (script.name === "before outage") {
                    assert.equal(shell?.owner, socket);
                    shell = { orphanedAt: now };
                    interruptedSocketClosed.resolve();
                } else if (shell?.owner === socket) {
                    assert.equal(script.end, "detach", script.name + " unexpectedly lost ownership");
                    shell = { orphanedAt: now };
                    if (script.name === "fresh") {
                        recordInterval(socket, "Resize echo to detach");
                        detached.resolve();
                    } else {
                        assert.equal(script.name, "reclaimed");
                        recordInterval(socket, "Reclaim echo to detach");
                        leftAfterReclaim.resolve();
                    }
                }
                if (script.name === "after explicit close") {
                    recordInterval(socket, "Final ready, output and exit to socket close");
                    originalLifecycleEnded.resolve();
                }
                if (closedSockets.size === attachments.length) finished.resolve();
            } catch (error) {
                finished.reject(error);
            }
        },
    },
});

const client = Bun.spawn([process.argv[2], "--lifecycle", server.url.origin], { stdout: observe ? 2 : "inherit", stderr: "inherit" });
const deadline = Promise.withResolvers<never>();
const timeout = setTimeout(() => deadline.reject(new Error("Timed out at attachment " + attachmentCount)), 15_000);
try {
    await Promise.race([
        Promise.all([finished.promise, client.exited.then(code => assert.equal(code, 0, "Swift client failed"))]),
        deadline.promise,
    ]);
    assert.equal(attachmentCount, attachments.length);
    assert.equal(freshShells, 9);
    assert.equal(takeovers, 2);
    assert.equal(checkpoints.size, 9);
    if (observe) {
        console.log(JSON.stringify({ bunVersion: Bun.version, attachmentCount, freshShells, takeovers, observations }));
    } else {
        console.log("Lifecycle peer verified fourteen attachments, two takeovers, ordered writes and resizes, automatic recovery, buffered input, in-band replay, malformed controls, in-place shell replacement after expiry or loss, explicit close and natural exit.");
    }
} finally {
    clearTimeout(timeout);
    client.kill();
    await server.stop(true);
}
