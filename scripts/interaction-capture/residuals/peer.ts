const outputs = [Buffer.from('\r\x1b[2K\x1b[32m~\x1b[0m # '), Buffer.from('\x1b[32mclear\x1b[0m'), Buffer.from('\r\n')];
const server = Bun.serve({hostname:"127.0.0.1",port:0,fetch(req,server){return server.upgrade(req)?undefined:new Response("no",{status:400})},websocket:{
    open(ws){ws.sendText('{"type":"ready","resumed":false}')},
    message(ws,message){
        if (typeof message === "string") return;
        const kind = Buffer.from(message).toString();
        if(kind==="E") { ws.sendBinary(Buffer.from("x")); return }
        if(kind!=="B") throw Error("bad trigger " + kind);
        const start = Bun.nanoseconds();
        for(const [i, delta] of [0,26000,33000].entries()){
            while(Bun.nanoseconds() < start + delta){}
            ws.sendBinary(outputs[i]);
        }
    }}});
console.log(server.port);
