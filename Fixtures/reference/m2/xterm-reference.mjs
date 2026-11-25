import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';

const checkout = resolve(process.argv[2] ?? '../toy-box');
const toyBoxRevision = 'b9d0eca3c5f4e9036e58327ba633eff52474bb92';
assert.equal(execFileSync('git', ['-C', checkout, 'rev-parse', 'HEAD'], {encoding:'utf8'}).trim(), toyBoxRevision);
export const server = createRequire(resolve(checkout, 'package.json'));
const packages = Object.fromEntries(['@xterm/headless', '@xterm/xterm', '@xterm/addon-unicode11'].map(
  name => [name, server(name + '/package.json').version]
));
assert.deepEqual(packages, {'@xterm/headless':'6.0.0', '@xterm/xterm':'6.0.0', '@xterm/addon-unicode11':'0.9.0'});
const { Terminal } = server('@xterm/headless');
const { emulatorOptions, loadUnicode11 } = await import(resolve(checkout, 'src/features/terminal/model/emulator.ts'));
export const reference = {toyBoxRevision, packages, scrollback:emulatorOptions.scrollback, unicode:'11'};

export function terminal(columns, rows) {
  const t = new Terminal({ ...emulatorOptions, cols:columns, rows });
  loadUnicode11(t);
  return t;
}

export function write(t, bytes) {
  return new Promise(done => t.write(bytes, done));
}
