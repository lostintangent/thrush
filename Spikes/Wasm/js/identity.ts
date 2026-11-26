import { join } from "node:path";
import { loadCaptures } from "./captures";
import { ScrollbackBuffer } from "./scrollback";

// Replays every capture after each write and resize, in the Wasm module and natively, and checks
// that both builds send the same bytes. Build NativeReplay first:
//   swift build -c release --product NativeReplay --scratch-path .build-native

const native = join(import.meta.dir, "../.build-native/release/NativeReplay");
const records: Uint8Array[] = [];
const replays: { capture: string; point: number; bytes: Uint8Array }[] = [];
const u16 = (value: number) => new Uint8Array(new Uint16Array([value]).buffer);
const u32 = (value: number) => new Uint8Array(new Uint32Array([value]).buffer);
const letter = (value: string) => new Uint8Array([value.charCodeAt(0)]);

for (const capture of loadCaptures()) {
  const buffer = new ScrollbackBuffer(capture.columns, capture.rows);
  records.push(letter("n"), u16(capture.columns), u16(capture.rows));
  capture.operations.forEach((operation, point) => {
    if ("write" in operation) {
      buffer.write(operation.write);
      records.push(letter("w"), u32(operation.write.length), operation.write);
    } else {
      buffer.resize(...operation.resize);
      records.push(letter("s"), u16(operation.resize[0]), u16(operation.resize[1]));
    }
    replays.push({ capture: capture.name, point, bytes: buffer.replay() });
    records.push(letter("p"));
  });
  buffer.dispose();
}

const child = Bun.spawnSync([native], { stdin: Buffer.concat(records) });
const output = new Uint8Array(child.stdout);
const view = new DataView(output.buffer, output.byteOffset);
let offset = 0;
const mismatches = replays.filter(({ bytes }) => {
  const length = view.getUint32(offset, true);
  const expected = output.subarray(offset + 4, offset + 4 + length);
  offset += 4 + length;
  return !Buffer.from(expected).equals(Buffer.from(bytes));
});
const total = replays.reduce((sum, { bytes }) => sum + bytes.length, 0);
console.log(`${replays.length} replays across ${new Set(replays.map((r) => r.capture)).size} captures, ${total} bytes`);
console.log(mismatches.length === 0 ? "every replay matches native byte for byte" : `${mismatches.length} differ:`);
for (const { capture, point } of mismatches.slice(0, 20)) console.log(`  ${capture} after operation ${point}`);
process.exit(mismatches.length === 0 && offset === output.length ? 0 : 1);
