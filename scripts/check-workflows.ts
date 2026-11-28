// Drive the recordings through the same Apple WebSocket client as both native hosts.
import assert from "node:assert/strict";
import { serveWorkflow } from "./workflow-peer.ts";

const client = process.argv[2];
if (!client) throw Error("Usage: bun scripts/check-workflows.ts PATH_TO_THRUSH_LOOPBACK_CHECK");
const workflows = {shell:"shell-workflow", vim:"vim-resume", codex:"codex-session"} as const;
for (const name of ["shell","vim","codex"] as const) {
    const {server, completed} = await serveWorkflow(name);
    const child = Bun.spawn([client, "--workflow", workflows[name], server.url.origin], {
        stdout:"inherit", stderr:"inherit",
    });
    const deadline = Promise.withResolvers<never>();
    const timeout = setTimeout(() => deadline.reject(Error("Timed out checking the " + name + " workflow")), 90_000);
    try {
        const exchange = Promise.all([
            completed, child.exited.then(code => assert.equal(code, 0, "Apple client failed for " + name)),
        ]);
        const [result] = await Promise.race([exchange, deadline.promise]);
        assert.equal(result.attachments, name === "vim" ? 2 : 1);
    } finally {
        clearTimeout(timeout);
        child.kill();
        await server.stop(true);
    }
}
