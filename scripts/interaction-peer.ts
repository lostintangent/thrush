// Run the packaged native app against an exact-byte peer on an ephemeral loopback port.
import { mkdir, mkdtemp, copyFile, readFile, rm } from "node:fs/promises";
import { join, dirname, resolve } from "node:path";
import { tmpdir } from "node:os";

const args = process.argv.slice(2);
const simulator = args[0] === "--simulator" ? args.splice(0, 2)[1] : undefined;
if (args.length !== 2) throw Error("Usage: interaction-peer.ts [--simulator UDID] APP OUTPUT.json");
const [app, output] = args.map(path => resolve(path));
const path = " " + "a soft wrap ".repeat(8) + "ends here.";
const letters = Array.from("abcdefghijklmnopqrst");
const echoes = ["翼", path, ...letters].map(value => Buffer.from(value));
const expected = [Buffer.from("翼"), Buffer.from("\x1b[200~" + path + "\x1b[201~"), ...letters.map(c => Buffer.from(c))];
let writes = 0;
let failure: string | undefined;
const peer = Bun.serve({
    hostname: "127.0.0.1", port: 0,
    fetch(request, server) {
        const url = new URL(request.url);
        if (url.pathname === "/socket" && url.searchParams.get("service") === "terminal" && server.upgrade(request)) return;
        return new Response("Expected a terminal WebSocket", { status: 400 });
    },
    websocket: {
        open(socket) {
            socket.sendText(JSON.stringify({ type: "ready", resumed: false }));
            const history = Array.from({length: 80}, (_, i) => "Line " + (i + 1)).join("\r\n");
            socket.sendBinary(Buffer.from(history + "\r\n~/thrush % \x1b[?2004h"));
        },
        message(socket, message) {
            if (typeof message === "string") {
                if (JSON.parse(message).type !== "resize") failure = "Unexpected control frame";
                return;
            }
            if (!expected[writes]?.equals(message)) {
                failure = "Unexpected input at frame " + (writes + 1);
                socket.close(1002, "Unexpected terminal input");
                return;
            }
            socket.sendBinary(echoes[writes++]);
        },
    },
});
const work = await mkdtemp(join(tmpdir(), "thrush-interactions-"));
let report = join(work, "interactions.json");
let child: ReturnType<typeof Bun.spawn> | undefined;
const identifier = "app.thrush.demo";
const deadline = Date.now() + 150_000;
function simctl(...arguments_: string[]): string {
    const result = Bun.spawnSync(["xcrun", "simctl", ...arguments_], {env: {
        ...process.env, DEVELOPER_DIR: process.env.DEVELOPER_DIR ?? "/Applications/Xcode.app/Contents/Developer",
    }});
    if (result.exitCode !== 0) throw Error(result.stderr.toString());
    return result.stdout.toString().trim();
}
try {
    const options = ["--endpoint", peer.url.origin, "--appearance", "dark"];
    if (simulator) {
        simctl("install", simulator, app);
        const container = simctl("get_app_container", simulator, identifier, "data");
        report = join(container, "Documents", "interaction-" + crypto.randomUUID() + ".json");
        simctl("launch", "--terminate-running-process", simulator, identifier, ...options, "--interaction-check", report);
    } else {
        child = Bun.spawn([join(app, "Contents/MacOS/ThrushDemo"), ...options, "--interaction-check", report],
                          {stdout: "inherit", stderr: "inherit"});
    }
    while (!(await Bun.file(report).exists())) {
        if (failure) throw Error(failure);
        if (child && child.exitCode !== null) throw Error("Demo exited before writing the interaction report");
        if (Date.now() > deadline) throw Error("Timed out waiting for the native interaction report");
        await Bun.sleep(100);
    }
    // The report is written atomically, after the app has drawn the final remote echo.
    const result = JSON.parse(await readFile(report, "utf8"));
    if (result.schemaVersion !== 1 || result.committedEcho !== "翼" || result.copiedText !== "翼" + path ||
        !result.historyReadingLine?.trim() || result.samples?.length !== letters.length) {
        throw Error("Incomplete native interaction checkpoints");
    }
    let previousGeneration = -1;
    for (const [index, sample] of result.samples.entries()) {
        const times = [sample.keyAt, sample.sentAt, sample.receivedAt];
        if (sample.submittedAt !== undefined) times.push(sample.submittedAt);
        if (sample.presentedAt !== undefined) times.push(sample.presentedAt);
        if (sample.marker !== letters[index] || !Number.isInteger(sample.generation) ||
            sample.generation <= previousGeneration || times.some((time, i) =>
                !Number.isFinite(time) || (i > 0 && time < times[i - 1]))) {
            throw Error("Invalid timing or generation for native key " + letters[index]);
        }
        previousGeneration = sample.generation;
    }
    if (failure || writes !== expected.length) throw Error(failure ?? "Missing input frames: " + writes);
    await mkdir(dirname(output), {recursive: true});
    await copyFile(report, output);
    console.log("Verified all " + writes + " native input frames. Report " + output);
} finally {
    child?.kill();
    if (simulator) {
        try { simctl("terminate", simulator, identifier); } catch { /* A successful probe may have exited. */ }
        await rm(report, {force: true});
    }
    peer.stop(true);
    await rm(work, {recursive: true, force: true});
}
