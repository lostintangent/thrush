// Measures the Wasm ScrollbackBuffer against another class of the same shape, such as one built on
// @xterm/headless, with each measurement in a fresh process and the order shuffled every round.
// Usage: bun js/compare.ts XTERM_MODULE WORKLOAD_DIR OUTPUT.json [ROUNDS]
// Make the workloads with `python3 scripts/comparison/workloads.py WORKLOAD_DIR`.
import { gzipSync, brotliCompressSync } from "node:zlib";
import { readFileSync, writeFileSync } from "node:fs";

const [xtermModule, workloads, outputPath, roundsArgument] = process.argv.slice(2);
const rounds = Number(roundsArgument ?? 5);
const here = new URL(".", import.meta.url).pathname;
const thrushModule = `${here}scrollback.ts`;
const modules = ["embedded.O3", "embedded.Oz", "full.O3"];

type Candidate = { name: string; module: string; wasm?: string; parse?: boolean };
const candidates: Candidate[] = [
  { name: "xterm", module: xtermModule },
  { name: "xterm parse only", module: xtermModule, parse: true },
  ...modules.map((variant) => ({ name: `thrush ${variant}`, module: thrushModule, wasm: `${here}../out/${variant}.wasm` })),
];

const grids = [[80, 24], [240, 60]];
const names = ["shell", "vim", "codex", "ascii", "sgr", "wide", "cursor", "scroll", "region"];
const empty = `${workloads}/empty.bin`;
writeFileSync(empty, "");

type Job = { candidate: Candidate; args: string[]; key: string };
const jobs: Job[] = [];
for (const candidate of candidates) {
  const job = (args: string[]) => jobs.push({ candidate, args, key: [candidate.name, ...args.map((a) => a.replace(`${workloads}/`, ""))].join(" ") });
  for (const [cols, rows] of grids) {
    for (const name of names) job([candidate.parse ? "parse" : "throughput", `${workloads}/${name}.bin`, `${cols}`, `${rows}`, "4096"]);
  }
  if (candidate.parse) continue;
  job(["echo", `${workloads}/shell.bin`]);
  for (const [cols, rows] of grids) {
    for (const name of ["shell", "vim", "codex", "scroll", "sgr", "wide"]) job(["replay", `${workloads}/${name}.bin`, `${cols}`, `${rows}`]);
    job(["memory", `${workloads}/shell.bin`, `${cols}`, `${rows}`, "20"]);
    job(["memory", empty, `${cols}`, `${rows}`, "20"]);
  }
  for (let i = 0; i < 4; i++) job(["start"]);
}

const results = new Map<string, Record<string, number>[]>();
for (let round = 0; round < rounds; round++) {
  const order = [...jobs].sort(() => Math.random() - 0.5);
  for (const { candidate, args, key } of order) {
    const run = Bun.spawnSync([process.execPath, `${here}bench.ts`, candidate.module, ...args], {
      env: { ...process.env, ...(candidate.wasm ? { THRUSH_WASM: candidate.wasm } : {}) },
      stderr: "pipe",
    });
    const line = run.stdout.toString().trim().split("\n").at(-1) ?? "";
    if (run.exitCode !== 0 || !line.startsWith("{")) throw new Error(`${key}: ${run.stderr.toString()}`);
    results.set(key, [...(results.get(key) ?? []), JSON.parse(line)]);
  }
  console.error(`round ${round + 1} of ${rounds}`);
}

function median(values: number[]) {
  const sorted = [...values].sort((a, b) => a - b);
  const middle = sorted.length >> 1;
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

const summary: Record<string, Record<string, number>> = {};
for (const [key, runs] of results) {
  summary[key] = {};
  for (const field of Object.keys(runs[0])) {
    if (typeof runs[0][field] === "number") summary[key][field] = median(runs.map((run) => run[field]));
  }
}

/** Minified bundle bytes, as a compiled Bun server would carry them, plus the module the Wasm side loads. */
async function size(entry: string, wasm?: string) {
  const build = await Bun.build({ entrypoints: [entry], minify: true, target: "bun" });
  const code = new Uint8Array(await build.outputs[0].arrayBuffer());
  const files = [code, ...(wasm ? [new Uint8Array(readFileSync(wasm))] : [])];
  const total = (bytes: (file: Uint8Array) => number) => files.reduce((sum, file) => sum + bytes(file), 0);
  return {
    javascript: code.length,
    wasm: wasm ? readFileSync(wasm).length : 0,
    raw: total((file) => file.length),
    gzip: total((file) => gzipSync(file, { level: 9 }).length),
    brotli: total((file) => brotliCompressSync(file).length),
  };
}

const sizes: Record<string, unknown> = { xterm: await size(xtermModule) };
for (const variant of modules) sizes[`thrush ${variant}`] = await size(thrushModule, `${here}../out/${variant}.wasm`);

const report = { bun: Bun.version, rounds, summary, sizes, runs: Object.fromEntries(results) };
writeFileSync(outputPath, `${JSON.stringify(report, null, 2)}\n`);
console.log(JSON.stringify({ summary, sizes }, null, 1));
