// Times one ScrollbackBuffer-shaped class in this process and prints one JSON line.
// Usage: bun js/bench.ts MODULE MEASURE [ARGS…], where MODULE exports `ScrollbackBuffer`.
//   throughput WORKLOAD COLS ROWS CHUNK   write every chunk, then wait for the last callback
//   parse WORKLOAD COLS ROWS CHUNK        the same through xterm's synchronous parser, for context
//   echo WORKLOAD                         time from writing one byte to its callback, while idle
//   replay WORKLOAD COLS ROWS             build the replay after the whole workload
//   start                                 load the module, then make a buffer and write to it
//   memory WORKLOAD COLS ROWS COUNT       resident and heap bytes for COUNT buffers holding WORKLOAD
import { readFileSync } from "node:fs";

const started = performance.now();
const [modulePath, measure, ...args] = process.argv.slice(2);
const { ScrollbackBuffer } = await import(modulePath);
const loaded = performance.now();

type Buffer = {
  write(data: Uint8Array | string, callback?: () => void): void;
  resize(cols: number, rows: number): void;
  replay(): Uint8Array;
  dispose(): void;
};

function chunks(workload: string, size: number) {
  const bytes = new Uint8Array(readFileSync(workload));
  const parts: Uint8Array[] = [];
  for (let offset = 0; offset < bytes.length; offset += size || bytes.length) {
    parts.push(bytes.subarray(offset, offset + (size || bytes.length)));
  }
  return { parts, length: bytes.length };
}

/** Writes every part the way Toy Box's runtime does, resolving once the last has been parsed. */
function feed(buffer: Buffer, parts: Uint8Array[]) {
  return new Promise<void>((resolve) => {
    if (parts.length === 0) return resolve();
    parts.forEach((part, i) => buffer.write(part, i === parts.length - 1 ? resolve : undefined));
  });
}

function percentile(values: number[], p: number) {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1)];
}

function gc() {
  Bun.gc(true);
  Bun.gc(true);
}

const create = (cols: number, rows: number): Buffer => new ScrollbackBuffer(cols, rows);
const result: Record<string, unknown> = { measure, args };

switch (measure) {
  case "throughput":
  case "parse": {
    const [workload, cols, rows, size] = [args[0], ...args.slice(1).map(Number)];
    const { parts, length } = chunks(workload, size);
    const passes: number[] = [];
    for (let i = 0; i < 8; i++) {
      const buffer = create(cols, rows);
      const start = performance.now();
      if (measure === "parse") {
        const core = (buffer as unknown as { _core: { writeSync(data: Uint8Array): void } })._core;
        for (const part of parts) core.writeSync(part);
      } else {
        await feed(buffer, parts);
      }
      const elapsed = performance.now() - start;
      if (i >= 3) passes.push(elapsed);
      buffer.dispose();
    }
    result.ms = percentile(passes, 50);
    result.mibPerSecond = length / (1 << 20) / (result.ms as number / 1000);
    break;
  }
  case "echo": {
    const buffer = create(80, 24);
    await feed(buffer, chunks(args[0], 4096).parts);
    const samples: number[] = [];
    for (let i = 0; i < 220; i++) {
      await Bun.sleep(2);
      const start = performance.now();
      await new Promise<void>((resolve) => buffer.write("a", resolve));
      if (i >= 20) samples.push((performance.now() - start) * 1000);
    }
    result.p50Microseconds = percentile(samples, 50);
    result.p95Microseconds = percentile(samples, 95);
    break;
  }
  case "replay": {
    const [workload, cols, rows] = [args[0], ...args.slice(1).map(Number)];
    const buffer = create(cols, rows);
    await feed(buffer, chunks(workload, 4096).parts);
    const samples: number[] = [];
    let bytes = 0;
    for (let i = 0; i < 28; i++) {
      const start = performance.now();
      bytes = buffer.replay().length;
      if (i >= 3) samples.push(performance.now() - start);
    }
    result.p50Ms = percentile(samples, 50);
    result.p95Ms = percentile(samples, 95);
    result.bytes = bytes;
    break;
  }
  case "start": {
    const buffer = create(80, 24);
    await new Promise<void>((resolve) => buffer.write("$ ", resolve));
    result.loadMs = loaded - started;
    result.firstWriteMs = performance.now() - loaded;
    break;
  }
  case "memory": {
    const [workload, cols, rows, count] = [args[0], ...args.slice(1).map(Number)];
    const { parts } = chunks(workload, 4096);
    const warm = create(cols, rows);
    await feed(warm, parts);
    warm.dispose();
    gc();
    const before = process.memoryUsage();
    const buffers: Buffer[] = [];
    for (let i = 0; i < count; i++) {
      const buffer = create(cols, rows);
      await feed(buffer, parts);
      buffers.push(buffer);
    }
    gc();
    const after = process.memoryUsage();
    result.residentPerShell = (after.rss - before.rss) / count;
    result.heapPerShell = (after.heapUsed - before.heapUsed) / count;
    result.arrayBuffersPerShell = (after.arrayBuffers - before.arrayBuffers) / count;
    result.replayBytes = buffers[0].replay().length;
    break;
  }
  default:
    throw new Error(`Unknown measure ${measure}`);
}

process.stdout.write(`${JSON.stringify(result)}\n`);
process.exit(0);
