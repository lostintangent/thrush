import assert from "node:assert/strict";
import { readFile, stat } from "node:fs/promises";
import { join } from "node:path";
import type { LiveRun, Recording } from "./run";
import { logicalLines, userPromptRows } from "./reference.mjs";

export const names = { shell: "shell-workflow", vim: "vim-resume", codex: "codex-session" } as const;
export type Workflow = keyof typeof names;
const edited = "note: 界 e\u0301first line";
const prompt = "thrush$";

export function liveFixture(recording: Recording) {
    // The recorded sync-open boundary can land inside one real WebSocket message. Keep every
    // live frame intact; count observable open frames separately and compare the completed paint.
    return { ...recording, events: recording.events.map(event => {
        if (event.name !== "Synchronized Codex repaint pending") return event;
        const { checkpoint: _, ...rest } = event;
        return rest;
    }) };
}

function checkpointReached(run: LiveRun, name: string) {
    const t = run.reference;
    if (t.modes.synchronizedOutputMode) return false;
    const buf = t.buffer.active;
    const visible = logicalLines(t, true).map((line: {text: string}) => line.text);
    const screen = visible.join("\n");
    const cursor = buf.getLine(buf.baseY + buf.cursorY)?.translateToString(true).trimEnd() ?? "";
    const alt = buf.type === "alternate";
    const editor = alt && visible.includes(edited) && visible.includes("second line");
    const question = "Name 12 songbirds on numbered lines. Start with Song thrush and end with European robin.";
    switch (name) {
    case "Fresh prompt": case "Shell prompt": return !alt && cursor === prompt && t.modes.bracketedPasteMode;
    case "Typed command": return cursor === prompt + " ./builx";
    case "Edited command": return cursor === prompt + " ./buil";
    case "Pasted build command": return cursor === prompt + " ./build 126 130";
    case "Numbered compiler log": case "Copy soft-wrapped compiler path": {
        const rows = logicalLines(t).map((line: {text: string}) => line.text);
        const numbered = rows.filter((row: string) => /^\d{4}  compile /.test(row)).map((row: string) => row.slice(0, 4));
        return cursor === prompt && numbered.join() === "0126,0127,0128,0129,0130";
    }
    case "Vim opens alternate screen": return alt && visible.includes("first line") && visible.includes("second line") && t.modes.bracketedPasteMode;
    case "Edited scratch file": case "Vim before detach": case "Vim serialized replay": return editor;
    case "Vim resumed ready": return run.ready.length === 2 && run.ready[1] && !alt && visible.every((row: string) => row === "");
    case "Synchronized Codex repaint complete": return screen.includes("OpenAI Codex") && screen.includes("›");
    case "Codex ready": return screen.includes("OpenAI Codex") && screen.includes("›") && /shortcuts|GPT-6\.1|gpt-6\.1/i.test(screen);
    case "Entered Codex prompt": return screen.replace(/\s+/g, " ").includes(question);
    case "Codex working": return /Working|esc to interrupt/i.test(screen);
    case "First three songbirds streamed": return /3\. Eurasian blue tit/.test(screen) && /1\. Song thrush/.test(screen);
    case "Received Codex answer": return /12\. European robin/.test(screen) && /Worked for|shortcuts/.test(screen) && !/esc to interrupt/i.test(screen);
    case "Earlier transcript page": return /1\. Song thrush/.test(screen) && /Back to bottom|latest/i.test(screen);
    case "Later transcript page": return /12\. European robin/.test(screen) && !/Back to bottom/i.test(screen);
    case "Returned to shell": return !alt && cursor === prompt && t.modes.bracketedPasteMode;
    default:
        if (name.startsWith("Resize to ")) return run.fixture.name === names.vim ? editor : cursor === prompt;
        throw Error("Missing live workflow predicate for " + name);
    }
}

type PromptBands = Record<string, ReturnType<typeof userPromptRows>>;

function codexColors(reply: string) {
    const match = /rgb:([0-9a-f]{4})\/([0-9a-f]{4})\/([0-9a-f]{4})/i.exec(reply);
    if (!match) return;
    const [r, g, b] = match.slice(1).map(component => parseInt(component.slice(0, 2), 16));
    const light = 0.299 * r + 0.587 * g + 0.114 * b > 128;
    const hex = (channels: number[]) => "#" + channels.map(n => n.toString(16).padStart(2, "0")).join("");
    const blend = (alpha: number) => hex([r, g, b].map(channel => Math.trunc(
        (light ? 0 : 255) * alpha + channel * (1 - alpha))));
    // Pinned Codex uses a different fill for the submitted transcript than the editable composer.
    // https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/tui/src/style.rs#L68
    // https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/tui/src/style.rs#L261
    return { background: hex([r, g, b]), composer: blend(light ? 0.04 : 0.12), history: blend(light ? 0.02 : 0.16) };
}

function bandEvidence(run: LiveRun, checkpoints: PromptBands) {
    const osc11Replies = [...run.osc11Replies];
    const expected = osc11Replies.length === 1 ? codexColors(osc11Replies[0]) : undefined;
    const fallbackIndex8 = Object.values(checkpoints).flat().some(row => row.styles.some(style => style.background.index === 8));
    const checks = ["Entered Codex prompt", "Codex working", "Received Codex answer"].map(name => {
        const color = name === "Entered Codex prompt" ? expected?.composer : expected?.history;
        const rows = checkpoints[name] ?? [];
        return color && run.sgrBackgrounds.has(color) && rows.length > 0 && rows.every(row =>
            row.styles.every(style => style.background.rgb === color));
    });
    return { osc11Replies, expected, sgr48TrueColor: Object.fromEntries(run.sgrBackgrounds),
        checkpoints, fallbackIndex8, verified: checks.every(Boolean) };
}

export async function exercise(run: LiveRun, workflow: Workflow) {
    const band: Record<string, ReturnType<typeof userPromptRows>> = {};
    for (const [index, event] of run.fixture.events.entries()) {
        if (event.lifecycle?.type === "detach") {
            await run.settleOutput("Vim redraw before backgrounding");
            run.phase("detach", index);
            await run.until(() => !run.downstreamOpen && run.closures.some(c => c.side === "upstream" && c.attachment === 1), "Vim detach");
        } else if (event.lifecycle?.type === "ready") {
            run.phase("resume", index);
            await run.until(() => run.ready.length === 2 && run.ready[1], "resumed ready on the same PTY");
        }
        if (event.action) {
            await run.input(index);
            if (event.name === "Enter quit command") {
                await run.until(() => logicalLines(run.reference, true).some(line => line.text.includes("/quit")),
                    "Codex slash-command menu before Enter");
            }
        }
        if (event.resize) {
            await run.layout(index);
            await run.settleOutput("PTY resize redraw");
        }
        if (event.checkpoint) {
            await run.checkpoint(index, () => {
                if (!checkpointReached(run, event.name)) return false;
                if (workflow === "codex" && ["Entered Codex prompt", "Codex working", "Received Codex answer"].includes(event.name)) {
                    band[event.name] = userPromptRows(run.reference);
                    run.evidence.codexUserBand = bandEvidence(run, band);
                }
                return true;
            });
        }
    }
    if (workflow === "codex") {
        const evidence = bandEvidence(run, band);
        run.evidence.codexUserBand = evidence;
        assert(evidence.verified, "Codex user-turn background did not match the truecolor blend of the native OSC 11 reply");
        run.evidence.synchronizedPaint = { intermediateFramesObserved: run.wire.synchronizedIntermediateFrames,
            pendingCheckpoint: "Recorded-only intermediate; live binary frame boundaries preserved" };
    }
    if (workflow === "shell") {
        const object = await stat(join(run.work, "compile.o"));
        assert(object.isFile() && object.size > 0, "Missing compiler output");
        run.evidence.compiledBytes = object.size;
    }
    if (workflow === "vim") {
        const file = await readFile(join(run.work, "scratch.txt"));
        assert.deepEqual(file, Buffer.from(edited + "\nsecond line\n"), "Vim saved unexpected bytes");
        run.evidence.savedFile = { name: "scratch.txt", text: file.toString(), bytes: file.length };
        assert.deepEqual(run.ready, [false, true]);
    } else assert.deepEqual(run.ready, [false]);
}
