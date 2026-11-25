// The iPhone recorder advances these gates from actual keyboard and accessibility observations.
import type { ServerWebSocket } from "bun";

type Socket = Pick<ServerWebSocket<unknown>, "sendText" | "sendBinary" | "close">;
const promptInput = "git";
const held = " status";

export class ReconnectRecording {
    private socket?: Socket;
    private transcript = "";
    private attachments = 0;
    private appReady = false;
    private recording = false;
    private interrupted = false;
    private resumed = false;
    private complete = false;
    private error?: string;
    private firstAck = false;
    private replayAck = false;
    private liveBytes = Buffer.alloc(0);
    private heldBytes = Buffer.alloc(0);

    attach(socket: Socket, index: number, transcript: string) {
        this.socket = socket;
        this.attachments++;
        if (index === 1 && this.attachments === 1) {
            this.transcript = transcript;
            socket.sendText(JSON.stringify({ type: "ready", resumed: false }));
            socket.sendBinary(Buffer.from(transcript + "\x1b[6n"));
        } else if (index !== 2 || !this.interrupted) {
            this.error = "Unexpected terminal attachment.";
            socket.close(1002);
        }
    }

    input(data: Buffer) {
        if (/^\x1b\[\d+;\d+R$/.test(data.toString())) {
            if (this.resumed) this.replayAck = true; else this.firstAck = true;
            return;
        }
        if (this.resumed && this.replayAck) {
            this.heldBytes = Buffer.concat([this.heldBytes, data]);
            if (!held.startsWith(this.heldBytes.toString())) this.error = "Unexpected held bytes after replay.";
        } else if (this.firstAck && this.recording && !this.interrupted) {
            this.liveBytes = Buffer.concat([this.liveBytes, data]);
            if (!promptInput.startsWith(this.liveBytes.toString())) this.error = "Unexpected live bytes.";
        } else {
            this.error = "Terminal input reached the peer before a shell was ready.";
        }
        if (!this.error) this.socket?.sendBinary(data);
    }

    control(request: Request, path: string) {
        if (this.error) return new Response(this.error, {status: 409});
        if (path === "/motion/state" && request.method === "GET") return Response.json({
            appReady: this.appReady, recording: this.recording, interrupted: this.interrupted,
            attachments: this.attachments, resumed: this.resumed, replayAcknowledged: this.replayAck,
            liveBytesHex: this.liveBytes.toString("hex"), heldBytesHex: this.heldBytes.toString("hex"), complete: this.complete,
        });
        if (request.method !== "POST") return new Response(null, {status: 405});
        switch (path) {
        case "/motion/app-ready":
            if (!this.firstAck) break;
            this.appReady = true;
            return new Response(null, {status: 204});
        case "/motion/start":
            if (!this.appReady) break;
            this.recording = true;
            return new Response(null, {status: 204});
        case "/motion/interrupt":
            if (this.liveBytes.toString() !== promptInput || this.interrupted || !this.socket) break;
            this.interrupted = true;
            this.socket.close(1011, "terminal socket lost");
            return new Response(null, {status: 204});
        case "/motion/resume":
            if (!this.interrupted || this.attachments !== 2 || this.resumed || !this.socket) break;
            this.resumed = true;
            this.socket.sendText(JSON.stringify({type: "ready", resumed: true}));
            this.socket.sendBinary(Buffer.from(this.transcript + promptInput + "\x1b[6n"));
            return new Response(null, {status: 204});
        case "/motion/complete":
            if (!this.replayAck || !this.heldBytes.equals(Buffer.from(held))) break;
            this.complete = true;
            return new Response(null, {status: 204});
        }
        return new Response("Premature or unexpected recording checkpoint: " + path, {status: 409});
    }
}
