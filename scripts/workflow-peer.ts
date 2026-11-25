// bun scripts/demo-peer.ts --workflow shell|vim|codex [--view [--driver]]
// Strict mode starts at the recorded grid and checks every input, reply and resize.
// View mode accepts a native grid, one changed size per recorded resize, and host-specific
// CPR/OSC replies. Screen and copy coordinates are comparable on the recorded grids.
// Driver mode adds a separate loopback HTTP listener for checkpoint acknowledgements.
// It compares the native pane against independent references at its actual grids.
import type { ServerWebSocket } from "bun";
import { setTimeout as delay } from "node:timers/promises";

const recordings = { shell: "shell-workflow", vim: "vim-resume", codex: "codex-session" } as const;
type Grid = { columns: number; rows: number };
type Event = {
    name: string; offsetMicroseconds: number; bytes?: string; input?: string; reply?: string;
    action?: { kind: string; value: string; modifiers?: string[] };
    replyOffsetMicroseconds?: number; resize?: Grid; checkpoint?: unknown;
    lifecycle?: { type: "ready" | "detach"; resumed?: boolean; clientId: string };
};
type Recording = Grid & { events: Event[] };
type Socket = ServerWebSocket<{ id: string; grid: Grid; run?: Run }>;
type Message = { kind: "stdin"; bytes: Buffer } | { kind: "resize"; grid: Grid } | { kind: "detach" | "resume" };
type Completion = { clientId: string; attachments: number };
type DriverPhase = "attaching" | "layout" | "playing" | "input" | "resize" | "detach" | "resume" | "checkpoint"
    | "close" | "completed" | "failed";
type DriverState = {
    phase: DriverPhase; eventIndex: number; name: string; outputBytes: number; attachments: number; grid: Grid;
    action?: Event["action"]; resize?: Grid; error?: string;
};
type NativeResize = Grid & { eventIndex: number; position: "before" | "after" };
const sameGrid = (a: Grid, b: Grid) => a.columns === b.columns && a.rows === b.rows;
const gridLabel = (g: Grid) => g.columns + "×" + g.rows;
const validGrid = (g: Grid) => Number.isSafeInteger(g.columns) && Number.isSafeInteger(g.rows)
    && g.columns >= 2 && g.rows >= 1;

// The HTTP driver acknowledges screenshots and settled layouts. Its resize claim
// must match the pane's real wire geometry. Input, replies and lifecycle stay on the socket.
class Driver {
    private gate?: ReturnType<typeof Promise.withResolvers<void>>;
    private checkpointJSON?: Promise<string>;
    readonly grids: Map<number, Grid>;
    private transitions: NativeResize[] = [];
    constructor(public state: DriverState) { this.grids = new Map([[-1, state.grid]]); }
    hold(phase: "layout" | "resize" | "checkpoint") {
        this.checkpointJSON = undefined;
        this.gate = Promise.withResolvers<void>();
        this.state.phase = phase;
        return this.gate.promise;
    }
    observeGrid(grid: Grid, position: NativeResize["position"]) {
        if (sameGrid(this.state.grid, grid)) return;
        this.state.grid = grid;
        if (this.state.eventIndex >= 0) this.transitions.push({ ...grid, eventIndex: this.state.eventIndex, position });
        this.checkpointJSON = undefined;
    }
    async checkpoint(index: number, fixture: Recording) {
        if (this.state.phase !== "checkpoint" || this.state.eventIndex !== index) return undefined;
        const gate = this.gate;
        if (!this.checkpointJSON) {
            const grids = new Map(this.grids), transitions = this.transitions.slice();
            this.checkpointJSON = import("./workflow-reference.mjs")
                .then(({ nativeCheckpoint }) => nativeCheckpoint(fixture, grids, index, transitions)).then(result => JSON.stringify(result));
        }
        const pending = this.checkpointJSON;
        const json = await pending;
        return this.gate === gate && this.checkpointJSON === pending ? json : undefined;
    }
    acknowledge(index: number) {
        if (this.state.phase !== "checkpoint" || this.state.eventIndex !== index) return false;
        this.release();
        return true;
    }
    settle(index: number, grid: Grid) {
        if ((this.state.phase !== "layout" && this.state.phase !== "resize") || this.state.eventIndex !== index
            || !sameGrid(this.state.grid, grid)) return false;
        this.grids.set(index, grid);
        delete this.state.resize;
        this.release();
        return true;
    }
    private release() {
        this.state.phase = "playing";
        this.gate!.resolve();
        this.gate = undefined;
        this.checkpointJSON = undefined;
    }
    fail(error: Error) {
        this.state = { ...this.state, phase: "failed", error: error.message };
        this.gate?.reject(error);
        this.gate = undefined;
        this.checkpointJSON = undefined;
    }
}

function initialState(grid: Grid): DriverState {
    return { phase: "attaching", eventIndex: -1, name: "", outputBytes: 0, attachments: 0,
        grid: { columns: grid.columns, rows: grid.rows } };
}

function serveDriver(port: number, drivers: Map<string, Driver>, fixtureFile: Bun.BunFile, fixture: Recording) {
    return Bun.serve({
        hostname: "127.0.0.1", port, maxRequestBodySize: 1024,
        async fetch(request) {
            const url = new URL(request.url);
            const origin = request.headers.get("Origin");
            if (!["localhost", "127.0.0.1"].includes(url.hostname) || (origin && origin !== url.origin))
                return new Response("Loopback control only", { status: 403 });
            const headers = { "Cache-Control": "no-store", "Content-Type": "application/json" };
            if (!["/state", "/ack", "/layout", "/checkpoint", "/fixture"].includes(url.pathname)) return new Response(null, { status: 404 });
            const method = url.pathname === "/ack" || url.pathname === "/layout" ? "POST" : "GET";
            if (request.method !== method) return new Response(null, { status: 405, headers: { Allow: method } });
            if (url.pathname === "/fixture") return new Response(fixtureFile, { headers });
            const id = url.searchParams.get("clientId");
            if (!id) return new Response("Missing clientId", { status: 400 });
            const driver = drivers.get(id);
            if (url.pathname === "/state") return Response.json(driver?.state ?? initialState(fixture), { headers });
            if (url.pathname === "/checkpoint") {
                const index = url.searchParams.get("eventIndex");
                if (!index || !/^\d+$/.test(index) || !Number.isSafeInteger(Number(index)))
                    return new Response("Expected a nonnegative eventIndex", { status: 400 });
                try {
                    const json = await driver?.checkpoint(Number(index), fixture);
                    return json === undefined ? new Response("No matching checkpoint is pending", { status: 409 })
                        : new Response(json, { headers });
                } catch (error) {
                    return new Response("Native checkpoint unavailable: " + String(error), { status: 500 });
                }
            }
            let data;
            try { data = await request.json(); } catch { return new Response("Invalid JSON", { status: 400 }); }
            if (url.pathname === "/layout") {
                if (!Number.isSafeInteger(data?.eventIndex) || data.eventIndex < -1 || !validGrid(data))
                    return new Response("Expected eventIndex, columns and rows", { status: 400 });
                return driver?.settle(data.eventIndex, { columns: data.columns, rows: data.rows })
                    ? new Response(null, { status: 204 }) : new Response("Layout does not match the wire", { status: 409 });
            }
            if (!Number.isSafeInteger(data?.eventIndex) || data.eventIndex < 0)
                return new Response("Expected a nonnegative eventIndex", { status: 400 });
            return driver?.acknowledge(data.eventIndex) ? new Response(null, { status: 204 })
                : new Response("No matching checkpoint is pending", { status: 409 });
        },
    });
}

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

// Strict checks use fixture bytes. In view mode only two terminal-generated
// answers can vary: a positive CPR bounded by the live grid, and the RGB
// digits of OSC 10/11. DA, mode replies, terminators and all user input stay exact.
async function match(bytes: Buffer, inbox: Inbox, grid: Grid, viewReply: boolean) {
    const expected = bytes.toString("latin1");
    const variable = /\x1b\[[1-9]\d*;[1-9]\d*R|\x1b\](?:10|11);rgb:[0-9a-f]{4}\/[0-9a-f]{4}\/[0-9a-f]{4}\x1b\\/igy;
    for (let i = 0; i < bytes.length;) {
        variable.lastIndex = i;
        const token = viewReply ? variable.exec(expected)?.[0] : undefined;
        if (token?.startsWith("\x1b[")) {
            let response = "";
            while (!response.endsWith("R")) {
                response += String.fromCharCode(await inbox.byte());
                if (response.length > 40 || (!"\x1b[".startsWith(response)
                    && !/^\x1b\[(?:[1-9]\d*(?:;(?:[1-9]\d*)?)?)?R?$/.test(response)))
                    throw Error("Malformed cursor-position reply");
            }
            const coordinates = /^\x1b\[([1-9]\d*);([1-9]\d*)R$/.exec(response);
            if (!coordinates || Number(coordinates[1]) > grid.rows || Number(coordinates[2]) > grid.columns)
                throw Error("Cursor-position reply outside " + gridLabel(grid));
            i += token.length;
        } else if (token) {
            const rgb = token.indexOf("rgb:") + 4;
            for (let j = 0; j < token.length; j++) {
                const ch = String.fromCharCode(await inbox.byte());
                const hex = j >= rgb && j < rgb + 14 && token[j] !== "/";
                if (hex ? !/^[\da-f]$/i.test(ch) : ch !== token[j]) throw Error("Malformed OSC color reply");
            }
            i += token.length;
        } else {
            const actual = await inbox.byte();
            if (actual !== bytes[i]) throw Error("Byte " + i + ": expected 0x" + bytes[i].toString(16)
                + ", received 0x" + actual.toString(16));
            i++;
        }
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
    private position: NativeResize["position"] = "before";

    constructor(private fixture: Recording, private view: boolean, private driver: Driver | undefined, socket: Socket,
                private finish: (result: Completion | Error) => void) {
        this.grid = socket.data.grid;
        this.socket = socket;
        socket.data.run = this;
    }
    start() {
        this.sendReady(false);
        void this.play().catch(error => this.fail(error));
    }
    resume(socket: Socket) {
        if ((this.phase !== "orphan" && this.phase !== "expectDetach") || (!this.driver && !sameGrid(this.grid, socket.data.grid)))
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
        if (this.driver) this.observeGrid(socket.data.grid);
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
                if (this.driver) this.driver.state.phase = "completed";
                this.finish({ clientId: socket.data.id, attachments: this.attachments });
                return;
            }
            const grid = { columns: control?.cols, rows: control?.rows };
            if (control?.type !== "resize" || !validGrid(grid)) throw Error("Expected valid resize or close control");
            if (this.driver) { this.observeGrid(grid); return; }
            this.inbox.push({ kind: "resize", grid });
        } else {
            this.inbox.push({ kind: "stdin", bytes: Buffer.from(data) });
        }
        if (this.phase === "done") throw Error("Unexpected input after final checkpoint");
    }
    private observeGrid(grid: Grid) {
        this.driver!.observeGrid(grid, this.position);
        this.grid = grid;
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
        this.driver?.fail(error);
        this.socket?.close(1002, "Workflow mismatch (see peer log)");
        this.finish(error);
    }
    private sendReady(resumed: boolean) {
        if (!this.socket || this.socket.sendText(JSON.stringify({ type: "ready", resumed })) === 0)
            throw Error("Could not send ready control");
    }
    private async play() {
        const events = this.fixture.events;
        const driver = this.driver;
        if (driver) {
            driver.state.attachments = 1;
            await driver.hold("layout");
        }
        let origin = performance.now() - events[0].offsetMicroseconds / 1000;
        for (const [index, event] of events.entries()) {
            this.at = event.name;
            this.position = "before";
            if (driver) driver.state = { phase: "playing", eventIndex: index, name: event.name,
                outputBytes: driver.state.outputBytes, attachments: this.attachments, grid: this.grid };
            const sync = (offset = event.offsetMicroseconds) => { origin = performance.now() - offset / 1000; };
            if (event.lifecycle?.type === "detach") {
                this.phase = "expectDetach";
                if (driver) driver.state.phase = "detach";
                console.log("Workflow waiting for detach and reattach with the same client ID");
                await this.inbox.control("detach");
                sync();
            } else if (event.lifecycle?.type === "ready") {
                if (driver) driver.state.phase = "resume";
                await this.inbox.control("resume");
                this.sendReady(true);
                this.position = "after";
                if (driver) driver.state.attachments = this.attachments;
                sync();
            }
            if (event.resize) {
                if (this.view) console.log(event.name + ": resize the view (recorded " + gridLabel(event.resize) + ")");
                if (driver) {
                    driver.state.resize = event.resize;
                    await driver.hold("resize");
                } else {
                    const message = await this.inbox.control("resize");
                    if (message.kind !== "resize" || (!this.view && !sameGrid(message.grid, event.resize))
                        || (this.view && sameGrid(message.grid, this.grid)))
                        throw Error("Expected resize to " + gridLabel(event.resize));
                    this.grid = message.grid;
                }
                sync();
            }
            if (event.bytes) {
                const wait = origin + event.offsetMicroseconds / 1000 - performance.now();
                if (wait >= 1) await delay(wait, undefined, { signal: this.abort.signal });
                const payload = Buffer.from(event.bytes, "base64");
                if (!this.socket || this.socket.sendBinary(payload) === 0)
                    throw Error("Could not send output");
                this.position = "after";
                if (driver) driver.state.outputBytes += payload.length;
            }
            if (event.reply) {
                await match(Buffer.from(event.reply, "base64"), this.inbox, this.grid, this.view);
                sync(event.replyOffsetMicroseconds);
            }
            if (event.input) {
                if (driver) Object.assign(driver.state, { phase: "input", action: event.action });
                if (this.view && event.action)
                    console.log(event.name + ": " + event.action.kind + " " + JSON.stringify(event.action.value));
                await match(Buffer.from(event.input, "base64"), this.inbox, this.grid, false);
                if (driver) { delete driver.state.action; driver.state.phase = "playing"; }
                sync();
            }
            // Checkpoints without wire data observe already-painted output. Their offsets can
            // include time spent inspecting the screen. Keep inter-output timing and skip this idle.
            if (event.checkpoint && driver) {
                this.position = "after";
                await driver.hold("checkpoint");
                sync(event.replyOffsetMicroseconds);
            } else if (event.checkpoint && !event.bytes && !event.input) sync();
        }
        if (this.inbox.pending) throw Error("Extra input after final checkpoint");
        this.phase = "done";
        if (driver) driver.state.phase = "close";
        console.log("Workflow complete for " + this.socket?.data.id + ". Waiting for explicit close.");
    }
}

/** Start one fixture per attaching client ID. A strict completion requires explicit close after the last output. */
export async function serveWorkflow(workflow: string, options: { port?: number; view?: boolean; driverPort?: number } = {}) {
    if (!Object.hasOwn(recordings, workflow)) throw Error("Expected shell, vim, or codex workflow");
    if (options.driverPort !== undefined && !options.view) throw Error("Driver mode requires --view");
    const name = recordings[workflow as keyof typeof recordings];
    const fixtureFile = Bun.file(new URL("../Fixtures/replays/" + name + ".json", import.meta.url));
    const fixture: Recording = await fixtureFile.json();
    const completed = Promise.withResolvers<Completion>();
    void completed.promise.catch(() => {}); // Standalone mode reports failures to stderr.
    const runs = new Map<string, Run>();
    const drivers = new Map<string, Driver>();
    const server = Bun.serve({
        hostname: "127.0.0.1", port: options.port ?? Number(process.env.THRUSH_PORT ?? 9138),
        fetch(request, server) {
            const url = new URL(request.url);
            const query = url.searchParams;
            const id = query.get("clientId");
            const grid = { columns: Number(query.get("cols")), rows: Number(query.get("rows")) };
            if (url.pathname !== "/socket" || query.get("service") !== "terminal" || !id || !validGrid(grid))
                return new Response("Expected terminal attachment with clientId, cols and rows", { status: 400 });
            if (drivers.has(id) && !runs.has(id)) return new Response("Use a fresh driver clientId", { status: 409 });
            if (!options.view && !runs.has(id) && !sameGrid(grid, fixture))
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
                const driver = options.driverPort === undefined ? undefined : new Driver(initialState(socket.data.grid));
                if (driver) drivers.set(id, driver);
                const run = new Run(fixture, !!options.view, driver, socket, result => {
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
    let driverServer;
    try {
        if (options.driverPort !== undefined) {
            driverServer = serveDriver(options.driverPort, drivers, fixtureFile, fixture);
            console.log("Thrush workflow driver listening at " + driverServer.url.origin);
        }
    } catch (error) {
        await server.stop(true);
        throw error;
    }
    return { server, driverServer, completed: completed.promise };
}
