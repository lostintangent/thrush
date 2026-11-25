import assert from "node:assert/strict";
import type { ServerWebSocket } from "bun";
import { openReference, referenceDocument, observeBackgrounds } from "./reference.mjs";

export type Grid = { columns: number; rows: number };
export type WorkflowEvent = {
    name: string; offsetMicroseconds: number; checkpoint?: unknown;
    action?: { kind: string; value: string; modifiers?: string[] }; input?: string;
    resize?: Grid; lifecycle?: { type: string }; copy?: { text: string };
};
export type Recording = Grid & { name: string; events: WorkflowEvent[]; [key: string]: unknown };
export type Phase = "attaching" | "layout" | "playing" | "input" | "resize" | "detach" | "resume" | "checkpoint"
    | "close" | "completed" | "failed" | "useHere" | "newShell" | "focus";
type Downstream = ServerWebSocket<{url: string; grid: Grid}>;
type Link = { app: Downstream; server: WebSocket; number: number; open: boolean; grid: Grid };
type Frame = { link: Link; data: string | Uint8Array };
type Closure = { side: "upstream" | "client"; code: number; atMs: number; attachment: number };
const same = (a: Grid, b: Grid) => a.columns === b.columns && a.rows === b.rows;
const replies = /^(?:\x1b\[(?:[?>]?[\d;$]*[cRy]|[IO])|\x1b\](?:4;\d+|10|11);rgb:[\da-f/]+(?:\x07|\x1b\\))+$/i;

export class LiveRun {
    readonly clientID = "thrush-native-workflow";
    readonly ready: boolean[] = [];
    readonly sgrBackgrounds = new Map<string, number>();
    readonly osc11Replies = new Set<string>();
    readonly perAttachment: { number: number; upstreamBytes: number; forwardedBytes: number; replayBytes: number; liveBytes: number }[] = [];
    readonly closures: Closure[] = [];
    readonly evidence: Record<string, unknown> = {};
    readonly acknowledgements: Record<string, unknown>[] = [];
    beforeComplete?: () => Promise<void>;
    attachments = 0;
    exits = 0;
    explicitCloses = 0;
    inputBytes = 0;
    outputBytes = 0;
    grid: Grid;
    reference: ReturnType<typeof openReference>;
    readonly wire = { upstreamBinaryFrames: 0, upstreamBinaryBytes: 0, forwardedBinaryFrames: 0,
        forwardedBinaryBytes: 0, replayFrames: 0, replayBytes: 0, synchronizedIntermediateFrames: 0,
        upstreamControls: 0, forwardedControls: 0, clientBinaryFrames: 0, clientControls: 0 };
    state: { phase: Phase; eventIndex: number; name: string; error?: string; capture?: boolean } =
        { phase: "attaching", eventIndex: -1, name: "" };
    failure?: Error;
    private active?: Link;
    private frames: Frame[] = [];
    private forwarding?: Link;
    private queuedBytes = 0;
    private lastOutputAt = 0;
    private wake?: () => void;
    private expectedInput?: Buffer;
    private pendingReference?: ReturnType<typeof referenceDocument>;
    private accepted = false;
    private replayNext = false;

    constructor(readonly fixture: Recording, readonly upstream: URL, readonly work: string) {
        this.grid = { columns: fixture.columns, rows: fixture.rows };
        this.reference = openReference(this.grid);
    }
    get downstreamOpen() { return this.active?.open === true; }
    get lastCloseCode() { return this.closures.at(-1)?.code; }
    get driverState() { return { ...this.state, outputBytes: this.outputBytes, attachments: this.attachments, grid: this.grid }; }
    phase(phase: Phase, index: number) {
        this.accepted = false;
        this.pendingReference = undefined;
        this.state = { phase, eventIndex: index, name: this.fixture.events[index]?.name ?? "" };
    }
    fail(reason: unknown) {
        if (this.failure) return;
        this.failure = reason instanceof Error ? reason : Error(String(reason));
        this.state = { ...this.state, phase: "failed", error: this.failure.message };
        this.wake?.();
    }

    attach(app: Downstream) {
        assert(!this.downstreamOpen, "Unexpected second native owner");
        const url = new URL(app.data.url, this.upstream);
        url.protocol = this.upstream.protocol === "https:" ? "wss:" : "ws:";
        const server = new WebSocket(url);
        server.binaryType = "arraybuffer";
        const link = { app, server, number: ++this.attachments, open: true, grid: app.data.grid };
        this.active = link;
        const totals = { number: link.number, upstreamBytes: 0, forwardedBytes: 0, replayBytes: 0, liveBytes: 0 };
        this.perAttachment.push(totals);
        this.grid = app.data.grid;
        server.onmessage = ({ data }) => {
            this.lastOutputAt = performance.now();
            const raw = typeof data === "string" ? data : new Uint8Array(data);
            if (typeof raw === "string") this.wire.upstreamControls++;
            else { this.wire.upstreamBinaryFrames++; this.wire.upstreamBinaryBytes += raw.byteLength; totals.upstreamBytes += raw.byteLength; }
            if (!link.open) return;
            this.queuedBytes += typeof raw === "string" ? Buffer.byteLength(raw) : raw.byteLength;
            if (this.queuedBytes > 8 * 1024 * 1024 || this.frames.length >= 4096) {
                this.fail(Error("Native checkpoint held more than 8 MiB or 4096 upstream frames"));
                return;
            }
            this.frames.push({ link, data: raw });
            this.wake?.();
        };
        server.onerror = () => this.fail(Error("Could not connect to the disposable terminal at " + this.upstream.origin));
        server.onclose = ({ code, reason }) => {
            this.closures.push({ side: "upstream", code, atMs: performance.now(), attachment: link.number });
            // Preserve any final data and exit control already queued by this upstream.
            this.flushClose(link, code, reason);
            this.wake?.();
        };
        this.wake?.();
    }
    private pendingClose = new Map<Link, { code: number; reason: string }>();
    private flushClose(link: Link, code: number, reason: string) {
        if (!link.open) return;
        if (this.forwarding === link || this.frames.some(frame => frame.link === link)) this.pendingClose.set(link, { code, reason });
        else {
            this.pendingClose.delete(link);
            if (code === 1006) link.app.terminate();
            else link.app.close(code === 1005 ? undefined : code, reason);
        }
    }
    disconnect(app: Downstream, code: number, reason: string) {
        const link = this.active;
        if (!link || link.app !== app) return;
        link.open = false;
        this.closures.push({ side: "client", code, atMs: performance.now(), attachment: link.number });
        this.pendingClose.delete(link);
        if (link.server.readyState < WebSocket.CLOSING) link.server.close(code === 1005 || code === 1006 ? undefined : code, reason);
        this.wake?.();
    }
    clientMessage(app: Downstream, raw: string | Buffer) {
        const link = this.active;
        assert(link?.open && link.app === app && link.server.readyState === WebSocket.OPEN, "Input without an open upstream");
        if (typeof raw === "string") {
            const control = JSON.parse(raw);
            if (control.type === "resize") {
                this.grid = { columns: control.cols, rows: control.rows };
                this.reference.resize(control.cols, control.rows);
            } else if (control.type === "close") this.explicitCloses++;
            else throw Error("Unknown terminal control " + control.type);
            this.wire.clientControls++;
        } else {
            this.inputBytes += raw.byteLength;
            this.wire.clientBinaryFrames++;
            for (const match of raw.toString("latin1").matchAll(/\x1b\]11;rgb:[0-9a-f/]+(?:\x07|\x1b\\)/gi)) this.osc11Replies.add(match[0]);
            const pending = this.expectedInput;
            if (pending && raw.length <= pending.length && raw.equals(pending.subarray(0, raw.length))) {
                this.expectedInput = raw.length < pending.length ? pending.subarray(raw.length) : undefined;
            } else if (!replies.test(raw.toString("latin1"))) {
                throw Error("Unexpected stdin during " + this.state.phase + " at " + this.state.name + ": " + raw.toString("hex").slice(0, 160));
            }
        }
        link.server.send(typeof raw === "string" ? raw : new Uint8Array(raw));
        this.wake?.();
    }
    private async forward(frame: Frame) {
        const { data, link } = frame;
        this.forwarding = link;
        this.queuedBytes -= typeof data === "string" ? Buffer.byteLength(data) : data.byteLength;
        assert(link.open && this.active === link, "A native attachment detached with undelivered upstream frames");
        if (typeof data === "string") {
            const control = JSON.parse(data);
            if (control.type === "ready") {
                assert(typeof control.resumed === "boolean");
                this.ready.push(control.resumed);
                this.reference.dispose();
                this.reference = openReference(this.grid);
                observeBackgrounds(this.reference, this.sgrBackgrounds);
                this.replayNext = control.resumed;
            } else if (control.type === "exit") this.exits++;
            else throw Error("Unknown upstream control " + control.type);
            assert(link.app.sendText(data) !== 0, "Native control socket closed");
            this.wire.forwardedControls++;
        } else {
            await new Promise<void>(done => this.reference.write(data, done));
            assert(link.app.sendBinary(data) !== 0, "Native output socket closed");
            const totals = this.perAttachment[link.number - 1];
            totals.forwardedBytes += data.byteLength;
            if (this.replayNext) totals.replayBytes += data.byteLength;
            else totals.liveBytes += data.byteLength;
            this.outputBytes += data.byteLength;
            this.wire.forwardedBinaryBytes += data.byteLength;
            this.wire.forwardedBinaryFrames++;
            if (this.replayNext) {
                this.wire.replayFrames++;
                this.wire.replayBytes += data.byteLength;
                this.replayNext = false;
            }
            if (this.reference.modes.synchronizedOutputMode) this.wire.synchronizedIntermediateFrames++;
        }
        this.forwarding = undefined;
        const closing = this.pendingClose.get(link);
        if (closing) this.flushClose(link, closing.code, closing.reason);
    }

    async until(test: () => boolean, description: string, timeoutMs = 40_000, forward = true) {
        const deadline = performance.now() + timeoutMs;
        while (true) {
            if (this.failure) throw this.failure;
            if (test()) return;
            const left = deadline - performance.now();
            if (left <= 0) throw Error("Timed out waiting for " + description + " at " + this.state.name);
            const frame = forward ? this.frames.shift() : undefined;
            if (frame) { await this.forward(frame); continue; }
            await new Promise<void>(resolve => {
                const timer = setTimeout(resolve, Math.min(left, 100));
                this.wake = () => { clearTimeout(timer); resolve(); };
            });
            this.wake = undefined;
        }
    }
    // A real Vim resize can return from the host layout before SIGWINCH redraws the PTY.
    // Drain that burst before exposing the checkpoint or instructing the pane to detach.
    async settleOutput(description: string) {
        const start = performance.now();
        await this.until(() => this.frames.length === 0 && performance.now() - Math.max(start, this.lastOutputAt) >= 250,
            description, 8_000);
    }
    async input(index: number) {
        const event = this.fixture.events[index];
        assert(event.input && event.action, "Missing recorded native input at " + event.name);
        this.expectedInput = Buffer.from(event.input, "base64");
        this.phase("input", index);
        await this.until(() => !this.expectedInput, "recorded stdin");
    }
    async layout(index: number, phase: "layout" | "resize" | "focus" = index === -1 ? "layout" : "resize") {
        this.phase(phase, index);
        await this.until(() => this.accepted, "native and wire grid agreement", 40_000, false);
    }
    settle(index: number, grid: Grid) {
        if (!["layout", "resize", "focus"].includes(this.state.phase) || index !== this.state.eventIndex || !same(grid, this.grid)) return false;
        this.accepted = true; this.wake?.(); return true;
    }
    async checkpoint(index: number, predicate: () => boolean, capture?: boolean) {
        const event = this.fixture.events[index];
        this.phase("playing", index);
        await this.until(predicate, event.name);
        this.phase("checkpoint", index);
        if (capture !== undefined) this.state.capture = capture;
        this.pendingReference = referenceDocument(this.reference, this.fixture, event);
        // Native framebuffer capture can retry for 160 seconds before the pane acknowledges.
        await this.until(() => this.accepted, "acknowledgement of " + event.name, 190_000, false);
    }
    projection(index: number) { return index === this.state.eventIndex ? this.pendingReference : undefined; }
    ack(body: Record<string, unknown>) {
        const ref = this.projection(Number(body.eventIndex));
        if (this.state.phase !== "checkpoint" || !ref || this.accepted) return false;
        assert.equal(body.name, this.state.name);
        assert.equal(body.receivedBytes, this.outputBytes);
        assert.equal(body.appliedBytes, this.outputBytes);
        assert.equal(body.attachments, this.attachments);
        assert.equal(body.columns, ref.columns); assert.equal(body.rows, ref.rows);
        if (ref.events[0].copy) assert.equal(body.copiedText, ref.events[0].copy.text);
        this.acknowledgements.push(body); this.accepted = true; this.wake?.();
        return true;
    }
}
