import { expect, test } from "bun:test";
import { serveWorkflow } from "./workflow-peer";

function client(base: URL, columns: number, rows: number) {
    const url = new URL("/socket", base);
    url.protocol = "ws:";
    url.search = new URLSearchParams({
        service: "terminal", clientId: "fixture client", cols: String(columns), rows: String(rows),
    }).toString();
    const socket = new WebSocket(url);
    socket.binaryType = "arraybuffer";
    let received = 0;
    const messages = new ReadableStream<string | ArrayBuffer>({
        start(controller) {
            socket.onmessage = event => { received++; controller.enqueue(event.data); };
            socket.onclose = () => controller.close();
        },
    }).getReader();
    async function next() {
        const { value, done } = await messages.read();
        if (done) throw Error("Socket closed before the expected frame");
        return value;
    }
    return { socket, next, get received() { return received; } };
}

test("shell keeps output frames intact when stdin spans multiple recorded key events", async () => {
    const fixture = await Bun.file(new URL("../Fixtures/replays/shell-workflow.json", import.meta.url)).json();
    const { server, completed } = await serveWorkflow("shell", { port: 0 });
    const { socket, next } = client(server.url, fixture.columns, fixture.rows);
    try {
        expect(JSON.parse(await next() as string)).toEqual({ type: "ready", resumed: false });
        const input = Buffer.concat(fixture.events.filter((e: {input?: string}) => e.input)
            .map((e: {input: string}) => Buffer.from(e.input, "base64")));
        for (const event of fixture.events) {
            if (event.resize) {
                socket.send(JSON.stringify({ type: "resize", cols: event.resize.columns, rows: event.resize.rows }));
                // Split one key sequence, then coalesce every remaining action into one socket write.
                socket.send(input.subarray(0, 2));
                socket.send(input.subarray(2));
            }
            if (event.bytes) {
                const frame = await next();
                expect(typeof frame).not.toBe("string");
                expect(Buffer.from(frame as ArrayBuffer).equals(Buffer.from(event.bytes, "base64"))).toBe(true);
            }
        }
        socket.send(JSON.stringify({ type: "close" }));
        expect(await completed).toEqual({ clientId: "fixture client", attachments: 1 });
    } finally {
        socket.close();
        await server.stop(true);
    }
}, 20_000);

test("out-of-order stdin fails at the resize gate", async () => {
    const { server, completed } = await serveWorkflow("shell", { port: 0 });
    const { socket, next } = client(server.url, 80, 24);
    try {
        await next();
        await next();
        socket.send(Buffer.from("./builx"));
        await expect(completed).rejects.toThrow("Expected resize, received stdin");
    } finally {
        socket.close();
        await server.stop(true);
    }
});

test("immediate same-ID reconnect at the detach boundary ignores the displaced socket's close", async () => {
    const fixture = await Bun.file(new URL("../Fixtures/replays/vim-resume.json", import.meta.url)).json();
    const { server, completed } = await serveWorkflow("vim", { port: 0 });
    let connection = client(server.url, fixture.columns, fixture.rows);
    const original = connection.socket;
    let replacements = 0;
    try {
        expect(JSON.parse(await connection.next() as string)).toEqual({ type: "ready", resumed: false });
        for (const event of fixture.events) {
            if (event.lifecycle?.type === "ready") {
                // The new upgrade arrives while the original socket is still open.
                connection = client(server.url, 80, 24);
                expect(JSON.parse(await connection.next() as string)).toEqual({ type: "ready", resumed: true });
                replacements++;
            }
            if (event.resize) connection.socket.send(JSON.stringify({ type: "resize", cols: event.resize.columns,
                                                                      rows: event.resize.rows }));
            if (event.input) connection.socket.send(Buffer.from(event.input, "base64"));
            if (event.bytes) {
                const frame = await connection.next();
                expect(Buffer.from(frame as ArrayBuffer).equals(Buffer.from(event.bytes, "base64"))).toBe(true);
            }
            if (event.reply) connection.socket.send(Buffer.from(event.reply, "base64"));
        }
        connection.socket.send(JSON.stringify({ type: "close" }));
        expect(replacements).toBe(1);
        expect((await completed).attachments).toBe(2);
    } finally {
        original.close();
        connection.socket.close();
        await server.stop(true);
    }
}, 10_000);

test("view mode drops the pane's focus reports and rejects a fragmented out-of-grid CPR", async () => {
    const fixture = await Bun.file(new URL("../Fixtures/replays/vim-resume.json", import.meta.url)).json();
    const { server, completed } = await serveWorkflow("vim", { port: 0, view: true });
    const { socket, next } = client(server.url, 81, 25);
    try {
        await next();
        for (const event of fixture.events) {
            if (event.input) socket.send(Buffer.from(event.input, "base64"));
            if (event.bytes) await next();
            if (event.reply === Buffer.from("\x1b[O").toString("base64")) {
                // A focused pane answers Vim's request, then loses focus before the next key.
                socket.send(Buffer.from("\x1b[I"));
                socket.send(Buffer.from("\x1b[O"));
            } else if (event.reply) {
                socket.send(Buffer.from("\x1b["));
                socket.send(Buffer.from("26;1R"));
                break;
            }
        }
        await expect(completed).rejects.toThrow("Cursor-position reply outside 81×25");
    } finally {
        socket.close();
        await server.stop(true);
    }
});

function control(origin: URL) {
    const url = (path: string) => {
        const endpoint = new URL(path, origin);
        endpoint.searchParams.set("clientId", "fixture client");
        return endpoint;
    };
    const state = async () => (await fetch(url("/state"), { cache: "no-store" })).json();
    async function wait(phase: string, index?: number) {
        const deadline = performance.now() + 5_000;
        let value;
        do {
            value = await state();
            if (value.phase === phase && (index === undefined || value.eventIndex === index)) return value;
            if (value.phase === "failed") throw Error(value.error);
            await Bun.sleep(5);
        } while (performance.now() < deadline);
        throw Error("Expected " + phase + " at " + index + ", received " + JSON.stringify(value));
    }
    async function ack(eventIndex: number) {
        const response = await fetch(url("/ack"), { method: "POST", body: JSON.stringify({ eventIndex }) });
        return response.status;
    }
    function checkpoint(eventIndex: number) {
        const endpoint = url("/checkpoint");
        endpoint.searchParams.set("eventIndex", String(eventIndex));
        return fetch(endpoint);
    }
    async function layout(eventIndex: number, grid: {columns: number; rows: number}) {
        return (await fetch(url("/layout"), { method: "POST", body: JSON.stringify({eventIndex, ...grid}) })).status;
    }
    async function observed(grid: {columns: number; rows: number}) {
        const deadline = performance.now() + 1000;
        do {
            const step = await state();
            if (step.grid.columns === grid.columns && step.grid.rows === grid.rows) return step;
            await Bun.sleep(3);
        } while (performance.now() < deadline);
        throw Error("Peer never received wire geometry " + JSON.stringify(grid));
    }
    return { state, wait, ack, checkpoint, layout, observed };
}

for (const [workflow, native] of ["shell", "vim", "codex"].flatMap(name => [[name, false], [name, true]] as const)) {
    const grids = native ? " on the pane's own grids" : " on the recorded grid";
    test("native driver gates " + workflow + " after every recorded checkpoint" + grids, async () => {
        const { server, driverServer, completed } = await serveWorkflow(workflow, { port: 0, view: true, driverPort: 0 });
        const driver = control(driverServer!.url);
        const fixture = await (await fetch(new URL("/fixture", driverServer!.url))).json();
        const initial = { columns: fixture.columns, rows: fixture.rows };
        let grid = native ? { columns: 47, rows: 42 } : initial;
        let count = 0;
        let attachments = 1;
        let replaced = false;
        expect(await driver.state()).toEqual({ phase: "attaching", eventIndex: -1, name: "", grid: initial, outputBytes: 0, attachments: 0 });
        expect(await driver.ack(1)).toBe(409);
        let peer = client(server.url, grid.columns, grid.rows);
        try {
            expect(JSON.parse(await peer.next() as string)).toEqual({ type: "ready", resumed: false });
            await driver.wait("layout", -1);
            expect(await driver.layout(-1, grid)).toBe(204);
            for (const [index, event] of fixture.events.entries()) {
                if (event.lifecycle?.type === "detach") {
                    await driver.wait("detach", index);
                    if (native) {
                        // A replacement attachment can arrive before URLSession delivers
                        // the old socket's close. It can also come back at a different size.
                        grid = { columns: 49, rows: 26 };
                        peer = client(server.url, grid.columns, grid.rows);
                        replaced = true;
                    } else peer.socket.close();
                }
                if (event.lifecycle?.type === "ready") {
                    if (!replaced) {
                        await driver.wait("resume", index);
                        peer = client(server.url, grid.columns, grid.rows);
                    }
                    expect(JSON.parse(await peer.next() as string)).toEqual({ type: "ready", resumed: true });
                    attachments++;
                }
                if (event.resize) {
                    const step = await driver.wait("resize", index);
                    expect(step.resize).toEqual(event.resize);
                    expect(step.grid).toEqual(grid);
                    if (native) {
                        const intermediate = { columns: grid.columns - 3, rows: grid.rows + 1 };
                        peer.socket.send(JSON.stringify({ type: "resize", cols: intermediate.columns, rows: intermediate.rows }));
                        expect((await driver.observed(intermediate)).phase).toBe("resize");
                        expect(await driver.layout(index, grid)).toBe(409);
                    }
                    grid = native && workflow === "vim" ? (grid.columns === 47 ? { columns: 90, rows: 18 }
                        : { columns: 47, rows: 25 }) : event.resize;
                    peer.socket.send(JSON.stringify({ type: "resize", cols: grid.columns, rows: grid.rows }));
                    await driver.observed(grid);
                    expect(await driver.layout(index, grid)).toBe(204);
                }
                if (event.input) {
                    expect((await driver.wait("input", index)).action).toEqual(event.action);
                    peer.socket.send(Buffer.from(event.input, "base64"));
                }
                if (event.bytes) {
                    const payload = Buffer.from(await peer.next() as ArrayBuffer);
                    expect(payload).toEqual(Buffer.from(event.bytes, "base64"));
                    count += payload.length;
                }
                if (event.reply) {
                    const reply = Buffer.from(event.reply, "base64").toString("latin1");
                    // A host can use its configured palette when responding to OSC.
                    peer.socket.send(Buffer.from(reply.replace(/rgb:[\da-f]{4}\/[\da-f]{4}\/[\da-f]{4}/gi,
                        "rgb:1122/3344/5566"), "latin1"));
                }
                if (event.checkpoint) {
                    const step = await driver.wait("checkpoint", index);
                    expect(step).toEqual({ phase: "checkpoint", name: event.name, eventIndex: index,
                        outputBytes: count, attachments, grid });
                    if (event.name === "Vim resumed ready" || event.checkpoint.synchronizedOutput) {
                        const received = peer.received;
                        await Bun.sleep(35);
                        expect(peer.received).toBe(received);
                        expect(await driver.state()).toEqual(step);
                    }
                    const [first, second] = await Promise.all([driver.checkpoint(index), driver.checkpoint(index)]);
                    expect(first.status).toBe(200);
                    const body = await first.text();
                    expect(await second.text()).toBe(body);
                    const projection = JSON.parse(body).events;
                    expect(projection.length).toBe(1);
                    const projected = projection[0];
                    expect(projected.name).toBe(event.name);
                    expect(projected.checkpoint.columns).toBe(grid.columns);
                    expect(projected.checkpoint.rows).toBe(grid.rows);
                    expect(projected.checkpoint.synchronizedOutput).toBe(event.checkpoint.synchronizedOutput);
                    if (event.copy) expect(projected.copy.text).toBe(event.copy.text);
                    if (!native) expect(projected).toEqual(event);
                    expect(await driver.ack(index + 1)).toBe(409);
                    expect((await Promise.all([driver.ack(index), driver.ack(index)])).sort()).toEqual([204, 409]);
                }
            }
            await driver.wait("close");
            peer.socket.send(JSON.stringify({ type: "close" }));
            expect(await completed).toEqual({ clientId: "fixture client", attachments });
            expect((await driver.state()).phase).toBe("completed");
        } finally {
            peer.socket.close();
            await server.stop(true);
            await driverServer!.stop(true);
        }
    }, 60_000);
}

test("driver control is isolated from the wire and records native grids even on a same-size resize", async () => {
    const { server, driverServer, completed } = await serveWorkflow("shell", { port: 0, view: true, driverPort: 0 });
    const driver = control(driverServer!.url);
    const noDriver = await serveWorkflow("shell", { port: 0, view: true });
    try {
        expect(noDriver.driverServer).toBeUndefined();
        expect((await fetch(new URL("/fixture", server.url))).ok).toBe(false);
        expect((await fetch(new URL("/socket", driverServer!.url))).status).toBe(404);
        expect((await fetch(new URL("/fixture", driverServer!.url), { method: "POST" })).status).toBe(405);
        expect((await fetch(new URL("/ack", driverServer!.url))).headers.get("Allow")).toBe("POST");
        expect((await fetch(new URL("/fixture", driverServer!.url), { headers: { Origin: "http://unrelated.example" } })).status).toBe(403);
        expect((await driver.checkpoint(1)).status).toBe(409);
        const peer = client(server.url, 43, 28);
        await peer.next();
        const layout = await driver.wait("layout", -1);
        expect(layout.outputBytes).toBe(0);
        for (const grid of [{ columns: 45, rows: 29 }, { columns: 44, rows: 27 }]) {
            peer.socket.send(JSON.stringify({ type: "resize", cols: grid.columns, rows: grid.rows }));
            expect((await driver.observed(grid)).phase).toBe("layout");
        }
        expect(await driver.layout(-1, { columns: 43, rows: 28 })).toBe(409);
        expect(peer.received).toBe(1);
        const actual = { columns: 44, rows: 27 };
        expect(await driver.layout(-1, actual)).toBe(204);
        const prompt = await driver.wait("checkpoint");
        expect(prompt.grid).toEqual(actual);
        await driver.ack(prompt.eventIndex);
        const resize = await driver.wait("resize");
        expect(await driver.ack(resize.eventIndex)).toBe(409);
        expect(await driver.layout(resize.eventIndex, actual)).toBe(204); // No duplicate wire resize.
        const resized = await driver.wait("checkpoint");
        expect(resized.grid).toEqual(prompt.grid);
        expect((await driver.checkpoint(prompt.eventIndex)).status).toBe(409);
        const response = await driver.checkpoint(resized.eventIndex);
        expect(response.status).toBe(200);
        const native = await response.json();
        expect(native.events.length).toBe(1);
        expect(native.events[0].name).toBe(resized.name);
        expect(native.events[0].checkpoint.columns).toBe(actual.columns);
        expect(native.events[0].checkpoint.rows).toBe(actual.rows);
        // UIKit can resize after a checkpoint starts. It invalidates the cached oracle.
        const next = { columns: 42, rows: 30 };
        peer.socket.send(JSON.stringify({ type: "resize", cols: next.columns, rows: next.rows }));
        expect((await driver.observed(next)).phase).toBe("checkpoint");
        const updated = await (await driver.checkpoint(resized.eventIndex)).json();
        expect(updated.events[0].checkpoint.columns).toBe(next.columns);
        expect(updated.events[0].checkpoint.rows).toBe(next.rows);
        expect((await driver.state()).phase).toBe("checkpoint");
        peer.socket.close();
        await expect(completed).rejects.toThrow("Unexpected detach");
        expect((await driver.state()).phase).toBe("failed");
    } finally {
        await server.stop(true);
        await driverServer!.stop(true);
        await noDriver.server.stop(true);
    }
});
