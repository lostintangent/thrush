// Plays a recording to a WebSocket client at its recorded grid and checks every input, reply and resize
// the client sends. check-workflows.ts drives it with Apple's WebSocket client.
import type { ServerWebSocket } from "bun";
import { setTimeout as delay } from "node:timers/promises";

const recordings = { shell: "shell-workflow", vim: "vim-resume", codex: "codex-session" } as const;
type Grid = { columns: number; rows: number };
type Event = {
    name: string; offsetMicroseconds: number; bytes?: string; input?: string; reply?: string;
    replyOffsetMicroseconds?: number; resize?: Grid; checkpoint?: unknown;
    lifecycle?: { type: "ready" | "detach"; resumed?: boolean; clientId: string };
};
type Recording = Grid & { events: Event[] };
type Socket = ServerWebSocket<{ id: string; grid: Grid; run?: Run }>;
type Message = { kind: "stdin"; bytes: Buffer } | { kind: "resize"; grid: Grid } | { kind: "detach" | "resume" };
type Completion = { clientId: string; attachments: number };
const sameGrid = (a: Grid, b: Grid) => a.columns === b.columns && a.rows === b.rows;
const gridLabel = (g: Grid) => g.columns + "×" + g.rows;
const validGrid = (g: Grid) => Number.isSafeInteger(g.columns) && Number.isSafeInteger(g.rows)
    && g.columns >= 2 && g.rows >= 1;

// Socket frames are ordered. A host may split one semantic input over many binary
// frames, or deliver multiple keyboard/reply writes together. Controls cannot cut a byte sequence.
class Inbox {
    private queue: Message[] = [];
    private offset = 0;
    private bytes = 0;
    private wake?: () => void;
    private stopped = false;

    push(message: Message) {
        if (this.stopped) return;
        if (message.kind === "stdin") {
            if (!message.bytes.length) return;
            this.bytes += message.bytes.length;
        }
        if (this.bytes > 64 * 1024 || this.queue.length >= 1024) throw Error("Too much input ahead of the recording");
        this.queue.push(message);
        this.wake?.();
    }
    stop() { this.stopped = true; this.wake?.(); }
    get pending() { return this.queue.length > 0; }

    private async head(): Promise<Message> {
        while (!this.stopped && !this.queue.length) {
            await new Promise<void>(resolve => { this.wake = resolve; });
            this.wake = undefined;
        }
        if (this.stopped) throw Error("Attachment closed");
        return this.queue[0];
    }
    async byte(): Promise<number> {
        const message = await this.head();
        if (message.kind !== "stdin") throw Error("Expected binary input, received " + message.kind);
        const byte = message.bytes[this.offset++];
        this.bytes--;
        if (this.offset === message.bytes.length) { this.offset = 0; this.queue.shift(); }
        return byte;
    }
    async control(kind: "resize" | "detach" | "resume") {
        const message = await this.head();
        if (message.kind !== kind) throw Error("Expected " + kind + ", received " + message.kind);
        this.queue.shift();
        return message;
    }
}

async function match(bytes: Buffer, inbox: Inbox) {
    for (let i = 0; i < bytes.length; i++) {
        const actual = await inbox.byte();
        if (actual !== bytes[i]) throw Error("Byte " + i + ": expected 0x" + bytes[i].toString(16)
            + ", received 0x" + actual.toString(16));
    }
}

class Run {
    readonly inbox = new Inbox();
    private abort = new AbortController();
    private expiry?: ReturnType<typeof setTimeout>;
    private socket?: Socket;
    private phase: "attached" | "expectDetach" | "orphan" | "done" | "closed" = "attached";
    private attachments = 1;
    private at = "initial attachment";
    private grid: Grid;

    constructor(private fixture: Recording, socket: Socket, private finish: (result: Completion | Error) => void) {
        this.grid = socket.data.grid;
        this.socket = socket;
        socket.data.run = this;
    }
    start() {
        this.sendReady(false);
        void this.play().catch(error => this.fail(error));
    }
    resume(socket: Socket) {
        if ((this.phase !== "orphan" && this.phase !== "expectDetach") || !sameGrid(this.grid, socket.data.grid))
            throw Error("Expected an explicitly detached workflow at " + gridLabel(this.grid));
        if (this.phase === "expectDetach") {
            // URLSession cancellation can reach the peer after its replacement socket's
            // upgrade. Displace the old owner only at the recorded detach boundary.
            const displaced = this.socket;
            this.socket = undefined;
            this.inbox.push({ kind: "detach" });
            displaced?.close(4000, "replaced");
        }
        clearTimeout(this.expiry);
        this.socket = socket;
        socket.data.run = this;
        this.attachments++;
        this.phase = "attached";
        this.inbox.push({ kind: "resume" });
    }
    message(socket: Socket, data: string | Buffer) {
        if (socket !== this.socket || this.phase === "closed") return;
        if (typeof data === "string") {
            const control = JSON.parse(data);
            if (control?.type === "close") {
                if (this.phase !== "done") throw Error("Explicit close before the final checkpoint");
                this.phase = "closed";
                this.inbox.stop();
                socket.close(1000);
                this.finish({ clientId: socket.data.id, attachments: this.attachments });
                return;
            }
            const grid = { columns: control?.cols, rows: control?.rows };
            if (control?.type !== "resize" || !validGrid(grid)) throw Error("Expected valid resize or close control");
            this.inbox.push({ kind: "resize", grid });
        } else {
            this.inbox.push({ kind: "stdin", bytes: Buffer.from(data) });
        }
        if (this.phase === "done") throw Error("Unexpected input after final checkpoint");
    }
    disconnect(socket: Socket) {
        if (this.socket !== socket || this.phase === "closed") return;
        this.socket = undefined;
        if (this.phase !== "expectDetach") { this.fail(Error("Unexpected detach")); return; }
        this.phase = "orphan";
        this.inbox.push({ kind: "detach" });
        this.expiry = setTimeout(() => this.fail(Error("30-second reattach window expired")), 30_000);
    }
    fail(cause: unknown) {
        if (this.phase === "closed") return;
        const error = Error(this.at + ": " + (cause instanceof Error ? cause.message : String(cause)));
        this.phase = "closed";
        this.abort.abort();
        clearTimeout(this.expiry);
        this.inbox.stop();
        this.socket?.close(1002, "Workflow mismatch (see peer log)");
        this.finish(error);
    }
    private sendReady(resumed: boolean) {
        if (!this.socket || this.socket.sendText(JSON.stringify({ type: "ready", resumed })) === 0)
            throw Error("Could not send ready control");
    }
    private async play() {
        const events = this.fixture.events;
        let origin = performance.now() - events[0].offsetMicroseconds / 1000;
        for (const event of events) {
            this.at = event.name;
            const sync = (offset = event.offsetMicroseconds) => { origin = performance.now() - offset / 1000; };
            if (event.lifecycle?.type === "detach") {
                this.phase = "expectDetach";
                console.log("Workflow waiting for detach and reattach with the same client ID");
                await this.inbox.control("detach");
                sync();
            } else if (event.lifecycle?.type === "ready") {
                await this.inbox.control("resume");
                this.sendReady(true);
                sync();
            }
            if (event.resize) {
                const message = await this.inbox.control("resize");
                if (message.kind !== "resize" || !sameGrid(message.grid, event.resize))
                    throw Error("Expected resize to " + gridLabel(event.resize));
                this.grid = message.grid;
                sync();
            }
            if (event.bytes) {
                const wait = origin + event.offsetMicroseconds / 1000 - performance.now();
                if (wait >= 1) await delay(wait, undefined, { signal: this.abort.signal });
                if (!this.socket || this.socket.sendBinary(Buffer.from(event.bytes, "base64")) === 0)
                    throw Error("Could not send output");
            }
            if (event.reply) {
                await match(Buffer.from(event.reply, "base64"), this.inbox);
                sync(event.replyOffsetMicroseconds);
            }
            if (event.input) {
                await match(Buffer.from(event.input, "base64"), this.inbox);
                sync();
            }
            // Checkpoints without wire data observe already-painted output. Their offsets can
            // include time spent inspecting the screen. Keep inter-output timing and skip this idle.
            if (event.checkpoint && !event.bytes && !event.input) sync();
        }
        if (this.inbox.pending) throw Error("Extra input after final checkpoint");
        this.phase = "done";
        console.log("Workflow complete for " + this.socket?.data.id + ". Waiting for explicit close.");
    }
}

/** Start one fixture per attaching client ID, on a free loopback port. Completion requires explicit close after the last output. */
export async function serveWorkflow(workflow: string) {
    if (!Object.hasOwn(recordings, workflow)) throw Error("Expected shell, vim, or codex workflow");
    const name = recordings[workflow as keyof typeof recordings];
    const fixture: Recording = await Bun.file(new URL("../../Fixtures/recordings/" + name + ".json", import.meta.url)).json();
    const completed = Promise.withResolvers<Completion>();
    void completed.promise.catch(() => {}); // Each run also logs its failure to stderr.
    const runs = new Map<string, Run>();
    const server = Bun.serve({
        hostname: "127.0.0.1", port: 0,
        fetch(request, server) {
            const url = new URL(request.url);
            const query = url.searchParams;
            const id = query.get("clientId");
            const grid = { columns: Number(query.get("cols")), rows: Number(query.get("rows")) };
            if (url.pathname !== "/socket" || query.get("service") !== "terminal" || !id || !validGrid(grid))
                return new Response("Expected terminal attachment with clientId, cols and rows", { status: 400 });
            if (!runs.has(id) && !sameGrid(grid, fixture))
                return new Response("Start this workflow at " + gridLabel(fixture), { status: 400 });
            if (!server.upgrade(request, { data: { id, grid } })) return new Response("WebSocket required", { status: 426 });
        },
        websocket: {
            data: {} as Socket["data"],
            idleTimeout: 0,
            maxPayloadLength: 64 * 1024,
            open(socket) {
                const id = socket.data.id;
                const existing = runs.get(id);
                if (existing) {
                    try { existing.resume(socket); }
                    catch (error) { console.error(error); socket.close(1008, "Unexpected reattachment"); }
                    return;
                }
                const run = new Run(fixture, socket, result => {
                    runs.delete(id);
                    if (result instanceof Error) { console.error(name + " / " + id + ": " + result.message); completed.reject(result); }
                    else completed.resolve(result);
                });
                runs.set(id, run);
                try { run.start(); } catch (error) { run.fail(error); }
            },
            message(socket, data) {
                const run = socket.data.run;
                try { run?.message(socket, data); } catch (error) { run?.fail(error); }
            },
            close(socket) { socket.data.run?.disconnect(socket); },
        },
    });
    return { server, completed: completed.promise };
}
