import { readFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";

/** What a PTY sent a terminal server, in order: chunks of output and the resizes between them. */
export type Capture = {
  name: string;
  columns: number;
  rows: number;
  operations: ({ write: Uint8Array } | { resize: [columns: number, rows: number] })[];
};

const fixtures = join(dirname(new URL(import.meta.url).pathname), "../../../Fixtures/reference");

/** Every program capture in the repository's reference fixtures. */
export function loadCaptures(): Capture[] {
  const paths = new Bun.Glob("**/*.capture.json").scanSync(fixtures);
  return Array.from(paths, (path) => loadCapture(join(fixtures, path)))
    .filter((capture) => capture !== undefined)
    .sort((a, b) => a.name.localeCompare(b.name));
}

/** The capture at `path`, or nothing for a fixture that records replays rather than a program. */
export function loadCapture(path: string): Capture | undefined {
  const { columns, rows, events } = JSON.parse(readFileSync(path, "utf8"));
  if (!events) return undefined;
  const operations: Capture["operations"] = [];
  for (const event of events) {
    if (event.resize) operations.push({ resize: [event.resize.columns, event.resize.rows] });
    if (event.bytes) operations.push({ write: Uint8Array.fromBase64(event.bytes) });
  }
  const folder = basename(dirname(path));
  return { name: `${folder}/${basename(path, ".capture.json")}`, columns, rows, operations };
}
