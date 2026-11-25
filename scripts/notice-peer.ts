// Script the five native pane notices using only the same WebSocket protocol as the PTY.
import type { ServerWebSocket } from "bun";
import { ReconnectRecording } from "./interaction-capture/reconnect-peer";

const scenes = ["connecting", "reconnecting", "replacement", "displaced", "ended", "motion"] as const;
type Scene = typeof scenes[number] | "prompt";
type Attachment = { id: string; scene: Scene; url: string; index: number; acknowledged: boolean };
type Socket = ServerWebSocket<Attachment>;
type Session = { count: number; owner?: Socket; other?: WebSocket };
const sessions = new Map<string, Session>();
const motion = new ReconnectRecording();
const csi = "\x1b[";
const prompt = csi + "36m~/thrush" + csi + "0m % ";
const rows = [prompt + "swift test", "Building for debugging…", "", "✓  TerminalTests passed",
    "✓  ConnectionTests passed", "", "Test run passed.", "", prompt];
const ready = (socket: Socket, resumed = false) => socket.sendText(JSON.stringify({ type: "ready", resumed }));
const write = (socket: Socket, text: string) => socket.sendBinary(Buffer.from(text));
const server = Bun.serve({
    hostname: "127.0.0.1",
    port: Number(process.env.THRUSH_PORT ?? 9138),
    fetch(request, server) {
        const url = new URL(request.url);
        if (url.pathname.startsWith("/motion/")) return motion.control(request, url.pathname);
        if (request.method === "POST" && url.pathname === "/interrupt-reconnecting") {
            // The capture controller sends this only after it observes the requested native
            // keyboard geometry on the original shell's GPU-completed frame.
            const attached = [...sessions.values()].map(session => session.owner).filter(socket =>
                socket?.data.scene === "reconnecting" && socket.data.index === 1 && socket.data.acknowledged);
            if (attached.length !== 1) return new Response("Expected one acknowledged shell.", { status: 409 });
            attached[0]!.close(1011, "terminal socket lost");
            console.log("reconnecting interrupted after native keyboard checkpoint");
            return new Response(null, { status: 204 });
        }
        const id = url.searchParams.get("clientId") ?? "";
        const scene = id.startsWith("thrush-prompt-") ? "prompt" : scenes.find(name => id.startsWith("thrush-notice-" + name + "-"));
        if (!scene || url.pathname !== "/socket" || url.searchParams.get("service") !== "terminal")
            return new Response("Expected a notice scene terminal attachment.", { status: 400 });
        const session = sessions.get(id) ?? { count: 0 };
        const data = { id, scene, url: request.url.replace(/^http/, "ws"), index: session.count + 1, acknowledged: false };
        sessions.set(id, session);
        session.count++;
        if (!server.upgrade(request, { data })) {
            session.count--;
            if (!session.count) sessions.delete(id);
            return new Response("Expected WebSocket.", { status: 426 });
        }
    },
    websocket: {
        data: {} as Attachment,
        open(socket) {
            const { id, scene, index } = socket.data;
            const session = sessions.get(id)!;
            console.log(scene, "attachment", index);
            if (scene === "motion") { motion.attach(socket, index, rows.join("\r\n")); return; }
            const previous = session.owner;
            session.owner = socket;
            if (scene === "connecting" || (scene === "reconnecting" && index > 1)) return;
            if (scene === "displaced" && previous) previous.close(4000, "replaced");
            ready(socket, scene === "displaced" && index > 1);
            if (scene === "prompt" || (index > 1 && scene === "replacement")) {
                write(socket, prompt);
                return;
            }
            const lines = [...rows];
            if (scene === "ended") lines[lines.length - 1] += "exit\r\nlogout";
            // DSR proves that the original client applied these bytes before the lifecycle changes.
            write(socket, lines.join("\r\n") + csi + "6n");
        },
        message(socket, message) {
            if (typeof message === "string") {
                if (JSON.parse(message).type === "close") socket.close(1000);
                return;
            }
            if (socket.data.scene === "motion") { motion.input(message); return; }
            const { id, scene, url, index } = socket.data;
            if (index !== 1 || socket.data.acknowledged || !/^\x1b\[\d+;\d+R$/.test(message.toString())) return;
            socket.data.acknowledged = true;
            console.log(scene, "transcript acknowledged");
            if (scene === "ended") socket.sendText(JSON.stringify({ type: "exit" }));
            if (scene === "replacement") socket.close(1011, "terminal socket lost");
            if (scene === "displaced") {
                // A second window attaches with precisely the same terminal URL and client ID.
                const other = new WebSocket(url);
                sessions.get(id)!.other = other;
                other.addEventListener("error", () => console.error("Second window failed to attach", id));
            }
        },
        close(socket) {
            const session = sessions.get(socket.data.id);
            if (session?.owner === socket) session.owner = undefined;
        },
    },
});
console.log("Thrush demo peer listening at http://127.0.0.1:" + server.port);
