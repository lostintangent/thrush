// Standalone development peer. Only the endpoint changes when the host points at a PTY.
import type { ServerWebSocket } from "bun";
import { serveWorkflow } from "./workflow-peer";
import shellFixture from "../Fixtures/recordings/shell-log.json";
import vimFixture from "../Fixtures/recordings/vim-edit.json";

const esc = "\x1b[";
const reset = esc + "0m";
const prompt = esc + "36m~/thrush" + reset + " " + esc + "90m%" + reset + " ";
const colors = { compile: 94, link: 35, check: 32 };
const steps = [
    ["compile", "Terminal.swift"], ["compile", "Screen.swift"], ["compile", "Input.swift"],
    ["compile", "TerminalView.swift"], ["compile", "GlyphAtlas.swift"], ["compile", "ShaderPipeline.swift"],
    ["link", "ThrushDemo"], ["check", "prompt and reply"], ["check", "cursor keys"],
    ["check", "wide text  翼 🐦"], ["check", "soft wraps"], ["check", "selection and copy"],
] as const;

function buildTranscript() {
    const lines = [prompt + "./build.sh", "Building for debug", ""];
    for (const [index, [operation, detail]] of steps.entries()) {
        if (index === 7) lines.push("");
        const number = (index + 1).toString().padStart(3, "0");
        lines.push(`${esc}90m${number}${reset}  ${esc}${colors[operation]}m${operation.padEnd(8)}${reset} ${detail}`);
    }
    lines.push(esc + "32mBuild complete." + reset, "", prompt + esc + "6 q");
    return lines.join("\r\n");
}

// Each stored style once, with blinking and concealed text among them.
const styles = [
    ["plain", ""], ["bold", "1"], ["dim", "2"], ["italic", "3"], ["underline", "4"], ["strikethrough", "9"],
    ["inverse", "7"], ["blink", "5"], ["concealed", "8"], ["blink inverse", "5;7"],
    ["blink underline", "4;5"], ["blink green", "5;32"],
] as const;

function buildStyles() {
    const sample = "A thrush sings";
    const lines = [prompt + "./styles.sh"];
    for (const [name, sgr] of styles) {
        // Brackets show that concealed text still occupies its cells.
        const text = sgr === "8" ? "[" + esc + "8m" + sample + reset + "]" : esc + sgr + "m" + sample + reset;
        lines.push(esc + "90m" + name.padEnd(sgr === "8" ? 15 : 16) + reset + text);
    }
    return lines.join("\r\n") + "\r\n" + prompt;
}

// A program that sets its own colors with OSC 4, 10, 11 and 12. It picks the canvas the host
// didn't, so the scene always shows program colors against the host's chrome.
const palettes = {
    paper: { background: "f4efe4", foreground: "2e2a24", cursor: "c4532d",
             indexed: { 2: "3f7d3a", 5: "9b3f8c", 6: "1f7a80", 8: "8c8475", 12: "2f5fa8" } },
    night: { background: "17151f", foreground: "e4dfd3", cursor: "e8915a",
             indexed: { 2: "9ccb77", 5: "d29be0", 6: "6cc6c2", 8: "6e6a7c", 12: "86a8f2" } },
} as const;

function setPalette(name: keyof typeof palettes) {
    const { background, foreground, cursor, indexed } = palettes[name];
    const rgb = (hex: string) => `rgb:${hex.slice(0, 2)}/${hex.slice(2, 4)}/${hex.slice(4)}`;
    const osc = (body: string) => "\x1b]" + body + "\x1b\\";
    return "palette " + name + "\r\n" + osc("11;" + rgb(background)) + osc("10;" + rgb(foreground)) +
        osc("12;" + rgb(cursor)) + osc("4;" + Object.entries(indexed).map(([index, hex]) => index + ";" + rgb(hex)).join(";"));
}

function buildColors(host: Appearance) {
    return prompt + setPalette(host === "dark" ? "paper" : "night") + buildTranscript();
}

type Scene = "shell" | "editor" | "log" | "vim" | "prompt" | "glyphs" | "styles" | "colors";
type Appearance = "light" | "dark";
type Session = { scene: Scene; cols: number; rows: number; input: string; appearance?: Appearance };
type Socket = ServerWebSocket<Session>;
const encode = (text: string) => Buffer.from(text, "utf8");

function recordGrid(event: string, { scene, cols, rows }: Session) {
    if (process.env.THRUSH_CAPTURE_GRID === "1") console.log(JSON.stringify({ time: Date.now(), event, scene, cols, rows }));
}

function recording(until: string, events: { name: string; bytes?: string }[]) {
    const stop = events.findIndex(event => event.name === until);
    if (stop < 0) throw Error("Missing recording checkpoint " + until);
    return events.slice(0, stop).flatMap(event => event.bytes ? [Buffer.from(event.bytes, "base64")] : []);
}
const log = recording("Full normal history", shellFixture.events);
const vim = recording("Edited scratch file", vimFixture.events);
const shellPrompt = recording("Fresh prompt", shellFixture.events);

async function draw(socket: Socket) {
    const { scene, cols, rows } = socket.data;
    switch (scene) {
        case "shell": socket.sendBinary(encode(buildTranscript())); return;
        case "prompt": for (const part of shellPrompt) socket.sendBinary(part); return;
        case "log": for (const part of log) socket.sendBinary(part); return;
        case "vim": for (const part of vim) socket.sendBinary(part); return;
        case "styles": socket.sendBinary(encode(buildStyles())); return;
        case "colors":
            socket.sendBinary(encode(socket.data.appearance ? buildColors(socket.data.appearance) : "\x1b]11;?\x1b\\"));
            return;
        case "glyphs":
            socket.sendBinary(encode(prompt + "printf 'A翼🐦Z\\n'\r\nA翼🐦Z" + esc + "2;6H" + esc + "2 q"));
            return;
        case "editor": {
            // Vim selects its scheme from the client's actual background, including host
            // overrides. Freeze that decision for this attachment just as the recorded Vim did.
            const appearance = socket.data.appearance;
            if (!appearance) {
                socket.sendBinary(encode("\x1b]11;?\x1b\\"));
                return;
            }
            const frames = await editorFrames(cols, rows, appearance);
            if (socket.readyState === 1 && cols === socket.data.cols && rows === socket.data.rows) {
                for (const frame of frames) socket.sendBinary(frame);
            }
            return;
        }
    }
}

type EditorRecording = {
    events: { name: string; resize?: { columns: number; rows: number }; bytes?: string }[];
};
const recordings = new Map<Appearance, Promise<EditorRecording>>();
const layouts = [
    { columns: 80, rows: 24, checkpoint: "Styled Swift buffer" },
    { columns: 47, rows: 24, checkpoint: "Styled Swift portrait" },
    { columns: 90, rows: 9, checkpoint: "Styled Swift landscape" },
];

async function editorFrames(columns: number, rows: number, appearance: Appearance) {
    const layout = [...layouts].sort((a, b) =>
        Math.abs(a.columns - columns) + Math.abs(a.rows - rows) * 2 -
        Math.abs(b.columns - columns) - Math.abs(b.rows - rows) * 2)[0];
    let file = recordings.get(appearance);
    if (!file) {
        file = Bun.file(new URL(`../Fixtures/recordings/vim-swift-${appearance}.json`, import.meta.url)).json();
        recordings.set(appearance, file);
    }
    const { events } = await file;
    if (layout === layouts[0]) return recording(layout.checkpoint, events);
    const resize = events.findIndex(event => event.resize?.columns === layout.columns && event.resize.rows === layout.rows);
    if (resize < 0) throw Error("Missing recorded editor resize to " + layout.columns + " × " + layout.rows);
    // At smaller grids, use the PTY's complete post-resize repaint in the alternate
    // screen. Replaying the 80-column edit before it would wrap using the wrong geometry.
    return [encode(esc + "?1049h"), ...recording(layout.checkpoint, events.slice(resize + 1))];
}

function reportedAppearance(bytes: Buffer): Appearance | undefined {
    const match = /\x1b\]11;rgb:([0-9a-f]{4})\/([0-9a-f]{4})\/([0-9a-f]{4})/i.exec(bytes.toString("utf8"));
    if (!match) return undefined;
    return .2126 * parseInt(match[1], 16) + .7152 * parseInt(match[2], 16) + .0722 * parseInt(match[3], 16)
        >= 32768 ? "light" : "dark";
}

const scenes = new Set<Scene>(["shell", "editor", "log", "vim", "prompt", "glyphs", "styles", "colors"]);
const colorScenes = new Set<Socket>();
const args = process.argv.slice(2);
if (args.length && (args[0] !== "--workflow" || !args[1] || args.length > 4
        || (args[2] && args[2] !== "--view") || (args[3] && args[3] !== "--driver")))
    throw Error("Usage: bun scripts/demo-peer.ts [--workflow shell|vim|codex [--view [--driver]]]");
const server = args.length ? (await serveWorkflow(args[1], { view: args[2] === "--view",
    driverPort: args[3] === "--driver" ? Number(process.env.THRUSH_DRIVER_PORT ?? 9139) : undefined })).server : Bun.serve({
    hostname: process.env.THRUSH_HOST ?? "127.0.0.1",
    port: Number(process.env.THRUSH_PORT ?? 9138),
    fetch(request, server) {
        const url = new URL(request.url);
        const query = url.searchParams;
        // POST /palette?name=paper|night switches each colors scene's palette mid-session, as a program would.
        const palette = query.get("name");
        if (url.pathname === "/palette" && request.method === "POST" && palette && Object.hasOwn(palettes, palette)) {
            for (const socket of colorScenes) socket.sendBinary(encode(setPalette(palette as keyof typeof palettes) + prompt));
            return new Response(null, { status: 204 });
        }
        const cols = Number(query.get("cols")), rows = Number(query.get("rows"));
        if (url.pathname !== "/socket" || query.get("service") !== "terminal" || !query.get("clientId") ||
            !Number.isSafeInteger(cols) || !Number.isSafeInteger(rows) || cols < 2 || rows < 1)
            return new Response("Expected a terminal attachment", { status: 400 });
        const candidate = query.get("clientId")?.split("-")[1] as Scene;
        const data: Session = { scene: scenes.has(candidate) ? candidate : "shell", cols, rows, input: "" };
        if (!server.upgrade(request, { data })) return new Response("Expected a WebSocket upgrade", { status: 426 });
    },
    websocket: {
        data: {} as Session,
        open(socket) {
            recordGrid("attach", socket.data);
            if (socket.data.scene === "colors") colorScenes.add(socket);
            socket.sendText(JSON.stringify({ type: "ready", resumed: false }));
            void draw(socket).catch(error => { console.error(error); socket.close(1011, "Scene failed"); });
        },
        async message(socket, message) {
            const state = socket.data;
            if (typeof message === "string") {
                const control = JSON.parse(message);
                if (control.type === "close") { socket.close(1000); return; }
                if (control.type === "resize" && Number.isSafeInteger(control.cols) && Number.isSafeInteger(control.rows)
                        && control.cols >= 2 && control.rows > 0) {
                    state.cols = control.cols;
                    state.rows = control.rows;
                    recordGrid("resize", state);
                    if (state.scene === "editor") await draw(socket);
                }
                return;
            }
            // Recordings supply their own editor output. A fresh prompt accepts a small set
            // of demo commands; other text only receives a remote echo.
            if ((state.scene === "editor" || state.scene === "colors") && !state.appearance) {
                state.appearance = reportedAppearance(message);
                if (state.appearance) await draw(socket);
                return;
            }
            if (state.scene === "vim" || state.scene === "editor" || state.scene === "glyphs") return;
            const text = message.toString("utf8");
            if (text === "\r") {
                socket.sendBinary(encode("\r\n"));
                if (state.input === "./build.sh" || state.input === "vim Prompt.swift") {
                    state.scene = state.input === "./build.sh" ? "shell" : "editor";
                    await draw(socket);
                } else socket.sendBinary(encode(prompt));
                state.input = "";
            } else if (text === "\x7f" && state.input.length) {
                state.input = Array.from(state.input).slice(0, -1).join("");
                socket.sendBinary(encode("\b \b"));
            } else if (text === "\x03") {
                state.input = "";
                socket.sendBinary(encode("^C\r\n" + prompt));
            } else if (!/[\x00-\x1f\x7f]/u.test(text)) {
                state.input += text;
                socket.sendBinary(message);
            }
        },
        close(socket) { colorScenes.delete(socket); },
    },
});
console.log("Thrush demo peer listening at " + server.url.origin);
