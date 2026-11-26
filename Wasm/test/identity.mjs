import { spawnSync } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { Terminal } from "../out/package/index.js";

// Checks that ThrushCore behaves the same in WebAssembly as natively. Both builds write and resize a
// terminal through every program capture in the reference fixtures, and after every step must
// return the same reply and the same replay, byte for byte.
// Usage: bun test/identity.mjs <path to NativeReplay>

const fixtures = new URL("../../Fixtures/reference/", import.meta.url).pathname;
const captures = readdirSync(fixtures, { recursive: true })
  .filter((path) => path.endsWith(".capture.json"))
  .sort()
  .map((path) => ({ path, ...JSON.parse(readFileSync(join(fixtures, path), "utf8")) }))
  .filter((capture) => capture.events);
const native = spawnSync(process.argv[2], captures.map(({ path }) => join(fixtures, path)), { maxBuffer: 2 ** 31 });
if (native.status !== 0) throw new Error(`NativeReplay failed: ${native.error ?? native.stderr}`);

let offset = 0;
let steps = 0;
const mismatches = [];
const next = () => {
  const length = native.stdout.readUInt32LE(offset);
  offset += 4 + length;
  return native.stdout.subarray(offset - length, offset);
};
for (const capture of captures) {
  const terminal = new Terminal(capture.columns, capture.rows);
  // A write that asks nothing returns undefined, where native ThrushCore returns an empty reply.
  const check = (reply, index) => {
    steps += 1;
    const expected = next();
    const replyAgrees = reply === undefined ? expected.length === 0 : reply.length > 0 && expected.equals(reply);
    const replayAgrees = next().equals(terminal.replay());
    if (!replyAgrees || !replayAgrees) mismatches.push(`${capture.path} after event ${index}`);
  };
  capture.events.forEach((event, index) => {
    if (event.resize) {
      terminal.resize(event.resize.columns, event.resize.rows);
      check(undefined, index);
    }
    if (event.bytes) check(terminal.write(Buffer.from(event.bytes, "base64")), index);
  });
  terminal.dispose();
}

if (offset !== native.stdout.length) mismatches.push("NativeReplay took more steps than the Wasm module");
console.log(`${steps} steps through ${captures.length} captures`);
for (const mismatch of mismatches.slice(0, 20)) console.log(`differs from native: ${mismatch}`);
process.exit(mismatches.length === 0 ? 0 : 1);
