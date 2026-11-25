// Named native inputs for the accessory, modifier latch and hardware keyboard.
// The shared generator obtains every expected byte from xterm's Mac keyboard evaluator.
export function hardwareKeys() {
  const events = [];
  const append = (name, fields) => events.push({name, offsetMicroseconds:events.length * 1000, ...fields});
  for (const application of [false, true]) {
    const mode = application ? 'application' : 'normal';
    const csi = application ? '\x1b[?1h' : '\x1b[?1l';
    append('Use ' + mode + ' cursor keys', {bytes:Buffer.from(csi).toString('base64'), checkpoint:true});
    for (const key of ['up','down','left','right','home','end','pageUp','pageDown','delete',
                       'escape','enter','tab','backspace']) {
      for (const modifiers of [[], ['shift'], ['alt'], ['control'], ['shift','alt','control']]) {
        append([mode, ...modifiers, key].join(' '), {action:{kind:'key', value:key, modifiers}});
      }
    }
  }
  for (const value of ['a','c','d','t','z',' ','3','4','5','6','7','8','[','\\',']']) {
    append('Control chord ' + JSON.stringify(value), {action:{kind:'key', value, modifiers:['control']}});
  }
  return {name:'hardware-keys', columns:80, rows:24, events};
}
