// The pinned reference emulator: the exact npm packages in package.json, started with the options below
// and Unicode 11 cell widths. This part loads under Node or Bun. reference.mjs adds what the browser
// package contributes.
//
// Install it with `bun install --cwd Fixtures/reference --frozen-lockfile`.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);

export const packages = JSON.parse(readFileSync(new URL('package.json', import.meta.url), 'utf8')).dependencies;
for (const [name, version] of Object.entries(packages)) {
  let installed;
  try { installed = require(`${name}/package.json`).version; } catch {}
  assert.equal(installed, version, `The reference needs ${name} ${version}. `
    + 'Install it with `bun install --cwd Fixtures/reference --frozen-lockfile`.');
}

/** The options every reference terminal starts with. */
export const options = { scrollback: 1000, allowProposedApi: true };

/** How fixtures name the reference they come from. */
export const reference = { packages, options, unicode: '11' };

export const { Terminal } = require('@xterm/headless');
export const { Unicode11Addon } = require('@xterm/addon-unicode11');

/** A headless reference terminal. `overrides` replaces options, such as the comparison's history length. */
export function headless(columns, rows, overrides = {}) {
  const t = new Terminal({ ...options, ...overrides, cols: columns, rows });
  t.loadAddon(new Unicode11Addon());
  t.unicode.activeVersion = reference.unicode;
  return t;
}
