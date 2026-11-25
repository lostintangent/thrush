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
const { Terminal: BrowserTerminal } = server('@xterm/xterm');
const { ThemeService } = await import(server.resolve('@xterm/xterm/src/browser/services/ThemeService.ts'));
const browser = new BrowserTerminal();
const handleColorEvent = browser._core._handleColorEvent;
browser.dispose();
const { emulatorOptions, loadUnicode11 } = await import(resolve(checkout, 'src/features/terminal/model/emulator.ts'));
export const reference = {toyBoxRevision, packages, scrollback:emulatorOptions.scrollback, unicode:'11',
  colorReports:'@xterm/xterm CoreBrowserTerminal._handleColorEvent and ThemeService'};

export function terminal(columns, rows) {
  const t = new Terminal({ ...emulatorOptions, cols:columns, rows });
  loadUnicode11(t);
  // The server's headless package emits parsed color events, but only the browser answers them.
  // Attach the pinned browser's own report handler and theme service to the server's ordered stream.
  const core = t._core;
  const colors = core._register(new ThemeService(core.optionsService));
  const receiver = { _themeService:colors, coreService:core.coreService };
  core._register(core._inputHandler.onColor(event => handleColorEvent.call(receiver, event)));
  return t;
}

export function write(t, bytes) {
  return new Promise(done => t.write(bytes, done));
}


const ansiNames = ['black', 'red', 'green', 'yellow', 'blue', 'magenta', 'cyan', 'white',
  'brightBlack', 'brightRed', 'brightGreen', 'brightYellow', 'brightBlue', 'brightMagenta', 'brightCyan', 'brightWhite'];

export function applyPalette(t, palette) {
  assert.equal(palette.ansi.length, ansiNames.length);
  const theme = { foreground:palette.foreground, background:palette.background };
  ansiNames.forEach((name, index) => theme[name] = palette.ansi[index]);
  t.options.theme = theme;
}
