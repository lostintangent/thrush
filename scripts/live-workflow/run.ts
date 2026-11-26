import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { join } from "node:path";
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
    | "close" | "completed" | "failed" | "reclaim" | "newShell" | "focus";
type Downstream = ServerWebSocket<{url: string; grid: Grid}>;
type Link = { app: Downstream; server: WebSocket; number: number; serverFrame: number; clientFrame: number; open: boolean; grid: Grid };
type Frame = { link: Link; number: number; data: string | Uint8Array };
type TraceEvent = "receivedFromUpstream" | "sentToNative" | "receivedFromNative";
type FrameObservation = {
    sequence: number; monotonicMs: number; attachment: number; frame: number; event: TraceEvent;
    phase: Phase; eventIndex: number; length: number; hex?: string; text?: string; sendResult?: number;
};
type Closure = { side: "upstream" | "client"; code: number; atMs: number; attachment: number };
const same = (a: Grid, b: Grid) => a.columns === b.columns && a.rows === b.rows;
const replies = /^(?:\x1b\[(?:[?>]?[\d;$]*[cRy]|\?\d*u|[IO])|\x1b\](?:4;\d+|10|11);rgb:[\da-f/]+(?:\x07|\x1b\\))+$/i;

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
    private readonly bootstrapWrites: { attachment: number; bytes: number }[] = [];
    attachments = 0;
    exits = 0;
    explicitCloses = 0;
    // The native session archives its old main screen only on an unexpected fresh ready.
    private archiveNextFresh = false;
    private previousScreen?: ReturnType<typeof openReference>;
    expectReplacement() { this.archiveNextFresh = true; }
    inputBytes = 0;
    outputBytes = 0;
    grid: Grid;
    reference: ReturnType<typeof openReference>;
    readonly wire = { upstreamBinaryFrames: 0, upstreamBinaryBytes: 0, forwardedBinaryFrames: 0,
        forwardedBinaryBytes: 0, replayFrames: 0, replayBytes: 0, synchronizedIntermediateFrames: 0,
        upstreamControls: 0, forwardedControls: 0, clientBinaryFrames: 0, clientControls: 0 };
    state: { phase: Phase; eventIndex: number; name: string; error?: string; capture?: boolean; ended?: boolean; archivedRows?: string[] } =
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

    private readonly recentFrames: FrameObservation[] = [];
    private observationCount = 0;
    constructor(readonly fixture: Recording, readonly upstream: URL, readonly work: string, private readonly traceLifecycleFrames = false,
                private readonly bootstrapShell?: string) {
        this.grid = { columns: fixture.columns, rows: fixture.rows };
        this.reference = openReference(this.grid);
    }
    get downstreamOpen() { return this.active?.open === true; }
    get lastCloseCode() { return this.closures.at(-1)?.code; }
    get driverState() { return { ...this.state, outputBytes: this.outputBytes, attachments: this.attachments, grid: this.grid }; }
    get observations() {
        return { state: this.driverState, wire: this.wire, bootstrapWrites: this.bootstrapWrites, inputBytes: this.inputBytes, attachments: this.attachments,
            ready: this.ready, exits: this.exits, explicitCloses: this.explicitCloses, perAttachment: this.perAttachment,
            closures: this.closures, checkpoints: this.acknowledgements, evidence: this.evidence, error: this.failure?.message,
            queuedFrames: this.frames.length, queuedBytes: this.queuedBytes, forwardingAttachment: this.forwarding?.number,
            lifecycleTrace: this.traceLifecycleFrames ? { timeOriginUnixMs: performance.timeOrigin, observations: this.observationCount,
                frames: this.recentFrames } : undefined };
    }

    private observe(link: Link, frame: number, event: TraceEvent, data: string | Uint8Array, sendResult?: number) {
        if (!this.traceLifecycleFrames) return;
        // Keep the recent finite shell exchange. Report an oversized frame's length without copying its payload.
        const length = typeof data === "string" ? Buffer.byteLength(data) : data.byteLength;
        const observation: FrameObservation = { sequence: ++this.observationCount, monotonicMs: performance.now(),
            attachment: link.number, frame, event, phase: this.state.phase, eventIndex: this.state.eventIndex, length, sendResult };
        if (length <= 4096) {
            if (typeof data === "string") observation.text = data;
            else observation.hex = Buffer.from(data).toString("hex");
        }
        if (this.recentFrames.length === 512) this.recentFrames.shift();
        this.recentFrames.push(observation);
    }

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
        const link = { app, server, number: ++this.attachments, serverFrame: 0, clientFrame: 0, open: true, grid: app.data.grid };
        this.active = link;
        const totals = { number: link.number, openedAtMs: performance.now(), grid: link.grid, upstreamBytes: 0, forwardedBytes: 0, replayBytes: 0, liveBytes: 0 };
        this.perAttachment.push(totals);
        this.grid = app.data.grid;
        server.onmessage = ({ data }) => {
            this.lastOutputAt = performance.now();
            const raw = typeof data === "string" ? data : new Uint8Array(data);
            const number = ++link.serverFrame;
            this.observe(link, number, "receivedFromUpstream", raw);
            if (typeof raw === "string") this.wire.upstreamControls++;
            else { this.wire.upstreamBinaryFrames++; this.wire.upstreamBinaryBytes += raw.byteLength; totals.upstreamBytes += raw.byteLength; }
            if (!link.open) {
                this.fail(Error(`Received output on detached attachment ${link.number}, frame ${number}`));
                return;
            }
            this.queuedBytes += typeof raw === "string" ? Buffer.byteLength(raw) : raw.byteLength;
            if (this.queuedBytes > 8 * 1024 * 1024 || this.frames.length >= 4096) {
                this.fail(Error("Native checkpoint held more than 8 MiB or 4096 upstream frames"));
                return;
            }
            this.frames.push({ link, number, data: raw });
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
        this.observe(link, ++link.clientFrame, "receivedFromNative", raw);
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
                if (this.archiveNextFresh) {
                    assert.equal(control.resumed, false, "Expected a new PTY after expiry");
                    this.previousScreen = this.reference;
                    this.archiveNextFresh = false;
                } else {
                    this.reference.dispose();
                    if (!control.resumed) {
                        this.previousScreen?.dispose();
                        this.previousScreen = undefined;
                    }
                }
                this.reference = openReference(this.grid);
                observeBackgrounds(this.reference, this.sgrBackgrounds);
                this.replayNext = control.resumed;
            } else if (control.type === "exit") this.exits++;
            else throw Error("Unknown upstream control " + control.type);
            const sent = link.app.sendText(data);
            this.observe(link, frame.number, "sentToNative", data, sent);
            assert(sent !== 0, "Native control socket closed");
            this.wire.forwardedControls++;
        } else {
            await new Promise<void>(done => this.reference.write(data, done));
            const sent = link.app.sendBinary(data);
            this.observe(link, frame.number, "sentToNative", data, sent);
            assert(sent !== 0, "Native output socket closed");
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

    // A hosted runner that has just booted a simulator pages its memory in from disk for minutes,
    // so a real program can take most of this budget to start. Thrush's own checks don't depend on it.
    async until(test: () => boolean, description: string, timeoutMs = 120_000, forward = true) {
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
    // Drain that burst before exposing the checkpoint or instructing the view to detach.
    async settleOutput(description: string) {
        const start = performance.now();
        await this.until(() => this.frames.length === 0 && performance.now() - Math.max(start, this.lastOutputAt) >= 250,
            description, 8_000);
    }
    verifyDetachBoundary(attachment: number, when: "before" | "after") {
        const checkpoint = this.acknowledgements.at(-1);
        const link = this.perAttachment[attachment - 1];
        assert(checkpoint && link && this.attachments === attachment && checkpoint.attachments === attachment,
               "Missing native checkpoint on attachment " + attachment);
        const detail = `Attachment ${attachment} ${when} detach after ${checkpoint.name}: `
            + `PTY sent ${link.upstreamBytes} bytes on this socket, relay forwarded ${link.forwardedBytes}; `
            + `cumulative relay ${this.outputBytes}, native received ${checkpoint.receivedBytes}; `
            + `queued frames ${this.frames.length}, bytes ${this.queuedBytes}`;
        assert(link.upstreamBytes === link.forwardedBytes && this.frames.length === 0 && this.queuedBytes === 0
            && checkpoint.receivedBytes === this.outputBytes, detail);
        if (when === "before") {
            assert(checkpoint.columns === this.grid.columns && checkpoint.rows === this.grid.rows,
                   detail + `; checkpoint grid ${checkpoint.columns}×${checkpoint.rows}, current ${this.grid.columns}×${this.grid.rows}`);
        }
    }
    async prepareFreshShell() {
        if (!this.bootstrapShell) return;
        const link = this.active;
        assert(link?.open && this.ready.at(-1) === false,
               "Only a newly allocated shell accepts fixture setup");
        const marker = ".thrush-ready-" + randomUUID();
        // This is a separate harness write. Every byte the PTY emits still reaches the native view and reference.
        const quotedPath = "'" + this.bootstrapShell.replaceAll("'", "'\\''") + "'";
        const command = Buffer.from("exec " + quotedPath + " " + marker + (this.previousScreen ? " --keep-history" : "") + "\r");
        link.server.send(command);
        this.bootstrapWrites.push({ attachment: link.number, bytes: command.length });
        await this.until(() => {
            const buffer = this.reference.buffer.active;
            return existsSync(join(this.work, marker)) && this.reference.modes.bracketedPasteMode &&
                buffer.getLine(buffer.baseY + buffer.cursorY)?.translateToString(true) === "thrush$ ";
        }, "the fixture Bash prompt on the supplied endpoint");
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
    async checkpoint(index: number, predicate: () => boolean, capture?: boolean, ended = false, archivedRows?: string[]) {
        const event = this.fixture.events[index];
        this.phase("playing", index);
        await this.until(predicate, event.name);
        this.phase("checkpoint", index);
        if (capture !== undefined) this.state.capture = capture;
        if (ended) this.state.ended = true;
        if (archivedRows) this.state.archivedRows = archivedRows;
        this.pendingReference = referenceDocument(this.reference, this.fixture, event, this.previousScreen);
        // Native framebuffer capture can retry for 160 seconds before the view acknowledges.
        await this.until(() => this.accepted, "acknowledgement of " + event.name, 190_000, false);
    }
    projection(index: number) { return index === this.state.eventIndex ? this.pendingReference : undefined; }
    ack(body: Record<string, unknown>) {
        const ref = this.projection(Number(body.eventIndex));
        if (this.state.phase !== "checkpoint" || !ref || this.accepted) return false;
        assert.equal(body.name, this.state.name);
        assert.equal(body.receivedBytes, this.outputBytes);
        assert.equal(body.attachments, this.attachments);
        assert.equal(body.columns, ref.columns); assert.equal(body.rows, ref.rows);
        if (ref.events[0].copy) assert.equal(body.copiedText, ref.events[0].copy.text);
        if (this.fixture.name === "live-lifecycle") {
            assert.equal(body.sameNativeCanvas, true, "The native view moved to a different canvas or window");
            assert.equal(body.sessionEnded, this.state.ended ?? false);
            if (this.state.archivedRows) assert.deepEqual(body.archivedRows, this.state.archivedRows);
        }
        this.acknowledgements.push(body); this.accepted = true; this.wake?.();
        return true;
    }
}
