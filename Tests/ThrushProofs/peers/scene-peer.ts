// The proofs' scene peer. Only the endpoint changes when the host points at a PTY.
import type { ServerWebSocket } from "bun";
import shellFixture from "../../../Fixtures/recordings/shell-log.json";
import vimFixture from "../../../Fixtures/recordings/vim-edit.json";
import { ReconnectRecording } from "./reconnect-peer";

const esc = "\x1b[";
const reset = esc + "0m";
const prompt = esc + "36m~/thrush" + reset + " " + esc + "90m%" + reset + " ";
const colors = { compile: 94, link: 35, check: 32 };
const steps = [
    ["compile", "Terminal.swift"], ["compile", "Screen.swift"], ["compile", "Input.swift"],
    ["compile", "TerminalView.swift"], ["compile", "GlyphAtlas.swift"], ["compile", "ShaderPipeline.swift"],
    ["link", "Thrush"], ["check", "prompt and reply"], ["check", "cursor keys"],
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
    ["plain", ""], ["bold", "1"], ["dim", "2"], ["italic", "3"], ["underline", "4"], ["double", "4:2"],
    ["curly", "4:3"], ["dotted", "4:4"], ["dashed", "4:5"], ["underline color", "4:3;58:5:1"], ["strikethrough", "9"],
    ["overline", "53"], ["inverse", "7"], ["blink", "5"], ["concealed", "8"], ["blink inverse", "5;7"],
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

const linkedPath = "Sources/Thrush/View/TerminalMetalView+Links.swift";

// An rg search for where links open, which names the file as a link to it on the machine the shell runs on,
// and the prompt after it.
function buildSearch() {
    const file = `\x1b]8;;file://devbox/home/robin/thrush/${linkedPath.replace("+", "%2B")}\x1b\\${reset}${esc}35m${linkedPath}${reset}\x1b]8;;\x1b\\`;
    return [prompt + 'rg -l "func openWebLink" Sources', file, prompt].join("\r\n");
}

// The search, gh's web address for that line, then Claude Code's trust prompt laid out as Claude lays it
// out at this width. Claude's "Security guide" is a link that says something other than where it goes.
// gh prints its address as plain text, which wraps on the Mac and the iPhone, and so does the file name
// on the iPhone.
function buildLinks(cols: number) {
    const page = `https://github.com/lostintangent/thrush/blob/main/${linkedPath}?plain=1#L176`;
    // Claude pads its box by a column on each side and places each word with a column move.
    const words = (text: string, style = "", unstyle = "") => {
        const rows: string[] = [];
        let row = "", column = 2;
        for (const word of text.split(" ")) {
            if (row && column + word.length - 1 > cols - 1) {
                rows.push(row + unstyle);
                row = "";
                column = 2;
            }
            row += `${esc}${column}G${row ? "" : style}${word}`;
            column += word.length + 1;
        }
        return [...rows, row + unstyle];
    };
    const amber = esc + "38;2;255;193;7m", gray = esc + "38;2;153;153;153m", violet = esc + "38;2;177;185;249m";
    const trust = [
        amber + "─".repeat(cols) + esc + "39m",
        ...words("Accessing workspace:", amber + esc + "1m", esc + "22m" + esc + "39m"),
        "",
        `${esc}2G${esc}1m/home/robin/thrush${esc}22m`,
        "",
        ...words("Quick safety check: Is this a project you created or one you trust? (Like your own code, a " +
            "well-known open source project, or work from your team). If not, take a moment to review what's in this folder first."),
        "",
        ...words("Claude Code'll be able to read, edit, and execute files here."),
        "",
        `${esc}2G\x1b]8;id=zaxmda;https://code.claude.com/docs/en/security\x07${gray}Security guide${esc}39m\x1b]8;;\x07`,
        "",
        `${esc}2G${violet}❯${esc}4GNo,${esc}8Gexit${esc}39m`,
        `${esc}4GYes,${esc}9GI${esc}11Gtrust${esc}17Gthis${esc}22Gfolder`,
        "",
        ...words("Enter to confirm · Esc to cancel", gray, esc + "39m"),
    ];
    return [buildSearch() + `gh browse -n ${linkedPath}:176`, page, prompt + "claude"].join("\r\n") +
        "\x1b]2;claude\x07" + esc + "?25l" + esc + "?2004h" + esc + "?1004h\r\n" + trust.join("\r\n") +
        // Claude parks its hidden cursor on the chosen answer.
        "\r\n" + esc + "1C" + esc + "4A";
}

// A finished test run, which the lifecycle scenes below show before their session changes.
const testRun = [prompt + "swift test", "Building for debugging…", "", "✓  TerminalTests passed",
    "✓  ConnectionTests passed", "", "Test run passed.", "", prompt].join("\r\n");

// The lifecycle scenes change the session itself as their captures advance them through the endpoints below.
const lifecycle = ["spinner-opening", "spinner-reconnecting", "shell-ended", "reconnect-typing"] as const;
type Scene = "shell" | "editor" | "log" | "vim" | "prompt" | "glyphs" | "styles" | "colors" | "links" | typeof lifecycle[number];
type Appearance = "light" | "dark";
type Session = {
    scene: Scene; clientId: string; cols: number; rows: number; input: string; appearance?: Appearance;
    index: number; acknowledged: boolean;
};
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
        case "links": socket.sendBinary(encode(buildLinks(cols))); return;
        case "colors":
            socket.sendBinary(encode(socket.data.appearance ? buildColors(socket.data.appearance) : "\x1b]11;?\x1b\\"));
            return;
        case "glyphs":
            socket.sendBinary(encode(prompt + "printf 'A翼🐦Z\\n'\r\nA翼🐦Z" + esc + "2;6H" + esc + "2 q"));
            return;
        // A DSR reply proves that the client applied these bytes before the session changes.
        case "spinner-opening": socket.sendBinary(encode(esc + "6n")); return;
        case "spinner-reconnecting": case "shell-ended": socket.sendBinary(encode(testRun + esc + "6n")); return;
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
    { columns: 45, rows: 18, checkpoint: "Styled Swift portrait" },
    { columns: 71, rows: 11, checkpoint: "Styled Swift landscape" },
];

async function editorFrames(columns: number, rows: number, appearance: Appearance) {
    const layout = [...layouts].sort((a, b) =>
        Math.abs(a.columns - columns) + Math.abs(a.rows - rows) * 2 -
        Math.abs(b.columns - columns) - Math.abs(b.rows - rows) * 2)[0];
    let file = recordings.get(appearance);
    if (!file) {
        file = Bun.file(new URL(`../../../Fixtures/recordings/vim-swift-${appearance}.json`, import.meta.url)).json();
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

const scenes = new Set<Scene>(["shell", "editor", "log", "vim", "prompt", "glyphs", "styles", "colors", "links", ...lifecycle]);
const sockets = new Set<Socket>();
const attachments = new Map<string, number>();
const motion = new ReconnectRecording();
const toolbar = { opened: 0, acknowledged: 0, exited: 0 };
const ready = (socket: Socket) => socket.sendText(JSON.stringify({ type: "ready", resumed: false }));
const attached = (scene: Scene, acknowledged: boolean) =>
    [...sockets].filter(socket => socket.data.scene === scene && socket.data.acknowledged === acknowledged);
const server = Bun.serve({
    hostname: process.env.THRUSH_HOST ?? "127.0.0.1",
    port: Number(process.env.THRUSH_PORT ?? 9138),
    fetch(request, server) {
        const url = new URL(request.url);
        const query = url.searchParams;
        if (url.pathname.startsWith("/motion/")) return motion.control(request, url.pathname);
        if (request.method === "POST" && url.pathname === "/release-opening") {
            const opening = attached("spinner-opening", false);
            if (opening.length !== 1) return new Response("Expected one waiting shell.", { status: 409 });
            ready(opening[0]!);
            void draw(opening[0]!);
            return new Response(null, { status: 204 });
        }
        if (request.method === "POST" && url.pathname === "/interrupt-reconnecting") {
            // The capture controller sends this only after it observes the requested native
            // keyboard geometry on the original shell's GPU-completed frame.
            const shells = attached("spinner-reconnecting", true);
            if (shells.length !== 1) return new Response("Expected one acknowledged shell.", { status: 409 });
            shells[0]!.close(1011, "terminal socket lost");
            return new Response(null, { status: 204 });
        }
        if (request.method === "GET" && url.pathname === "/toolbar-state") return Response.json(toolbar);
        if (request.method === "POST" && url.pathname === "/exit-shell") {
            const shells = attached("shell-ended", true);
            if (shells.length !== 1 || toolbar.exited) return new Response("Expected one live shell.", { status: 409 });
            shells[0]!.sendBinary(encode("exit\r\nlogout"));
            shells[0]!.sendText(JSON.stringify({ type: "exit" }));
            shells[0]!.close(1000);
            toolbar.exited++;
            return new Response(null, { status: 204 });
        }
        // POST /palette?name=paper|night switches each colors scene's palette mid-session, as a program would.
        const palette = query.get("name");
        if (url.pathname === "/palette" && request.method === "POST" && palette && Object.hasOwn(palettes, palette)) {
            const bytes = encode(setPalette(palette as keyof typeof palettes) + prompt);
            for (const socket of sockets) if (socket.data.scene === "colors") socket.sendBinary(bytes);
            return new Response(null, { status: 204 });
        }
        // POST /links?draw=0 clears each links scene and POST /links?draw=1 lays it out again, as output that
        // takes a link from under a resting pointer and brings it back. POST /links?draw=2 lays it out with
        // Claude exited and the search run again, which puts a file link on the bottom rows.
        const drawn = query.get("draw");
        if (url.pathname === "/links" && request.method === "POST" && (drawn === "0" || drawn === "1" || drawn === "2")) {
            for (const socket of sockets) if (socket.data.scene === "links")
                socket.sendBinary(encode(esc + "H" + esc + "2J" + (drawn === "0" ? "" : esc + "3J" + buildLinks(socket.data.cols)) +
                    (drawn === "2" ? esc + "4B\r" + esc + "?1004l" + esc + "?2004l" + esc + "?25h" + buildSearch() : "")));
            return new Response(null, { status: 204 });
        }
        const cols = Number(query.get("cols")), rows = Number(query.get("rows")), clientId = query.get("clientId");
        // The proofs choose a scene with their endpoint's path, so its terminal attaches at /<scene>/socket.
        const path = /^(?:\/([a-z-]+))?\/socket$/.exec(url.pathname);
        if (!path || query.get("service") !== "terminal" || !clientId ||
            !Number.isSafeInteger(cols) || !Number.isSafeInteger(rows) || cols < 2 || rows < 1)
            return new Response("Expected a terminal attachment", { status: 400 });
        const candidate = path[1] as Scene;
        const scene = scenes.has(candidate) ? candidate : "shell";
        const data: Session = { scene, clientId, cols, rows, input: "", index: 0, acknowledged: false };
        if (!server.upgrade(request, { data })) return new Response("Expected a WebSocket upgrade", { status: 426 });
    },
    websocket: {
        data: {} as Session,
        open(socket) {
            const state = socket.data;
            recordGrid("attach", state);
            sockets.add(socket);
            state.index = (attachments.get(state.clientId) ?? 0) + 1;
            attachments.set(state.clientId, state.index);
            if (state.scene === "reconnect-typing") { motion.attach(socket, state.index, testRun); return; }
            // An opening shell waits for POST /release-opening, and a lost one never comes back.
            if (state.scene === "spinner-opening" || (state.scene === "spinner-reconnecting" && state.index > 1)) return;
            if (state.scene === "shell-ended") toolbar.opened++;
            ready(socket);
            void draw(socket).catch(error => { console.error(error); socket.close(1011, "Scene failed"); });
        },
        async message(socket, message) {
            const state = socket.data;
            if (typeof message === "string") {
                const control = JSON.parse(message);
                if (control.type === "close") { socket.close(1000); return; }
                if (control.type === "resize" && Number.isSafeInteger(control.cols) && Number.isSafeInteger(control.rows)
                        && control.cols >= 2 && control.rows > 0) {
                    const widthChanged = control.cols !== state.cols;
                    state.cols = control.cols;
                    state.rows = control.rows;
                    recordGrid("resize", state);
                    if (state.scene === "editor") await draw(socket);
                    // Claude lays its prompt out again at a new width. The scene starts over with it.
                    if (state.scene === "links" && widthChanged) socket.sendBinary(encode(esc + "H" + esc + "2J" + esc + "3J" + buildLinks(state.cols)));
                }
                return;
            }
            if (state.scene === "reconnect-typing") { motion.input(message); return; }
            if ((lifecycle as readonly Scene[]).includes(state.scene)) {
                if (!state.acknowledged && /^\x1b\[\d+;\d+R$/.test(message.toString())) {
                    state.acknowledged = true;
                    if (state.scene === "shell-ended") toolbar.acknowledged++;
                }
                return;
            }
            // Recordings supply their own editor output. A fresh prompt accepts a small set
            // of scene commands; other text only receives a remote echo.
            if ((state.scene === "editor" || state.scene === "colors") && !state.appearance) {
                state.appearance = reportedAppearance(message);
                if (state.appearance) await draw(socket);
                return;
            }
            if (state.scene === "vim" || state.scene === "editor" || state.scene === "glyphs" || state.scene === "links") return;
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
        close(socket) { sockets.delete(socket); },
    },
});
console.log("Thrush scene peer listening at " + server.url.origin);
