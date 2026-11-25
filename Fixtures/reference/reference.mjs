// The reference terminal that conformance cases and fixtures come from: headless.mjs, plus what the
// pinned browser package adds. The browser answers color queries, and its TypeScript sources define
// keyboard, clipboard and selection behavior. Bun runs those sources directly.
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { headless } from './headless.mjs';

export { options, packages, reference } from './headless.mjs';

const require = createRequire(import.meta.url);
const sources = join(dirname(require.resolve('@xterm/xterm/package.json')), 'src');

// The sources import one another from their own root, as in `common/Color`, which tsconfig.json maps.
/** Imports one of the browser package's TypeScript sources, such as `common/input/Keyboard`. */
export function source(path) {
  return import(join(sources, `${path}.ts`));
}

const { ThemeService } = await source('browser/services/ThemeService');
const { Terminal: BrowserTerminal } = require('@xterm/xterm');
const browser = new BrowserTerminal();
const handleColorEvent = browser._core._handleColorEvent;
browser.dispose();

/** A reference terminal that answers color queries the way the browser does, from `palette` when given. */
export function terminal(columns, rows, palette) {
  const t = headless(columns, rows);
  // The headless package parses color queries, but only the browser package answers them.
  const core = t._core;
  const colors = core._register(new ThemeService(core.optionsService));
  const receiver = { _themeService: colors, coreService: core.coreService };
  core._register(core._inputHandler.onColor(event => handleColorEvent.call(receiver, event)));
  if (palette) applyPalette(t, palette);
  return t;
}

const ansiNames = ['black', 'red', 'green', 'yellow', 'blue', 'magenta', 'cyan', 'white',
  'brightBlack', 'brightRed', 'brightGreen', 'brightYellow', 'brightBlue', 'brightMagenta', 'brightCyan', 'brightWhite'];

/** Sets the colors the terminal reports, as `{ foreground, background, ansi: [16 colors] }`. */
export function applyPalette(t, palette) {
  assert.equal(palette.ansi.length, ansiNames.length);
  const theme = { foreground: palette.foreground, background: palette.background };
  ansiNames.forEach((name, index) => theme[name] = palette.ansi[index]);
  t.options.theme = theme;
}

/** Writes bytes through the public write path, resolving once the terminal has parsed them. */
export function write(t, bytes) {
  return new Promise(done => t.write(bytes, done));
}
