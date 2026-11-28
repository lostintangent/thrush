// ThrushCore's side of the harness: one long-lived ThrushConformance process that replays cases.
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';

/** Serializes a case for Swift: writes as base64 and xterm's checkpoints as expectations. */
export function encodeCase(testCase, expected) {
  return {
    name: testCase.name, subject: testCase.subject, size: testCase.size,
    ...(testCase.palette && { palette: testCase.palette }),
    steps: withEnd(testCase.steps).map(step => step.write ? { write: Buffer.from(step.write).toString('base64') } : step),
    ...(expected && { expected }),
  };
}

export const withEnd = steps => steps.at(-1)?.checkpoint === 'end' ? steps : [...steps, { checkpoint: 'end' }];

export class Thrush {
  #process;
  #lines;
  #pending = [];
  #executable;

  constructor(executable) {
    this.#executable = executable;
    this.#start();
  }

  #start() {
    this.#process = spawn(this.#executable, [], { stdio: ['pipe', 'pipe', 'pipe'] });
    let stderr = '';
    this.#process.stderr.on('data', data => stderr += data);
    this.#lines = createInterface({ input: this.#process.stdout });
    this.#lines.on('line', line => this.#pending.shift()?.resolve(JSON.parse(line)));
    this.#process.on('exit', (code, signal) => {
      const crash = { crashed: `${signal ?? `exit ${code}`}${stderr ? `: ${stderr.trim().split('\n').slice(-3).join(' ')}` : ''}` };
      for (const request of this.#pending.splice(0)) request.resolve(crash);
      this.#process = undefined;
    });
  }

  /** Where Thrush differs from the expected checkpoints, as `{ differences }`, or `{ crashed }` when ThrushCore traps. */
  run(testCase, expected) {
    return this.request(encodeCase(testCase, expected));
  }

  /** Sends one request ConformanceServer.swift reads, and resolves with its result or `{ crashed }`. */
  request(request) {
    if (!this.#process) this.#start();
    return new Promise(resolve => {
      this.#pending.push({ resolve });
      this.#process.stdin.write(JSON.stringify(request) + '\n');
    });
  }

  close() {
    this.#process?.stdin.end();
  }
}
