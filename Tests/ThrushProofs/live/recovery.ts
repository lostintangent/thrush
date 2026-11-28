import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import type { LiveRun, Recording } from "./run";
import { logicalLines } from "../../../Fixtures/reference/workflows/live.mjs";

const token = "build-" + randomUUID().slice(0, 8);
const driver = "/usr/bin/python3 -B recovery-producer.py";
const text = (name: string, value: string) => ({ name, action: { kind: "text", value }, input: Buffer.from(value).toString("base64") });
const enter = (name: string) => ({ name, action: { kind: "key", value: "enter" }, input: "DQ==" });

export function recoveryFixture(shell: Recording): Recording {
    const checkpoint = shell.events.find(event => event.checkpoint)?.checkpoint;
    assert(checkpoint);
    const steps = [text("Start the build producer", driver), enter("Run the build"), { name: "Build armed", checkpoint },
        { name: "Silent build tail restored", checkpoint }, text("Send build confirmation", token),
        enter("Confirm the build"), { name: "Same-view confirmation received", checkpoint }];
    return { ...shell, name: "live-recovery", events: steps.map((event, offsetMicroseconds) => ({ ...event, offsetMicroseconds })) };
}

export async function runRecovery(run: LiveRun) {
    const rows = () => logicalLines(run.reference, true).map((row: {text: string}) => row.text);
    await run.until(() => rows().some((row: string) => row.trimEnd() === "thrush$"), "fresh shell prompt");
    await run.input(0);
    await run.input(1);
    await run.checkpoint(2, () => rows().includes("Waiting for the terminal output burst"), false);
    await writeFile(join(run.work, "recovery-stop-now"), "");
    // The launcher resumes this process after the last write. No native input can trigger a repair.
    await run.until(() => {
        if (run.ready.length === 1) assert(!rows().includes("Build complete"), "The silent tail escaped as live output");
        return run.ready.length === 2;
    }, "drain on the real upstream socket");
    assert.deepEqual(run.ready, [false, true]);
    const before = run.outputBytes;
    await run.until(() => run.wire.replayFrames === 1, "the serialized frame immediately after in-band ready");
    const restored = rows();
    const expected = Array<string>(run.grid.rows).fill("");
    expected[0] = "Build complete";
    expected[2] = "131072 compilation updates processed";
    expected[4] = "Result: all checks passed";
    expected[6] = "Ready for input";
    assert.deepEqual(restored, expected, "The replay by itself must restore the silent tail");
    assert.equal(run.reference.buffer.active.cursorX, 0);
    assert.equal(run.reference.buffer.active.cursorY, 7);
    assert.equal(run.outputBytes - before, run.wire.replayBytes);
    assert.equal(run.attachments, 1);
    const reparsed = run.outputBytes;
    await run.checkpoint(3, () => true, true);
    run.phase("playing", 3);
    await run.settleOutput("producer remains silent after the drain");
    assert.equal(run.outputBytes, reparsed, "Unexpected live bytes before the user confirms");
    await run.input(4);
    await run.input(5);
    expected[7] = "Confirmed: " + token;
    await run.checkpoint(6, () => rows().includes(expected[7]), true);
    assert.deepEqual(rows(), expected);
    assert.equal(await readFile(join(run.work, "recovery-input"), "utf8"), token);
    assert.deepEqual(run.ready, [false, true]);
    assert.equal(run.attachments, 1);
    assert.equal(run.wire.replayFrames, 1);
    const producer = JSON.parse(await readFile(join(run.work, "recovery-produced.json"), "utf8"));
    assert.equal(producer.payloadBytes, 8 * 1024 * 1024, "Expected the full 8 MiB PTY burst");
    run.evidence.recovery = { ...producer,
        token, restoredRows: restored, confirmedRows: rows(), bytesBeforeReplay: before,
        bytesAfterReplay: reparsed, postReplayEchoBytes: run.outputBytes - reparsed };
}
