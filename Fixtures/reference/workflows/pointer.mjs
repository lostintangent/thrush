// Generate expected mouse bytes using the pinned xterm service, including binary legacy coordinates.
export function encodePointer(t, {value:action, pointer:{button,column,row}, modifiers}) {
  const wheel = button === 'wheelUp' || button === 'wheelDown';
  const buttons = {left:0, middle:1, right:2, none:3, wheelUp:4, wheelDown:4};
  const actions = {release:0, press:1, move:32};
  const output = [];
  const data = t.onData(value => output.push(Buffer.from(value, 'utf8')));
  const binary = t.onBinary(value => output.push(Buffer.from(value, 'latin1')));
  t._core.coreMouseService.triggerMouseEvent({
    col:column, row, x:0, y:0, button:buttons[button],
    action:wheel ? Number(button === 'wheelDown') : actions[action],
    ctrl:modifiers.includes('control'), alt:modifiers.includes('alt'), shift:modifiers.includes('shift'),
  });
  data.dispose();
  binary.dispose();
  return Buffer.concat(output);
}

export function pointerInput() {
  const name = 'pointer-input', columns = 240, rows = 8, events = [];
  const sample = (name, fields) => events.push({name, offsetMicroseconds:events.length * 1000, ...fields});
  const mode = (name, control) => sample(name, {bytes:Buffer.from(control).toString('base64'), checkpoint:true});
  const pointer = (name, value, button, column, row, modifiers = []) =>
    sample(name, {action:{kind:'pointer', value, modifiers, pointer:{button,column,row}}});

  // The editor requests tracking. Normal shell sessions keep the pointer for local selection.
  pointer('Shell owns selection', 'press', 'left', 4, 3);
  mode('Editor enables X11 mouse', '\x1b[?1000h');
  pointer('X11 click', 'press', 'left', 4, 3);
  pointer('X11 release with modifiers', 'release', 'right', 7, 2, ['shift','control']);
  pointer('X11 byte above ASCII', 'press', 'middle', 200, 1, ['alt']);
  pointer('X11 column limit', 'press', 'right', 222, 1);
  pointer('Unencodable X11 column', 'press', 'right', 223, 1);
  pointer('X11 ignores motion', 'move', 'left', 5, 3);
  mode('Editor requests SGR drag', '\x1b[?1002;1006h');
  pointer('SGR right button', 'press', 'right', 231, 7);
  pointer('SGR drag', 'move', 'right', 230, 6, ['alt']);
  pointer('SGR button release', 'release', 'right', 230, 6, ['alt']);
  pointer('Drag mode ignores hover', 'move', 'none', 11, 2);
  pointer('Wheel toward history', 'press', 'wheelUp', 11, 2, ['control']);
  pointer('Wheel toward prompt', 'press', 'wheelDown', 11, 2);
  mode('Editor tracks all motion', '\x1b[?1003h');
  pointer('SGR hover', 'move', 'none', 8, 3);
  pointer('Off-grid hit', 'press', 'middle', columns, 2);
  mode('Editor restores shell selection', '\x1b[?1003;1006l');
  pointer('Exit leaves mouse local', 'press', 'left', 2, 1);
  return {name, columns, rows, events};
}
