// Exercise the running view's native actions against one real shell, then two fresh successors.
import assert from "node:assert/strict";
import { setTimeout as delay } from "node:timers/promises";
import type { LiveRun, Recording } from "./run";

type Step = { name: string; text?: string; enter?: true; checkpoint?: true };
const steps = {
    identify: { name: "Identify the first shell", text: "TAG=acorn; echo START:$$" },
    runIdentify: { name: "Run the shell identity command", enter: true },
    first: { name: "First shell identity", checkpoint: true },
    background: { name: "Background the view" },
    foreground: { name: "Return to the running shell" },
    resumed: { name: "Foreground restored the original screen", checkpoint: true },
    verify: { name: "Read the retained shell variable", text: "echo FORE:$TAG:$$" },
    runVerify: { name: "Run the variable check", enter: true },
    retained: { name: "Foreground preserved the shell variable", checkpoint: true },
    reclaim: { name: "Tap the displaced terminal grid" },
    reclaimed: { name: "A grid tap restored the other owner's output", checkpoint: true },
    orphan: { name: "Leave the shell beyond orphan expiry" },
    returnAfterExpiry: { name: "Return after orphan expiry" },
    replaced: { name: "The replacement prompt starts above an empty grid", checkpoint: true },
    identifyReplacement: { name: "Identify the replacement shell", text: "echo FRESH:${TAG-unset}:$$" },
    runIdentifyReplacement: { name: "Run the replacement identity command", enter: true },
    fresh: { name: "Expired shell replaced with a clean environment", checkpoint: true },
    quit: { name: "Print the final line and exit", text: "echo FINAL:$$; exit" },
    runQuit: { name: "Exit the real shell", enter: true },
    ended: { name: "Final output survives shell exit", checkpoint: true },
    newShell: { name: "Have the app create a new session" },
    empty: { name: "The new session starts with a clean screen and history", checkpoint: true },
    focusNewShell: { name: "Focus the new shell for typing" },
    identifyNewShell: { name: "Identify the new shell", text: "echo NEW:${TAG-unset}:$$" },
    runIdentifyNewShell: { name: "Run the new shell identity command", enter: true },
    restarted: { name: "The app opened a fresh session", checkpoint: true },
} as const satisfies Record<string, Step>;
const keys = Object.keys(steps) as (keyof typeof steps)[];
const index = (key: keyof typeof steps) => keys.indexOf(key);

// The initial manifest declares checkpoint names. /checkpoint serves each actual reference screen.
export function lifecycleFixture(shell: Recording): Recording {
    const reference = shell.events.find(event => event.checkpoint)?.checkpoint;
    assert(reference, "The shell recording needs a reference checkpoint for manifest decoding");
    const events = keys.map((key, offsetMicroseconds) => {
        const step: Step = steps[key];
        const event = { name: step.name, offsetMicroseconds };
        if (step.checkpoint) return { ...event, checkpoint: reference };
        if (step.text !== undefined) return { ...event, action: { kind: "text", value: step.text }, input: Buffer.from(step.text).toString("base64") };
        if (step.enter) return { ...event, action: { kind: "key", value: "enter" }, input: "DQ==" };
        return event;
    });
    return { ...shell, name: "live-lifecycle", events };
}

function matchingRow(run: LiveRun, pattern: RegExp) {
    const buffer = run.reference.buffer.active;
    for (let row = buffer.baseY; row < buffer.length; row++) {
        const match = pattern.exec(buffer.getLine(row)?.translateToString(true) ?? "");
        if (match) return match;
    }
}

function pidOnScreen(run: LiveRun, pattern: RegExp) {
    const pid = Number(matchingRow(run, pattern)?.[1]);
    assert(Number.isSafeInteger(pid) && pid > 1, "Expected a shell PID on its own terminal row");
    return pid;
}

async function waitForDeath(pid: number, timeoutMs: number) {
    const deadline = performance.now() + timeoutMs;
    while (performance.now() < deadline) {
        try { process.kill(pid, 0); }
        catch (error) {
            if ((error as NodeJS.ErrnoException).code === "ESRCH") return;
            throw error;
        }
        await delay(35);
    }
    throw Error("Shell PID " + pid + " is still running");
}

async function within<T>(work: Promise<T>, description: string): Promise<T> {
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
        const timeout = new Promise<never>((_, reject) => {
            timer = setTimeout(() => reject(Error("Timed out waiting for " + description)), 10_000);
        });
        return await Promise.race([work, timeout]);
    } finally {
        clearTimeout(timer);
    }
}

function takeOver(run: LiveRun, originalPID: number) {
    const url = new URL("/socket", run.upstream);
    url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
    url.search = new URLSearchParams({ service: "terminal", clientId: run.clientID,
        cols: String(run.grid.columns), rows: String(run.grid.rows) }).toString();
    const socket = new WebSocket(url);
    socket.binaryType = "arraybuffer";
    const output = Promise.withResolvers<void>();
    const closed = Promise.withResolvers<number>();
    let resumed = false, replayed = false, tail = "";
    const expected = "OTHER:acorn:" + originalPID;
    socket.addEventListener("error", () => output.reject(Error("Second owner could not attach")));
    socket.addEventListener("close", event => {
        closed.resolve(event.code);
        output.reject(Error("Second owner closed before its shell answered"));
    });
    socket.addEventListener("message", event => {
        try {
            if (typeof event.data === "string") {
                const control = JSON.parse(event.data);
                assert(!resumed && control.type === "ready" && control.resumed === true, "Takeover must resume the live shell");
                resumed = true;
            } else {
                assert(resumed, "Takeover received data before ready");
                if (!replayed) {
                    replayed = true;
                    socket.send(Buffer.from("echo OTHER:$TAG:$$\r"));
                } else {
                    tail += Buffer.from(event.data).toString("ascii");
                    if (tail.includes(expected + "\r\n")) output.resolve();
                    tail = tail.slice(-512);
                }
            }
        } catch (error) { output.reject(error); }
    });
    return { socket, output: output.promise, closed: closed.promise };
}

export async function runLifecycle(run: LiveRun) {
    const waitReady = (attachment: number, resumed: boolean) => run.until(
        () => run.attachments === attachment && run.ready.length === attachment && run.ready.at(-1) === resumed,
        "attachment " + attachment + " ready, resumed=" + resumed);
    const hasPrompt = () => {
        const buffer = run.reference.buffer.active;
        return run.reference.modes.bracketedPasteMode &&
            buffer.getLine(buffer.baseY + buffer.cursorY)?.translateToString(true) === "thrush$ ";
    };
    const screen = async (key: keyof typeof steps, pattern: RegExp) => {
        const matches = () => Boolean(matchingRow(run, pattern)) && (key === "ended" || hasPrompt());
        if (key === "first" || key === "reclaimed") {
            // Reattaching at a new size can produce a separate PTY redraw after the serialized prompt.
            // Deliver the whole burst before freezing the screen for its final native acknowledgement.
            await run.until(matches, steps[key].name);
            await run.settleOutput("settled PTY output before " + steps[key].name);
        }
        await run.checkpoint(index(key), matches, key === "reclaimed" || key === "ended", key === "ended");
    };
    const focus = async (key: "focusNewShell") => {
        await run.until(hasPrompt, "fresh shell prompt before focusing");
        const before = run.grid;
        await run.layout(index(key), "focus");
        return { step: key, before, after: run.grid };
    };
    const command = async (text: keyof typeof steps, enter: keyof typeof steps) => {
        await run.input(index(text));
        await run.input(index(enter));
    };
    const background = async (key: "background" | "orphan", attachment: number) => {
        run.verifyDetachBoundary(attachment, "before");
        run.phase("detach", index(key));
        const closed = () => run.closures.find(item => item.attachment === attachment && item.side === "upstream");
        await run.until(() => Boolean(closed()), "real shell detached");
        run.verifyDetachBoundary(attachment, "after");
        return closed()!.atMs;
    };

    await waitReady(1, false);
    await command("identify", "runIdentify");
    const start = /^START:([0-9]+)$/;
    await screen("first", start);
    const original = pidOnScreen(run, start);

    await background("background", 1);
    run.phase("resume", index("foreground"));
    await waitReady(2, true);
    await screen("resumed", start);
    assert.equal(pidOnScreen(run, start), original);
    await command("verify", "runVerify");
    await screen("retained", new RegExp("^FORE:acorn:" + original + "$"));

    const owner = takeOver(run, original);
    let reclaimBytes: number;
    try {
        await within(owner.output, "the second owner’s output");
        await run.until(() => run.closures.some(item => item.attachment === 2 && item.side === "upstream" && item.code === 4000),
                        "server displaced the native view with close code 4000");
        await delay(350);
        assert.equal(run.attachments, 2, "The displaced view reconnected without its user");
        const before = run.inputBytes;
        run.phase("reclaim", index("reclaim"));
        await waitReady(3, true);
        await screen("reclaimed", new RegExp("^OTHER:acorn:" + original + "$"));
        assert.equal(await within(owner.closed, "the second owner to close"), 4000, "The grid tap must displace the second owner");
        reclaimBytes = run.inputBytes - before;
        assert.equal(reclaimBytes, 0, "A reclaim tap sent terminal input");
    } finally {
        if (owner.socket.readyState < WebSocket.CLOSING) owner.socket.close();
    }

    const detachedAt = await background("orphan", 3);
    await waitForDeath(original, 40_000);
    const orphanMs = performance.now() - detachedAt;
    assert(orphanMs >= 29_000, "The real PTY expired before its 30-second orphan window");
    run.expectReplacement();
    run.phase("resume", index("returnAfterExpiry"));
    await waitReady(4, false);
    await run.prepareFreshShell();
    await run.checkpoint(index("replaced"), () => hasPrompt() && run.reference.buffer.active.cursorY === 0, true, false,
                         ["START:" + original, "FORE:acorn:" + original, "OTHER:acorn:" + original]);
    await command("identifyReplacement", "runIdentifyReplacement");
    const fresh = /^FRESH:unset:([0-9]+)$/;
    await screen("fresh", fresh);
    const replacement = pidOnScreen(run, fresh);
    assert.notEqual(replacement, original);
    assert(!matchingRow(run, start), "New shell inherited the orphan's old screen");

    await command("quit", "runQuit");
    await run.until(() => run.exits === 1, "terminal sent natural exit");
    await screen("ended", new RegExp("^FINAL:" + replacement + "$"));
    await waitForDeath(replacement, 5_000);
    const beforeNew = run.inputBytes;
    run.phase("newShell", index("newShell"));
    await waitReady(5, false);
    const restartBytes = run.inputBytes - beforeNew;
    assert.equal(restartBytes, 0, "The app toolbar sent terminal input");
    await run.prepareFreshShell();
    await run.checkpoint(index("empty"), () => hasPrompt() && run.reference.buffer.active.cursorY === 0 &&
                         run.reference.buffer.active.baseY === 0, false);
    const newShellFocus = await focus("focusNewShell");
    await command("identifyNewShell", "runIdentifyNewShell");
    const newShell = /^NEW:unset:([0-9]+)$/;
    await screen("restarted", newShell);
    const restarted = pidOnScreen(run, newShell);
    assert.notEqual(restarted, replacement);
    assert(!matchingRow(run, /^FINAL:[0-9]+$/), "The new session inherited the ended shell's screen");
    assert.deepEqual(run.ready, [false, true, true, false, false]);
    run.beforeComplete = async () => {
        await waitForDeath(restarted, 5_000);
        assert.equal(run.explicitCloses, 1, "The final shell needs one explicit close");
        run.evidence.lifecycle = { originalPID: original, replacementPID: replacement, restartedPID: restarted,
            observedOrphanLifetimeMs: Math.round(orphanMs), reclaimTapInputBytes: reclaimBytes, newSessionInputBytes: restartBytes,
            focusGrids: [newShellFocus],
            displacedCloseCode: 4000, finalRowBeforeNewShell: "FINAL:" + replacement, explicitlyClosedPIDDead: true };
    };
}
