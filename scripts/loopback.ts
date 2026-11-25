// bun scripts/loopback.ts --serve replays the fixture for a host running on this Mac.
// scripts/check-loopback.sh also starts a platform client and verifies the complete wire exchange.
import assert from "node:assert/strict";
import type { ServerWebSocket } from "bun";
import fixture from "../Fixtures/first-bytes.json";

type Session = {
    closeOnly: boolean;
    received: number;
    complete: boolean;
};

const command = process.argv[2];
if (process.argv.length !== 3) {
    throw new Error("Usage: bun scripts/loopback.ts --serve | PATH_TO_CHECK_EXECUTABLE");
}
const standalone = command === "--serve";
const expectedInput = fixture.events.flatMap(event => {
    const messages = [];
    if (event.reply.length) messages.push(event.reply);
    if (event.up) messages.push(event.up);
    return messages;
});
const finished = Promise.withResolvers<void>();
let attachmentCount = 0;
let fixturesAccepted = 0;
let closesAccepted = 0;

function fail(reason: unknown) {
    if (standalone) console.error(reason);
    else finished.reject(reason);
}

async function replay(socket: ServerWebSocket<Session>) {
    const start = performance.now();
    for (const event of fixture.events) {
        const remaining = start + event.offsetMicroseconds / 1_000 - performance.now();
        if (remaining >= 1) await Bun.sleep(remaining);
        assert(socket.sendBinary(Uint8Array.from(event.bytes)) > 0, "Fixture frame failed to send");
    }
}

const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch(request, server) {
        try {
            const url = new URL(request.url);
            assert.equal(url.pathname, "/socket");
            const items = url.searchParams;
            assert.deepEqual([...items.keys()].sort(), ["clientId", "cols", "rows", "service"]);
            assert.equal(items.get("service"), "terminal");
            assert.equal(items.get("cols"), String(fixture.columns));
            assert.equal(items.get("rows"), String(fixture.rows));
            assert(items.get("clientId"));
            if (!standalone) {
                assert.equal(items.get("clientId"), "thrush + check");
                assert(attachmentCount < 2, "Unexpected extra attachment");
                if (attachmentCount === 1) assert.equal(fixturesAccepted, 1);
            }
            const closeOnly = !standalone && attachmentCount === 1;
            if (!server.upgrade(request, { data: { closeOnly, received: 0, complete: false } })) {
                throw new Error("Expected a WebSocket upgrade");
            }
            attachmentCount++;
        } catch (error) {
            fail(error);
            return new Response("Unexpected terminal attachment", { status: 400 });
        }
    },
    websocket: {
        data: {} as Session,
        open(socket) {
            socket.sendText(JSON.stringify({ type: "ready", resumed: false }));
            if (!socket.data.closeOnly) void replay(socket).catch(fail);
        },
        message(socket, message) {
            try {
                const state = socket.data;
                assert(!state.complete, "Unexpected frame after session completion");
                if (state.closeOnly) {
                    assert.equal(typeof message, "string", "Expected text close control");
                    assert.deepEqual(JSON.parse(message as string), { type: "close" });
                    state.complete = true;
                    closesAccepted++;
                    socket.close(1000);
                    finished.resolve();
                } else if (state.received < expectedInput.length) {
                    assert(typeof message !== "string", "Expected binary stdin");
                    assert.deepEqual([...message], expectedInput[state.received], "Wrong bytes at outbound frame " + state.received);
                    state.received++;
                } else {
                    assert.equal(typeof message, "string", "Expected text resize control");
                    assert.deepEqual(JSON.parse(message as string), {
                        type: "resize", cols: fixture.columns + 1, rows: fixture.rows + 1,
                    });
                    state.complete = true;
                    fixturesAccepted++;
                    socket.sendText(JSON.stringify({ type: "exit" }));
                }
            } catch (error) {
                fail(error);
                socket.close(1002, "unexpected frame");
            }
        },
        close(socket) {
            if (!socket.data.complete) fail(new Error("Client disconnected before its last expected frame"));
        },
    },
});

if (standalone) {
    console.log("Listening at " + server.url.origin);
} else {
    const client = Bun.spawn([command, server.url.origin], { stdout: "inherit", stderr: "inherit" });
    const timeout = setTimeout(() => fail(new Error("Timed out waiting for the loopback exchange")), 15_000);
    try {
        // Both sides must finish: client exit alone does not prove its last write reached the peer.
        await Promise.all([finished.promise, client.exited.then(code => assert.equal(code, 0, "Swift client failed"))]);
        assert.equal(fixturesAccepted, 1);
        assert.equal(closesAccepted, 1);
        console.log("Loopback passed: " + fixture.events.length + " output chunks, " + expectedInput.length
            + " ordered binary writes, fresh ready, resize, exit, reattach and explicit close.");
    } finally {
        clearTimeout(timeout);
        client.kill();
        await server.stop(true);
    }
}
