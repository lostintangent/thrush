// One disposable upstream and one native pane per invocation. Both listeners bind only loopback.
import assert from "node:assert/strict";
import { readFile, writeFile, stat, rename } from "node:fs/promises";
import { resolve } from "node:path";
import { parseArgs } from "node:util";
import { logicalLines } from "./reference.mjs";
import { LiveRun, type Recording } from "./run";
import { exercise, liveFixture, names, type Workflow } from "./workflows";

const { values } = parseArgs({ args: Bun.argv.slice(2), options: {
    workflow: { type: "string" }, upstream: { type: "string" }, work: { type: "string" }, report: { type: "string" },
}, strict: true });
const workflow = values.workflow as Workflow | "lifecycle";
assert(workflow === "lifecycle" || Object.hasOwn(names, workflow), "Expected --workflow shell|vim|codex|lifecycle");
assert(values.upstream && values.work && values.report, "Supply --upstream URL --work DISPOSABLE_PTY_DIR --report PATH");
const upstream = new URL(values.upstream);
const hosts = new Set(["127.0.0.1", "localhost", "[::1]"]);
assert(hosts.has(upstream.hostname) && ["http:", "https:"].includes(upstream.protocol) &&
    upstream.pathname === "/" && !upstream.search && !upstream.hash && !upstream.username && !upstream.password,
    "Expected a loopback Toy Box origin");
const work = resolve(values.work);
assert((await stat(work)).isDirectory(), "The disposable working directory must exist");
const life = workflow === "lifecycle" ? await import("./lifecycle.ts") : undefined;
const name = names[workflow === "lifecycle" ? "shell" : workflow];
const recorded: Recording = JSON.parse(await readFile(new URL("../../Fixtures/replays/" + name + ".json", import.meta.url), "utf8"));
const fixture = life ? life.lifecycleFixture(recorded) : liveFixture(recorded);
const run = new LiveRun(fixture, upstream, work);
const report = resolve(values.report);
const local = (request: Request) => {
    const url = new URL(request.url);
    return hosts.has(url.hostname) && (!request.headers.has("Origin") || request.headers.get("Origin") === url.origin);
};
function validGrid(columns: number, rows: number) {
    return Number.isSafeInteger(columns) && columns >= 2 && columns <= 512 && Number.isSafeInteger(rows) && rows >= 1 && rows <= 256;
}
const terminal = Bun.serve({
    hostname: "127.0.0.1", port: 0,
    fetch(request, server) {
        if (!local(request)) return new Response(null, { status: 403 });
        const url = new URL(request.url), q = url.searchParams;
        const grid = { columns: Number(q.get("cols")), rows: Number(q.get("rows")) };
        if (request.method !== "GET" || url.pathname !== "/socket" || q.get("service") !== "terminal" ||
            q.get("clientId") !== run.clientID || !validGrid(grid.columns, grid.rows)) return new Response(null, { status: 400 });
        if (run.downstreamOpen || run.state.phase === "completed" || run.failure) return new Response(null, { status: 409 });
        if (!server.upgrade(request, { data: { url: url.pathname + url.search, grid } })) return new Response(null, { status: 426 });
    },
    websocket: {
        data: {} as {url: string; grid: {columns: number; rows: number}},
        idleTimeout: 0,
        open(socket) { try { run.attach(socket); } catch (error) { run.fail(error); } },
        message(socket, frame) { try { run.clientMessage(socket, frame); } catch (error) { run.fail(error); } },
        close(socket, code, reason) { try { run.disconnect(socket, code, reason); } catch (error) { run.fail(error); } },
    },
});
const control = Bun.serve({
    hostname: "127.0.0.1", port: 0, maxRequestBodySize: 65_536,
    async fetch(request) {
        if (!local(request)) return new Response(null, {status: 403});
        const { pathname, searchParams } = new URL(request.url);
        if (!["/fixture", "/state", "/ack", "/layout", "/checkpoint"].includes(pathname)) return new Response(null, {status: 404});
        const method = pathname === "/ack" || pathname === "/layout" ? "POST" : "GET";
        if (request.method !== method) return new Response(null, {status: 405, headers: { Allow: method }});
        const json = (value: unknown) => Response.json(value, { headers: { "Cache-Control": "no-store" } });
        if (pathname === "/fixture") return json(fixture);
        if (searchParams.get("clientId") !== run.clientID) return new Response(null, {status: 400});
        if (pathname === "/state") return json(run.driverState);
        if (pathname === "/checkpoint") {
            const index = searchParams.get("eventIndex");
            const doc = index && /^\d+$/.test(index) ? run.projection(Number(index)) : undefined;
            return doc ? json(doc) : new Response(null, {status: 409});
        }
        let body;
        try { body = await request.json(); } catch { return new Response(null, {status: 400}); }
        try {
            const accepted = pathname === "/ack" ? run.ack(body)
                : validGrid(body.columns, body.rows) && run.settle(body.eventIndex, body);
            return new Response(null, {status: accepted ? 204 : 409});
        } catch (error) {
            run.fail(error);
            return new Response(String(error), {status: 422});
        }
    },
});
const persist = async (completed: boolean) => {
    const result = { workflow, completed, error: run.failure?.message, lastViewport: run.failure ? logicalLines(run.reference, true).map(line => line.text) : undefined, wire: run.wire, inputBytes: run.inputBytes,
        attachments: run.attachments, ready: run.ready, exits: run.exits, explicitCloses: run.explicitCloses,
        perAttachment: run.perAttachment, closures: run.closures, checkpoints: run.acknowledgements, evidence: run.evidence };
    await writeFile(report + ".tmp", JSON.stringify(result, null, 2) + "\n");
    await rename(report + ".tmp", report);
};
console.log(JSON.stringify({ endpoint: terminal.url.origin, driver: control.url.origin }));
try {
    await run.until(() => run.ready.length === 1, "first native terminal connection", 120_000);
    assert.equal(run.ready[0], false, "Workflow must start with a fresh disposable PTY");
    await run.layout(-1);
    if (life) await life.runLifecycle(run);
    else { assert(workflow !== "lifecycle"); await exercise(run, workflow); }
    run.phase("close", fixture.events.length);
    await run.until(() => run.explicitCloses === 1 && !run.downstreamOpen &&
        run.closures.some(c => c.attachment === run.attachments && c.side === "upstream"), "explicit PTY close");
    await run.beforeComplete?.();
    assert.equal(run.wire.upstreamBinaryFrames, run.wire.forwardedBinaryFrames, "Binary frame count changed in transit");
    assert.equal(run.wire.upstreamBinaryBytes, run.wire.forwardedBinaryBytes, "Binary byte count changed in transit");
    await persist(true);
    run.phase("completed", fixture.events.length);
} catch (error) {
    run.fail(error);
    console.error(error);
    await persist(false);
}
