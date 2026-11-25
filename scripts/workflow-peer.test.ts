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
    const messages = new ReadableStream<string | ArrayBuffer>({
        start(controller) {
            socket.onmessage = event => controller.enqueue(event.data);
            socket.onclose = () => controller.close();
        },
    }).getReader();
    async function next() {
        const { value, done } = await messages.read();
        if (done) throw Error("Socket closed before the expected frame");
        return value;
    }
    return { socket, next };
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

test("view mode rejects a fragmented out-of-grid CPR", async () => {
    const fixture = await Bun.file(new URL("../Fixtures/replays/vim-resume.json", import.meta.url)).json();
    const { server, completed } = await serveWorkflow("vim", { port: 0, view: true });
    const { socket, next } = client(server.url, 81, 25);
    try {
        await next();
        for (const event of fixture.events) {
            if (event.input) socket.send(Buffer.from(event.input, "base64"));
            if (event.bytes) await next();
            if (event.reply) {
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
