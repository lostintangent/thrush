// A disposable interactive /bin/sh, with a real controlling terminal and exactly one permitted attachment.
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const work = mkdtempSync(join(tmpdir(), "thrush-cover-shell-"));
let attached = false;
let shell: ReturnType<typeof Bun.spawn> | undefined;
const server = Bun.serve({
    hostname: "127.0.0.1", port: 0,
    fetch(request, server) {
        const url = new URL(request.url), cols = Number(url.searchParams.get("cols")), rows = Number(url.searchParams.get("rows"));
        if (url.pathname !== "/socket" || url.searchParams.get("service") !== "terminal"
                || !url.searchParams.get("clientId") || !Number.isInteger(cols) || cols < 2 || !Number.isInteger(rows) || rows < 1)
            return new Response("Expected a terminal attachment.", { status: 400 });
        if (attached) return new Response("The original terminal socket disconnected.", { status: 409 });
        if (!server.upgrade(request, {data: {cols, rows}})) return new Response("Expected WebSocket.", { status: 426 });
    },
    websocket: {
        data: {} as {cols: number; rows: number},
        open(socket) {
            attached = true;
            socket.sendText(JSON.stringify({ type: "ready", resumed: false }));
            shell = Bun.spawn(["/bin/sh", "-i"], {
                cwd: work, env: { PATH: "/usr/bin:/bin", HOME: work, TERM: "xterm-256color", PS1: "$ " },
                terminal: { ...socket.data, name: "xterm-256color", data: (_, bytes) => socket.sendBinary(bytes) },
            });
            console.log("PTY shell PID", shell.pid);
            void shell.exited.then(() => { if (socket.readyState === 1) socket.sendText(JSON.stringify({ type: "exit" })); });
        },
        message(socket, message) {
            if (typeof message !== "string") { shell?.terminal?.write(message); return; }
            const control = JSON.parse(message);
            if (control.type === "resize") shell?.terminal?.resize(control.cols, control.rows);
            if (control.type === "close") shell?.kill();
        },
        close() { shell?.kill(); },
    },
});
process.on("SIGTERM", () => { shell?.kill(); server.stop(true); rmSync(work, {recursive: true, force: true}); });
console.log(server.url.origin);
